import Foundation
import XPC

extension OverlayEnvelope {

    /// A message dictionary taken apart into the pieces the coders work in.
    public struct Parts {
        /// `_CodableBody`.
        public let body: Data
        /// `_CodableCoderVersion`, or `nil` when the key is absent. Absent is not
        /// corrupt: it is how the iOS 18-era overlay wrote every message, and
        /// `XPCLegacyOverlayCoder` is what reads those.
        public let coderVersion: Int64?
        /// `_CodableIsSync`. Absent means `false`.
        public let isSync: Bool
        /// `_CodableOutOfLine`, in order.
        public let outOfLine: [Data]
        /// `_CodableOutOfLine4CodableObject`, in order.
        public let outOfLineObjects: [xpc_object_t]
    }

    /// Assemble a complete message dictionary from an encoded value.
    ///
    /// Every key is written, including empty arrays. Apple's decoder tolerates a
    /// missing `_CodableOutOfLine`, but writing it costs nothing and keeps the
    /// message shaped like the ones the framework produces.
    public static func message(_ encoded: XPCOverlayEncoder.Encoded,
                               isSync: Bool = false) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        encoded.body.withUnsafeBytes {
            xpc_dictionary_set_data(message, body, $0.baseAddress, $0.count)
        }
        xpc_dictionary_set_int64(message, coderVersion, OverlayWireFormat.coderVersion)
        xpc_dictionary_set_bool(message, isSyncKey, isSync)

        let blobs = xpc_array_create(nil, 0)
        for blob in encoded.outOfLine {
            blob.withUnsafeBytes {
                xpc_array_append_value(blobs, xpc_data_create($0.baseAddress, $0.count))
            }
        }
        xpc_dictionary_set_value(message, outOfLine, blobs)

        let objects = xpc_array_create(nil, 0)
        for object in encoded.outOfLineObjects {
            xpc_array_append_value(objects, object)
        }
        xpc_dictionary_set_value(message, outOfLineObjects, objects)
        return message
    }

    /// Take a received message dictionary apart.
    ///
    /// Only `_CodableBody` is required. A missing version is reported as `nil`
    /// rather than as an error, because telling the two generations apart is the
    /// caller's decision and `nil` is the signal that does it.
    public static func parts(of message: xpc_object_t) throws -> Parts {
        guard let raw = xpc_dictionary_get_value(message, body),
              xpc_get_type(raw) == XPC_TYPE_DATA,
              let bytes = xpc_data_get_bytes_ptr(raw)
        else { throw OverlayCoderError.missingEnvelopeKey(body) }

        return Parts(
            body: Data(bytes: bytes, count: xpc_data_get_length(raw)),
            coderVersion: int64(message, coderVersion),
            isSync: xpc_dictionary_get_bool(message, isSyncKey),
            outOfLine: blobs(message, outOfLine),
            outOfLineObjects: values(message, outOfLineObjects))
    }

    /// `xpc_dictionary_get_int64` returns `0` for an absent key, which collides
    /// with a real version `0`. Reading the value first keeps the two apart.
    private static func int64(_ message: xpc_object_t, _ key: String) -> Int64? {
        guard let raw = xpc_dictionary_get_value(message, key),
              xpc_get_type(raw) == XPC_TYPE_INT64 else { return nil }
        return xpc_int64_get_value(raw)
    }

    private static func blobs(_ message: xpc_object_t, _ key: String) -> [Data] {
        values(message, key).compactMap {
            guard xpc_get_type($0) == XPC_TYPE_DATA,
                  let bytes = xpc_data_get_bytes_ptr($0) else { return nil }
            return Data(bytes: bytes, count: xpc_data_get_length($0))
        }
    }

    private static func values(_ message: xpc_object_t, _ key: String) -> [xpc_object_t] {
        guard let array = xpc_dictionary_get_value(message, key),
              xpc_get_type(array) == XPC_TYPE_ARRAY else { return [] }
        return (0..<xpc_array_get_count(array)).map { xpc_array_get_value(array, $0) }
    }

    /// `isSync` the constant, shadowed inside ``message(_:isSync:)`` by the
    /// parameter of the same name.
    private static var isSyncKey: String { isSync }
}

extension XPCOverlayEncoder {

    /// Encode straight to a message dictionary, ready to send.
    ///
    ///     try session.send(message: XPCDictionary(encoder.message(value)))
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func message<T: Encodable>(_ value: T, isSync: Bool = false) throws -> xpc_object_t {
        OverlayEnvelope.message(try encode(value), isSync: isSync)
    }
}

extension XPCOverlayDecoder {

    /// Decode straight from a received message dictionary.
    ///
    /// The version is checked, so an iOS 18-era message is rejected as one rather
    /// than failing somewhere inside the stream.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func decode<T: Decodable>(_ type: T.Type = T.self,
                                     from message: xpc_object_t) throws -> T {
        let parts = try OverlayEnvelope.parts(of: message)
        switch parts.coderVersion {
        case OverlayWireFormat.coderVersion:
            break
        case nil:
            throw OverlayCoderError.missingEnvelopeKey(OverlayEnvelope.coderVersion)
        case .some(let version):
            throw OverlayCoderError.unsupportedCoderVersion(version)
        }
        return try decode(type, from: parts.body,
                          outOfLine: parts.outOfLine,
                          outOfLineObjects: parts.outOfLineObjects)
    }
}
