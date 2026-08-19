import GRPCCore
import Synchronization

/// A `ClientTransport` over one `XPCConnection`.
///
/// - Important: the connection is not created or activated here -- `init(connection:)` takes an
///   already-activated client `XPCConnection` (e.g. from `XPCConnection.connecting(to:queue:)`).
///   Ownership follows `XPCConnection`'s contract: this transport holds `connection` for its own
///   lifetime, which is what keeps every stream `withStream` hands out usable for as long as the
///   caller's closure runs -- see `XPCConnection`'s and `openClientStream`'s doc comments for what
///   happens if a stream outlives its connection instead.
///
/// Pinned against grpc-swift-2 2.4.2: `ClientContext.init(descriptor:remotePeer:localPeer:)` and
/// `MethodDescriptor.fullyQualifiedMethod` matched the plan verbatim.
///
/// A `final class`, not a struct: `state`'s `Synchronization.Mutex` is `~Copyable`, and a
/// `Copyable`-conforming struct cannot hold a `~Copyable` stored property -- the same reason
/// `XPCOutboundWriter` (which stores an `Atomic`) is a class rather than a struct.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class XPCClientTransport: ClientTransport {
    public typealias Bytes = [UInt8]

    private let connection: XPCConnection

    /// `connect()`'s state, made explicit rather than "one optional continuation slot": that
    /// earlier shape let a second concurrent `connect()` silently overwrite the first's
    /// continuation, leaking it (the runtime reports this as "SWIFT TASK CONTINUATION MISUSE")
    /// and stranding the first caller parked forever. With this enum every transition is
    /// explicit: `.idle -> .connected` (first `connect()` parks), `.connected -> .shutDown`
    /// (`beginGracefulShutdown()`, or cancellation of `connect()`'s own task, resumes the parked
    /// caller and retires the slot), and `.idle -> .shutDown` (either of those arriving before
    /// any `connect()` call, so a *later* `connect()` returns immediately instead of parking on
    /// a shutdown that already happened).
    private enum ConnectState {
        case idle
        case connected(CheckedContinuation<Void, any Error>)
        case shutDown
    }
    private let state = Mutex<ConnectState>(.idle)

    init(connection: XPCConnection) {
        self.connection = connection
    }

    public var retryThrottle: RetryThrottle? { nil }

    /// Blocks until `beginGracefulShutdown()` is called, or until this call's own task is
    /// cancelled -- mirroring `GRPCInProcessTransport`'s reference client, which parks the same
    /// way and also returns (rather than throwing) once its task is cancelled. Returning
    /// normally on cancellation, not throwing `CancellationError`, matters beyond style here:
    /// `GRPCClient.runConnections()` calls `transport.connect()` and wraps *any* thrown error --
    /// cancellation included -- in a `RuntimeError(code: .transportError, ...)`, which would
    /// misreport an ordinary cancelled shutdown as a transport failure. Deadlines, retries, and
    /// draining semantics beyond parking/unparking are later tasks' concern; the underlying
    /// `XPCConnection` is already activated by the time it is handed to this transport, so there
    /// is no connecting work left for this method to do.
    ///
    /// A second, concurrent call while one `connect()` is already parked is refused with a
    /// thrown `RPCError(code: .failedPrecondition)` rather than silently clobbering the first --
    /// gRPC's own client already throws (`RuntimeError`) rather than traps when its analogous
    /// `runConnections()` is misused this way, so a thrown error is the precedent this follows;
    /// a caller that never calls `connect()` twice concurrently (the documented, correct usage)
    /// never sees it.
    public func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { current in
                    switch current {
                    case .idle:
                        current = .connected(continuation)
                        return nil   // parked; resumed later by shutdown or cancellation
                    case .connected:
                        return .failure(RPCError(
                            code: .failedPrecondition,
                            message: "XPCClientTransport.connect() is already running "
                                + "-- it must not be called more than once concurrently"))
                    case .shutDown:
                        return .success(())
                    }
                }
                switch immediate {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                case nil: break   // parked above; nothing to resume yet
                }
            }
        } onCancel: {
            self.shutDownAndTakePending()?.resume()
        }
    }

    public func beginGracefulShutdown() {
        shutDownAndTakePending()?.resume()
    }

    /// Moves to `.shutDown` and hands back whatever `connect()` call was parked, if any -- the
    /// one piece of logic `beginGracefulShutdown()` and cancellation of `connect()`'s task share,
    /// since both end `connect()` the same way (resume it to return normally). Called at most
    /// once per parked continuation because the state leaves `.connected` the moment it is taken,
    /// so a second caller (a duplicate `beginGracefulShutdown()`, or shutdown racing cancellation)
    /// finds `.shutDown` and gets `nil` back -- never a second resume of the same continuation,
    /// which would trap.
    private func shutDownAndTakePending() -> CheckedContinuation<Void, any Error>? {
        state.withLock { current in
            let pending: CheckedContinuation<Void, any Error>?
            if case .connected(let continuation) = current { pending = continuation } else { pending = nil }
            current = .shutDown
            return pending
        }
    }

    /// How many deadline timers have actually *expired* on this transport.
    ///
    /// Test observability, and it has to be: "the timer for a completed RPC was cancelled rather
    /// than left to fire later" is a negative, and one with no other visible symptom -- a leaked
    /// timer keeps the transport alive for the rest of its timeout and then emits a `.cancel` for a
    /// finished RPC, neither of which any assertion on the RPC itself can see. Pinned by
    /// `LifecycleTests.testACompletedCallLeavesNoDeadlineTimerBehind`. Nothing in the transport
    /// branches on it.
    let firedDeadlines = Mutex(0)

    public func withStream<T: Sendable>(
        descriptor: MethodDescriptor,
        options: CallOptions,
        _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T
    ) async throws -> T {
        // Refuse to open a stream once either end is shutting down: this transport's own
        // `beginGracefulShutdown()`, or the peer's `.goAway` (which sets `connection.isDraining`).
        // Failing here is strictly better than opening a stream the peer will immediately refuse --
        // the caller gets `.unavailable`, which is retryable, instead of waiting out a deadline.
        let isShutDown = state.withLock { current -> Bool in
            if case .shutDown = current { return true } else { return false }
        }
        if isShutDown || connection.isDraining {
            let reason = isShutDown
                ? "this transport has shut down"
                : "the connection is draining (the peer sent goAway, or it has been torn down)"
            throw RPCError(code: .unavailable, message: "no new streams: \(reason)")
        }

        let (streamID, stream) = connection.openClientStream(descriptor: descriptor)
        // The deadline goes on the wire too. It is not what *enforces* the deadline (the local timer
        // below is), but a peer that knows the deadline can stop working on a doomed RPC without
        // waiting for the `.cancel` to arrive.
        try connection.send(.openStream(streamID,
                                        method: descriptor.fullyQualifiedMethod,
                                        deadlineNanos: options.timeout.map(Self.nanoseconds(in:))))
        let context = ClientContext(
            descriptor: descriptor,
            remotePeer: "xpc:peer",
            localPeer: "xpc:self"
        )

        // `CallOptions.timeout` as a per-stream timer (design section 8). On expiry the peer is told
        // to stop (`.cancel`) and the local half is failed with `.deadlineExceeded`, which is what
        // unblocks the closure: its `stream.inbound` iteration throws, and any writer parked on
        // credit for this stream is released by `failStream`.
        //
        // Cancelled unconditionally on the way out by the `defer` below -- on success, on a throw,
        // and on cancellation of this call's own task -- so no RPC can leave a timer behind. The
        // cost of leaving one is not hypothetical: the task holds this transport (and through it
        // the connection) for the whole of the timeout, so a server under load would accumulate one
        // sleeping task per completed RPC for as long as its longest deadline, and each would
        // eventually put a pointless `.cancel` frame on the wire for an RPC that is already over.
        let deadline: Task<Void, Never>? = options.timeout.map { timeout in
            Task { [self] in
                do { try await Task.sleep(for: timeout) }
                catch { return }   // cancelled: the RPC finished inside its deadline
                // Re-checked because `Task.sleep` returning and this task being cancelled can race:
                // the RPC may have completed in the instant between the two.
                if Task.isCancelled { return }
                firedDeadlines.withLock { $0 += 1 }
                let error = RPCError(
                    code: .deadlineExceeded,
                    message: "stream \(streamID): the call's \(timeout) deadline expired")
                try? connection.send(.cancel(streamID, reason: "deadline exceeded after \(timeout)"))
                connection.failStream(streamID, error)
            }
        }
        defer { deadline?.cancel() }

        // Mirrors `GRPCInProcessTransport`'s client: the closure's own result (success or
        // thrown error) is what this method returns/rethrows, but the stream's outbound side is
        // always closed on the way out -- "the opened stream is closed after the closure is
        // finished" is `ClientTransport.withStream`'s documented contract, not optional cleanup.
        // `finish()` is safe even if `closure` already called it (e.g. the brief's own test
        // does): `XPCOutboundWriter.finish()` sends one more `.halfClose`, which the peer's
        // already-terminated `StreamChannel` drops without effect.
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await closure(stream, context))
        } catch {
            outcome = .failure(error)
        }
        await stream.outbound.finish()
        return try outcome.get()
    }

    public func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? { nil }

    /// A `Duration` as whole nanoseconds, saturating rather than trapping. `Duration.components`
    /// is (seconds, attoseconds); an attosecond is 1e-18, so 1e9 of them make a nanosecond. Only
    /// used for the wire's advisory `deadlineNanos` -- the local timer sleeps on the `Duration`
    /// itself and never goes through this.
    private static func nanoseconds(in duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        let fromSeconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !fromSeconds.overflow else { return seconds < 0 ? .min : .max }
        let total = fromSeconds.partialValue.addingReportingOverflow(attoseconds / 1_000_000_000)
        return total.overflow ? (seconds < 0 ? .min : .max) : total.partialValue
    }
}
