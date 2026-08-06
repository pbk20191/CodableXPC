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

    /// Handles one inbound request: `(seq, body, reply)`.
    ///
    /// The `seq` is the envelope's correlation id. It is passed in because Phase B's
    /// cancellation is a notification naming a `requestSeq`: without the id, a
    /// receiver cannot map an inbound `invocationCancelled` onto the execution it
    /// started.
    public typealias RequestHandler =
        @Sendable (UInt64, Packet.Payload, @escaping @Sendable (Packet.Payload) -> Void) -> Void
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

    /// Internal for tests: teardown has run, from either our own `cancel` or the
    /// raw transport's death channel.
    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Internal for tests: an `activate()` is parked awaiting `helloAck`.
    var hasOutstandingHelloWaiter: Bool { lock.withLock { helloWaiter != nil } }

    /// Internal for tests: requests registered and not yet resolved.
    var pendingRequestCount: Int { get async { await requests.pendingCount } }

    public init(debugName: String, role: TransportRole, rawTransport: RawTransportProtocol) {
        self.debugName = debugName
        self.role = role
        self.rawTransport = rawTransport
        rawTransport.setPacketHandler { [weak self] packet in
            self?.handleReceived(packet: packet)
        }
        // The death channel. Without it a request whose peer crashed is
        // indistinguishable from one whose peer is slow, and this protocol has no
        // timeout to fall back on -- it would wait forever.
        rawTransport.setCancellationHandler { [weak self] reason in
            self?.handleRawTransportCancellation(reason: reason)
        }
    }

    /// The pipe died from the far side. Fail everything, but do *not* call
    /// `rawTransport.cancel` -- the raw transport is the thing telling us it is
    /// already gone, and re-entering it would just echo.
    private func handleRawTransportCancellation(reason: String) {
        guard beginCancelling() else { return }
        failEverything(reason: reason)
    }

    /// Claim the one-shot teardown. Returns `false` if teardown already ran, so our
    /// own `cancel` and a remote death cannot double-fire.
    private func beginCancelling() -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
    }

    private func failEverything(reason: String) {
        resumeHelloWaiter(with: .failure(SetupError("transport cancelled: \(reason)")))
        Task { await requests.failAll(with: .transportCancelled(message: reason)) }
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
            // One waiter slot, so a concurrent second activate() must not overwrite the
            // first: the displaced continuation would never be resumed and its caller
            // would hang forever. Fail the newcomer instead.
            let occupied: Bool = lock.withLock {
                guard helloWaiter == nil else { return true }
                helloWaiter = continuation
                return false
            }
            guard !occupied else {
                continuation.resume(returning: .failure(
                    SetupError("activate() is already in progress and awaiting helloAck")
                ))
                return
            }
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

    /// Reserve a correlation id. Split from `sendRequest` so a caller can register
    /// cancellation bookkeeping against the id before the request is in flight.
    ///
    /// Ids come from a per-transport monotonic counter and are unique within a
    /// transport, not globally. Reserving one and never sending it is harmless: no
    /// state is allocated until `sendRequest` registers a waiter.
    public func allocateSeq() -> UInt64 {
        lock.withLock {
            defer { _nextSeq += 1 }
            return _nextSeq
        }
    }

    /// Send a request under a `seq` obtained from `allocateSeq()` and await its reply.
    ///
    /// Reusing a `seq` that is still in flight fails the *new* caller rather than
    /// displacing the old one; see `RequestTable.waitForReply`.
    public func sendRequest(seq: UInt64, _ payload: Packet.Payload) async -> RequestTable.Outcome {
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
        guard beginCancelling() else { return }
        rawTransport.cancel(reason: reason)
        failEverything(reason: reason)
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
            guard let negotiated = negotiatedVersion,
                  packet.header.version == negotiated
            else {
                // Cancel rather than drop. Dropping is strictly worse: the protocol has
                // no timeout, so a silently discarded request hangs the sender forever,
                // and interpreting a body under the wrong version's rules is exactly
                // what the version field exists to prevent.
                let expected = negotiatedVersion.map { "\($0.rawValue)" } ?? "none negotiated"
                cancel(reason: """
                    protocol version mismatch: peer sent \(packet.header.kind) at version \
                    \(packet.header.version.rawValue), expected \(expected)
                    """)
                return
            }
            handleNegotiated(packet)
        }
    }

    private func handleNegotiated(_ packet: Packet) {
        switch packet.header.kind {
        case .request:
            guard let seq = packet.header.seq, let handler = inboundRequestHandler else { return }
            handler(seq, packet.payload) { [weak self] reply in
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
        // A second hello on a live session is ignored, not honoured. Without this a
        // buggy or hostile peer could kill an established session mid-flight by
        // sending an unsatisfiable hello, since the no-overlap path cancels.
        guard lock.withLock({ _negotiatedVersion }) == nil else { return }

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
