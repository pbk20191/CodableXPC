import XPC

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat {

    /// A typed wrapper over an `XPC_TYPE_ENDPOINT` object.
    ///
    /// An endpoint is a transferable reference to a listener. Bridge to Apple's
    /// `XPC.XPCEndpoint` by passing `underlyingEndpoint` to its public initializer.
    public struct Endpoint {
        @usableFromInline
        internal let underlyingEndpoint: xpc_object_t

        /// Wraps an existing endpoint object.
        /// - Precondition: `endpoint` is an `XPC_TYPE_ENDPOINT`.
        public init(_ endpoint: xpc_object_t) {
            precondition(
                xpc_get_type(endpoint) == XPC_TYPE_ENDPOINT,
                "XPCCompat.Endpoint requires an XPC_TYPE_ENDPOINT object"
            )
            self.underlyingEndpoint = endpoint
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Endpoint {
    /// The wrapped `xpc_endpoint_t`, for interoperation with the C API and Apple's overlay.
    public var underlying: xpc_object_t { underlyingEndpoint }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Endpoint: Equatable {
    public static func == (lhs: XPCCompat.Endpoint, rhs: XPCCompat.Endpoint) -> Bool {
        xpc_equal(lhs.underlyingEndpoint, rhs.underlyingEndpoint)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Endpoint: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(xpc_hash(underlyingEndpoint))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Endpoint: CustomDebugStringConvertible {
    public var debugDescription: String { xpcDescription(underlyingEndpoint) }
}
