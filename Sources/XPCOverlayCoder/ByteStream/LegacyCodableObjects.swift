import Foundation
import XPC
import XPCDispatchDataBridge

extension CodingUserInfoKey {

    /// The key the overlay looks for when a live XPC object crosses a `Codable`
    /// graph — `XPCEndpoint` being the one shipping type that uses it.
    ///
    /// The same key, with the same raw value, in both overlay generations. The
    /// iOS 18 `XPCCodableObject.encode(to:)` reads `Encoder.userInfo`, projects
    /// `static CodingUserInfoKey.xpcCodable`, throws `CodingUserInfoKeyNotFound`
    /// if it is absent, appends to the array it finds, and writes the pre-append
    /// count through a single-value container. The newer generation's body is
    /// the same sequence. Only the envelope key holding the array moved.
    ///
    /// - Note: the raw value was first measured off this machine's running
    ///   libswiftXPC — macOS 27, build 26A5388g — by calling the static getter;
    ///   at eleven characters it is a Swift small string, so it is in no string
    ///   table, and Hex-Rays dropped the argument in every dump. It was then
    ///   confirmed for this generation too: Apple's iOS 18 encoder, run in an
    ///   18.6 simulator, names `_XPCCodable` verbatim in the error it throws
    ///   when the array is absent.
    static let xpcLegacyCodableObjects = CodingUserInfoKey(rawValue: "_XPCCodable")!

    /// The same array again, unwrapped, under a key of our own. It does two jobs.
    ///
    /// It keeps `XPCArray`'s OS floor out of the containers. Apple's code casts
    /// the entry above to `XPCArray`, so that is what has to be stored there —
    /// but `XPCArray` is macOS 13+, and the encoding containers carry no
    /// availability of their own. Reading it back through them is a compile
    /// error. Nothing above macOS 13 can actually reach this code, since
    /// ``XPCLegacyOverlayEncoder/encode(_:)`` is gated, but the compiler cannot
    /// see that from inside a container conformance; the alternative is an
    /// `if #available` whose else-branch would silently write the wrong format.
    /// A raw `xpc_object_t` has no floor at all.
    ///
    /// And its presence *is* the signal that this message carries a side array,
    /// which is how ``LegacyOverlayGeneration`` gating works: an `iOS17` coder
    /// installs neither key, so ``LegacyOutOfLineData/isEnabled(_:)`` is false
    /// and `Data` takes its ordinary `Codable` path.
    static let xpcLegacyRawObjectArray = CodingUserInfoKey(rawValue: "_XPCCodableRawArray")!
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
        userInfo[.xpcLegacyRawObjectArray] = array
        return array
    }

    static func install(_ objects: [xpc_object_t],
                        into userInfo: inout [CodingUserInfoKey: Any]) {
        let array = xpc_array_create(nil, 0)
        for object in objects {
            xpc_array_append_value(array, object)
        }
        userInfo[.xpcLegacyCodableObjects] = XPCArray(array)
        userInfo[.xpcLegacyRawObjectArray] = array
    }

    static func drain(_ array: xpc_object_t) -> [xpc_object_t] {
        var objects: [xpc_object_t] = []
        for index in 0..<xpc_array_get_count(array) {
            objects.append(xpc_array_get_value(array, index))
        }
        return objects
    }
}

/// `Data` does not travel in the byte stream. It goes in the side array as an
/// `xpc_data`, and the stream carries an ordinary integer index to it.
///
/// Measured against Apple's own iOS 18 coder in a 18.6 simulator: encoding a
/// `Data` with no `_XPCCodable` array in `userInfo` throws
/// `CodingUserInfoKeyNotFound`, and with one it appends an `xpc_data` and writes
/// tag 2 with the index. `Data` is the only type that does this — `String`,
/// `Date`, `UUID`, `URL` and even `[UInt8]` all take their ordinary `Codable`
/// path.
enum LegacyOutOfLineData {

    /// Whether this message's generation carries a side array at all. An iOS 17
    /// coder installs none, and `Data` then takes its ordinary `Codable` path.
    static func isEnabled(_ userInfo: [CodingUserInfoKey: Any]) -> Bool {
        userInfo[.xpcLegacyRawObjectArray] != nil
    }

    static func array(in userInfo: [CodingUserInfoKey: Any]) throws -> xpc_object_t {
        guard let array = userInfo[.xpcLegacyRawObjectArray],
              xpc_get_type(array as! xpc_object_t) == XPC_TYPE_ARRAY else {
            throw LegacyOverlayCoderError.missingEnvelopeKey(
                CodingUserInfoKey.xpcLegacyCodableObjects.rawValue)
        }
        return array as! xpc_object_t
    }

    static func append(_ data: Data, to userInfo: [CodingUserInfoKey: Any]) throws -> Int {
        let objects = try array(in: userInfo)
        let index = xpc_array_get_count(objects)
        // An empty Data has a nil baseAddress, and xpc_data_create(nil, 0) does not
        // produce an object -- the append would then be skipped and every later
        // index would be off by one.
        let object: xpc_object_t = data.isEmpty
            ? xpc_data_create([UInt8](), 0)
            : DispatchDataBridge.xpcData(for: data)
        xpc_array_append_value(objects, object)
        return index
    }

    static func read(at index: Int, from userInfo: [CodingUserInfoKey: Any]) throws -> Data {
        let objects = try array(in: userInfo)
        guard index >= 0, index < xpc_array_get_count(objects) else {
            throw LegacyOverlayCoderError.outOfLineIndexOutOfRange(index)
        }
        let object = xpc_array_get_value(objects, index)
        guard xpc_get_type(object) == XPC_TYPE_DATA else {
            throw LegacyOverlayCoderError.outOfLineIndexOutOfRange(index)
        }
        // An empty xpc_data has a nil bytes pointer, which is not a failure.
        let length = xpc_data_get_length(object)
        guard length > 0, let bytes = xpc_data_get_bytes_ptr(object) else { return Data() }
        return Data(bytes: bytes, count: length)
    }
}
