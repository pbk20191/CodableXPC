import Foundation
import Synchronization
import XPC

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
/// **The raw transport is a back-reference.** Apple hands the raw transport its parent
/// ``Transport`` via ``RawTransportProtocol/activate(linking:)``; the raw transport then
/// routes inbound packets into ``handleReceivedPacket(_:)`` and pipe-death into
/// ``handleCancellation()``. There is no injected packet/cancellation closure and no
/// per-role branching at this level -- role now lives on ``XPCRawTransport``.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
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
    private let rawTransport: any RawTransportProtocol
    /// Apple's `Transport.queue: OS_dispatch_queue_serial` -- the transport's single serial queue,
    /// shared as the executor of both ``requests`` and the backpressure manager, and the queue the
    /// raw transports hop onto to deliver inbound traffic (so ``handleReceivedPacket(_:)`` always
    /// runs on it). Label `XPCTransport-<debugName>`. Internal, not private, because the nested raw
    /// transports -- in their own files -- deliver onto it.
    let queue: DispatchSerialQueue
    private let requests: RequestTable

    /// The one-shot teardown fuse; `beginCancelling` is its `compareExchange`.
    private let cancelledFuse = Atomic<Bool>(false)

    /// Disjoint from the handlers below -- nothing reads a seq and a handler in one critical
    /// section -- so the monotonic id source is a plain `Atomic<UInt64>`.
    private let nextSeq = Atomic<UInt64>(1)

    /// The outbound backpressure manager. Apple's `Transport` holds a long-lived
    /// `BackpressureManager<ID64>` created in its initializer and reconfigured in place; this
    /// mirrors that -- created disabled (`N: 0, enabled: false`), then reconfigured by
    /// ``setBackpressurePolicy(_:)``. A `let`: the reference never changes, only the actor's state,
    /// so no lock is needed around it (the actor guards its own state).
    private let backpressure: BackpressureManager<UInt64>

    /// The inbound handlers and the weakly-held session, under one `Synchronization.Mutex`.
    private struct Handlers {
        weak var inboundSession: (any InboundSession)?
        var inboundRequestHandler: RequestHandler?
        var inboundNotificationHandler: NotificationHandler?
    }
    private let handlers = Mutex<Handlers>(Handlers())

    /// The session speaking over this transport, held **weakly** (Apple's
    /// `Transport.(inboundSession)`). The session owns the transport, so the back-pointer must
    /// not own the session.
    public var inboundSession: (any InboundSession)? { handlers.withLock { $0.inboundSession } }

    /// Seat the session that speaks over this transport. The one writer, called from
    /// `Session`'s initializer.
    ///
    /// **Traps on a second live install**, and the alternative is worse than a trap: a silent
    /// overwrite orphans the first session, which would then never be told the pipe died and
    /// would hold its exported actors strongly for the life of the process.
    ///
    /// A *dead* previous session is not an error, and re-installing the same session is
    /// idempotent.
    func install(inboundSession session: any InboundSession) {
        handlers.withLock { handlers in
            if let existing = handlers.inboundSession, existing !== session {
                preconditionFailure("""
                    this transport already has a live session (\(existing)); a second one \
                    would silently orphan the first, which would then never learn that the \
                    transport had died
                    """)
            }
            handlers.inboundSession = session
        }
    }

    public var inboundRequestHandler: RequestHandler? {
        get { handlers.withLock { $0.inboundRequestHandler } }
        set { handlers.withLock { $0.inboundRequestHandler = newValue } }
    }

    public var inboundNotificationHandler: NotificationHandler? {
        get { handlers.withLock { $0.inboundNotificationHandler } }
        set { handlers.withLock { $0.inboundNotificationHandler = newValue } }
    }

    /// What the pipe can prove about the process on the other end, or `nil`.
    ///
    /// Forwarded rather than cached: Apple's `Session.RemoteInterface.auditToken` reaches
    /// through the transport's `rawTransport` existential on every read, and a cached copy
    /// would answer for a peer that is no longer there.
    public var peerAttestation: (any PeerAttestation)? { rawTransport.peerAttestation }

    /// Internal for tests: teardown has run, from either our own `cancel` or the
    /// raw transport's death channel.
    var isCancelled: Bool { cancelledFuse.load(ordering: .acquiring) }

    /// Internal for tests: requests registered and not yet resolved.
    var pendingRequestCount: Int { get async { await requests.pendingCount } }

    /// - Parameter qos: the QoS of the transport's serial queue. Apple's is `.unspecified`;
    ///   this is a knob (defaulting to Apple's value) so an in-process test can pin the
    ///   delivering context's priority floor -- the one input to the inbound priority clamp
    ///   that is read off the delivering context rather than the wire.
    public init(debugName: String, qos: DispatchQoS = .unspecified,
                rawTransport: any RawTransportProtocol) {
        self.debugName = debugName
        self.rawTransport = rawTransport
        // Apple's `Transport` mints one serial queue and shares it with the request manager and
        // the backpressure manager (their `init(queue:)`), so both serialize on the same executor.
        let queue = DispatchSerialQueue(label: "XPCTransport-\(debugName)", qos: qos)
        self.queue = queue
        self.requests = RequestTable(queue: queue)
        self.backpressure = BackpressureManager<UInt64>(queue: queue, N: 0, enabled: false)
    }

    /// Claim the one-shot teardown. Returns `false` if teardown already ran, so our own
    /// `cancel` and a remote death cannot double-fire.
    private func beginCancelling() -> Bool {
        cancelledFuse.compareExchange(
            expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged
    }

    /// Both teardown paths -- our own `cancel` and the peer's death -- funnel here, and
    /// `beginCancelling` has already made sure this runs once.
    ///
    /// The session is told **first**, and synchronously, so a caller that observes its own
    /// failure cannot see a session that had not yet cleared its exported-actor table.
    private func failEverything(reason: String) {
        inboundSession?.handleTransportCancellation()
        Task { await requests.failAll(with: .transportCancelled(message: reason)) }
    }

    // MARK: activation

    /// Bring the pipe up. Apple's `Transport.activate() throws(SetupError)`: the whole body is
    /// `try rawTransport.activate(linking: self)`. There is no handshake and nothing to await.
    public func activate() throws(SetupError) {
        try rawTransport.activate(linking: self)
    }

    // MARK: sending

    /// Reserve a correlation id. Split from `sendRequest` so a caller can register
    /// cancellation bookkeeping against the id before the request is in flight.
    public func allocateSeq() -> UInt64 {
        nextSeq.wrappingAdd(1, ordering: .relaxed).oldValue
    }

    /// Send a request under a `seq` obtained from `allocateSeq()` and await its response.
    public func sendRequest(seq: UInt64, _ payload: Packet.Payload) async -> RequestTable.Outcome {
        let token = await backpressure.acquireSlot(for: seq, priority: Task.currentPriority)
        defer {
            if let token {
                Task { await backpressure.releaseSlot(token: token) }
            }
        }
        let packet = Packet(header: .request(ID64(rawValue: seq)), payload: payload)
        // Bound to an explicitly typed local rather than passed as a literal: on Swift 6.4
        // a throwing closure literal cannot be converted to a `throws(RawTransportError)`
        // parameter. Do not inline this.
        let send: () throws(RawTransportError) -> Void = { try self.rawTransport.send(packet: packet) }
        return await requests.waitForReply(seq: seq, sending: send)
    }

    /// Apple's `Transport.setBackpressurePolicy(_:)`: bound the number of in-flight requests to
    /// the policy's limit, or remove the bound when the policy is disabled.
    public func setBackpressurePolicy(_ policy: XPCActorSystem.BackpressurePolicy) {
        _ = backpressure.syncToActor { $0.apply(N: policy.maxConcurrentRequests, enabled: policy.enabled) }
    }

    public func sendNotification(_ payload: Packet.Payload) throws(RawTransportError) {
        try rawTransport.send(packet: Packet(header: .notification, payload: payload))
    }

    /// Our own teardown. Apple's `Transport.cancel() -> Bool`: trips the fuse and calls
    /// `rawTransport.cancel()` only on the first transition. We additionally fail our own
    /// outstanding requests here rather than relying on the raw transport's death channel to
    /// loop back -- the same effect, one hop sooner. Returns whether this call was the one
    /// that cancelled.
    @discardableResult
    public func cancel() -> Bool {
        guard beginCancelling() else { return false }
        rawTransport.cancel()
        failEverything(reason: "the transport was cancelled")
        return true
    }

    // MARK: receiving

    /// The raw transport calls this for every inbound packet, on ``queue``.
    ///
    /// Apple's `Transport.handleReceivedPacket(_:)` asserts `.onQueue(queue)` and switches on
    /// the header tag. A malformed message never reaches here -- `Packet.init?(rawValue:)` has
    /// already dropped it -- so the only thing left to decide is which of the three kinds it is.
    func handleReceivedPacket(_ packet: Packet) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch packet.header {
        case .request(let id):
            guard let handler = inboundRequestHandler else { return }
            // Apple's reply closure captures the request `id` and `self` (strongly): the reply
            // must land whether or not the transport has other references left.
            handler(id.rawValue, packet.payload) { [id, self] reply in
                self.sendResponse(id: id, payload: reply)
            }
        case .response(let id):
            Task { await requests.complete(seq: id.rawValue, with: .reply(packet.payload)) }
        case .notification:
            inboundNotificationHandler?(packet.payload)
        }
    }

    /// The pipe died, from the far side. Apple's `Transport.handleCancellation()`: trip the
    /// fuse, fail every pending request, and clear-and-notify the inbound session. Do *not*
    /// call `rawTransport.cancel()` -- the raw transport is the thing telling us it is already
    /// gone. Runs at most once (the shared fuse gates it against our own `cancel()`).
    func handleCancellation() {
        guard beginCancelling() else { return }
        failEverything(reason: "the transport's peer is gone")
    }

    /// A response re-uses the id it received, which is what lets the peer's request table
    /// find the waiter.
    private func sendResponse(id: ID64, payload: Packet.Payload) {
        try? rawTransport.send(packet: Packet(header: .response(id), payload: payload))
    }
}
