import GRPCCore
import Synchronization

// Pinned against grpc-swift-2 2.4.2 (resolved from `from: "2.4.1"`). `listen`'s signature
// matched the plan verbatim. `configure(context:)` (added in gRPCSwift 2.3) is a protocol
// requirement but ships a default no-op implementation in an extension, so it does NOT need
// to be implemented here to satisfy the conformance -- it's a hook for later tasks to
// override only if they need to read `GRPCServerContext.methods` before `listen` is called.
//
// `ServerContext.RPCCancellationHandle` does have a public `init()` in 2.4.2, but calling it
// directly builds a handle that is never bound into `ServerContext.rpcCancellation`'s task
// local -- so `withRPCCancellationHandler(operation:onCancelRPC:)`, called from *inside* a
// handler, would silently no-op against it. `withServerContextRPCCancellationHandle(_:)` is
// the one documented as "intended for use when implementing a `ServerTransport`" (see
// `ServerContext+RPCCancellationHandle.swift`), and is exactly the pattern
// `GRPCInProcessTransport.Server.listen` itself uses -- followed here for the same reason.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class XPCServerTransport: ServerTransport {
    public typealias Bytes = GRPCSwiftData

    private let connection: XPCConnection

    /// `listen()`'s state, made explicit for the same reason `XPCClientTransport.ConnectState`
    /// is: every transition must be unambiguous rather than inferred from side effects.
    ///
    /// - `.idle -> .listening`: the first `listen()` call, which then drains
    ///   `connection.acceptedStreams` until it finishes.
    /// - `.listening -> .draining`: `beginGracefulShutdown()` while `listen()` is running. New
    ///   streams are refused from here on, but the handlers already running are *not* disturbed --
    ///   `listen()` stays inside its task group until the last of them returns.
    /// - `.draining -> .shutDown` / `.listening -> .shutDown`: `listen()`'s accept loop and task
    ///   group have both finished -- because the drain completed, or because the accept loop ended
    ///   on its own (peer death, or the connection's `deinit`). Either way a `listen()` that has
    ///   already run once never runs a second time.
    /// - `.idle -> .shutDown`: `beginGracefulShutdown()` arriving before any `listen()` call, so
    ///   a *later* `listen()` returns immediately instead of accepting anything.
    ///
    /// Unlike `XPCClientTransport.connect()`, no continuation is parked in this enum: the actual
    /// "block until told to stop" signal here is `connection.acceptedStreams` itself, whose
    /// continuation `connection.stopAcceptingNewStreams()` finishes -- so `beginGracefulShutdown()`
    /// unblocks a running `listen()` by causing *that* AsyncStream to finish, not by resuming
    /// anything owned by this type.
    private enum ListenState: Sendable {
        case idle
        case listening
        case draining
        case shutDown
    }
    private let state = Mutex<ListenState>(.idle)

    init(connection: XPCConnection) {
        self.connection = connection
    }

    /// Drains `connection.acceptedStreams`, running `streamHandler` for each accepted stream in
    /// its own child task. Per-task work is: build a `ServerContext` (via
    /// `withServerContextRPCCancellationHandle`, see the type's doc comment for why), then call
    /// `streamHandler`.
    ///
    /// - A second, concurrent call while one `listen()` is already running is refused with a
    ///   thrown `RPCError(code: .failedPrecondition)` -- the entry check and the `.idle ->
    ///   .listening` transition happen together under one `state.withLock`, so two racing calls
    ///   can never both see `.idle` and both start accept loops.
    /// - A call made after `beginGracefulShutdown()` (or after a previous `listen()` has already
    ///   ended) finds `.draining`/`.shutDown` and returns immediately without touching
    ///   `connection.acceptedStreams` at all.
    /// - Once `beginGracefulShutdown()` has run, this method **drains**: the accept loop ends (its
    ///   `AsyncStream` was finished by `connection.stopAcceptingNewStreams()`) but the task group
    ///   keeps every handler that was already running, so `listen()` returns only after the last of
    ///   them has returned. `beginGracefulShutdown()` itself never waits.
    /// - Cancelling this call's own task is *not* graceful: `onCancel` begins the shutdown and then
    ///   tears the streams down with `connection.failAll(...)`, because a cancelled task wants out
    ///   now. The group's children are cancelled by the runtime too. Nothing in the loop below
    ///   throws on cancellation, so (mirroring `XPCClientTransport.connect()`, and matching what
    ///   `GRPCServer.serve()` expects: it wraps *any* thrown error from `listen` in a
    ///   `RuntimeError(code: .transportError, ...)`, which would misreport an ordinary cancelled
    ///   shutdown as a transport failure) this method returns normally rather than throwing.
    public func listen(
        streamHandler: @escaping @Sendable (RPCStream<Inbound, Outbound>, ServerContext) async -> Void
    ) async throws {
        let previous: ListenState = state.withLock { current in
            let previous = current
            if case .idle = current { current = .listening }
            return previous
        }
        switch previous {
        case .listening:
            throw RPCError(
                code: .failedPrecondition,
                message: "XPCServerTransport.listen() is already running "
                    + "-- it must not be called more than once concurrently")
        case .draining, .shutDown:
            return
        case .idle:
            break
        }

        let connection = self.connection
        await withTaskCancellationHandler {
            await withDiscardingTaskGroup { group in
                for await accepted in connection.acceptedStreams {
                    group.addTask {
                        await withServerContextRPCCancellationHandle { handle in
                            // The handle is registered against this stream *before* the handler
                            // runs, so an inbound `.cancel` frame for it, a graceful shutdown, or
                            // peer death can all reach the handler through
                            // `withRPCCancellationHandler` / `context.cancellation` -- Task 6 built
                            // valid contexts but registered nothing, so a cancel had no way in.
                            // `alreadyDraining` closes the race where the shutdown swept the table
                            // between this stream being accepted and this task being scheduled.
                            let alreadyDraining = connection.setCancellationObserver(
                                forStream: accepted.id) { handle.cancel() }
                            if alreadyDraining { handle.cancel() }

                            let context = ServerContext(
                                descriptor: accepted.descriptor,
                                remotePeer: "xpc:peer",
                                localPeer: "xpc:self",
                                cancellation: handle
                            )
                            await streamHandler(accepted.stream, context)
                            // Retires the stream: drops its registry entry and flushes whatever
                            // credit it is still withholding. A handler that returns without
                            // draining its request half (it read one message and stopped, say)
                            // would otherwise pin a window's worth of withheld credit replies and
                            // strand a peer that is still writing -- see
                            // `XPCConnection.streamHandlerFinished(_:)`.
                            connection.streamHandlerFinished(accepted.id)
                        }
                        // Referenced so this task captures `connection` strongly for its whole
                        // lifetime: `accepted.stream`'s outbound writer holds it only weakly
                        // (see `XPCConnection`'s and `AcceptedStream`'s doc comments), and this
                        // is what keeps it alive for as long as the handler above is using it.
                        _ = connection
                    }
                }
            }
            // Reached only once the accept loop has ended *and* the task group has drained -- i.e.
            // every handler that was in flight when the shutdown began has returned. This is the
            // drain: `beginGracefulShutdown()` itself never waits.
        } onCancel: {
            // Cancelling `listen()`'s own task is not a graceful shutdown -- the caller wants out
            // now -- so this both begins the shutdown and tears the streams down. The task group's
            // children are cancelled by the runtime as well, so a handler that cooperates with
            // cancellation ends promptly and one that does not still finds its streams failed.
            self.beginGracefulShutdown()
            self.connection.failAll(RPCError(
                code: .unavailable, message: "the server's listen() task was cancelled"))
        }

        state.withLock { $0 = .shutDown }
    }

    /// Begins a **graceful** shutdown: sends `.goAway`, refuses new streams, and lets the streams
    /// already in flight finish. Returns immediately -- the waiting happens in `listen()`, which
    /// stays inside its task group until the last handler returns (design section 8).
    ///
    /// Three things happen, in this order:
    /// 1. `connection.stopAcceptingNewStreams()` -- `.goAway` to the peer, later `.openStream`
    ///    frames refused with `.status(.unavailable)`, and `acceptedStreams` finished so `listen()`'s
    ///    accept loop ends.
    /// 2. `connection.signalCancellationToAllStreams()` -- every in-flight RPC's
    ///    `ServerContext.cancellation` handle fires, which is how a handler is *asked* to wind up.
    ///    This is a signal, not a teardown: nothing is failed, and a handler that ignores it runs
    ///    to completion.
    /// 3. `listen()` drains and returns, moving the state to `.shutDown`.
    ///
    /// This deliberately no longer calls `connection.failAll(...)`, which is what the previous
    /// implementation did (Task 6 deferred draining to this task): failing in-flight streams is the
    /// opposite of draining them. The forceful teardown still exists for the paths that mean it --
    /// cancellation of `listen()`'s own task, and peer death.
    ///
    /// Idempotent: a second call finds `.draining`/`.shutDown` and does nothing.
    public func beginGracefulShutdown() {
        let shouldDrain = state.withLock { current -> Bool in
            switch current {
            case .draining, .shutDown:
                return false
            case .idle:
                // No `listen()` to drain, and none may start later.
                current = .shutDown
                return true
            case .listening:
                current = .draining
                return true
            }
        }
        guard shouldDrain else { return }
        connection.stopAcceptingNewStreams()
        connection.signalCancellationToAllStreams()
    }
}
