import Foundation
import XPC

extension CodingUserInfoKey {

    /// The key the overlay looks for when a live XPC object crosses a `Codable`
    /// graph — `XPCEndpoint` being the one shipping type that uses it.
    ///
    /// The same key, with the same raw value, in both overlay generations. The
    /// iOS 18 `XPCCodableObject.encode(to:)` reads `Encoder.userInfo`, projects
    /// `static CodingUserInfoKey.xpcCodable`, throws `CodingUserInfoKeyNotFound`
    /// if it is absent, appends to the array it finds, and writes the pre-append
    /// count through a single-value container. The iOS 26 body is the same
    /// sequence. Only the envelope key holding the array moved.
    ///
    /// - Note: the raw value was measured off the *running* iOS 26 dylib by
    ///   calling the static getter — at eleven characters it is a Swift small
    ///   string, so it is in no string table, and Hex-Rays dropped the argument
    ///   in both dumps. It is inherited here rather than measured: no iOS 18
    ///   binary exists on a machine that can run one. Everything else about this
    ///   file is read directly from the iOS 18 disassembly.
    public static let xpcLegacyCodableObjects = CodingUserInfoKey(rawValue: "_XPCCodable")!
}

/// Bridges the `_CodableOutOfLine` side array in and out of `userInfo`.
///
/// Nothing here touches `XPCCodableObject` itself, which is unreachable SPI. Its
/// whole job is to append to an array and encode the index, so putting an array
/// where it expects one is enough for `XPCEndpoint` to travel through a coder
/// Apple has never heard of.
///
/// The index it writes is an ordinary `Int` through a single-value container, so
/// it lands on the wire as a plain integer tag. That is why ``LegacyOverlayTag``
/// has no case for an object reference: the format does not need one.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
enum LegacyCodableObjects {

    /// An empty array installed under the key, plus the raw handle to read back.
    static func install(into userInfo: inout [CodingUserInfoKey: Any]) -> xpc_object_t {
        let array = xpc_array_create(nil, 0)
        userInfo[.xpcLegacyCodableObjects] = XPCArray(array)
        return array
    }

    static func install(_ objects: [xpc_object_t],
                        into userInfo: inout [CodingUserInfoKey: Any]) {
        let array = xpc_array_create(nil, 0)
        for object in objects {
            xpc_array_append_value(array, object)
        }
        userInfo[.xpcLegacyCodableObjects] = XPCArray(array)
    }

    static func drain(_ array: xpc_object_t) -> [xpc_object_t] {
        var objects: [xpc_object_t] = []
        for index in 0..<xpc_array_get_count(array) {
            objects.append(xpc_array_get_value(array, index))
        }
        return objects
    }
}
