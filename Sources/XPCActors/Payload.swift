import Foundation
import XPC

extension Packet {

    /// `Packet.Payload` -- an xpc dictionary with exactly one entry, `"payload"`,
    /// holding an overlay-encoded message.
    ///
    /// Apple's `Payload.init<A>(encoding:userInfo:)` (`0x2ad4e1488`) creates an empty
    /// `XPCDictionary` and calls `XPCDictionary.encode(value, forKey: "payload",
    /// withUserInfo:)` -- and this now calls **exactly that**, Apple's own overlay coder in
    /// `libswiftXPC.dylib`, bound directly (see ``XPC/XPCDictionary/appleEncode(_:forKey:withUserInfo:)``
    /// in `AppleCoder.swift`). That call is not a native-xpc encoder: inside `libswiftXPC` it
    /// routes through `XPCReceivedMessage.encodeMessage(_:userInfo:)`, the XPC **overlay**'s
    /// Codable coder, whose output is a five-key envelope carrying one `xpc_data` byte stream
    /// under `_CodableBody`. Calling it directly is what lets ``XPCActors`` carry its own wire
    /// coding with no dependency on the `XPCOverlayCoder` reconstruction.
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

        /// Deliberately not defaulted, and this is the only guard left for it.
        ///
        /// `ActorID.encode` is a `preconditionFailure` when the session is missing, not a
        /// throw -- so `userInfo: [:]` is a process-trapping spelling for any value that
        /// contains an actor reference, and the shape of that value follows from which
        /// `func` a peer chose to invoke. A default would make the trapping spelling the
        /// shortest one.
        ///
        /// The argument used to live on `RemoteInvocationResponse.init(result:userInfo:)`,
        /// which pre-encoded the result and so was the only place that could hold it.
        /// Making the response generic removed that initializer and with it the guard;
        /// the exposure did not go away, it moved here -- and widened, because requests
        /// carry actor references in their arguments too.
        ///
        /// Note the asymmetry it protects against: outbound, a missing session **traps**
        /// (`ActorID.encode`); inbound, it **throws** (`ActorID.init(from:)`). Callers
        /// with genuinely nothing session-bound to encode pass `[:]` and say so.
        @available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
        public init<T: Encodable>(
            encoding value: T,
            userInfo: [CodingUserInfoKey: Any]
        ) throws {
            // Apple's own body, called directly: an empty dictionary, then
            // `encode(value, forKey: "payload", withUserInfo:)` -- which encodes the value into
            // the dictionary under `payload`, leaving exactly `{ "payload": <envelope> }`.
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            try XPCDictionary(dictionary).appleEncode(
                value, forKey: EnvelopeKey.payload, withUserInfo: userInfo)
            self.object = dictionary
        }
        @available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
        public func decode<T: Decodable>(
            as type: T.Type = T.self,
            userInfo: [CodingUserInfoKey: Any] = [:]
        ) throws -> T {
            guard body != nil else { throw PacketCodingError.payloadHasNoBody }
            return try XPCDictionary(object).appleDecode(
                as: type, forKey: EnvelopeKey.payload, withUserInfo: userInfo)
        }
    }
}
