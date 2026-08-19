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
    public typealias Bytes = [UInt8]

    private let connection: XPCConnection

    /// `listen()`'s state, made explicit for the same reason `XPCClientTransport.ConnectState`
    /// is: every transition must be unambiguous rather than inferred from side effects.
    ///
    /// - `.idle -> .listening`: the first `listen()` call, which then drains
    ///   `connection.acceptedStreams` until it finishes.
    /// - `.listening -> .shutDown`: either `beginGracefulShutdown()` (explicit) or `listen()`'s
    ///   own accept loop ending on its own (peer death, or the connection's `deinit`) -- both
    ///   routes land here so a `listen()` that has already run once never runs a second time.
    /// - `.idle -> .shutDown`: `beginGracefulShutdown()` arriving before any `listen()` call, so
    ///   a *later* `listen()` returns immediately instead of accepting anything.
    ///
    /// Unlike `XPCClientTransport.connect()`, no continuation is parked in this enum: the actual
    /// "block until told to stop" signal here is `connection.acceptedStreams` itself, whose
    /// continuation `connection.failAll(...)` finishes (see that method's doc comment) -- so
    /// `beginGracefulShutdown()` unblocks a running `listen()` by causing *that* AsyncStream to
    /// finish, not by resuming anything owned by this type.
    private enum ListenState: Sendable {
        case idle
        case listening
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
    ///   ended) finds `.shutDown` and returns immediately without touching
    ///   `connection.acceptedStreams` at all.
    /// - Cancelling this call's own task calls `beginGracefulShutdown()` from the
    ///   `withTaskCancellationHandler` `onCancel` side, which -- via `connection.failAll(...)`
    ///   finishing `acceptedStreams`'s continuation -- unblocks the `for await` below the same
    ///   way an explicit `beginGracefulShutdown()` or peer death does. Nothing in the loop below
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
        case .shutDown:
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
                            let context = ServerContext(
                                descriptor: accepted.descriptor,
                                remotePeer: "xpc:peer",
                                localPeer: "xpc:self",
                                cancellation: handle
                            )
                            await streamHandler(accepted.stream, context)
                        }
                        // Referenced so this task captures `connection` strongly for its whole
                        // lifetime: `accepted.stream`'s outbound writer holds it only weakly
                        // (see `XPCConnection`'s and `AcceptedStream`'s doc comments), and this
                        // is what keeps it alive for as long as the handler above is using it.
                        _ = connection
                    }
                }
            }
        } onCancel: {
            self.beginGracefulShutdown()
        }

        state.withLock { $0 = .shutDown }
    }

    /// Stops accepting new streams and releases a running `listen()`. Idempotent: a second call
    /// finds `.shutDown` already set and skips calling `connection.failAll(...)` again --
    /// harmless either way since `failAll` (and the `AsyncStream.Continuation.finish()` inside
    /// it) is itself safe to call more than once, but skipping makes the no-op explicit rather
    /// than relying on that.
    ///
    /// No drain state machine: existing streams are not specially waited on here (YAGNI --
    /// deadlines, `.goAway`, and graceful draining semantics are Task 9/10's job). This only
    /// needs to make `listen()` return; `connection.failAll(...)` already fails every live
    /// stream's inbound sequence (rather than leaving any hung) as a side effect.
    public func beginGracefulShutdown() {
        let shouldFail = state.withLock { current -> Bool in
            if case .shutDown = current { return false }
            current = .shutDown
            return true
        }
        if shouldFail {
            connection.failAll(RPCError(code: .unavailable, message: "server shutting down"))
        }
    }
}
