import Foundation
#if canImport(XPC)
import XPC

/// Carries any `xpc_object_t` through a `Codable` graph unchanged.
///
/// Nothing is serialised. This encoder builds a native object tree, so an xpc
/// object is already in its final form — it is placed in the tree as itself, and
/// read back the same way. That is the difference from a byte-stream coder,
/// which has to put such a value in a side table and leave an index behind.
///
///     struct Handoff: Codable {
///         let label: String
///         let endpoint: XPCNativeObject
///     }
///
/// Any type works: `endpoint`, `shmem`, `fd`, `connection`, `activity`, a
/// `mach_port`-bearing object, or another dictionary. This module does not
/// interpret them and does not need to.
///
/// ## What the wrapper is for
///
/// It is the declaration. A `Codable` value carrying a live resource cannot be
/// archived, cached, or replayed, and whoever receives an `fd` now owns it and
/// must close it — none of which is visible when the field is typed as `Data` or
/// hidden behind a protocol conformance. Spelling `XPCNativeObject` in the type
/// is the author saying they know.
///
/// ## It is also the zero-copy route for a large payload
///
/// A `Data` field is copied, which is what a value type should do:
/// `xpc_data_create` takes a pointer and a length, so it duplicates the bytes —
/// 12 ms for 64 MiB, and twice the memory. `xpc_data_create_with_dispatch_data`
/// takes ownership of the buffer instead and copies nothing.
///
///     let blob = xpc_data_create_with_dispatch_data(myDispatchData)
///     let value = Payload(name: "big", blob: XPCNativeObject(blob))
///
/// Measured end to end through this coder: the pages that go in are the pages
/// that come out.
///
/// This module will not make that object for you from a `Data`. Turning one into
/// a `dispatch_data_t` means either copying — which is what you were avoiding —
/// or promising the storage outlives the call, and `Data` makes no such promise;
/// a small one lives inline in the struct. Whoever holds the `DispatchData`
/// knows its lifetime, so the object is theirs to build.
///
/// ## Outside this coder it refuses
///
/// `XPCEncoder` recognises the type and never calls ``encode(to:)``. Any other
/// encoder does call it, and it throws rather than inventing a representation —
/// a JSON document with an endpoint silently reduced to `{}` would be worse than
/// a failure. Decoding is the same in reverse.
public struct XPCNativeObject {

    public let object: xpc_object_t

    public init(_ object: xpc_object_t) {
        self.object = object
    }

    /// The xpc type, for a caller that wants to check before unwrapping.
    public var type: xpc_type_t { xpc_get_type(object) }
}

extension XPCNativeObject: Codable {

    public init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "XPCNativeObject can only be decoded by XPCDecoder, which "
                + "reads the object out of the graph. \(Swift.type(of: decoder)) has no graph "
                + "to read it from."))
    }

    public func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(self, .init(
            codingPath: encoder.codingPath,
            debugDescription: "XPCNativeObject can only be encoded by XPCEncoder, which places "
                + "the object in the graph. \(Swift.type(of: encoder)) would have to invent a "
                + "representation for it."))
    }
}

extension XPCNativeObject: Equatable {

    /// `xpc_equal` — structural for containers, identity for the live ones. Two
    /// dictionaries with the same contents compare equal; two connections do not
    /// unless they are the same connection.
    public static func == (lhs: XPCNativeObject, rhs: XPCNativeObject) -> Bool {
        xpc_equal(lhs.object, rhs.object)
    }
}

extension XPCNativeObject: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(xpc_hash(object))
    }
}

extension XPCNativeObject: CustomStringConvertible {
    public var description: String { "XPCNativeObject(\(xpcTypeName(type)))" }
}
#endif
