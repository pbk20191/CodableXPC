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

    public func withStream<T: Sendable>(
        descriptor: MethodDescriptor,
        options: CallOptions,
        _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T
    ) async throws -> T {
        let (streamID, stream) = connection.openClientStream(descriptor: descriptor)
        try connection.send(.openStream(streamID, method: descriptor.fullyQualifiedMethod, deadlineNanos: nil))
        let context = ClientContext(
            descriptor: descriptor,
            remotePeer: "xpc:peer",
            localPeer: "xpc:self"
        )

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
}
