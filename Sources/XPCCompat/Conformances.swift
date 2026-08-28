import XPC
import CoreFoundation

// xpc_copy_description returns a malloc'd C string the caller must free.
//
// It is handed to CoreFoundation rather than copied: `kCFAllocatorMalloc` names the
// deallocator, so the CFString adopts the buffer and frees it when it dies. That is
// the whole point of the no-copy call, and it only happens when CoreFoundation
// accepts the bytes.
//
// It does not always accept them. The description embeds a dictionary's keys
// verbatim, and libxpc never UTF-8-validates a key -- a key set through the C API
// with the bytes 0xFF 0xFE arrives here inside `"\xFF\xFE" => <int64: ...>`. For
// that buffer `CFStringCreateWithCStringNoCopy` answers nil, and a nil return means
// it took nothing: the buffer is still ours to free, and the string is still ours
// to produce. So the nil path frees and falls back to a repairing decode, which is
// what `String(cString:)` did here before -- invalid bytes become U+FFFD.
//
// Getting this wrong is not a cosmetic bug. `debugDescription` is the one thing a
// caller reaches for when something has already gone wrong, and a force-bridge of
// the nil would end the process over one byte a peer chose.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal func xpcDescription(_ object: xpc_object_t) -> String {
    let raw: UnsafeMutablePointer<CChar>? = xpc_copy_description(object)
    guard let raw = raw else { return "<xpc: no description>" }

    if let adopted = CFStringCreateWithCStringNoCopy(
        nil, raw, CFStringBuiltInEncodings.UTF8.rawValue, kCFAllocatorMalloc) {
        // CoreFoundation owns `raw` now; freeing it here would be a double free.
        return adopted as String
    }

    // Nothing adopted it, so both the buffer and the string are still ours.
    defer { free(raw) }
    return String(decodingCString: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self),
                  as: UTF8.self)
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
