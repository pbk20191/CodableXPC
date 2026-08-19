import GRPCCore

// Pinned against grpc-swift-2 2.4.2 (resolved from `from: "2.4.1"`). `listen`'s signature
// matched the plan verbatim. `configure(context:)` (added in gRPCSwift 2.3) is a protocol
// requirement but ships a default no-op implementation in an extension, so it does NOT need
// to be implemented here to satisfy the conformance -- it's a hook for later tasks to
// override only if they need to read `GRPCServerContext.methods` before `listen` is called.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class XPCServerTransport: ServerTransport {
    public typealias Bytes = [UInt8]

    public func listen(
        streamHandler: @escaping @Sendable (RPCStream<Inbound, Outbound>, ServerContext) async -> Void
    ) async throws { fatalError("unimplemented") }

    public func beginGracefulShutdown() { fatalError("unimplemented") }
}
