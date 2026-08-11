import Foundation
import XPC

/// Which end of the pipe this is.
///
/// It no longer selects any behaviour. Both roles now do the same thing on
/// `activate()`, because there is no handshake to be asymmetric about: an initiator
/// dialled out and a responder was accepted, and that is the whole of the difference.
/// Kept because it is still a true and useful fact about a transport -- every debug
/// message and every future asymmetry wants it -- not because anything branches on it.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public enum TransportRole: Sendable {
    /// Dialled out to a peer.
    case initiator
    /// Accepted an inbound connection.
    case responder
}

/// The session on the receiving end of a transport.
///
/// Apple's `InboundSessionProtocol`, which is class-bound and has six requirements:
/// `handleReceivedRequest`, `handleReceivedNotification`, `handleActorShared`,
/// `handleTransportCancellation`, `actorSystem` and `isBidirectional`. Only the one this
/// slice has a caller for is here; the rest arrive with the inbound execution path, and
/// adding a requirement nothing invokes would only be a stub with a protocol around it.
///
/// It exists at all so that ``Transport`` can tell its session the pipe is gone without
/// knowing what a session is -- and so it can hold it **weakly**, which a stored closure
/// could not do: a session holds its transport strongly, so a closure capturing the
/// session would make the pair immortal.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public protocol InboundSession: AnyObject, Sendable {
    /// The pipe died, from either end. Apple's does two things -- cancel the invocation
    /// executions this process started for the peer, and complete the cancellation,
    /// which empties the exported-actor table.
    func handleTransportCancellation()
}

/// Packet framing and request correlation.
///
/// Every packet is sent one-way; a response is an ordinary inbound packet matched by
/// the envelope's `headerID`. The XPC reply channel is never used, because it binds a
/// response to the requester and would make it impossible for a listener-side peer to
/// originate a call. Apple's `XPCRawTransport.send(packet:)` sends all three kinds
/// through the one-way `XPCSession.send(message:)` for the same reason.
///
/// There is no version negotiation. `hello` and `helloAck` do not exist in
/// `XPCDistributed`, so sending them would put a packet category on the wire that no
/// real peer can decode. What that costs is written down where the version key used to
/// be, in `EnvelopeKey`.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public final class Transport: @unchecked Sendable {

    /// Handles one inbound request: `(id, body, reply)`.
    ///
    /// The `id` is the envelope's correlation id. It is passed in because cancellation
    /// is a notification naming a request id: without it, a receiver cannot map an
    /// inbound `invocationCancelled` onto the execution it started.
    public typealias RequestHandler =
        @Sendable (UInt64, Packet.Payload, @escaping @Sendable (Packet.Payload) -> Void) -> Void
    public typealias NotificationHandler = @Sendable (Packet.Payload) -> Void

    private let debugName: String
    public let role: TransportRole
    private let rawTransport: RawTransportProtocol
    private let requests = RequestTable()

    private let lock = NSLock()
    private var _nextSeq: UInt64 = 1
    private var cancelled = false

    private var _inboundRequestHandler: RequestHandler?
    private var _inboundNotificationHandler: NotificationHandler?
    private weak var _inboundSession: (any InboundSession)?

    /// The session speaking over this transport, held **weakly**.
    ///
    /// Apple's `Transport.(inboundSession)` is a weak `InboundSessionProtocol?` that
    /// `Session.init(actorSystem:transport:options:)` assigns itself into
    /// (`swift_unknownObjectWeakAssign` into `transport+0x10`). The direction of the
    /// strength is the whole of it: the session owns the transport, so the back-pointer
    /// must not own the session.
    ///
    /// Read-only from outside, because Apple's field is `private` and has exactly one
    /// writer. See ``install(inboundSession:)``.
    public var inboundSession: (any InboundSession)? { lock.withLock { _inboundSession } }

    /// Seat the session that speaks over this transport. The one writer, called from
    /// `Session`'s initializer.
    ///
    /// **Traps on a second live install**, and the alternative is worse than a trap: a
    /// silent overwrite orphans the first session, which would then never be told the pipe
    /// died and would hold its exported actors strongly for the life of the process. There
    /// is no correct recovery and nothing a peer can do to reach it -- the only way here is
    /// calling `makeSession(over:)` twice on one transport, in our own code, which is the
    /// same criterion `actorReady`'s trap uses.
    ///
    /// A *dead* previous session is not an error: the weak reference is already `nil`, so
    /// re-using a transport whose session has gone is allowed. So is re-installing the
    /// same session, which makes the call idempotent.
    func install(inboundSession session: any InboundSession) {
        lock.withLock {
            if let existing = _inboundSession, existing !== session {
                preconditionFailure("""
                    this transport already has a live session (\(existing)); a second one \
                    would silently orphan the first, which would then never learn that the \
                    transport had died
                    """)
            }
            _inboundSession = session
        }
    }

    public var inboundRequestHandler: RequestHandler? {
        get { lock.withLock { _inboundRequestHandler } }
        set { lock.withLock { _inboundRequestHandler = newValue } }
    }

    public var inboundNotificationHandler: NotificationHandler? {
        get { lock.withLock { _inboundNotificationHandler } }
        set { lock.withLock { _inboundNotificationHandler = newValue } }
    }

    /// What the pipe can prove about the process on the other end, or `nil`.
    ///
    /// Forwarded rather than cached: Apple's `Session.RemoteInterface.auditToken` reaches
    /// through the transport's `rawTransport` existential on every read, and a cached copy
    /// would answer for a peer that is no longer there.
    public var peerAttestation: (any PeerAttestation)? { rawTransport.peerAttestation }

    /// Internal for tests: teardown has run, from either our own `cancel` or the
    /// raw transport's death channel.
    var isCancelled: Bool { lock.withLock { cancelled } }

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

    /// Both teardown paths -- our own `cancel` and the peer's death -- funnel here, and
    /// `beginCancelling` has already made sure this runs once.
    ///
    /// The session is told **first**, and synchronously. Failing the request table is a
    /// hop through the actor, so a caller that observes its own failure would otherwise
    /// be able to see a session that had not yet cleared its exported-actor table. Apple
    /// runs `handleTransportCancellation` on the transport's serial queue for the same
    /// class of reason.
    private func failEverything(reason: String) {
        inboundSession?.handleTransportCancellation()
        Task { await requests.failAll(with: .transportCancelled(message: reason)) }
    }

    // MARK: activation

    /// Bring the pipe up.
    ///
    /// Nothing is exchanged and nothing is awaited: with no version to agree, there is
    /// no state a peer has to reach before traffic can flow, for either role.
    ///
    /// **A listener does not learn of a peer until that peer sends something.** An XPC
    /// session is not established by activation alone, so a responder waiting to be told
    /// a peer exists will wait forever if the initiator only activates. This is
    /// Apple's behaviour too -- `XPCDistributed` has no handshake either -- but it is a
    /// change from the version of this transport that exchanged `hello`, where
    /// activation *was* the notification. Anything that assumed "activate implies the
    /// far side exists" has to send first now.
    public func activate() async throws(SetupError) {
        do {
            try rawTransport.activate()
        } catch {
            throw SetupError("could not activate transport: \(error)")
        }
    }

    // MARK: sending

    /// Reserve a correlation id. Split from `sendRequest` so a caller can register
    /// cancellation bookkeeping against the id before the request is in flight.
    ///
    /// Ids come from a per-transport monotonic counter and are unique within a
    /// transport, not globally -- which is all `headerID` needs, since a peer matches a
    /// response against the requests it has outstanding on this one pipe. Reserving one
    /// and never sending it is harmless: no state is allocated until `sendRequest`
    /// registers a waiter.
    public func allocateSeq() -> UInt64 {
        lock.withLock {
            defer { _nextSeq += 1 }
            return _nextSeq
        }
    }

    /// Send a request under a `seq` obtained from `allocateSeq()` and await its
    /// response.
    ///
    /// Reusing a `seq` that is still in flight fails the *new* caller rather than
    /// displacing the old one; see `RequestTable.waitForReply`.
    public func sendRequest(seq: UInt64, _ payload: Packet.Payload) async -> RequestTable.Outcome {
        let packet = Packet(header: .request(ID64(rawValue: seq)), payload: payload)
        // Bound to an explicitly typed local rather than passed as a literal: on Swift 6.4
        // a throwing closure literal cannot be converted to a `throws(RawTransportError)`
        // parameter. Do not inline this.
        let send: () throws(RawTransportError) -> Void = { try self.rawTransport.send(packet: packet) }
        return await requests.waitForReply(seq: seq, sending: send)
    }

    public func sendNotification(_ payload: Packet.Payload) throws(RawTransportError) {
        try rawTransport.send(packet: Packet(header: .notification, payload: payload))
    }

    public func cancel(reason: String) {
        guard beginCancelling() else { return }
        rawTransport.cancel(reason: reason)
        failEverything(reason: reason)
    }

    // MARK: receiving

    /// Internal for tests; the raw transport calls this for every inbound packet.
    ///
    /// A malformed message never reaches here -- `Packet.init?(rawValue:)` has already
    /// dropped it -- so the only thing left to decide is which of the three kinds it is.
    func handleReceived(packet: Packet) {
        switch packet.header {
        case .request(let id):
            guard let handler = inboundRequestHandler else { return }
            handler(id.rawValue, packet.payload) { [weak self] reply in
                self?.sendResponse(id: id, payload: reply)
            }
        case .response(let id):
            Task { await requests.complete(seq: id.rawValue, with: .reply(packet.payload)) }
        case .notification:
            inboundNotificationHandler?(packet.payload)
        }
    }

    /// A response re-uses the id it received, which is what lets the peer's request
    /// table find the waiter. Apple's reply closure captures the request id and stores
    /// it into the header it builds, for the same reason.
    private func sendResponse(id: ID64, payload: Packet.Payload) {
        try? rawTransport.send(packet: Packet(header: .response(id), payload: payload))
    }
}
