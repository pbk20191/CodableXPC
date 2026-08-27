import Dispatch
import GRPCCore
import Synchronization

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
            case connected(CheckedContinuation<Void, any Error>)
            case draining(CheckedContinuation<Void, any Error>?)
            case shutDown
        }

        var phase: Phase = .idle

        /// Calls that have claimed a slot in `withStream` and not yet released it. Claimed before
        /// `openStream`, released by a `defer`, so it counts exactly the window in which an RPC
        /// could still be running.
        var liveCalls = 0

        /// Whatever continuation is parked, whichever phase holds it. Read-only: every caller
        /// assigns a new phase immediately afterwards, which is what empties the slot.
        var parked: CheckedContinuation<Void, any Error>? {
            switch phase {
            case .connected(let continuation): continuation
            case .draining(let continuation): continuation
            case .idle, .shutDown: nil
            }
        }

        /// Whether new streams are refused. Both cases are **permanent** for this transport --
        /// there is no reconnect -- which is why `withStream` reports them as
        /// `.failedPrecondition` rather than `.unavailable`.
        var isShuttingDown: Bool {
            switch phase {
            case .idle, .connected: false
            case .draining, .shutDown: true
            }
        }
    }
    private let state = Mutex(ConnectState())

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

        var label: String {
            switch self {
            case .machService(let name): "machService:\(name)"
            case .xpcService(let name): "xpcService:\(name)"
            }
        }
    }

    /// Dials a launchd Mach service by name and returns a transport speaking to it.
    ///
    /// The session is live when this returns -- `XPCPipe`'s dial factory activates it -- so
    /// `connect()` has no connecting work to do. A peer that is not there yet is not an error here:
    /// libxpc will launch or wait for it, and a peer that never appears surfaces as peer death,
    /// which fails every stream with `.unavailable`.
    public static func connecting(toMachService name: String) throws -> XPCClientTransport {
        try dialling(.machService(name))
    }

    /// Dials an XPC service bundle inside the calling application, by bundle identifier.
    public static func connecting(toXPCService name: String) throws -> XPCClientTransport {
        try dialling(.xpcService(name))
    }

    private static func dialling(_ peer: Peer) throws -> XPCClientTransport {
        // One serial queue per connection (Task 5 §6.4). Nothing else may share it: the mux
        // decodes and routes every inbound blob on it, and `XPCPipe.accepting` blocks on the
        // queue it is handed.
        let queue = DispatchSerialQueue(
            label: ConnectionQueueLabel.mint(role: "client", peer: peer.label))

        // `building` runs synchronously inside the factory, before the session is activated, and
        // `RPCTransportCore.init` installs both pipe handlers itself (weakly). Installing our own
        // here would *replace* the core's and silently disconnect the mux.
        var built: RPCTransportCore?
        let build: (XPCPipe) -> Void = { pipe in
            built = RPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: .client)
        }
        // The returned pipe is intentionally discarded: `built` holds it strongly, so this is not
        // its last reference. (A dialled pipe must be activate-then-cancelled before release, and
        // `XPCPipe` owns that -- see its disposal matrix.)
        switch peer {
        case .machService(let name):
            _ = try XPCPipe.connecting(toMachService: name, queue: queue, building: build)
        case .xpcService(let name):
            _ = try XPCPipe.connecting(toXPCService: name, queue: queue, building: build)
        }

        guard let core = built else {
            // Unreachable: both factories call `building` synchronously before returning. A trap
            // rather than a thrown error, because the only way here is a broken `XPCPipe`, and
            // recovering would mean handling a pipe with no mux behind it.
            preconditionFailure("XPCPipe.connecting did not run its `building` closure")
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
    public func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                // L7: take-and-transition under the lock, resume *outside* it.
                let immediate: Result<Void, any Error>? = state.withLock { state in
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
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
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
            // It is also the **only** client-side path that reaches the mux's teardown at all, and
            // that matters for more than the contract: `ClientTransport`'s own guidance is to hold
            // a transport for the lifetime of the application, so without this a transport that
            // shut down gracefully would keep its XPC session open until it was released. The
            // server's equivalent is `XPCServerTransport.listen`'s `onCancel` plus its
            // `closeAll()`.
            //
            // Safe from a cancellation handler: `failAll` takes its snapshot under the registry
            // lock and resumes/fails everything outside it.
            self.core.failAll(
                RPCError(
                    code: .unavailable,
                    message: "the client's connect() task was cancelled"))
            self.shutDownForcefully()?.resume()
        }
    }

    private static let concurrentConnect = RPCError(
        code: .failedPrecondition,
        message: "XPCClientTransport.connect() is already running "
            + "-- it must not be called more than once concurrently")

    /// Begins a **graceful** shutdown: sends `goAway`, refuses new calls, and lets the calls
    /// already in flight run to completion. Returns immediately -- the waiting happens in
    /// `connect()`.
    ///
    /// Three things happen, in this order:
    /// 1. `core.beginDraining()` -- `goAway` on the wire, and `openStream` throws `.unavailable`
    ///    from here on, so `withStream` refuses new calls even if it were asked past the local
    ///    gate;
    /// 2. this transport moves to `.draining` (RPCs still in flight) or straight to `.shutDown`
    ///    (none), which is the local gate `withStream` checks;
    /// 3. a parked `connect()` is resumed **only in the second case**. Otherwise the last
    ///    in-flight call to finish resumes it, in ``callDidFinish()``.
    ///
    /// It deliberately does **not** call `core.failAll(...)` or `core.close()`: failing in-flight
    /// streams is the opposite of draining them. Cancelling `connect()`'s task is the forceful
    /// lever, and gRPC documents it as such.
    ///
    /// Idempotent: a second call finds `.draining`/`.shutDown` and changes nothing, and
    /// `beginDraining()` is itself a no-op once draining.
    public func beginGracefulShutdown() {
        core.beginDraining()
        let pending: CheckedContinuation<Void, any Error>? = state.withLock { state in
            guard !state.isShuttingDown else { return nil }
            let parked = state.parked
            guard state.liveCalls == 0 else {
                state.phase = .draining(parked)
                return nil
            }
            state.phase = .shutDown
            return parked
        }
        pending?.resume()
    }

    /// One `withStream` call has released its claim. If that was the last one and a drain is
    /// waiting on it, this is the edge that finally lets `connect()` return.
    ///
    /// Called from a `defer` in `withStream`, so it runs on every exit path -- and *after* the
    /// stream's own retirement `defer`, since defers unwind last-in-first-out. That order is
    /// load-bearing: when the count reaches zero every stream really has been retired, rather
    /// than merely being about to be.
    private func callDidFinish() {
        let pending: CheckedContinuation<Void, any Error>? = state.withLock { state in
            state.liveCalls -= 1
            guard case .draining(let parked) = state.phase, state.liveCalls == 0 else { return nil }
            state.phase = .shutDown
            return parked
        }
        pending?.resume()
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
    private func shutDownForcefully() -> CheckedContinuation<Void, any Error>? {
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
            guard !state.isShuttingDown else {
                return RPCError(
                    code: .failedPrecondition,
                    message: "no new streams: this transport has begun shutting down")
            }
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
        if core.isDraining {
            throw RPCError(
                code: .unavailable,
                message: "no new streams: the connection is draining (the peer sent goAway, or "
                    + "it has been torn down)")
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
