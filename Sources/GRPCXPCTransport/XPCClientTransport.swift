import Dispatch
import GRPCCore
import Synchronization
import XPC

/// The process-wide source of connection-queue labels, shared by both transports.
///
/// Every connection gets its own `DispatchSerialQueue`, and the label is the only thing that
/// distinguishes them in a crash log, an Instruments trace or a `dispatchPrecondition` failure.
/// A per-object counter is not enough: a test harness (and an XPC service that both serves and
/// dials) runs several transports in one process, and per-object numbering makes every one of
/// their queues read the same. This counter is per *process*, so a label identifies exactly one
/// queue for the run.
///
/// Correctness never depends on the label; readability of a diagnostic does, which is why it is
/// worth the four lines.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum ConnectionQueueLabel {
    private static let counter = Atomic<Int>(0)

    /// - Parameter role: `"client"` or `"server"`.
    /// - Parameter peer: how the peer was named -- a service name, or `"endpoint"`/`"accepted"`.
    static func mint(role: String, peer: String) -> String {
        let n = counter.wrappingAdd(1, ordering: .relaxed).newValue
        return "GRPCXPCTransport.\(role).\(n).\(peer)"
    }
}

/// grpc-swift's `ClientTransport` over one `RPCTransportCore` -- i.e. over one XPC session.
///
/// This type is thin on purpose. Every hard part of a client transport lives one layer down:
/// stream-id allocation, the op grammar, flow control and the deadline timer are all
/// `RPCTransportCore`'s (see `RPCTransportCore.openStream(descriptor:timeout:)`), and the XPC
/// session itself is `XPCPipe`'s. What is left here is exactly four things:
///
/// 1. `connect()`'s lifecycle machine (L7) -- park, and be released **once the last in-flight RPC
///    has finished**, or at once by cancellation of `connect()`'s own task;
/// 2. `withStream`'s obligation to retire the stream on **every** exit path
///    (`clientCallFinished(_:)`, which is also what cancels the deadline timer -- L12);
/// 3. counting live calls, which is what makes (1)'s drain a real barrier;
/// 4. refusing new streams once either side is draining.
///
/// # Ownership (L6)
///
/// `core` is held strongly and is this transport's only stored reference; the core holds the pipe,
/// the pipe holds the `XPCSession`, and libxpc's end of that chain reaches back into the core
/// **weakly** (`RPCTransportCore.init` installs both pipe handlers with `[weak self]`). So nothing
/// outside this transport holds it, and dropping it runs `deinit` all the way down to
/// `session.cancel()`. There is no `deinit` here, and there deliberately is not one: the core's own
/// `deinit` fails every live stream and cancels the pipe, which is the whole of what this type
/// would have to do.
///
/// A `final class`, not a struct, because `state`'s `Synchronization.Mutex` is `~Copyable` and a
/// `Copyable` struct cannot store one.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class XPCClientTransport: ClientTransport {
    public typealias Bytes = GRPCSwiftData

    private let core: RPCTransportCore

    /// The parked ``connect()`` caller's continuation -- and **the reason its payload is a
    /// `Result` rather than the continuation's own failure type**.
    ///
    /// The obvious spelling is `CheckedContinuation<Void, RPCError>`, and it was that until this
    /// commit. It does not survive contact with `withTaskCancellationHandler`, which is plain
    /// `rethrows` and **not** typed-`rethrows`: a `throws(RPCError)` operation closure comes back
    /// out of it as `any Error` (measured -- "thrown expression type 'any Error' cannot be
    /// converted to error type 'RPCError'"), so ``parkUntilReleased()`` could not be
    /// `throws(RPCError)` and ``connect()`` had to cast the erased error back with an unreachable
    /// trap for the case the cast could not rule out.
    ///
    /// Carrying the outcome as a **value** removes the erasure at its source instead of undoing
    /// it afterwards: the operation closure no longer throws, so there is nothing for `rethrows`
    /// to widen, and `Result.get()` is `throws(Failure)` -- the concrete `RPCError` survives the
    /// unwrap on the far side. No cast, and no unreachable branch to justify.
    ///
    /// The failure case is reachable only *before* anything parks (the concurrent-`connect()`
    /// refusal, resolved inside the same `withLock` that would otherwise have parked). Every
    /// resume of a slot that actually parked carries `.success(())`, which is why each of them
    /// below reads `resume(returning: .success(()))` and none of them can spell a failure.
    private typealias ParkedConnect = CheckedContinuation<Result<Void, RPCError>, Never>

    /// `connect()`'s state and the live-call count, under **one** lock because they are one
    /// decision: whether a shutdown may release `connect()` yet.
    ///
    /// The count is not cosmetic. `ClientTransport.connect()`'s contract is *"the function exits
    /// when all open streams have been closed and new connections are no longer required"*, and
    /// `GRPCClient.runConnections()` is documented to return *"once `beginGracefulShutdown()` has
    /// been called and all in-flight RPCs have finished executing"*. An implementation that
    /// resumes `connect()` the moment shutdown is requested turns `runConnections()` into a false
    /// drain barrier -- `await runConnections(); exit(0)` in an XPC service would then kill live
    /// RPCs. The reference implementation resumes only at zero
    /// (`InProcessTransport+Client.swift`: `beginGracefulShutdown` finishes the continuation only
    /// if `openStreams.count == 0`, and `removeStream` finishes it when the last stream closes),
    /// and `.draining` is how that is done here.
    ///
    /// `RPCTransportCore.liveStreamCount` cannot be used for this: it gives the value but not the
    /// *edge*, and the edge -- "the count just reached zero" -- is what has to resume the
    /// continuation exactly once. Hence a transport-side counter, incremented and decremented in
    /// `withStream` under this same lock.
    private struct ConnectState {

        /// Made explicit rather than "one optional continuation slot": that earlier shape let a
        /// second concurrent `connect()` silently overwrite the first's continuation, leaking it
        /// (the runtime reports this as "SWIFT TASK CONTINUATION MISUSE") and stranding the first
        /// caller parked forever.
        ///
        /// | from | event | to | effect |
        /// |---|---|---|---|
        /// | `.idle` | `connect()` | `.connected(c)` | parks |
        /// | `.connected` | a second concurrent `connect()` | unchanged | throws `.failedPrecondition` |
        /// | `.idle`/`.connected`, `liveCalls == 0` | `beginGracefulShutdown()` | `.shutDown` | resumes the parked caller, if any |
        /// | `.idle`/`.connected`, `liveCalls > 0` | `beginGracefulShutdown()` | `.draining(c?)` | resumes **nothing** yet |
        /// | `.draining` | the last live call finishes | `.shutDown` | resumes the parked caller |
        /// | `.draining` | `connect()`, nothing parked | `.draining(c)` | parks; released by the drain |
        /// | any | cancellation of `connect()`'s task | `.shutDown` | fails every stream, then resumes |
        /// | `.shutDown` | `connect()` | unchanged | returns immediately |
        ///
        /// `.draining` carries an *optional* continuation because a shutdown can arrive before any
        /// `connect()` call, and a `connect()` arriving during the drain must still be released by
        /// it rather than parking forever.
        enum Phase {
            case idle
            case connected(ParkedConnect)
            case draining(ParkedConnect?)
            case shutDown
        }

        var phase: Phase = .idle

        /// Raised by `beginGracefulShutdown()` **before** it calls `core.beginDraining()`, and
        /// never lowered.
        ///
        /// It exists for one reason: to make "this side asked for the shutdown" observable no
        /// later than the mux's own draining flag. `phase` cannot do that job, because the phase
        /// transition needs `liveCalls`, and reading `liveCalls` means taking this lock -- which
        /// `beginGracefulShutdown()` must not hold across `core.beginDraining()` (L7: that call
        /// reaches libxpc through `pipe.send`). So the two updates cannot be one atomic step, and
        /// the only remaining choice is which of them lands first.
        ///
        /// **They used to land in the wrong order**, and the window between them was reachable: a
        /// `withStream` running there passed the gate below (`isShuttingDown` still false), saw
        /// `core.isDraining` true, re-read the phase, still found `.idle` -- and reported a
        /// purely local, permanent shutdown as `.unavailable` "the peer sent goAway", i.e. as
        /// *retryable* and as *the peer's fault*. `withStream`'s contract gives those two codes
        /// distinct meanings (`.failedPrecondition` = "closing or closed", `.unavailable` = "may
        /// be possible after some backoff"), so a caller acts on the difference.
        ///
        /// This flag closes that window by landing first, which makes the implication one-way and
        /// safe: *a local drain is visible here at least as early as it is visible in the mux*.
        /// The opposite skew -- this true while `core.isDraining` is still false -- is harmless,
        /// because the gate below already refuses with the local, permanent error.
        var localShutdownRequested = false

        /// Calls that have claimed a slot in `withStream` and not yet released it. Claimed before
        /// `openStream`, released by a `defer`, so it counts exactly the window in which an RPC
        /// could still be running.
        var liveCalls = 0

        /// Whatever continuation is parked, whichever phase holds it. Read-only: every caller
        /// assigns a new phase immediately afterwards, which is what empties the slot.
        var parked: ParkedConnect? {
            switch phase {
            case .connected(let continuation): continuation
            case .draining(let continuation): continuation
            case .idle, .shutDown: nil
            }
        }

        /// Whether new streams are refused. Every case is **permanent** for this transport --
        /// there is no reconnect -- which is why `withStream` reports them as
        /// `.failedPrecondition` rather than `.unavailable`.
        ///
        /// `localShutdownRequested` is part of the answer and not merely a hint at one: it is the
        /// half of a local shutdown that is already visible while `beginGracefulShutdown()` is
        /// still inside `core.beginDraining()`, and refusing there is exactly as correct as
        /// refusing a moment later -- the shutdown has been asked for and will not be revoked.
        var isShuttingDown: Bool {
            if localShutdownRequested { return true }
            switch phase {
            case .idle, .connected: return false
            case .draining, .shutDown: return true
            }
        }
    }
    private let state = Mutex(ConnectState())

    /// What a caller that just transitioned the state owes the outside world. Returned from under
    /// the lock and acted on outside it (L7).
    ///
    /// The three cases are mutually exclusive by construction, which is the point of making this a
    /// sum type rather than a pair: `closeSubstrate` is returned **exactly when** the transition
    /// reached `.shutDown` with nothing parked, and `resume` exactly when there was something
    /// parked. So "who releases the XPC session" has one answer per shutdown:
    ///
    /// * something was parked -> resume it, and `connect()`'s own tail calls `core.close()`;
    /// * nothing was parked -> no `connect()` tail will ever run, so **this** caller closes.
    private enum Completion {
        case nothing
        case resume(ParkedConnect)
        case closeSubstrate
    }

    /// Applies a ``Completion`` outside the lock.
    private func complete(_ completion: Completion) {
        switch completion {
        case .nothing:
            break
        case .resume(let continuation):
            continuation.resume(returning: .success(()))
        case .closeSubstrate:
            core.close()
        }
    }

    /// Adopts an already-live client-role core. The factories below are the ordinary way in; this
    /// exists separately because the in-process pair (`XPCServerTransport.connectingClient()`)
    /// builds its core from an endpoint, which only the XPC-importing file can name.
    init(core: RPCTransportCore) {
        precondition(
            core.role == .client,
            "XPCClientTransport requires a client-role RPCTransportCore: only a client allocates "
                + "stream ids")
        self.core = core
    }

    // =======================================================================================
    // MARK: - Dialling
    // =======================================================================================

    /// How a client names its peer. Deliberately *not* including an `XPCEndpoint` case: naming
    /// that type would mean `import XPC` in this file, and the accept/dial traps documented in
    /// `XPCPipe` are only encapsulated while the set of files that can reach libxpc stays at
    /// `XPCPipe.swift`, `GRPCDispatchData.swift` and `XPCServerTransport.swift`. Endpoint dialling
    /// therefore lives on the server transport, which already owns an `XPCListener`.
    private enum Peer {
        case machService(String)
        case xpcService(String)
        case peer(XPCEndpoint)

        var label: String {
            switch self {
            case .machService(let name): "machService:\(name)"
            case .xpcService(let name): "xpcService:\(name)"
            // No interpolation: an anonymous endpoint has no stable name a human could match
            // against anything, and this string ends up as a dispatch queue label in crash logs.
            // `dialledCore` already appends a process-wide counter, which is what distinguishes
            // one anonymous dial from the next.
            case .peer: "endpoint"
            }
        }
    }

    /// Dials a launchd Mach service by name and returns a transport speaking to it.
    ///
    /// The session is live when this returns -- `XPCPipe`'s dial factory activates it -- so
    /// `connect()` has no connecting work to do.
    ///
    /// **This throws for a name that does not resolve**, which is a correction: it used to say a
    /// missing peer "is not an error here" and would surface later as peer death. Measured in Task
    /// 8b §6.1, and a change in the platform since Task 5 rather than a change here --
    /// `XPCSession(machService:)` with a well-formed but nonexistent name now throws from
    /// `activate()` ("Underlying connection was invalidated ... Bad file descriptor"), where it
    /// used to activate successfully. A launchd job that exists but is not running still launches
    /// on demand as before; it is a name with no job behind it that now fails early.
    ///
    /// A peer that dies later still surfaces as peer death, which fails every stream with
    /// `.unavailable`.
    public static func connecting(toMachService name: String) throws(RPCError) -> XPCClientTransport {
        try dialling(.machService(name))
    }

    /// Dials an XPC service bundle inside the calling application, by bundle identifier.
    public static func connecting(toXPCService name: String) throws(RPCError) -> XPCClientTransport {
        try dialling(.xpcService(name))
    }
    
    /// Dials an **anonymous** listener's endpoint -- the third topology, and the one a launchd
    /// name cannot express.
    ///
    /// `XPCEndpoint` is not discoverable: the server side gets one from
    /// ``XPCServerTransport/anonymous()``'s ``XPCServerTransport/endpoint`` and has to hand it to
    /// this side over a channel that already exists, which is the ordinary XPC brokering pattern
    /// (a broker service vends per-client endpoints over its own connection). That is why this
    /// takes an endpoint rather than a name, and why there is nothing to look up.
    ///
    /// Taking an `XPCEndpoint` is what obliges this file to `import XPC`; the rest of the op
    /// layer stays substrate-agnostic.
    public static func connecting(to endpoint: XPCEndpoint) throws(RPCError) -> XPCClientTransport {
        try dialling(.peer(endpoint))
    }


    /// **The one build-a-client-core recipe.** Mints the connection queue, builds the mux inside
    /// `building`, and hands back both halves.
    ///
    /// Every dial in this package goes through here -- the two public factories above,
    /// `XPCServerTransport.connectingClient()` (which dials an `XPCEndpoint`, a type this file may
    /// not name), and the test suite's `InspectableXPCPair`. It was written out three times
    /// before, invariant comments and all, which meant a change to pipe retention or handler
    /// installation had to be made three times or the dial paths would diverge -- from each other,
    /// and from the one the tests claim to be inspecting. This is not ordinary duplication to
    /// tolerate: the accept/dial recipe is where both of this project's reproduced process deaths
    /// lived.
    ///
    /// The invariants, all four of them, now stated once:
    ///
    /// * **One serial queue per connection** (Task 5 §6.4). Nothing else may share it: the mux
    ///   decodes and routes every inbound blob on it, and `XPCPipe.accepting` blocks on the queue
    ///   it is handed.
    /// * **`building` installs no pipe handlers.** It constructs the core and nothing else;
    ///   `RPCTransportCore.init` installs `onReceive`/`onPeerDeath` itself, and **weakly** (L6).
    ///   Installing them here would *replace* the core's -- `XPCPipe`'s setters are set-once and
    ///   trap on a `precondition` -- and silently disconnect the mux.
    /// * **`building` runs synchronously**, inside the dial factory and before the session is
    ///   activated, which is what makes the `guard` below unreachable and lets a `var` capture
    ///   carry the core back out.
    /// * **The pipe is not this function's to drop.** `core` holds it strongly, so the reference
    ///   returned here is never its last one; a caller that wants only the transport discards it
    ///   (`_ =`) and a caller whose *subject* is the pipe keeps it. Either is safe: a dialled
    ///   pipe's one safe disposal is activate-then-cancel, and whichever of `core.close()` /
    ///   `XPCPipe.deinit` gets there first performs exactly one cancel (the obligation is taken
    ///   and cleared under the pipe's own lock). See `XPCPipe`'s disposal matrix.
    ///
    /// - Parameter peer: how the peer was named, for the queue label only -- see
    ///   ``ConnectionQueueLabel``. Correctness never depends on it.
    /// - Parameter dial: **exactly one of `XPCPipe`'s three dial factories**, applied to the queue
    ///   and `building` closure this function supplies. A closure rather than a `Peer` case
    ///   because `XPCEndpoint` cannot be named in this file (see ``Peer``), and the endpoint dial
    ///   is one of the callers this recipe has to cover.
    /// - Returns: the live core and the pipe it was built on.
    static func dialledCore(
        peer: String,
        _ dial: (DispatchSerialQueue, (XPCPipe) -> Void) throws(RPCError) -> XPCPipe
    ) throws(RPCError) -> (core: RPCTransportCore, pipe: XPCPipe) {
        let queue = DispatchSerialQueue(
            label: ConnectionQueueLabel.mint(role: "client", peer: peer))

        var built: RPCTransportCore?
        let pipe = try dial(queue) { pipe in
            built = RPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: .client)
        }

        guard let core = built else {
            // Unreachable: every dial factory calls `building` synchronously before returning. A
            // trap rather than a thrown error, because the only way here is a broken `XPCPipe`,
            // and recovering would mean handling a pipe with no mux behind it.
            preconditionFailure("XPCPipe.connecting did not run its `building` closure")
        }
        return (core, pipe)
    }

    private static func dialling(_ peer: Peer) throws(RPCError) -> XPCClientTransport {
        let (core, _) = try dialledCore(peer: peer.label) { (queue, building) throws(RPCError) in
            switch peer {
            case .machService(let name):
                try XPCPipe.connecting(toMachService: name, queue: queue, building: building)
            case .xpcService(let name):
                try XPCPipe.connecting(toXPCService: name, queue: queue, building: building)
            case .peer(let endPoint):
                try XPCPipe.connecting(to: endPoint, queue: queue, building: building)
            }
        }
        return XPCClientTransport(core: core)
    }

    // =======================================================================================
    // MARK: - ClientTransport
    // =======================================================================================

    /// No throttle: retry policy is a `MethodConfig` concern and this transport supplies none.
    public var retryThrottle: RetryThrottle? { nil }

    /// Blocks until `beginGracefulShutdown()` has been called **and every in-flight RPC has
    /// finished**, or until this call's own task is cancelled.
    ///
    /// That is `ClientTransport.connect()`'s documented contract -- *"the function exits when all
    /// open streams have been closed and new connections are no longer required"* -- and it is
    /// what makes `GRPCClient.runConnections()` a real drain barrier rather than a signal that a
    /// drain was requested. See ``ConnectState`` for the state table and for why the count is
    /// kept here rather than read from the mux.
    ///
    /// **Returning normally on cancellation, not throwing `CancellationError`, matters beyond
    /// style:** `GRPCClient.runConnections()` calls `transport.connect()` and wraps *any* thrown
    /// error -- cancellation included -- in a `RuntimeError(code: .transportError, ...)`, which
    /// would misreport an ordinary cancelled shutdown as a transport failure.
    ///
    /// There is genuinely no connecting work to do: `XPCPipe`'s dial factory returns an already
    /// activated session, so by the time a transport exists the connection exists.
    ///
    /// A second, concurrent call while one `connect()` is already parked is refused with a thrown
    /// `RPCError(code: .failedPrecondition)` rather than silently clobbering the first -- gRPC's
    /// own client throws (`RuntimeError`) rather than traps when its analogous
    /// `runConnections()` is misused this way, so a thrown error is the precedent this follows; a
    /// caller that never calls `connect()` twice concurrently (the documented, correct usage)
    /// never sees it.
    ///
    /// **That refusal is the only error this can produce, which is why it is `throws(RPCError)`.**
    /// The parked continuation is resumed with `resume()` on every path that releases it -- the
    /// drain, the last in-flight call finishing, and cancellation -- so nothing but
    /// ``concurrentConnect`` ever travels through it, and the continuation's failure type is
    /// `RPCError` rather than `any Error`. Narrowing a witness of `ClientTransport.connect()`'s
    /// untyped `throws` requirement is allowed (a `throws(E)` function is a subtype of a `throws`
    /// one) and costs a caller nothing: an existing `catch` still catches it.
    public func connect() async throws(RPCError) {
        // The concurrent-call refusal propagates from here, thrown before anything was parked,
        // and must **not** reach the tail below -- see the last paragraph of that comment. It is
        // an ordinary typed `try` and no longer a cast with an unreachable trap behind it,
        // because ``ParkedConnect`` keeps the outcome a value across
        // `withTaskCancellationHandler` instead of letting it be erased and re-narrowed.
        try await parkUntilReleased()

        // **This is where the XPC session is released**, and it is deliberately in the tail rather
        // than in either of the two paths that get here, because it is the one point both of them
        // pass through: a completed graceful drain, and a cancelled `connect()`. The client's
        // counterpart to `listen()`'s trailing `acceptor.closeAll()`.
        //
        // `core.failAll` -- which is what `onCancel` calls, and all it calls -- does **not** touch
        // the pipe; `core.close()` is `failAll` *plus* `pipe.cancel()`. Without this line nothing
        // on the client side ever cancelled the session, so a transport held for the lifetime of
        // the application (which `ClientTransport`'s own guidance recommends) kept it open
        // indefinitely after shutting down, and only `deinit` closed it.
        //
        // Safe here, and only here -- but the two paths that reach it are safe for **different
        // reasons**, and an earlier version of this comment gave the graceful one's reason for both:
        //
        // * **graceful** (`beginGracefulShutdown()`, then the last call drains): `liveCalls == 0` by
        //   the time this runs, and by the LIFO ordering of `withStream`'s two `defer`s every stream
        //   is already out of the mux's table with its ops already handed to `pipe.send`. So this
        //   fails nothing that is live.
        // * **cancelled** (this call's task): `liveCalls` may be **non-zero** -- and this is where
        //   the old comment was wrong, because `shutDownForcefully()` sets `.shutDown`
        //   unconditionally without reading or zeroing the count, so bodies can still be unwinding.
        //   What makes it safe is not the count but the ordering: `onCancel` has already run
        //   `core.failAll(...)`, so every stream is failed and every parked waiter woken *before*
        //   this line, and `close()`'s own `failAll` finds nothing left to fail. gRPC documents task
        //   cancellation as the forceful lever precisely so that in-flight calls do not have to be
        //   waited for.
        //
        // In both cases: a `withStream` body still unwinding finds `clientCallFinished` a no-op, and
        // a `pipe.send` after `cancel()` throws `.unavailable`, which is the correct surface. And
        // `close()` is idempotent, so the `.shutDown`-returns-immediately arm reaching it is
        // harmless.
        //
        // A *second*, concurrent `connect()` throws `concurrentConnect` above and never reaches
        // this line -- which is required, not incidental: it must not close the session out from
        // under the first `connect()`.
        core.close()
    }

    /// ``connect()``'s suspension.
    ///
    /// `throws(RPCError)` across a `withTaskCancellationHandler`, which is plain `rethrows` and
    /// would erase a typed throw to `any Error`. It does not erase this one because **nothing is
    /// thrown inside it**: the operation closure is non-throwing and yields a
    /// `Result<Void, RPCError>` (see ``ParkedConnect``), and the `try` happens on the far side of
    /// the erasing call, where `Result.get()`'s `throws(Failure)` gives back the concrete type.
    ///
    /// Still split out from ``connect()`` so the drain barrier's tail reads as a tail rather than
    /// as the continuation of a suspension.
    private func parkUntilReleased() async throws(RPCError) {
        let outcome: Result<Void, RPCError> = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: ParkedConnect) in
                // L7: take-and-transition under the lock, resume *outside* it.
                let immediate: Result<Void, RPCError>? = state.withLock { state in
                    if state.parked != nil {
                        return .failure(Self.concurrentConnect)
                    }
                    switch state.phase {
                    case .idle:
                        state.phase = .connected(continuation)
                        return nil  // parked; resumed by the drain or by cancellation
                    case .connected:
                        // Unreachable: `.connected` always carries a continuation, so the
                        // `parked != nil` test above caught it. Kept exhaustive rather than
                        // `default:` so a future phase cannot fall through silently.
                        return .failure(Self.concurrentConnect)
                    case .draining:
                        // A shutdown is already under way with RPCs still in flight. Park: the
                        // last of them to finish releases this call, which is the same contract
                        // as parking before the shutdown.
                        state.phase = .draining(continuation)
                        return nil
                    case .shutDown:
                        return .success(())
                    }
                }
                switch immediate {
                case .success: continuation.resume(returning: .success(()))
                case .failure(let error): continuation.resume(returning: .failure(error))
                case nil: break  // parked above; nothing to resume yet
                }
            }
        } onCancel: {
            // `beginGracefulShutdown()`'s own documentation names this as *the* forceful lever:
            // "If you want to forcefully cancel all active streams then cancel the task running
            // `connect()`." So this is not a quiet variant of the graceful path -- it fails every
            // live stream (which also wakes every waiter parked on a flow-control window, since
            // `failAll` fails the connection window too) and only then releases `connect()`.
            //
            // **`failAll` fails the streams; it does not touch the pipe.** Releasing the XPC
            // session is `core.close()`'s job and happens in ``connect()``'s tail, which both
            // this path and a completed graceful drain pass through. Saying it here instead would
            // be the round-1 mistake again: a comment claiming a teardown the code does not do,
            // in the file's most lifecycle-critical spot.
            //
            // Safe from a cancellation handler: `failAll` takes its snapshot under the registry
            // lock and resumes/fails everything outside it.
            self.core.failAll(
                RPCError(
                    code: .unavailable,
                    message: "the client's connect() task was cancelled"))
            self.shutDownForcefully()?.resume(returning: .success(()))
        }
        // `Result.get()` is `throws(Failure)`, so this is where the concrete `RPCError` comes
        // back -- outside the `rethrows` call that would have erased it.
        return try outcome.get()
    }

    /// A local shutdown is **permanent** for this transport -- there is no reconnect -- so
    /// `withStream`'s documented mapping applies: `.failedPrecondition` for "the transport is
    /// closing or has been closed", and `.unavailable` only for "temporarily not possible... may be
    /// possible after some backoff". Telling a caller to back off and retry a transport that will
    /// never reopen would be a lie. `InProcessTransport+Client` reports the same condition the same
    /// way.
    private static let localShutdownRefusal = RPCError(
        code: .failedPrecondition,
        message: "no new streams: this transport has begun shutting down")

    /// The peer's `goAway`, by contrast, *is* retryable in the sense `.unavailable` means: this
    /// connection is finished, another one to the same peer may work.
    private static let peerDrainingRefusal = RPCError(
        code: .unavailable,
        message: "no new streams: the connection is draining (the peer sent goAway, or it has "
            + "been torn down)")

    private static let concurrentConnect = RPCError(
        code: .failedPrecondition,
        message: "XPCClientTransport.connect() is already running "
            + "-- it must not be called more than once concurrently")

    /// Begins a **graceful** shutdown: sends `goAway`, refuses new calls, and lets the calls
    /// already in flight run to completion. Returns immediately -- the waiting happens in
    /// `connect()`.
    ///
    /// Four things happen, **in this order, and the first one is load-bearing**:
    /// 1. `ConnectState.localShutdownRequested` is raised, which closes the local gate
    ///    `withStream` checks. It happens *before* step 2 so that no observer can ever see the mux
    ///    draining without also seeing that **this side** asked for it -- see the flag's own doc
    ///    comment for the misreport that ordering prevents;
    /// 2. `core.beginDraining()` -- `goAway` on the wire, and `openStream` throws `.unavailable`
    ///    from here on, so `withStream` refuses new calls even if it were asked past the local
    ///    gate;
    /// 3. this transport moves to `.draining` (RPCs still in flight) or straight to `.shutDown`
    ///    (none), which is what a parked `connect()` waits on;
    /// 4. a parked `connect()` is resumed **only in the second case**. Otherwise the last
    ///    in-flight call to finish resumes it, in ``callDidFinish()``.
    ///
    /// Steps 3 and 4 stay *after* step 2 for a reason of their own: step 4 is what lets
    /// `connect()`'s tail run `core.close()`, and closing before `beginDraining()` had its turn
    /// would cancel the pipe with the `goAway` never sent -- the peer would learn of an orderly
    /// shutdown as peer death. So the local flag moves to the front, and nothing else moves.
    ///
    /// It deliberately does **not** call `core.failAll(...)`: failing in-flight streams is the
    /// opposite of draining them, and cancelling `connect()`'s task is the forceful lever gRPC
    /// documents for that.
    ///
    /// It also does not call `core.close()` **here**, because when this method returns the drain is
    /// not over -- there may be RPCs still running, and closing would cut them off. The session is
    /// released in `connect()`'s tail instead, which both the graceful and the cancelled exit pass
    /// through, *with one exception this method has to cover itself*: if the shutdown arrives with
    /// nothing parked and no live calls, no `connect()` will ever run that tail, so this call is
    /// the last one able to close and does. (Same for ``callDidFinish()`` when the last live call
    /// drains with nothing parked.) That is what `Completion.closeSubstrate` carries.
    ///
    /// Idempotent: a second call finds `.draining`/`.shutDown` and changes nothing, and
    /// `beginDraining()` is itself a no-op once draining.
    public func beginGracefulShutdown() {
        state.withLock { $0.localShutdownRequested = true }
        core.beginDraining()
        let completion: Completion = state.withLock { state in
            // Keyed on the **phase**, not on `isShuttingDown`: the line above has just made
            // `isShuttingDown` true, so guarding on it would make this block unreachable and
            // nothing would ever leave `.idle`. The phase is still the whole of the idempotence
            // question -- `.draining`/`.shutDown` is exactly "a previous call (or a cancellation)
            // already did this".
            switch state.phase {
            case .draining, .shutDown: return .nothing
            case .idle, .connected: break
            }
            let parked = state.parked
            guard state.liveCalls == 0 else {
                state.phase = .draining(parked)
                return .nothing
            }
            state.phase = .shutDown
            if let parked { return .resume(parked) }
            return .closeSubstrate
        }
        complete(completion)
    }

    /// One `withStream` call has released its claim. If that was the last one and a drain is
    /// waiting on it, this is the edge that finally lets `connect()` return.
    ///
    /// Called from a `defer` in `withStream`, so it runs on every exit path -- and *after* the
    /// stream's own retirement `defer`, since defers unwind last-in-first-out. That order is
    /// load-bearing: when the count reaches zero every stream really has been retired, rather
    /// than merely being about to be.
    private func callDidFinish() {
        let completion: Completion = state.withLock { state in
            state.liveCalls -= 1
            guard case .draining(let parked) = state.phase, state.liveCalls == 0 else {
                return .nothing
            }
            state.phase = .shutDown
            if let parked { return .resume(parked) }
            // The shutdown arrived before any `connect()` did, and none came since, so no
            // `connect()` tail will run: this is the last caller able to release the session.
            return .closeSubstrate
        }
        complete(completion)
    }

    /// Moves straight to `.shutDown` and hands back whatever `connect()` call was parked, if any.
    /// The forceful counterpart to `beginGracefulShutdown()`'s bookkeeping, used only by
    /// cancellation of `connect()`'s own task.
    ///
    /// Called at most once per parked continuation because the slot is emptied by the same
    /// `withLock` that reads it, so a second caller (cancellation racing a shutdown, or a
    /// duplicate shutdown) gets `nil` back -- never a second resume of the same continuation,
    /// which would trap.
    ///
    /// The continuation is *returned* rather than resumed here so the resume happens outside the
    /// lock (L7).
    private func shutDownForcefully() -> ParkedConnect? {
        state.withLock { state in
            let parked = state.parked
            state.phase = .shutDown
            return parked
        }
    }

    /// Opens one RPC, runs `closure` against it, and retires it on the way out.
    ///
    /// # The deadline (L12)
    ///
    /// **Exactly one timer is armed per deadline-bearing RPC, and this method arms none of them.**
    /// `options.timeout` is passed to `RPCTransportCore.openStream(descriptor:timeout:)`, which
    /// arms a single `DispatchSourceTimer` on the connection's queue, owned by the stream's
    /// registry entry. On expiry it does exactly what this method's predecessor did by hand: a
    /// `cancel` op to the peer, and the local inbound half failed with
    /// `RPCError(code: .deadlineExceeded)` -- which is what unblocks the closure, since its
    /// `stream.inbound` iteration throws and any writer parked on credit is released.
    ///
    /// The old build armed a `Task { try await Task.sleep(...) }` here as well. That is now a
    /// *second* timer for the same RPC, which is precisely what L12 forbids, so it is gone. The
    /// core's timer is cancelled by every path that removes the stream from the table -- and
    /// `defer { core.clientCallFinished(id) }` below is what guarantees one of those paths runs on
    /// **every** exit from this method: a normal return, a throw from `closure`, and cancellation
    /// of this call's task (the `defer` runs while unwinding either way). After a clean completion
    /// the call is free: the entry is already gone, so `clientCallFinished` finds nothing, sends
    /// nothing, and returns.
    ///
    /// The same `defer` is the "send `cancel` if the stream did not terminate cleanly" rule: the
    /// *presence of a table entry* at that moment is the definition of "did not complete", so
    /// `clientCallFinished` needs no other signal to decide.
    public func withStream<T: Sendable>(
        descriptor: MethodDescriptor,
        options: CallOptions,
        _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T
    ) async throws -> T {
        // Claim a slot in the drain count, and check the local gate, under **one** lock. Both
        // halves have to be atomic: a `beginGracefulShutdown()` racing this either loses (the
        // call is claimed and the drain waits for it) or wins (this throws) -- never both, which
        // is what an unclaimed-but-opening call would be.
        //
        // `.failedPrecondition`, not `.unavailable`: `withStream`'s own documentation assigns
        // `.failedPrecondition` to "the transport is closing or has been closed" and reserves
        // `.unavailable` for "temporarily not possible... may be possible after some backoff".
        // This transport has no reconnect, so a local shutdown is permanent and telling a caller
        // to back off and retry would be a lie. (`InProcessTransport+Client` reports the same
        // condition the same way.)
        let refusal: RPCError? = state.withLock { state in
            guard !state.isShuttingDown else { return Self.localShutdownRefusal }
            state.liveCalls += 1
            return nil
        }
        if let refusal { throw refusal }
        // Installed before anything that can throw, so the claim is released on every exit.
        defer { callDidFinish() }

        // The peer's own drain is a different condition and keeps `.unavailable`: the peer sent
        // `goAway`, so another connection to it may well work, which is exactly what
        // `.unavailable` means. Failing here is strictly better than opening a stream the peer
        // will immediately refuse. `core.openStream` also checks, under its own lock, so this is
        // a clearer error rather than the only gate.
        //
        // The local state is **re-read** rather than assumed, because `core.isDraining` is the
        // disjunction of the mux's three flags (`isClosed || localDraining || peerDraining`): a
        // local `beginGracefulShutdown()` landing between the gate above and this check would
        // otherwise be reported as a retryable `.unavailable` *and* blamed on the peer -- which
        // inverts the very distinction the code above exists to draw.
        //
        // The re-read only works because the two flags are **ordered**:
        // `beginGracefulShutdown()` raises `localShutdownRequested` before it calls
        // `core.beginDraining()`, so `core.isDraining` can never be true *because of this side*
        // while this re-read still answers "not shutting down". Until that ordering existed the
        // re-read was correct and still lost the race it was written to win -- the window it
        // could not see was inside `beginGracefulShutdown()` itself.
        if core.isDraining {
            throw state.withLock { state -> RPCError in
                state.isShuttingDown ? Self.localShutdownRefusal : Self.peerDrainingRefusal
            }
        }

        // The `openStream` op is not sent here: `RequestOpEncoder` prepends it to whatever the
        // first part produces, so a stream that is opened and abandoned costs the peer nothing
        // *until the first write or `finish()`*. Note that `finish()` below is unconditional and
        // does emit the deferred `openStream` when nothing else was written, so a closure that
        // throws before writing still opens a stream on the peer and has its handler cancelled.
        // That is `withStream`'s contract, not an oversight -- see the `finish()` note below.
        let (id, stream) = try core.openStream(descriptor: descriptor, timeout: options.timeout)
        defer { core.clientCallFinished(id) }

        let context = ClientContext(
            descriptor: descriptor,
            remotePeer: "xpc:peer",
            localPeer: "xpc:self")

        // Mirrors `GRPCInProcessTransport`'s client: the closure's own result (success or thrown
        // error) is what this method returns/rethrows, but the stream's outbound side is always
        // closed on the way out -- "the opened stream is closed after the closure is finished" is
        // `ClientTransport.withStream`'s documented contract, not optional cleanup. `finish()` is
        // safe even if `closure` already called it: `OutboundOpWriter` is idempotent there and,
        // once its encoder has thrown, deliberately silent. It also cannot suspend, even in a
        // cancelled task: `halfClose` is a control op and control ops bypass flow control.
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await closure(stream, context))
        } catch {
            outcome = .failure(error)
        }
        await stream.outbound.finish()
        return try outcome.get()
    }

    /// No per-method configuration: this transport negotiates nothing (§O5) and supplies no
    /// retry or hedging policy.
    public func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? { nil }
}
