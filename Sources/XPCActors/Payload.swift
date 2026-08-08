import Foundation
import XPC
import XPCOverlayCoder

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Packet {

    /// `Packet.Payload` -- an xpc dictionary with exactly one entry, `"payload"`,
    /// holding an overlay-encoded message.
    ///
    /// Apple's `Payload.init<A>(encoding:userInfo:)` (`0x2ad4e1488`) creates an empty
    /// `XPCDictionary` and calls `XPCDictionary.encode(value, forKey: "payload",
    /// withUserInfo:)`. That call is not a native-xpc encoder: in `libswiftXPC` it
    /// routes through `XPCReceivedMessage.encodeMessage(_:userInfo:)`, the XPC
    /// **overlay**'s Codable coder, whose output is a five-key envelope carrying one
    /// `xpc_data` byte stream under `_CodableBody`.
    ///
    /// So every key name in the wire spec -- `genericSubsitutions`,
    /// `targetedSharedActor`, the `WireCode` discriminator, `_0` -- lives inside that
    /// stream and is tagged by the overlay's own format, not by xpc. Which is also why
    /// a body is free to be a top-level array: a `RemoteInvocationResponse` is one.
    ///
    /// `userInfo` is threaded through both directions on purpose. It is how an
    /// `ActorID` codes itself as a `SharedActorKey` against its owning session, and how
    /// a decoded key is turned back into a proxy; the overlay coder carries a `userInfo`
    /// in both directions for exactly this.
    public struct Payload: @unchecked Sendable {

        /// `{ "payload": <overlay envelope> }`.
        public let object: xpc_object_t

        /// The overlay envelope itself -- the value under `"payload"`, which is what a
        /// peer's coder is handed.
        var body: xpc_object_t? {
            xpc_dictionary_get_value(object, EnvelopeKey.payload)
        }

        /// Wrap an already-encoded overlay envelope.
        init(body: xpc_object_t) {
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(dictionary, EnvelopeKey.payload, body)
            self.object = dictionary
        }

        /// Adopt a dictionary that is already in payload shape. Tests only; the
        /// envelope parser goes through ``init(body:)``.
        init(unchecked object: xpc_object_t) {
            self.object = object
        }

        public init<T: Encodable>(
            encoding value: T,
            userInfo: [CodingUserInfoKey: Any] = [:]
        ) throws {
            var encoder = XPCOverlayEncoder()
            encoder.userInfo = userInfo
            self.init(body: try encoder.message(value))
        }

        public func decode<T: Decodable>(
            as type: T.Type = T.self,
            userInfo: [CodingUserInfoKey: Any] = [:]
        ) throws -> T {
            guard let body else { throw PacketCodingError.payloadHasNoBody }
            var decoder = XPCOverlayDecoder()
            decoder.userInfo = userInfo
            return try decoder.decode(type, from: body)
        }
    }
}
