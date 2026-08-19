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
/// A `final class`, not a struct: `shutdown`'s `Synchronization.Mutex` is `~Copyable`, and a
/// `Copyable`-conforming struct cannot hold a `~Copyable` stored property -- the same reason
/// `XPCOutboundWriter` (which stores an `Atomic`) is a class rather than a struct.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class XPCClientTransport: ClientTransport {
    public typealias Bytes = [UInt8]

    private let connection: XPCConnection

    /// Resumed by `beginGracefulShutdown()`; parked on by `connect()`. `nil` once shutdown has
    /// already been signalled (or before `connect()` has stored anything to resume), so a
    /// `beginGracefulShutdown()` that arrives before -- or a second one after -- `connect()`
    /// parks is a harmless no-op rather than a double-resume trap.
    private let shutdown = Mutex<CheckedContinuation<Void, Never>?>(nil)

    init(connection: XPCConnection) {
        self.connection = connection
    }

    public var retryThrottle: RetryThrottle? { nil }

    /// Blocks until `beginGracefulShutdown()` is called -- mirroring `GRPCInProcessTransport`'s
    /// reference client, which likewise just parks until told to stop. Deadlines, retries, and
    /// draining semantics beyond that are later tasks' concern; the underlying `XPCConnection` is
    /// already activated by the time it is handed to this transport, so there is no connecting
    /// work left for this method to do.
    public func connect() async throws {
        await withCheckedContinuation { continuation in
            shutdown.withLock { $0 = continuation }
        }
    }

    public func beginGracefulShutdown() {
        shutdown.withLock { pending in
            pending?.resume()
            pending = nil
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
