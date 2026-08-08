import Foundation
import XPC

extension CodingUserInfoKey {

    /// The key Apple's overlay looks for when a live XPC object crosses a `Codable`
    /// graph — `XPCEndpoint` being the one type that ships using it.
    ///
    /// Their declaration is `@_spi(Testing)` and unreachable: the shipping module is
    /// built from the public interface, so `@_spi(Testing) import XPC` silently
    /// yields nothing, and forcing the package interface with `-package-name XPC`
    /// is refused outright.
    ///
    /// None of that matters, because `CodingUserInfoKey` is equal by `rawValue`.
    /// A key built from the same string *is* their key. The raw value was read out
    /// of the running dylib by calling the static getter directly — Hex-Rays had
    /// dropped the argument, and at eleven characters it is a Swift small string, so
    /// it appears in no string table either.
    public static let xpcOverlayCodableObjects = CodingUserInfoKey(rawValue: "_XPCCodable")!
}

/// Bridges the `_CodableOutOfLine4CodableObject` side array in and out of `userInfo`.
///
/// The overlay's `XPCCodableObject` — the thing that actually reads this array — is
/// itself unreachable SPI, but it never needs to be touched. Its whole job is to
/// append to the array and encode the index, so putting an array where it expects
/// one is enough for `XPCEndpoint` to encode and decode through a coder Apple has
/// never heard of.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
enum OverlayCodableObjects {

    /// An empty array installed under the key, plus the raw handle to read back.
    static func install(into userInfo: inout [CodingUserInfoKey: Any]) -> xpc_object_t {
        let array = xpc_array_create(nil, 0)
        userInfo[.xpcOverlayCodableObjects] = XPCArray(array)
        return array
    }

    static func install(_ objects: [xpc_object_t],
                        into userInfo: inout [CodingUserInfoKey: Any]) {
        let array = xpc_array_create(nil, 0)
        for object in objects {
            xpc_array_append_value(array, object)
        }
        userInfo[.xpcOverlayCodableObjects] = XPCArray(array)
    }

    static func drain(_ array: xpc_object_t) -> [xpc_object_t] {
        var objects: [xpc_object_t] = []
        for index in 0..<xpc_array_get_count(array) {
            objects.append(xpc_array_get_value(array, index))
        }
        return objects
    }
}
