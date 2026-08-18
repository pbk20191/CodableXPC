import XPC

// xpc_copy_description returns a malloc'd C string the caller must free.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal func xpcDescription(_ object: xpc_object_t) -> String {
    let raw: UnsafeMutablePointer<CChar>? = xpc_copy_description(object)
    guard let raw = raw else { return "<xpc: no description>" }
    defer { free(raw) }
    return String(cString: raw)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary: Equatable {
    public static func == (lhs: XPCCompat.Dictionary, rhs: XPCCompat.Dictionary) -> Bool {
        xpc_equal(lhs.underlying, rhs.underlying)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(xpc_hash(underlying))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Dictionary: CustomDebugStringConvertible {
    public var debugDescription: String { xpcDescription(underlying) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array: Equatable {
    public static func == (lhs: XPCCompat.Array, rhs: XPCCompat.Array) -> Bool {
        xpc_equal(lhs.underlying, rhs.underlying)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(xpc_hash(underlying))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension XPCCompat.Array: CustomDebugStringConvertible {
    public var debugDescription: String { xpcDescription(underlying) }
}
