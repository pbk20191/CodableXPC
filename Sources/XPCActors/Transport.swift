import Foundation
import XPC

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum TransportRole: Sendable {
    /// Dials out and sends `hello`.
    case initiator
    /// Listens and answers `hello` with `helloAck`.
    case responder
}

/// Packet framing, version negotiation, and request correlation.
///
/// Every packet is sent one-way; a reply is an ordinary inbound packet matched by
/// `seq`. The XPC reply channel is never used, because it binds a response to the
/// requester and would make it impossible for a listener-side peer to originate a
/// call.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class Transport: @unchecked Sendable {

    public typealias RequestHandler =
        @Sendable (Packet.Payload, @escaping @Sendable (Packet.Payload) -> Void) -> Void
    public typealias NotificationHandler = @Sendable (Packet.Payload) -> Void

    private let debugName: String
    private let role: TransportRole
    private let rawTransport: RawTransportProtocol
    private let requests = RequestTable()

    private let lock = NSLock()
    private var _negotiatedVersion: ProtocolVersion?
    private var _nextSeq: UInt64 = 1
    private var helloWaiter: CheckedContinuation<Result<ProtocolVersion, SetupError>, Never>?
    private var cancelled = false

    private var _inboundRequestHandler: RequestHandler?
    private var _inboundNotificationHandler: NotificationHandler?

    public var inboundRequestHandler: RequestHandler? {
        get { lock.withLock { _inboundRequestHandler } }
        set { lock.withLock { _inboundRequestHandler = newValue } }
    }

    public var inboundNotificationHandler: NotificationHandler? {
        get { lock.withLock { _inboundNotificationHandler } }
        set { lock.withLock { _inboundNotificationHandler = newValue } }
    }

    public var negotiatedVersion: ProtocolVersion? {
        lock.withLock { _negotiatedVersion }
    }

    public init(debugName: String, role: TransportRole, rawTransport: RawTransportProtocol) {
        self.debugName = debugName
        self.role = role
        self.rawTransport = rawTransport
        rawTransport.setPacketHandler { [weak self] packet in
            self?.handleReceived(packet: packet)
        }
    }

    // MARK: activation

    /// Bring the pipe up. For an initiator this performs the `hello` exchange and
    /// does not return until a version is agreed; for a responder it returns as
    /// soon as the pipe is live, and the version is set when `hello` arrives.
    public func activate() async throws(SetupError) {
        do {
            try rawTransport.activate()
        } catch {
            throw SetupError("could not activate transport: \(error)")
        }
        guard role == .initiator else { return }

        let hello: Packet
        do {
            hello = try makePacket(kind: .hello, seq: nil,
                                   payload: Packet.Payload(encoding: HelloBody.current))
        } catch {
            throw SetupError("could not encode hello: \(error)")
        }

        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<ProtocolVersion, SetupError>, Never>) in
            lock.withLock { helloWaiter = continuation }
            do {
                try rawTransport.send(packet: hello)
            } catch {
                resumeHelloWaiter(with: .failure(SetupError("could not send hello: \(error)")))
            }
        }
        // `_negotiatedVersion` is written in `handleHelloAck`, before the waiter is
        // resumed -- not here. That is what keeps the write ordered before any
        // packet the peer sends immediately after its `helloAck`.
        if case .failure(let error) = result {
            throw error
        }
    }

    // MARK: sending

    public func sendRequest(_ payload: Packet.Payload) async -> RequestTable.Outcome {
        let seq = nextSeq()
        let packet: Packet
        do {
            packet = try makeNegotiatedPacket(kind: .request, seq: seq, payload: payload)
        } catch {
            // Typed throws: `error` is a RawTransportError here.
            return .failed(.transportCancelled(message: "\(error)"))
        }
        // Bound to an explicitly typed local rather than passed as a literal: on Swift 6.4
        // a throwing closure literal cannot be converted to a `throws(RawTransportError)`
        // parameter. Do not inline this.
        let send: () throws(RawTransportError) -> Void = { try self.rawTransport.send(packet: packet) }
        return await requests.waitForReply(seq: seq, sending: send)
    }

    public func sendNotification(_ payload: Packet.Payload) throws(RawTransportError) {
        let packet = try makeNegotiatedPacket(kind: .notification, seq: nil, payload: payload)
        try rawTransport.send(packet: packet)
    }

    public func cancel(reason: String) {
        let alreadyCancelled: Bool = lock.withLock {
            defer { cancelled = true }
            return cancelled
        }
        guard !alreadyCancelled else { return }
        rawTransport.cancel(reason: reason)
        resumeHelloWaiter(with: .failure(SetupError("transport cancelled: \(reason)")))
        Task { await requests.failAll(with: .transportCancelled(message: reason)) }
    }

    // MARK: receiving

    /// Internal for tests; the raw transport calls this for every inbound packet.
    func handleReceived(packet: Packet) {
        switch packet.header.kind {
        case .hello:
            handleHello(packet)
        case .helloAck:
            handleHelloAck(packet)
        case .request, .reply, .notification:
            guard packet.header.version == negotiatedVersion else { return }
            handleNegotiated(packet)
        }
    }

    private func handleNegotiated(_ packet: Packet) {
        switch packet.header.kind {
        case .request:
            guard let seq = packet.header.seq, let handler = inboundRequestHandler else { return }
            handler(packet.payload) { [weak self] reply in
                self?.sendReply(seq: seq, payload: reply)
            }
        case .reply:
            guard let seq = packet.header.seq else { return }
            Task { await requests.complete(seq: seq, with: .reply(packet.payload)) }
        case .notification:
            inboundNotificationHandler?(packet.payload)
        case .hello, .helloAck:
            break
        }
    }

    private func sendReply(seq: UInt64, payload: Packet.Payload) {
        guard let packet = try? makeNegotiatedPacket(kind: .reply, seq: seq, payload: payload)
        else { return }
        try? rawTransport.send(packet: packet)
    }

    private func handleHello(_ packet: Packet) {
        guard role == .responder else { return }

        let negotiated: ProtocolVersion? = (try? packet.payload.decode(as: HelloBody.self))
            .flatMap { ProtocolVersion.negotiate(peerMin: $0.min, peerMax: $0.max) }

        guard let version = negotiated else {
            // Tell the peer before dying. A responder that merely cancels leaves the
            // initiator's activate() suspended forever: this protocol has no timeout,
            // so an absent reply is indistinguishable from a slow one.
            sendHelloRejection()
            cancel(reason: "no common protocol version")
            return
        }
        guard let ack = try? makePacket(
            kind: .helloAck, seq: nil,
            payload: Packet.Payload(encoding: HelloAckBody(version: version.rawValue))
        ) else {
            sendHelloRejection()
            cancel(reason: "could not encode helloAck")
            return
        }
        // Store before sending, so a packet the peer sends immediately on receiving
        // this ack cannot arrive before our own version gate knows the answer.
        lock.withLock { _negotiatedVersion = version }
        try? rawTransport.send(packet: ack)
    }

    /// A `helloAck` carrying the reserved sentinel, meaning "no version in common".
    private func sendHelloRejection() {
        guard let rejection = try? makePacket(
            kind: .helloAck, seq: nil,
            payload: Packet.Payload(encoding: HelloAckBody(version: ProtocolVersion.unnegotiated.rawValue))
        ) else { return }
        try? rawTransport.send(packet: rejection)
    }

    private func handleHelloAck(_ packet: Packet) {
        guard role == .initiator else { return }
        guard let body = try? packet.payload.decode(as: HelloAckBody.self) else {
            resumeHelloWaiter(with: .failure(SetupError("malformed helloAck")))
            return
        }
        let version = ProtocolVersion(rawValue: body.version)
        guard version != .unnegotiated else {
            resumeHelloWaiter(
                with: .failure(SetupError("peer rejected the connection: no common protocol version"))
            )
            return
        }
        guard version >= ProtocolVersion.minimumSupported,
              version <= ProtocolVersion.current
        else {
            resumeHelloWaiter(
                with: .failure(SetupError("peer chose unsupported version \(body.version)"))
            )
            return
        }
        lock.withLock { _negotiatedVersion = version }
        resumeHelloWaiter(with: .success(version))
    }

    private func resumeHelloWaiter(with result: Result<ProtocolVersion, SetupError>) {
        let waiter: CheckedContinuation<Result<ProtocolVersion, SetupError>, Never>? =
            lock.withLock {
                defer { helloWaiter = nil }
                return helloWaiter
            }
        waiter?.resume(returning: result)
    }

    // MARK: helpers

    private func nextSeq() -> UInt64 {
        lock.withLock {
            defer { _nextSeq += 1 }
            return _nextSeq
        }
    }

    private func makePacket(
        kind: PacketKind, seq: UInt64?, payload: Packet.Payload
    ) throws -> Packet {
        guard let header = PacketHeader(version: .unnegotiated, kind: kind, seq: seq) else {
            throw SetupError("invalid handshake header for \(kind)")
        }
        return Packet(header: header, payload: payload)
    }

    private func makeNegotiatedPacket(
        kind: PacketKind, seq: UInt64?, payload: Packet.Payload
    ) throws(RawTransportError) -> Packet {
        guard let version = negotiatedVersion else {
            throw RawTransportError.rawTransportCancelled(message: "no version negotiated yet")
        }
        guard let header = PacketHeader(version: version, kind: kind, seq: seq) else {
            throw RawTransportError.rawTransportCancelled(message: "invalid header for \(kind)")
        }
        return Packet(header: header, payload: payload)
    }
}
