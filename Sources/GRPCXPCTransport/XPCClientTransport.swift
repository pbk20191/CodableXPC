import GRPCCore

// Pinned against grpc-swift-2 2.4.2 (resolved from `from: "2.4.1"`). Every signature below
// -- `withStream`'s parameter labels included -- matched the plan verbatim; nothing needed
// to change. `Bytes: GRPCContiguousBytes & Sendable` and `[UInt8]` already conforms, so no
// extra conformance was required to satisfy `typealias Bytes = [UInt8]`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct XPCClientTransport: ClientTransport {
    public typealias Bytes = [UInt8]

    public var retryThrottle: RetryThrottle? { nil }

    public func connect() async throws { fatalError("unimplemented") }
    public func beginGracefulShutdown() { fatalError("unimplemented") }

    public func withStream<T: Sendable>(
        descriptor: MethodDescriptor,
        options: CallOptions,
        _ closure: (RPCStream<Inbound, Outbound>, ClientContext) async throws -> T
    ) async throws -> T { fatalError("unimplemented") }

    public func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? { nil }
}
