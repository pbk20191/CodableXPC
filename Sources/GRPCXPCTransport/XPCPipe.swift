import Dispatch
import GRPCCore
import Synchronization
import XPC

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// The one and only `MessagePipe` conformer, and **the one and only place in this target that may
// `import XPC`**. Everything above it -- `RPCOp`, `CompactWireCodec`, the four state machines, the
// mux -- is substrate-agnostic, and stays that way precisely because this file exists. If a later
// task finds itself wanting `xpc_object_t` anywhere else, that is a design defect to report, not
// an import to add.
//
// One `XPCSession` carries one pipe. A blob rides as a one-key XPC dictionary -- `{"b": xpc_data}`
// -- and the payload crosses to libxpc through exactly two calls:
//
//   outbound: `blob.createXPCRepresentation()`   (GRPCDispatchData.swift)
//   inbound:  `GRPCSwiftData(from: xpc_object_t)` (GRPCDispatchData.swift, zero-copy at >= 15 bytes)
//
// Nothing else in this file -- and nothing at all outside it -- touches an `xpc_object_t` carrying
// payload bytes.
//
// # What this file owes the core
//
// `MessagePipe`'s doc comment (RPCOp.swift) makes two MUST-promises that the whole core is built
// on, and this is the file that has to make them true:
//
// 1. **Order.** Blobs reach `onReceive` in the order the peer handed them to `send(_:)`. There is
//    no sequence number anywhere in the op model (§O2) because of this promise. libxpc keeps
//    message order on a connection, and this file never re-orders on top of it: every inbound
//    delivery is a single `queue.async` issued from libxpc's own (serial, per-connection) event
//    stream, so enqueue order == receive order == send order.
// 2. **Queue affinity.** Every handler invocation -- `onReceive`'s and `onPeerDeath`'s -- runs on
//    `queue`, and only on `queue`. This is not achieved by configuring the session's target queue
//    and hoping; it is achieved *structurally*, by never calling a handler inline from a libxpc
//    callback. Every callback body is `queue.async { ... }` against the very same
//    `DispatchSerialQueue` object that the `queue` property returns (`delivery.queue` in both
//    cases -- one stored property, not two queues configured alike). `setTargetQueue(queue)` is
//    still called, so the hop is usually a same-queue re-enqueue rather than a thread switch, but
//    correctness does not depend on it having taken effect. (L4.)
//
// # Lifecycle: the two libxpc traps
//
// Both are measured, both are fatal, and they point in opposite directions:
//
//   - cancelling an `XPCSession` that was **never activated** traps (`_xpc_api_misuse`), and
//   - releasing an `XPCSession` that **was** activated and never cancelled traps as well.
//
// So "always cancel" and "never cancel" are both wrong, and the pipe has to actually know. That
// knowledge is `State.sessionIsLive`: seeded `true` for an accepted (server) session -- which
// `IncomingSessionRequest.accept` hands back already live -- and `false` for a dialled (client)
// session, which is created `.inactive` and flips to `true` only after `session.activate()`
// returns *without throwing*. A dial whose `activate()` throws therefore leaves `sessionIsLive`
// false and `deinit` releases the session without cancelling it, which is the only non-trapping
// move on that path. See ``XPCPipe/deinit``.
//
// # Timers
//
// There are none (L12). This file starts no timer, arms no `DispatchSourceTimer`, and schedules
// no delayed work of any kind; deadlines are the client transport's business (Task 7).

// ===========================================================================================
// MARK: - Inbound delivery
// ===========================================================================================

/// Everything a libxpc callback needs, and **nothing that points back at the `XPCPipe`**.
///
/// This split is what makes `XPCPipe.deinit` reachable (L6). The session's incoming-message and
/// cancellation handlers are retained by libxpc for as long as the session lives, and the session
/// is owned by the pipe -- so a handler that captured the pipe (even through a box, as an earlier
/// reviewed transport in this repo does) would close a `pipe -> session -> handler -> pipe` cycle
/// and make the pipe immortal, leaking the XPC session with it. The handlers capture *this* object
/// instead, which knows only a queue and two closures and holds no session and no pipe.
///
/// It is also what removes the accept-time chicken-and-egg entirely: a `Delivery` can be built
/// *before* `request.accept(...)` is called, so the handlers passed to `accept` are already wired
/// to their final destination at the instant the session goes live. There is no window, and
/// therefore no pending table (L5).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private final class Delivery: Sendable {

    /// The serial queue every handler runs on. This exact object is what `XPCPipe.queue` returns
    /// and what every `async` below targets -- there is deliberately only one of them.
    let queue: DispatchSerialQueue

    private struct Handlers: Sendable {
        var onReceive: (@Sendable (GRPCSwiftData) -> Void)?
        var onPeerDeath: (@Sendable () -> Void)?
        /// Set-once bookkeeping that survives ``shutDown()`` clearing the closures, so a handler
        /// registered after teardown is refused rather than silently installed on a dead pipe.
        var receiveInstalled = false
        var peerDeathInstalled = false
        var isShutDown = false
    }
    private let handlers = Mutex(Handlers())

    init(queue: DispatchSerialQueue) {
        self.queue = queue
    }

    /// Registers the blob handler. Set-once: a second registration is a caller bug and traps
    /// rather than silently discarding the first handler's stream of blobs.
    func setReceiveHandler(_ handler: @escaping @Sendable (GRPCSwiftData) -> Void) {
        handlers.withLock {
            guard !$0.isShutDown else { return }   // a dead pipe delivers nothing; installing is moot
            precondition(!$0.receiveInstalled, "XPCPipe.onReceive may only be set once")
            $0.receiveInstalled = true
            $0.onReceive = handler
        }
    }

    func setPeerDeathHandler(_ handler: @escaping @Sendable () -> Void) {
        handlers.withLock {
            guard !$0.isShutDown else { return }
            precondition(!$0.peerDeathInstalled, "XPCPipe.onPeerDeath may only be set once")
            $0.peerDeathInstalled = true
            $0.onPeerDeath = handler
        }
    }

    /// Called from libxpc's incoming-message callback, on whatever queue libxpc chose.
    ///
    /// The blob is decoded *here*, synchronously on the callback, and only the resulting
    /// `GRPCSwiftData` is carried across the hop. That is deliberate: `GRPCSwiftData(from:)` is a
    /// no-copy view whose deallocator holds the `xpc_object_t` alive, so the value is safe to
    /// escape, while the `XPCDictionary` it came out of is not `Sendable` and must not.
    ///
    /// The hop is a plain `queue.async`, one per message, issued from libxpc's per-connection
    /// event stream -- which libxpc delivers serially -- so blobs land on `queue` in exactly the
    /// order they arrived, which is the order the peer sent them. This is the whole of the
    /// ordering promise; there is no re-sequencing step because there is nothing to re-sequence.
    func deliver(_ message: XPCDictionary) {
        guard let blob = Self.blob(in: message) else {
            // Not a `{"b": xpc_data}` message at all: there is no blob to decode and no stream to
            // fail (this layer does not know what a stream is). Dropped. A peer sending malformed
            // dictionaries is a protocol violation the mux cannot act on either, since nothing
            // identifies which -- if any -- stream it meant.
            return
        }
        queue.async {
            // `self` (a `Delivery`) is captured strongly for the duration of the hop only. It is
            // safe precisely because a `Delivery` points at nothing -- no session, no pipe -- so
            // this cannot extend any lifetime that matters. `Mutex` is non-copyable and cannot
            // appear in a capture list, so the capture is of `self`, not of the lock.
            self.handlers.withLock { $0.onReceive }?(blob)
        }
    }

    /// Called from libxpc's session-cancellation callback. Fires `onPeerDeath` on `queue`.
    ///
    /// libxpc invokes this for *our own* `cancel()` too, not only for the peer going away.
    /// `XPCPipe.cancel()` clears the handlers (via ``shutDown()``) under the lock *before* it
    /// calls `session.cancel(reason:)`, so a self-inflicted cancellation finds `onPeerDeath` nil
    /// and reports nothing -- the pipe never tells its owner that the peer died because the owner
    /// hung up.
    func peerDied() {
        queue.async {
            self.handlers.withLock { $0.onPeerDeath }?()
        }
    }

    /// Drops both handlers and refuses further registration. Idempotent.
    ///
    /// Any hop already in flight (a `queue.async` enqueued before this ran) will find the handlers
    /// nil and do nothing, which is the correct behaviour for a blob that arrived on a pipe its
    /// owner has already torn down.
    func shutDown() {
        handlers.withLock {
            $0.isShutDown = true
            $0.onReceive = nil
            $0.onPeerDeath = nil
        }
    }

    // MARK: The inbound libxpc crossing

    /// Reads `{"b": xpc_data}` and wraps the payload with `GRPCSwiftData(from:)` -- one of the two
    /// places in this target where payload bytes cross to or from libxpc.
    private static func blob(in message: XPCDictionary) -> GRPCSwiftData? {
        message.withUnsafeUnderlyingDictionary { raw -> GRPCSwiftData? in
            guard let value = xpc_dictionary_get_value(raw, XPCPipe.blobKey),
                  xpc_get_type(value) == XPC_TYPE_DATA
            else { return nil }
            return GRPCSwiftData(from: value)
        }
    }
}

// ===========================================================================================
// MARK: - XPCPipe
// ===========================================================================================

/// A `MessagePipe` over one `XPCSession`.
///
/// Build one with ``connecting(to:queue:building:)`` (client) or ``accepting(_:queue:building:)``
/// (server). Both factories hand the caller a pipe that is *fully built* -- handlers installed,
/// session live -- so there is never a moment where the pipe exists but cannot receive.
///
/// - Important: **Ownership (L6).** Whoever creates a pipe owns it and must keep it alive for as
///   long as anything built on it is in use. The pipe deliberately makes itself easy to release:
///   nothing libxpc retains points back at it (see ``Delivery``), so dropping the last reference
///   really does run `deinit`, which cancels the session and releases the native resource. The
///   converse obligation is the owner's: a mux that holds this pipe weakly, or an owner that drops
///   it early, gets `RPCError(code: .unavailable, ...)` out of ``send(_:)`` from then on -- which
///   is the designed failure, not a bug.
///
/// - Important: **Handlers must not capture the pipe (or its owner) strongly** -- see
///   ``onReceive(_:)``. That is the one way to make `deinit` unreachable, and it is a leak of the
///   native session, not merely of Swift memory.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class XPCPipe: MessagePipe {

    /// The dictionary key a blob rides under. One letter on purpose: it is on the wire once per
    /// message and carries no information -- the dictionary has exactly one key.
    static let blobKey = "b"

    /// How this pipe's session came to be, which is the whole of what activation tracking needs
    /// to know at construction time.
    enum Origin: Sendable {
        /// Handed back already live by `XPCListener.IncomingSessionRequest.accept`. Must **never**
        /// be activated again; must be cancelled exactly once before release.
        case accepted
        /// Created `.inactive` by a dial. Must be activated exactly once, and may only be
        /// cancelled if that activation succeeded.
        case dialled
    }

    /// L7's explicit lifecycle. One lock, three reachable resting states, and a transient
    /// `activating` so that a concurrent ``cancel()`` during `session.activate()` is resolved
    /// deterministically instead of racing.
    enum Phase: Sendable {
        /// Dialled, inactive, nothing can arrive. Only ``activate()`` leaves this state.
        case idle
        /// `session.activate()` is in flight. Reserved under the lock so a second activation is
        /// refused rather than attempted.
        case activating
        /// Live: sends are attempted, deliveries flow.
        case running
        /// Torn down, by ``cancel()`` or by a failed activation. Terminal; sends fail fast and
        /// handlers are gone. Re-entering it is a no-op, which is what makes teardown idempotent.
        case shutDown
    }

    private struct State: Sendable {
        var phase: Phase
        /// Whether `session.cancel(reason:)` is both **required** (to avoid the release trap) and
        /// **legal** (to avoid the never-activated trap). Cleared by whoever performs the cancel,
        /// so exactly one of ``cancel()`` / ``deinit`` ever calls it.
        var sessionIsLive: Bool
    }

    private let session: XPCSession
    private let delivery: Delivery
    private let state: Mutex<State>

    /// See ``MessagePipe/queue``. This returns the *stored* queue -- the same object every
    /// `async` in ``Delivery`` targets and the same object handed to `setTargetQueue`. There is
    /// one queue here, not one exposed and one used.
    var queue: DispatchSerialQueue { delivery.queue }

    /// Private: a pipe is only ever built by a factory, because the factories are what make
    /// "handlers installed before anything can be delivered" structural rather than a convention
    /// a caller has to remember.
    private init(session: XPCSession, origin: Origin, delivery: Delivery) {
        self.session = session
        self.delivery = delivery
        switch origin {
        case .accepted:
            // Already live. Nothing to activate, and a cancel is already owed.
            self.state = Mutex(State(phase: .running, sessionIsLive: true))
        case .dialled:
            // Inactive. Cancelling it now would trap; only a successful `activate()` earns that.
            self.state = Mutex(State(phase: .idle, sessionIsLive: false))
        }
    }

    /// The RAII half of the lifecycle: release the native session without tripping either libxpc
    /// trap.
    ///
    /// `sessionIsLive` is exactly the predicate "this session was activated (or arrived already
    /// activated) and has not been cancelled yet". Cancelling when it is false traps
    /// (`_xpc_api_misuse` on a never-activated session); *not* cancelling when it is true traps on
    /// release. Both directions are measured, so this is a two-sided obligation and not a
    /// best-effort tidy-up.
    ///
    /// Taken and cleared under the lock so that a `cancel()` racing this cannot double-cancel --
    /// though in practice `deinit` implies no other reference exists.
    ///
    /// Reaching here at all is the L6 property: nothing libxpc retains points back at the pipe.
    deinit {
        let owesCancel = state.withLock { st -> Bool in
            let live = st.sessionIsLive
            st.sessionIsLive = false
            st.phase = .shutDown
            return live
        }
        // Handlers first, so a delivery already in flight on `queue` finds nothing to call rather
        // than reaching into an owner that is being torn down.
        delivery.shutDown()
        if owesCancel {
            session.cancel(reason: "XPCPipe deinitialized")
        }
    }

    // ---------------------------------------------------------------------------------------
    // MARK: MessagePipe
    // ---------------------------------------------------------------------------------------

    /// Hands one blob to the peer as `{"b": xpc_data}`, one-way -- never the reply overload.
    ///
    /// One-way is load-bearing: this transport's flow control is an explicit `credit` op (§O4),
    /// not an XPC reply, so the reply channel stays unused in both directions and either peer can
    /// originate. (The legacy stack used replies as credit; that is gone.)
    ///
    /// Callable from any queue, as `MessagePipe` promises. No lock is held across
    /// `session.send(message:)`: libxpc's own send is thread-safe and totally ordered per
    /// connection, so serializing sends here would buy nothing but a contention point. Two blobs
    /// handed to `send` concurrently from two threads have no defined order *to* preserve -- what
    /// the contract promises, and what libxpc delivers, is that whichever order libxpc accepts
    /// them in is the order the peer's `onReceive` sees.
    ///
    /// Errors are shaped, never passed through: once the peer is gone libxpc fails the send with
    /// its own rich error, and every caller in this transport -- and gRPC's machinery above it --
    /// expects a transport failure as an `RPCError`.
    func send(_ blob: GRPCSwiftData) throws {
        // Fail fast on a pipe that is already torn down. This is the only lock the send path
        // takes, and it is read-only.
        let phase = state.withLock { $0.phase }
        guard phase == .running else {
            throw RPCError(
                code: .unavailable,
                message: "the XPC pipe is not running (\(phase)); the blob was not sent")
        }
        let message = xpc_dictionary_create(nil, nil, 0)
        // The outbound libxpc crossing -- the only one in this target.
        xpc_dictionary_set_value(message, Self.blobKey, blob.createXPCRepresentation())
        do {
            try session.send(message: XPCDictionary(message))
        } catch {
            throw RPCError(
                code: .unavailable,
                message: "the XPC connection is no longer available "
                    + "(sending a \(blob.count)-byte blob failed: \(error))")
        }
    }

    /// See ``MessagePipe/onReceive(_:)``. Set once, and -- via the factories -- always before the
    /// session can deliver anything.
    ///
    /// - Important: **`handler` must not capture this pipe, or anything that owns it, strongly.**
    ///   This is the one ownership rule the pipe cannot enforce for you, and breaking it leaks the
    ///   XPC session. The retain path is
    ///   `libxpc -> the session's handlers -> Delivery -> handler -> (you) -> pipe -> session`,
    ///   and libxpc holds its end for as long as the session is alive -- which is until the pipe's
    ///   `deinit` cancels it, which now never runs. Measured, not theorised: a probe whose
    ///   `onReceive` echoed through a strongly-captured `pipe` left the accepted pipe alive
    ///   forever; the identical probe with `[weak pipe]` released it immediately.
    ///
    ///   For Task 6 this means the mux's handler closure must reach the core **weakly**
    ///   (`[weak core]`), exactly as the plan's L6 already requires of outbound writers -- the
    ///   cycle runs through the core just as readily as through the pipe.
    func onReceive(_ handler: @escaping @Sendable (GRPCSwiftData) -> Void) {
        delivery.setReceiveHandler(handler)
    }

    /// See ``MessagePipe/onPeerDeath(_:)``. Fires on `queue` when libxpc reports the session
    /// cancelled by the far end; deliberately silent when *this* side cancelled (see
    /// ``Delivery/peerDied()``).
    ///
    /// - Important: the same no-strong-capture rule as ``onReceive(_:)``.
    func onPeerDeath(_ handler: @escaping @Sendable () -> Void) {
        delivery.setPeerDeathHandler(handler)
    }

    /// Tears the pipe down from this side. Idempotent (L7: double shutdown is safe).
    ///
    /// Take-and-transition happens atomically under the lock; `session.cancel(reason:)` is called
    /// **outside** it, because it is a libxpc call that synchronously reaches the session's
    /// cancellation handler and a lock held across it would be held across foreign code.
    ///
    /// A pipe cancelled before it was ever activated (`.idle`) still reaches `.shutDown` and still
    /// does **not** cancel the session -- `sessionIsLive` is false there, and cancelling a
    /// never-activated session traps.
    func cancel() {
        let owesCancel = state.withLock { st -> Bool in
            guard st.phase != .shutDown else { return false }
            st.phase = .shutDown
            let live = st.sessionIsLive
            st.sessionIsLive = false
            return live
        }
        // Before the libxpc cancel, so the cancellation handler libxpc is about to run finds no
        // `onPeerDeath` and does not report our own hang-up as the peer dying.
        delivery.shutDown()
        if owesCancel {
            session.cancel(reason: "XPCPipe cancelled")
        }
    }

    // ---------------------------------------------------------------------------------------
    // MARK: Activation
    // ---------------------------------------------------------------------------------------

    /// Activates a dialled session exactly once. Private: ``connecting(to:queue:building:)`` and
    /// its siblings are the only callers, and they construct-and-activate in one step so there is
    /// no window in which a caller holds an unactivated pipe.
    ///
    /// L7 in miniature:
    /// - the `.idle -> .activating` transition is taken under the lock, so a second concurrent
    ///   call is refused **deterministically** rather than racing into a second
    ///   `session.activate()` (which libxpc would trap on);
    /// - `session.activate()` runs outside the lock;
    /// - a throw lands the pipe in `.shutDown` with `sessionIsLive` still false, which is exactly
    ///   what `deinit` needs on the failed-dial path;
    /// - a success that finds the phase no longer `.activating` (someone cancelled meanwhile)
    ///   honours the cancel: the now-live session is cancelled immediately rather than leaking.
    private func activate() throws {
        try state.withLock { st in
            switch st.phase {
            case .idle:
                st.phase = .activating
            case .activating, .running:
                throw RPCError(code: .failedPrecondition,
                               message: "the XPC pipe has already been activated")
            case .shutDown:
                throw RPCError(code: .unavailable,
                               message: "the XPC pipe was cancelled before it could be activated")
            }
        }
        do {
            try session.activate()
        } catch {
            state.withLock { st in
                st.phase = .shutDown
                // Deliberately left false: this session never activated, so cancelling it in
                // `deinit` would trap. Releasing it is the only safe move.
                st.sessionIsLive = false
            }
            delivery.shutDown()
            throw RPCError(code: .unavailable,
                           message: "could not activate the XPC session: \(error)")
        }
        let cancelledMeanwhile = state.withLock { st -> Bool in
            guard st.phase == .activating else { return true }   // a concurrent cancel() won
            st.phase = .running
            st.sessionIsLive = true
            return false
        }
        if cancelledMeanwhile {
            session.cancel(reason: "XPCPipe cancelled during activation")
        }
    }
}

// ===========================================================================================
// MARK: - Accepting (server side)
// ===========================================================================================

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension XPCPipe {

    /// Accepts one inbound session and returns a **fully built** pipe together with the decision
    /// the listener's incoming-session handler must return.
    ///
    /// Call this from inside an `XPCListener`'s incoming-session closure and return the decision
    /// it yields:
    ///
    /// ```swift
    /// let listener = XPCListener(options: .inactive) { request in
    ///     let queue = DispatchSerialQueue(label: "…")
    ///     let (decision, pipe) = XPCPipe.accepting(request, queue: queue) { pipe in
    ///         let core = RPCTransportCore(pipe: pipe, codec: CompactWireCodec())
    ///         pipe.onReceive { core.receive($0) }      // installed here, not later
    ///         pipe.onPeerDeath { core.peerDied() }
    ///     }
    ///     …publish `pipe` (or the core built from it) to whoever will own it…
    ///     return decision
    /// }
    /// try listener.activate()
    /// ```
    ///
    /// # Why `building:` is a closure and not "return the pipe and configure it after"
    ///
    /// L5. `request.accept(...)` hands back a session that is **already live**, so the peer's
    /// first blob can be delivered the moment it returns. Anything registered afterwards races
    /// that blob, and the losing move is precisely the two-phase "register later" design that
    /// produced dropped frames, a table leak and then silent data loss in the previous build.
    /// Two independent things close the window here, and both are structural:
    ///
    /// 1. The ``Delivery`` object exists *before* `accept` is called and is what the handlers
    ///    passed to `accept` capture -- so there is no moment at which the session is live with no
    ///    handler behind it.
    /// 2. The whole body runs inside `queue.sync`, and every inbound delivery is a `queue.async`
    ///    onto that same queue. A blob that arrives mid-accept is therefore *enqueued* behind this
    ///    block and cannot run until after `building` has returned. The handler is installed
    ///    before the first blob is dispatched, not merely before the first blob arrives.
    ///
    /// There is no pending table, no buffer and nothing to claim later, because there is nothing
    /// left to drop.
    ///
    /// - Precondition: not called from `queue` (it blocks on it). In practice the listener's
    ///   incoming-session handler runs on the listener's own queue, and each accepted session gets
    ///   a queue of its own.
    /// - Parameter queue: this connection's serial queue. Every handler will run on it, and it is
    ///   set as the session's target queue so the delivery hop is a same-queue re-enqueue.
    /// - Parameter building: called synchronously with the finished pipe, before the decision is
    ///   handed back to libxpc and before any blob can be dispatched. Install `onReceive` and
    ///   `onPeerDeath` here.
    /// - Returns: the listener decision to return, and the pipe. **The returned pipe is the only
    ///   strong reference** -- nothing in libxpc holds one (L6) -- so whoever calls this owns the
    ///   connection's lifetime.
    static func accepting(
        _ request: XPCListener.IncomingSessionRequest,
        queue: DispatchSerialQueue,
        building build: (XPCPipe) -> Void
    ) -> (XPCListener.IncomingSessionRequest.Decision, XPCPipe) {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            let delivery = Delivery(queue: queue)
            // Wired to their final destination *before* the session exists, let alone goes live.
            let (decision, session) = request.accept(
                incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                    delivery.deliver(message)
                    // Always `nil`: this transport never uses XPC's reply channel (see `send`).
                    // Returning nil does not make libxpc synthesize a reply.
                    return nil
                },
                cancellationHandler: { (_: XPCRichError) in
                    delivery.peerDied()
                })
            session.setTargetQueue(queue)
            let pipe = XPCPipe(session: session, origin: .accepted, delivery: delivery)
            build(pipe)
            return (decision, pipe)
        }
    }
}

// ===========================================================================================
// MARK: - Dialling (client side)
// ===========================================================================================

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension XPCPipe {

    /// Dials the anonymous listener that vended `endpoint` and returns a live pipe.
    static func connecting(
        to endpoint: XPCEndpoint,
        queue: DispatchSerialQueue,
        building build: (XPCPipe) -> Void
    ) throws -> XPCPipe {
        try dialling(queue: queue, building: build) {
            try XPCSession(endpoint: endpoint, targetQueue: queue, options: .inactive)
        }
    }

    /// Dials a launchd Mach service by name.
    static func connecting(
        toMachService name: String,
        queue: DispatchSerialQueue,
        building build: (XPCPipe) -> Void
    ) throws -> XPCPipe {
        try dialling(queue: queue, building: build) {
            try XPCSession(machService: name, targetQueue: queue, options: .inactive)
        }
    }

    /// Dials an XPC service bundle inside the calling application, by bundle identifier.
    static func connecting(
        toXPCService name: String,
        queue: DispatchSerialQueue,
        building build: (XPCPipe) -> Void
    ) throws -> XPCPipe {
        try dialling(queue: queue, building: build) {
            try XPCSession(xpcService: name, targetQueue: queue, options: .inactive)
        }
    }

    /// The one dial recipe, shared by the three ways of naming a peer.
    ///
    /// Construct-and-activate in a single step, on purpose: a factory that returned an
    /// unactivated pipe would leave a window in which a caller could drop it (or forget to
    /// activate it), and while the ``XPCPipe/deinit`` guard makes that *safe*, it would still be a
    /// pipe that silently never worked. Here the only pipe a caller can hold is a live one.
    ///
    /// Order matters and is the mirror of the accept path's:
    /// 1. create the session `.inactive` with `targetQueue: queue` -- nothing is delivered while
    ///    it is inactive, which is what makes this side's ordering question trivial;
    /// 2. install the incoming-message and cancellation handlers, both routed through
    ///    ``Delivery``;
    /// 3. hand the finished pipe to `building` so the owner can register `onReceive` /
    ///    `onPeerDeath`;
    /// 4. *then* activate. The first blob the peer can possibly send arrives after step 4, so
    ///    there is no race to close and no `queue.sync` needed here.
    ///
    /// A throw from any step releases the pipe with `sessionIsLive` false, so `deinit` does not
    /// cancel a session that never activated.
    private static func dialling(
        queue: DispatchSerialQueue,
        building build: (XPCPipe) -> Void,
        _ makeSession: () throws -> XPCSession
    ) throws -> XPCPipe {
        let delivery = Delivery(queue: queue)
        let session: XPCSession
        do {
            session = try makeSession()
        } catch {
            throw RPCError(code: .unavailable,
                           message: "could not create the XPC session: \(error)")
        }
        session.setIncomingMessageHandler { (message: XPCDictionary) -> XPCDictionary? in
            delivery.deliver(message)
            return nil
        }
        session.setCancellationHandler { (_: XPCRichError) in
            delivery.peerDied()
        }
        session.setTargetQueue(queue)
        let pipe = XPCPipe(session: session, origin: .dialled, delivery: delivery)
        build(pipe)
        try pipe.activate()
        return pipe
    }
}
