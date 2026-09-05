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
//    cases -- one stored property, not two queues configured alike). The session is pointed at
//    that queue all the same -- **once**, and by whichever route its kind allows: a dialled
//    session gets it as the initializer's `targetQueue:` argument, an accepted one through
//    `setTargetQueue(queue)` (it is handed back already built, so there is no initializer to pass
//    it to).
//
//    **The hop is a real cross-queue enqueue, not a same-queue re-enqueue** -- this doc said the
//    latter until it was measured, and the measurement says otherwise. With the target queue set
//    exactly as this file sets it, libxpc delivers on **its own** `com.apple.session.queue`, which
//    *targets* ours: `__dispatch_queue_get_label(nil)` inside the callback reads
//    `com.apple.session.queue` for 5 000/5 000 messages on an accepted session and 3 000/3 000 on
//    a dialled one, and the `queue.async` block then runs on the connection queue. Because the two
//    queues share a target chain there is no separate worker thread to wake, so it is *cheap*
//    (~0.2-0.5 µs CPU, ~2.25 µs scheduling latency in situ, n=20 000) -- but it is a genuine async
//    boundary with a block allocation and an enqueue, not the near-free re-post "re-enqueue"
//    implies. Do not budget it at zero, and do not delete it on the theory that it is one: the hop
//    has two jobs neither of which the target chain supplies.
//
//    * **Off-stack execution.** Without it, `receive()` runs *inside* libxpc's incoming-message
//      callback for this session, and a routing turn that sends -- a `cancel`, a `credit`, an
//      accept refusal -- would then take `RPCTransportCore`'s blocking `submission` lock and issue
//      an `xpc_session_send` **from inside libxpc's own delivery context**, stalling delivery of
//      every subsequent message behind that syscall. The hop is what keeps routing off that stack.
//    * **The affinity/label contract**, i.e. point 2 itself: the hop is what makes
//      `__dispatch_queue_get_label(nil)` inside `receive` read the connection queue's label. (The
//      core's L4 `dispatchPrecondition(.onQueue:)` tripwire is target-chain permissive and would
//      pass without it, so this is a contract the hop keeps, not one it is checked against.)
//
//    **Affinity** does not depend on the target-queue call having taken effect -- the hop alone
//    guarantees it.
//    **Ordering does**, and the two must not be conflated: order survives only because libxpc
//    issues one session's inbound callbacks serially, and pointing the session at a
//    `DispatchSerialQueue` is what makes that explicit. If those callbacks ever ran concurrently
//    the `async` hops could be enqueued out of order -- which is exactly the failure shape a
//    sabotage run produced when the hop was swapped for a global concurrent queue. (L4.)
//
// # Lifecycle: the XPCSession disposal matrix
//
// Disposing of an `XPCSession` is narrower than the obvious reading of "don't cancel what you
// didn't activate", and the rules differ between the two kinds of session this file holds.
// Measured row by row, each in its own process so a trap shows as a process death
// (`EXC_BREAKPOINT`, exit 133). The trap is always
// `_xpc_api_misuse <- -[OS_xpc_session _xref_dispose] <- XPCSession.__deallocating_deinit`, i.e.
// it fires from the session's own `deinit`, not from anything this file calls.
//
// **Dialled sessions** (`XPCSession(endpoint:)` and `XPCSession(machService:)` behave identically):
//
//     | disposal                                          | result                        |
//     |---------------------------------------------------|-------------------------------|
//     | construct `.inactive`, NEVER activate, release     | TRAPS `_xpc_api_misuse`       |
//     | cancel a never-activated session, then release     | TRAPS                         |
//     | activate, then release UNCANCELLED                 | TRAPS                         |
//     | `activate()` THREW, then release                   | safe                          |
//     | activate -> cancel -> release                      | safe -- the ONLY safe disposal|
//
// So for a dialled session the rule is **activate-then-cancel, always**, with a *failed*
// `activate()` as the only other safe terminal state -- a failed activation self-invalidates the
// session, which is why releasing it is fine there and nowhere else. In particular, "we never
// activated it, so releasing it is safe" is **false**; that mistake is a process death, not a leak.
//
// **Accepted sessions** -- handed back by `IncomingSessionRequest.accept` -- follow different
// rules, and they are the *opposite* of the dialled ones in the way that matters most:
//
//     | disposal of an accepted session                          | result                  |
//     |----------------------------------------------------------|-------------------------|
//     | cancel INSIDE the incoming-session closure, before the    | TRAPS `_xpc_api_misuse` |
//     |   accept Decision has been returned to libxpc             |                         |
//     | release uncancelled inside that closure                   | safe                    |
//     | cancel after the Decision returned, then release          | safe                    |
//     | release UNCANCELLED after the Decision returned           | safe (dealloc confirmed |
//     |                                                           | by a weak reference)    |
//
// ## One mechanism, four rows
//
// Do not memorise the table; it follows from two facts.
//
// 1. **libxpc holds its own reference to an accepted session for the whole accept window.**
//    Measured: the session does not deallocate until the incoming-session closure returns, so a
//    release inside that window is never the last one -- which is why row 2 is safe, and it is
//    safe for a reason that has nothing to do with this file's bookkeeping.
// 2. **`xpc_session_cancel` is simply illegal inside that window**, whatever the refcount. That is
//    row 1, and it is why row 1 traps while row 2 does not.
//
// Everything else follows: once the Decision has been returned the window is closed, libxpc drops
// its reference, and both cancel-then-release and plain release become ordinary and safe.
//
// **The consequence Task 7 needs: an accepted session never *requires* cancelling in order to be
// released safely** -- the exact opposite of a dialled one, which traps unless it is cancelled.
// This file still cancels accepted sessions, because that is what hangs the peer up promptly and
// what makes the peer's `onPeerDeath` fire; but it is a behaviour, not a safety obligation.
//
// ## What this file does with that
//
// `State.sessionIsLive` is the predicate "a cancel is owed and is legal right now".
//
//   - **dialled:** seeded `false` (the session is `.inactive`), flipped to `true` only after
//     `session.activate()` returns without throwing, and back to `false` only in the code path
//     that performs the cancel. The other half of the obligation lives in ``XPCPipe/activate()``:
//     **no path may release a constructed dialled session without activating it first**, so a pipe
//     that was cancelled before it could be activated is activated anyway, purely so that it can
//     be cancelled.
//   - **accepted:** seeded `false` and **never set**. An accepted pipe's obligation is not stored
//     at all: ``XPCPipe/takeCancelObligation()`` asks libxpc instead, via
//     `Delivery.windowIsProvedClosed`. See below.
//
// ## The span that used to be "the one hazard this file cannot close" -- now closed
//
// The hazard was real and is worth recording, because the shape of the mistake recurs. An earlier
// version of this file flipped the "a cancel is owed" flag from an `acceptWindowClosed()` hook
// called when `building` returned. `building` returning is **not** the instant the accept
// `Decision` reaches libxpc, and the span between them is exactly where the caller does its
// publishing -- so the flag said "a cancel is owed" while a cancel was still illegal, and a caller
// that dropped the pipe there ran `deinit`, cancelled into an open window (row A1) and killed the
// process. The file documented that as unclosable, having tried two closures that both fail (never
// cancelling accepted sessions silences `onPeerDeath`; deferring onto a caller queue has no
// ordering relationship to the `Decision`).
//
// **That enumeration was complete when it was written and was never revisited after
// ``XPCPipe/onWindowProvedClosed(_:)`` landed** -- a third option, in this same file, three commits
// later: a libxpc-ordered hook this file's own matrix measures safe to act from. The span is now
// closed structurally rather than documented:
//
//   * there is no stored flag to be re-armed early, and no `acceptWindowClosed()` hook;
//   * `takeCancelObligation()` reads `Delivery.windowIsProvedClosed` at the moment of the take, so
//     "the window has not been proved closed" answers **do nothing** -- and doing nothing means
//     releasing the session uncancelled, which rows A2 and A4 measure safe *both inside the window
//     and after it*. It is the one disposal that is safe without knowing where in the accept you
//     are, which is precisely what a caller cannot know;
//   * once a proof has fired, cancelling is legal (A11/A12 for the delivery exit, N8 for the
//     cancellation exit), so the peer is still hung up promptly and `onPeerDeath` still fires;
//   * how long the flag can stay false is bounded: a peer that connects and never sends never
//     reaches the incoming-session closure at all (N2, 40/40), so there is no accepted pipe whose
//     proof is not already in flight.
//
// "Publish before you return" survives as a rule, but it is now about the *core*, not about
// survival: dropping the pipe in that span is safe, and what it costs is a peer that is released
// rather than hung up. To refuse a peer, use ``XPCPipe/rejecting(_:reason:)`` -- it never creates a
// session at all.
//
// **And the span is worse than "you must not drop the pipe in it": you must not touch the session
// in it at all.** Measured after a process death in the server transport (Task 7 round 4): a `send`
// inside the accept closure traps (row A5), and so does a `send` or a `cancel` hopped onto the
// connection's own queue from inside it (A7, A10) or performed by another thread racing the
// closure's return (A8, A9).
//
// **The window's boundary, stated correctly** -- an earlier version of this comment got it wrong and
// the correction matters more than the original claim. The window is exactly
// `[request.accept() … the Decision reaches libxpc]`. It does **not** outlive the closure: a send
// immediately after the Decision has been returned is safe (row A6, 60/60), and A8/A9's ~1-in-150
// is the racing thread sometimes beating `return decision` -- made deterministic by A8b/A9b, which
// hold the window open 50 ms and trap 30/30.
//
// The reason no fix can be built on "wait until the closure returns" is therefore **not** that the
// window outlives the closure. It is the reason the paragraph above already gave: the caller cannot
// *observe* the instant the Decision reaches libxpc, so there is no instant it can name from inside
// its own closure -- or schedule relative to it -- that is provably after the window. That kills
// "defer past the closure" exactly as dead, and unlike the other claim it is true.
//
// What *is* usable is a libxpc-ordered event. Two are measured, and both are exits from the window
// rather than guesses about its end:
//
//   * **the first message libxpc delivers.** Two rows, and they say different things -- worth
//     keeping separate, because collapsing them is how an earlier version of this comment came to
//     claim more than it had. A11/A12 (200 runs each) say *acting from the first delivery does not
//     trap*: absence of a trap, which is evidence about the operation. **A13** (60/60) is the
//     ordering row, added because the first two do not establish it: it holds the accept window open
//     50 ms with a spinner -- the same amplification that turns A8/A9's 1-in-150 into A8b/A9b's
//     30/30 -- sets the session's target queue as this file does, and asserts that **no delivery
//     lands before `return decision`**. So "the window is closed by the time a message arrives" is
//     now a measurement rather than an inference about libxpc's internals.
//   * **the session's cancellation handler** (N8: 40/40) -- it never fires inside the window, and
//     does fire on peer death.
//
// That is what ``XPCPipe/onWindowProvedClosed(_:)`` exists for, and it is the only sound place for an
// owner to do anything to a freshly accepted session.
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
        /// Fires at most once, from whichever libxpc-ordered event proves this session's accept
        /// window closed first -- the first inbound message, or the session's cancellation. Taken
        /// out of the slot by whoever fires it, so it cannot fire twice.
        var onWindowProvedClosed: (@Sendable () -> Void)?
        /// Set-once bookkeeping that survives ``shutDown()`` clearing the closures, so a handler
        /// registered after teardown is refused rather than silently installed on a dead pipe.
        var receiveInstalled = false
        var peerDeathInstalled = false
        var windowProofInstalled = false
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

    func setWindowProofHandler(_ handler: @escaping @Sendable () -> Void) {
        handlers.withLock {
            guard !$0.isShutDown else { return }
            precondition(
                !$0.windowProofInstalled, "XPCPipe.onWindowProvedClosed may only be set once")
            $0.windowProofInstalled = true
            $0.onWindowProvedClosed = handler
        }
    }

    /// Whether the window-proof handler has already been claimed. Exists purely so the steady
    /// state of ``noteWindowProvedClosed()`` is **one relaxed load** rather than a mutex
    /// acquisition: that function is called from every inbound message, on both roles, for the
    /// whole life of the connection, and a dialled pipe never installs a handler at all.
    private let windowProofClaimed = Atomic<Bool>(false)

    /// Whether either libxpc-ordered exit from the accept window has fired: the first inbound
    /// message, or the session's cancellation.
    ///
    /// This is the **authoritative** answer to "has this accepted session's accept window closed?",
    /// and `XPCPipe` reads it instead of storing a guess. It lives here rather than on the pipe
    /// because only this object is on the receiving end of libxpc's callbacks -- and it is
    /// deliberately independent of whether anyone installed a handler, because it records a
    /// platform fact rather than an interest in one.
    var windowIsProvedClosed: Bool { windowProofClaimed.load(ordering: .acquiring) }

    /// Takes the window-proof handler, if it has not already been taken, and fires it on ``queue``.
    ///
    /// Called from **both** libxpc-ordered exits from the accept window, and for every inbound
    /// message rather than only the first, because "first" is not knowable at the call site -- the
    /// claim below is what makes it exactly-once:
    ///
    /// * ``deliver(_:)``, *before* the `{"b": xpc_data}` shape check, because the fact it reports is
    ///   about libxpc rather than about this transport's wire format: a peer whose first message is
    ///   malformed has still proved its session finished being accepted;
    /// * ``peerDied()``, as its first statement, because a peer that connects and then dies without
    ///   ever sending a second message would otherwise leave the proof to arrive never. Measured
    ///   safe: an accepted session's cancellation handler never fires inside the accept window
    ///   (row N8, 40/40). Self-inflicted cancels do not reach here with a handler installed --
    ///   ``shutDown()`` nils the slot before ``XPCPipe/cancel()`` calls `session.cancel(reason:)``.
    ///
    /// In both cases the hop is enqueued *before* the caller's own hop, so an owner learns the
    /// window is closed before the first op, or the peer-death notification, reaches it.
    private func noteWindowProvedClosed() {
        // Fast path, and the only work done for all but one message in a connection's life.
        guard !windowProofClaimed.load(ordering: .relaxed) else { return }
        let (won, _) = windowProofClaimed.compareExchange(
            expected: false, desired: true, ordering: .releasing)
        guard won else { return }

        let handler = handlers.withLock { handlers -> (@Sendable () -> Void)? in
            let taken = handlers.onWindowProvedClosed
            handlers.onWindowProvedClosed = nil
            return taken
        }
        guard let handler else { return }
        queue.async { handler() }
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
        // Before the shape check: any message at all is the proof (see
        // ``noteWindowProvedClosed()``).
        noteWindowProvedClosed()
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
    ///
    /// It is also the **second** exit from the accept window, and that is not incidental: with only
    /// the first-delivery exit, a peer that connected and then died without sending again would
    /// leave its owner's bookkeeping stranded forever, holding a live session. Measured safe by row
    /// N8 (40/40): an accepted session's cancellation handler never fires inside the accept window,
    /// and does fire on peer death.
    func peerDied() {
        // First statement, before this function's own hop, so the proof is enqueued ahead of the
        // peer-death notification and an owner can act on the session while handling the death.
        noteWindowProvedClosed()
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
            // A pipe torn down before its peer ever spoke will never prove its window closed. The
            // handler is dropped rather than fired: firing it would report a fact that is not in
            // evidence, and its whole purpose is to be trustworthy. This is also what makes
            // ``peerDied()``'s proof a no-op for a *self-inflicted* cancel, since
            // ``XPCPipe/cancel()`` runs this before it calls `session.cancel(reason:)`.
            $0.onWindowProvedClosed = nil
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

/// The one ``RPCTransportCore`` instantiation the XPC transports ever build: the mux over an
/// ``XPCPipe``, speaking `CompactWireCodec`'s encoding.
///
/// `RPCTransportCore` is generic over its two seams rather than holding them as existentials, so
/// every `pipe.send` / `codec.encode` / `codec.decode` on the hot path is a static call the
/// optimizer can specialize -- see that type for the release-vs-debug caveat. The seams are still
/// seams: the test target instantiates the core over its own `TestPipe` and its own `HookedCodec`.
/// XPC itself only ever needs this one pairing, and both of `XPCServerTransport.Acceptor`'s tables
/// (`pending`, `connections`) and its `AsyncStream` hold exactly it -- **nothing in either
/// transport wants a heterogeneous collection of cores**, which is the one thing that would have
/// forced an existential back.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
typealias XPCTransportCore = RPCTransportCore<XPCPipe, CompactWireCodec>

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
    private let origin: Origin
    private let delivery: Delivery
    private let state: Mutex<State>

    /// See ``MessagePipe/queue``. This returns the *stored* queue -- the same object every
    /// `async` in ``Delivery`` targets and the same object the session is pointed at (by
    /// `targetQueue:` when dialled, by `setTargetQueue` when accepted). There is one queue here,
    /// not one exposed and one used.
    var queue: DispatchSerialQueue { delivery.queue }

    /// Private: a pipe is only ever built by a factory, because the factories are what make
    /// "handlers installed before anything can be delivered" structural rather than a convention
    /// a caller has to remember.
    private init(session: XPCSession, origin: Origin, delivery: Delivery) {
        self.session = session
        self.origin = origin
        self.delivery = delivery
        switch origin {
        case .accepted:
            // Already live, so nothing to activate. `sessionIsLive` stays **false for the whole
            // life of an accepted pipe** and is not the predicate for one: see
            // ``takeCancelObligation()``, which reads `delivery.windowIsProvedClosed` instead. An
            // accepted session may not be cancelled until libxpc has proved its accept window
            // closed, and this file cannot know that instant -- only libxpc can tell it.
            self.state = Mutex(State(phase: .running, sessionIsLive: false))
        case .dialled:
            // Inactive. Cancelling it now would trap; only a successful `activate()` earns that.
            //
            // Nothing is done to the session here, and in particular its target queue is *not*
            // set: every dial factory already passed `targetQueue: queue` to the initializer, and
            // `delivery.queue` is that same object. A third setting of it (this one, plus
            // `dialling`'s) said nothing the first had not.
            self.state = Mutex(State(phase: .idle, sessionIsLive: false))
        }
    }

    /// The RAII half of the lifecycle: release the native session along the one disposal the
    /// matrix at the top of this file shows to be safe.
    ///
    /// `sessionIsLive` is the predicate "a cancel is owed and is legal right now". Cancelling when
    /// it is false traps; for a *dialled* session, not cancelling when it is true traps on release.
    /// Both directions are measured, so this is a two-sided obligation and not a best-effort
    /// tidy-up.
    ///
    /// **`sessionIsLive == false` does not by itself make release safe, and the two kinds of
    /// session are safe for different reasons.** Reaching `deinit` with a constructed session and
    /// the flag false is legitimate in exactly three ways:
    ///
    ///   - **dialled, `activate()` threw** -- safe because a failed activation *self-invalidates*
    ///     the session. This is the only safe "false" a dialled session has, and ``activate()`` is
    ///     what guarantees no other one exists: see its `.shutDown` arm, which activates before
    ///     cancelling rather than returning early.
    ///   - **accepted, libxpc has not yet proved the accept window closed** -- safe twice over:
    ///     inside the window libxpc holds its own reference, so this release is never the last one
    ///     (row A2), and after it a release of an uncancelled accepted session is safe and does
    ///     deallocate (row A4). This is the case that used to be a process death.
    ///   - **accepted, `building` cancelled the pipe** -- the same case: an accepted session never
    ///     *requires* cancelling in order to be released, so the pipe is released uncancelled.
    ///
    /// The last two are **not** self-invalidation, and reading them that way leads to wrong
    /// conclusions about the whole accept path. See the matrix at the top of this file.
    ///
    /// Taken and cleared under the lock so that a `cancel()` racing this cannot double-cancel --
    /// though in practice `deinit` implies no other reference exists.
    ///
    /// Reaching here at all is the L6 property: nothing libxpc retains points back at the pipe.
    deinit {
        let owesCancel = takeCancelObligation()
        // Handlers first, so a delivery already in flight on `queue` finds nothing to call rather
        // than reaching into an owner that is being torn down.
        delivery.shutDown()
        if owesCancel {
            session.cancel(reason: "XPCPipe deinitialized")
        }
    }

    /// Takes the one-shot "cancel this session" obligation, atomically, and marks it discharged.
    ///
    /// The single place the two kinds of session differ, and the reason they cannot share a stored
    /// flag:
    ///
    ///   - **dialled:** the obligation is *stored*. `sessionIsLive` becomes true when
    ///     ``activate()`` succeeds and is cleared here, because for a dialled session **not**
    ///     cancelling is the trap. Semantics unchanged.
    ///   - **accepted:** the obligation is *asked*, not stored, and the source of truth is libxpc:
    ///     `delivery.windowIsProvedClosed`. Cancelling an accepted session before libxpc has proved
    ///     its accept window closed traps (row A1); releasing one uncancelled never does, inside the
    ///     window or after it (rows A2 and A4). So the safe reading of "not proved yet" is **do
    ///     nothing**, and that is what makes this side of the file free of the span that used to be
    ///     "the one hazard this file cannot close" -- see the header.
    ///
    /// `phase` is the latch rather than `sessionIsLive`, so that a `cancel()` followed by `deinit`
    /// cannot cancel twice on the accepted path either (where `sessionIsLive` is always false and
    /// therefore cannot latch anything). For the dialled path the guard is redundant but harmless:
    /// every path that reaches `.shutDown` has already cleared or never set the flag.
    private func takeCancelObligation() -> Bool {
        state.withLock { st -> Bool in
            guard st.phase != .shutDown else { return false }
            st.phase = .shutDown
            switch origin {
            case .dialled:
                let live = st.sessionIsLive
                st.sessionIsLive = false
                return live
            case .accepted:
                return delivery.windowIsProvedClosed
            }
        }
    }

    // ---------------------------------------------------------------------------------------
    // MARK: MessagePipe
    // ---------------------------------------------------------------------------------------

    /// One blob already turned into the `{"b": xpc_data}` dictionary libxpc will carry. See
    /// ``MessagePipe/Prepared``.
    ///
    /// `@unchecked Sendable`, and the reason is narrow enough to state exactly: the overlay's
    /// `XPCDictionary` is a *mutable* handle on an `xpc_object_t` and so is rightly not `Sendable`,
    /// but this wrapper is `frozen` in practice -- one `let`, built in one place
    /// (``XPCPipe/prepare(_:)``), read in one place (``XPCPipe/send(_:)``), and exposing no way to
    /// reach or mutate the dictionary in between. libxpc's own objects are refcount-safe across
    /// threads; what is not safe is two threads mutating one dictionary, and there is no second
    /// reference here to mutate it through. It also never actually crosses a thread today -- the
    /// core prepares and submits in one synchronous function -- so the annotation buys uniformity
    /// at the seam rather than covering for a real hand-off.
    ///
    /// The `count` is carried alongside because the error message wants it and the built message
    /// no longer has the blob to ask.
    struct Prepared: @unchecked Sendable {
        fileprivate let message: XPCDictionary
        fileprivate let count: Int
    }

    /// Builds the `{"b": xpc_data}` message, which is where the outbound payload copy happens.
    ///
    /// **This is the whole reason `MessagePipe` has a prepare step.** `xpc_dictionary_create` plus
    /// `createXPCRepresentation()` -- the `Data` -> `xpc_data` payload copy -- used to run inside
    /// `RPCTransportCore`'s submission lock, because they lived at the top of `send`. Every writer
    /// contending for that lock blocked a cooperative-pool thread for the duration of another
    /// writer's *copy*, on top of its syscall. Building here moves all of it outside, and the lock
    /// now spans the `xpc_session_send` and nothing else: measured, that halves the hold for small
    /// messages and takes a quarter to a third off it at 64 KiB (table on
    /// ``RPCTransportCore/submission``).
    ///
    /// Deliberately **not** phase-checked. A pipe torn down between this call and ``send(_:)``
    /// would defeat a check here anyway, and the check that matters is the one that guards the
    /// libxpc call -- see `send`. The worst a shut-down pipe costs here is one wasted message.
    func prepare(_ blob: GRPCSwiftData) -> Prepared {
        let message = xpc_dictionary_create(nil, nil, 0)
        // The outbound libxpc crossing -- the only one in this target.
        xpc_dictionary_set_value(message, Self.blobKey, blob.createXPCRepresentation())
        return Prepared(message: XPCDictionary(message), count: blob.count)
    }

    /// Hands one prepared blob to the peer, one-way -- never the reply overload.
    ///
    /// One-way is load-bearing: this transport's flow control is an explicit `credit` op (§O4),
    /// not an XPC reply, so the reply channel stays unused in both directions and either peer can
    /// originate. (The legacy stack used replies as credit; that is gone.)
    ///
    /// Callable from any queue, as `MessagePipe` promises. No lock is held *here* across
    /// `session.send(message:)`: libxpc's own send is thread-safe and totally ordered per
    /// connection, so serializing sends *in this file* would buy nothing but a contention point.
    /// Two blobs handed to `send` concurrently from two threads have no defined order *to*
    /// preserve -- what the contract promises, and what libxpc delivers, is that whichever order
    /// libxpc accepts them in is the order the peer's `onReceive` sees.
    ///
    /// **That last sentence is load-bearing above this file, and it is measured rather than
    /// assumed.** `RPCTransportCore` orders its own outbound ops by serialising the *decision to
    /// send* with the submission under one lock of its own, which is only worth anything if
    /// libxpc's "accepted order" respects a happens-before between two threads' sends. Row **S1**
    /// of `docs/xpc-platform-matrix/SendOrderMatrix.swift`: 20 000 sends from 8 threads, each
    /// issued while holding a lock, arrived in exact submission order, 5 runs out of 5. Its control
    /// row **S2** moves the send outside the lock -- allocating the sequence number under it, as a
    /// check-then-send does -- and reorders 10 168 of 20 000. So the ordering the layers above rely
    /// on comes from *their* serialisation plus libxpc's FIFO, and neither half is sufficient
    /// alone. Note what that row does and does not license: it is the *submission* that has to stay
    /// under the core's lock. ``prepare(_:)`` is not a submission and has no order to keep.
    ///
    /// **The phase check stays here, not in `prepare`**, because here is where it is effective: it
    /// is the guard immediately before the libxpc call, and the core holds its submission lock
    /// across this function, so a `cancel()` cannot land between the check and the send.
    ///
    /// Errors are shaped, never passed through: once the peer is gone libxpc fails the send with
    /// its own rich error, and every caller in this transport -- and gRPC's machinery above it --
    /// expects a transport failure as an `RPCError`.
    func send(_ prepared: Prepared) throws(RPCError) {
        // Fail fast on a pipe that is already torn down. This is the only lock the send path
        // takes, and it is read-only.
        let phase = state.withLock { $0.phase }
        guard phase == .running else {
            throw RPCError(
                code: .unavailable,
                message: "the XPC pipe is not running (\(phase)); the blob was not sent")
        }
        do {
            try session.send(message: prepared.message)
        } catch {
            throw RPCError(
                code: .unavailable,
                message: "the XPC connection is no longer available "
                    + "(sending a \(prepared.count)-byte blob failed: \(error))")
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

    /// Fires once, on `queue`, when this session's accept window is **provably closed** -- at the
    /// first message libxpc delivers on it (whatever its shape, and before that message reaches
    /// ``onReceive(_:)``), or at the session's cancellation, whichever libxpc does first.
    ///
    /// # What it is for
    ///
    /// The span documented at the top of this file -- between `building` returning and the Decision
    /// actually reaching libxpc -- cannot be *observed* by this file, and it turns out it cannot be
    /// observed by the caller either. This hook is what lets both stop trying: it reports the fact
    /// rather than predicting the instant, and it is what closed that span (see the header).
    ///
    /// **Not because the window outlives the closure.** It does not: the window is exactly
    /// `[request.accept() … Decision reaches libxpc]`, and a send immediately after the Decision has
    /// been returned is safe (row A6, 60/60). The reason is the one the top of this file gives --
    /// the caller cannot *observe* the instant the Decision reaches libxpc, so it has no instant it
    /// can name from inside its own closure, and nothing it schedules there is provably after the
    /// window. Measured, in the out-of-process matrix (Task 7 round 4):
    ///
    /// * a `send` **or** a `cancel` enqueued on this pipe's own queue from inside the accept closure
    ///   traps (A7, A10: `_xpc_api_misuse`, ~1 in 150 runs) -- so "hop onto the connection queue" is
    ///   not a fix;
    /// * the same operations from another thread racing the closure's return trap at the same rate
    ///   (A8, A9), and deterministically 30/30 when the window is held open (A8b, A9b) -- so
    ///   "wait for the closure to return" is not a fix either.
    ///
    /// What *is* safe is a libxpc-ordered event, and there are two:
    ///
    /// * **the first delivery**, on three rows that say three different things and are worth not
    ///   collapsing. A11/A12 (200 runs each) say acting from the first delivery does not trap --
    ///   evidence about the *operation*. **A13 (60/60) is the ordering row**: window held open 50 ms
    ///   with a spinner, target queue set as this file sets it, and no delivery lands before
    ///   `return decision`. N3 (150/150) says the triggering blob is redelivered even if the peer
    ///   cancels in its very next statement. Together they support "a message having arrived means
    ///   the window is closed"; A11/A12 alone would not, and an earlier version of this doc said
    ///   they did.
    /// * **the session's cancellation** (N8: 40/40 -- never inside the window, and does fire on peer
    ///   death). This is the exit that bounds the problem: without it, a peer that connected and
    ///   then died would leave an owner's bookkeeping stranded forever, holding a live session.
    ///
    /// So an owner that must send to, cancel, or otherwise touch an accepted session it has just
    /// built should defer that work to this handler rather than doing it in `building` or after
    /// `accepting` returns. `XPCServerTransport.Acceptor` does exactly that.
    ///
    /// - Note: registering from inside `building` cannot miss the triggering message. `building`
    ///   runs inside `accepting`'s `queue.sync`, and every delivery is a `queue.async` onto that
    ///   same serial queue, so the first delivery is necessarily *enqueued behind* the block that
    ///   installs this handler.
    /// - Note: never fires if **this side** cancels the pipe first (``cancel()`` clears the slot
    ///   before it cancels the session), and never fires for a dialled pipe whose peer neither
    ///   speaks nor dies. "Not yet proven" is the safe reading in both cases -- and a peer that
    ///   connects without ever sending cannot occur, because such a peer never reaches the
    ///   incoming-session closure at all (N2, 40/40).
    /// - Important: the same no-strong-capture rule as ``onReceive(_:)``. This handler is held by
    ///   `Delivery`, i.e. by libxpc's end of the retain path, so capturing the pipe or its owner
    ///   strongly leaks the session exactly as it does there.
    func onWindowProvedClosed(_ handler: @escaping @Sendable () -> Void) {
        delivery.setWindowProofHandler(handler)
    }

    /// Tears the pipe down from this side. Idempotent (L7: double shutdown is safe).
    ///
    /// Take-and-transition happens atomically under the lock; `session.cancel(reason:)` is called
    /// **outside** it, because it is a libxpc call that synchronously reaches the session's
    /// cancellation handler and a lock held across it would be held across foreign code.
    ///
    /// A pipe cancelled before it was ever activated (`.idle`) reaches `.shutDown` without
    /// touching the session: `sessionIsLive` is false there, and cancelling a never-activated
    /// session traps. That is **not** the end of the obligation -- releasing that session would
    /// trap as well. The debt is settled by ``activate()``, which sees `.shutDown`, activates the
    /// session anyway and cancels it immediately. Deferring rather than skipping is the only
    /// arrangement that satisfies every row of the disposal matrix at the top of this file.
    func cancel() {
        let owesCancel = takeCancelObligation()
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
    /// - a throw from `session.activate()` self-invalidates the session, so the pipe lands in
    ///   `.shutDown` with `sessionIsLive` false and `deinit` may simply release it -- the only case
    ///   in which releasing an uncancelled **dialled** session is safe (an accepted one is a
    ///   different matter entirely; see the matrix at the top of this file);
    /// - **every other exit still activates first.** A pipe already `.shutDown` when this runs
    ///   (the `building` closure cancelled it) does *not* get to skip activation: an
    ///   `XPCSession` that is merely constructed and released traps exactly as hard as an
    ///   activated-and-uncancelled one. It is activated, then cancelled, then the throw is
    ///   reported. Same for the `.activating -> someone cancelled` window after a successful
    ///   activate. Both windows funnel through the one safe disposal -- see the matrix at the top
    ///   of this file.
    private func activate() throws(RPCError) {
        let cancelledBeforeActivation = try state.withLock { st throws(RPCError) -> Bool in
            switch st.phase {
            case .idle:
                st.phase = .activating
                return false
            case .activating, .running:
                // Throws WITHOUT activating -- the one arm here that does. That is only safe
                // because it is unreachable: `activate()` has a single call site (`dialling`),
                // which calls it once, synchronously, on a pipe no other thread can yet see. If a
                // future caller ever makes a second activation reachable, this arm must not stay
                // as it is: reaching it means a session exists that this throw would abandon, and
                // for a dialled session abandoning it is the trap, not a leak. (Today the session
                // survives regardless -- the pipe still owns it and `deinit` still settles it --
                // but that is a property of there being no second caller, not of this arm.)
                throw RPCError(code: .failedPrecondition,
                               message: "the XPC pipe has already been activated")
            case .shutDown:
                // Cancelled by the `building` closure, before this ran. We must STILL activate:
                // the session exists, and the only non-trapping way to dispose of an existing,
                // non-self-invalidated session is activate-then-cancel. Returning early here is
                // what used to turn `building { $0.cancel() }` into `_xpc_api_misuse` at release.
                return true
            }
        }
        do {
            try session.activate()
        } catch {
            state.withLock { st in
                st.phase = .shutDown
                // Deliberately left false, and this is the ONLY safe "false" for an existing
                // session: a failed `activate()` self-invalidates it, so releasing it is fine and
                // cancelling it is not. Every other path must have activated first.
                st.sessionIsLive = false
            }
            delivery.shutDown()
            throw RPCError(code: .unavailable,
                           message: "could not activate the XPC session: \(error)")
        }
        if cancelledBeforeActivation {
            // Activated purely so that it can be cancelled. `cancel()` already ran `shutDown()`
            // on the delivery, so nothing is reported to the (departing) owner.
            session.cancel(reason: "XPCPipe cancelled before activation")
            throw RPCError(code: .unavailable,
                           message: "the XPC pipe was cancelled before it could be activated")
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
    ///     // `building` runs synchronously, so this is assigned before `accepting` returns.
    ///     var built: XPCTransportCore?
    ///     let (decision, pipe) = XPCPipe.accepting(request, queue: queue) { pipe in
    ///         // Building the core is the whole of the recipe. **Do not install `onReceive` or
    ///         // `onPeerDeath` yourself**: `RPCTransportCore.init` installs both -- weakly, for
    ///         // the retain-cycle reason on `onReceive(_:)` -- and a second call trips the
    ///         // set-once `precondition` on each setter.
    ///         let core = XPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: .server)
    ///         built = core
    ///         // The one handler an owner does install, and here is the only place it cannot miss
    ///         // the triggering message. It captures a *value* (never the core: L6), because it
    ///         // is held at libxpc's end of the retain path.
    ///         let key = ObjectIdentifier(core)
    ///         pipe.onWindowProvedClosed { [weak owner] in owner?.windowProvedClosed(key) }
    ///     }
    ///     …publish `built` -- which owns `pipe` -- to whoever will own the connection…
    ///     return decision
    /// }
    /// try listener.activate()
    /// ```
    ///
    /// `XPCServerTransport.Acceptor.accept(_:)` is that example as shipped, one admission check
    /// wider.
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
    ///   set as the session's target queue. That does **not** make the delivery hop a same-queue
    ///   re-enqueue -- this doc said so until it was measured, and libxpc in fact delivers on its
    ///   own `com.apple.session.queue` (5 000/5 000 on an accepted session), which merely *targets*
    ///   this one. Setting the target queue buys the shared target chain -- so the hop wakes no
    ///   second thread, and an inline delivery would be excluded by this function's own
    ///   `queue.sync` -- but the hop itself is a real cross-queue enqueue that exists to keep
    ///   routing off libxpc's delivery stack and to hold the label/affinity contract. See point 2
    ///   of the header.
    /// - Parameter building: called synchronously with the finished pipe, before the decision is
    ///   handed back to libxpc and before any blob can be dispatched. Install `onReceive` and
    ///   `onPeerDeath` here.
    /// - Returns: the listener decision to return, and the pipe. **The returned pipe is the only
    ///   strong reference** -- nothing in libxpc holds one (L6) -- so whoever calls this owns the
    ///   connection's lifetime.
    ///
    /// - Important: **publish the returned pipe before returning the decision.** Dropping it in
    ///   that span is no longer fatal -- it used to be a process death and is now a released peer,
    ///   see the header -- but it still abandons a connection the peer believes it has, and it
    ///   abandons it *silently*: the session is released uncancelled, so the peer is not hung up
    ///   promptly.
    ///
    ///   **You may not send to, cancel, or otherwise operate on the session in that span**, and that
    ///   has not changed: every such operation traps (rows A5, A7–A10), and this function cannot
    ///   tell you when the span ends because only the caller returns the Decision. Defer any such
    ///   work to ``onWindowProvedClosed(_:)``, which is exactly what it is for.
    ///
    ///   To turn a peer away use ``rejecting(_:reason:)`` *instead of* calling this -- it creates
    ///   no session, so the span does not exist -- rather than accepting and then discarding.
    ///
    /// - Note: `building` calling `pipe.cancel()` is safe (the session is left to be released
    ///   uncancelled, which for an accepted session is measured safe) but pointless -- the peer
    ///   has already been admitted at that point. ``rejecting(_:reason:)`` is what you want.
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

    /// Refuses an inbound session. **This is the correct way to turn a peer away** -- today that
    /// means one thing: the server is draining.
    ///
    /// It does **not** yet mean "a peer requirement failed". There is no peer-gating facility in this
    /// stack: RULING 3 removed `peerAttestation` from ``MessagePipe`` and nothing replaced it, so a
    /// caller has nothing to check a peer against. When one is added this is where the refusal
    /// belongs, which is why the shape is worth stating -- but it is not a use case a caller has
    /// today, and listing it as one implies a facility that does not exist.
    ///
    /// Refusing is not the same as accepting and then cancelling. `reject` never creates an
    /// `XPCSession` at all, so there is nothing to dispose of and none of the accept-window
    /// hazards in the matrix at the top of this file apply. Accepting first and cancelling inside
    /// the listener's closure traps; accepting first and dropping the pipe inside the closure
    /// traps. This does neither.
    ///
    /// It exists here rather than being left to the caller so that the whole accept-side decision
    /// surface (admit / refuse) lives in the one file allowed to `import XPC`.
    static func rejecting(
        _ request: XPCListener.IncomingSessionRequest,
        reason: String
    ) -> XPCListener.IncomingSessionRequest.Decision {
        request.reject(reason: reason)
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
    ) throws(RPCError) -> XPCPipe {
        try dialling(queue: queue, building: build) {
            try XPCSession(endpoint: endpoint, targetQueue: queue, options: .inactive)
        }
    }

    /// Dials a launchd Mach service by name.
    static func connecting(
        toMachService name: String,
        queue: DispatchSerialQueue,
        building build: (XPCPipe) -> Void
    ) throws(RPCError) -> XPCPipe {
        try dialling(queue: queue, building: build) {
            try XPCSession(machService: name, targetQueue: queue, options: .inactive)
        }
    }

    /// Dials an XPC service bundle inside the calling application, by bundle identifier.
    static func connecting(
        toXPCService name: String,
        queue: DispatchSerialQueue,
        building build: (XPCPipe) -> Void
    ) throws(RPCError) -> XPCPipe {
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
    /// Every throw path here leaves a session that is safe to release, and each for its own
    /// reason -- not because "it never activated", which is the belief that used to kill the
    /// process:
    ///
    ///   - `makeSession()` threw: there is no session at all;
    ///   - `session.activate()` threw: libxpc self-invalidated it;
    ///   - the pipe was cancelled inside `building`: ``activate()`` has already done
    ///     activate-then-cancel before rethrowing.
    ///
    /// In all three `sessionIsLive` is false, so `deinit` correctly does not cancel.
    private static func dialling(
        queue: DispatchSerialQueue,
        building build: (XPCPipe) -> Void,
        _ makeSession: () throws -> XPCSession
    ) throws(RPCError) -> XPCPipe {
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
        // No `setTargetQueue(queue)`: `makeSession` passed `targetQueue: queue` to the
        // initializer -- step 1 above -- and this is the same queue object. Setting a session's
        // target queue is not cumulative; the second call only restated the first.
        let pipe = XPCPipe(session: session, origin: .dialled, delivery: delivery)
        build(pipe)
        try pipe.activate()
        return pipe
    }
}
