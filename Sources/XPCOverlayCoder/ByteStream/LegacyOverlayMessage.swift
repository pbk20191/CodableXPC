import Foundation
import XPC
import XPCDispatchDataBridge

extension LegacyOverlayEnvelope {

    /// A legacy message dictionary taken apart into the pieces the coders work in.
    public struct Parts {
        /// `_CodableBody`.
        public let body: Data
        /// `_CodableIsSync`. Absent means `false`.
        public let isSync: Bool
        /// `_CodableOutOfLine`, in order.
        public let outOfLineObjects: [xpc_object_t]
        /// `_CodableError`, written by the framework rather than by the coder when
        /// a handler that owed a reply did not produce one.
        public let error: String?
    }

    /// Assemble a complete legacy message dictionary from an encoded value.
    ///
    /// Three keys and no version, which is the whole difference from
    /// `XPCOverlayCoder`'s envelope. The absence is not an omission to be fixed:
    /// it is the signal a newer reader uses to reject the message.
    public static func message(_ encoded: XPCLegacyOverlayEncoder.Encoded,
                               isSync: Bool = false,
                               generation: LegacyOverlayGeneration = .iOS18) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(message, body, DispatchDataBridge.xpcData(for: encoded.body))
        xpc_dictionary_set_bool(message, isSyncKey, isSync)

        // iOS 17 writes two keys and stops -- its encodeMessage has no third.
        guard generation.carriesOutOfLineObjects else { return message }

        let objects = xpc_array_create(nil, 0)
        for object in encoded.outOfLineObjects {
            xpc_array_append_value(objects, object)
        }
        xpc_dictionary_set_value(message, outOfLineObjects, objects)
        return message
    }

    /// Take a received legacy message dictionary apart.
    ///
    /// - Throws: ``LegacyOverlayCoderError/notALegacyMessage`` when the message
    ///   carries `_CodableCoderVersion`. That key belongs to the newer generation,
    ///   whose body this module cannot read — and unlike a newer reader, which
    ///   spots a legacy message by the missing version, nothing in a legacy body
    ///   announces itself. Checking for the newer key is the only direction the
    ///   detection works in.
    public static func parts(of message: xpc_object_t) throws -> Parts {
        if xpc_dictionary_get_value(message, OverlayCoderVersionKey) != nil {
            throw LegacyOverlayCoderError.notALegacyMessage
        }
        guard let raw = xpc_dictionary_get_value(message, body),
              xpc_get_type(raw) == XPC_TYPE_DATA,
              let bytes = xpc_data_get_bytes_ptr(raw)
        else { throw LegacyOverlayCoderError.missingEnvelopeKey(body) }

        var objects: [xpc_object_t] = []
        if let array = xpc_dictionary_get_value(message, outOfLineObjects),
           xpc_get_type(array) == XPC_TYPE_ARRAY {
            objects = (0..<xpc_array_get_count(array)).map { xpc_array_get_value(array, $0) }
        }

        return Parts(
            body: Data(bytes: bytes, count: xpc_data_get_length(raw)),
            isSync: xpc_dictionary_get_bool(message, isSyncKey),
            outOfLineObjects: objects,
            error: xpc_dictionary_get_string(message, error).map { String(cString: $0) })
    }

    /// The newer generation's version key. Named here rather than imported so this
    /// module keeps no dependency on `XPCOverlayCoder`; the two are alternatives,
    /// not layers.
    private static var OverlayCoderVersionKey: String { "_CodableCoderVersion" }

    /// `isSync` the constant, shadowed inside ``message(_:isSync:)`` by the
    /// parameter of the same name.
    private static var isSyncKey: String { isSync }
}

extension XPCLegacyOverlayEncoder {

    /// Encode straight to a legacy message dictionary.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func message<T: Encodable>(_ value: T, isSync: Bool = false) throws -> xpc_object_t {
        LegacyOverlayEnvelope.message(try encode(value), isSync: isSync, generation: generation)
    }
}

extension XPCLegacyOverlayDecoder {

    /// Decode straight from a received legacy message dictionary.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func decode<T: Decodable>(_ type: T.Type = T.self,
                                     from message: xpc_object_t) throws -> T {
        let parts = try LegacyOverlayEnvelope.parts(of: message)
        return try decode(type, from: parts.body,
                          outOfLineObjects: parts.outOfLineObjects)
    }
}
