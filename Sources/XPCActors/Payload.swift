import Foundation
import XPC
import CodableXPC

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Packet {

    /// The body of a packet: an xpc dictionary produced by `CodableXPC`'s coder.
    ///
    /// `userInfo` is threaded through both directions on purpose. Phase B puts the
    /// owning session in there, which is how an `ActorID` encodes itself as a
    /// `SharedActorKey` and how a decoded key is turned back into a proxy.
    public struct Payload: @unchecked Sendable {
        public let object: xpc_object_t

        /// Wrap an object already known to be a dictionary. Only the envelope
        /// parser and tests should use this.
        init(unchecked object: xpc_object_t) {
            self.object = object
        }

        public init<T: Encodable>(
            encoding value: T,
            userInfo: [CodingUserInfoKey: Any] = [:]
        ) throws {
            var encoder = XPCEncoder()
            encoder.userInfo = userInfo
            let encoded = try encoder.encode(value)
            guard xpc_get_type(encoded) == XPC_TYPE_DICTIONARY else {
                throw PacketCodingError.bodyIsNotADictionary
            }
            self.object = encoded
        }

        public func decode<T: Decodable>(
            as type: T.Type = T.self,
            userInfo: [CodingUserInfoKey: Any] = [:]
        ) throws -> T {
            var decoder = XPCDecoder()
            decoder.userInfo = userInfo
            return try decoder.decode(type, from: object)
        }
    }
}
