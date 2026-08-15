import XCTest
import XPC
import XPCOverlayCoder
@testable import XPCActors

/// `Packet.Payload` -- `{ "payload": <overlay envelope> }`, one entry.
///
/// The body is not a native xpc structure. Apple's `Payload.init(encoding:userInfo:)`
/// (`0x2ad4e1488`) calls `XPCDictionary.encode(value, forKey: "payload", withUserInfo:)`,
/// which routes through `XPCReceivedMessage.encodeMessage` -- the XPC *overlay*'s
/// Codable coder, whose output is an envelope carrying one `xpc_data` byte stream.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class PayloadTests: XCTestCase {

    struct Body: Codable, Equatable {
        let name: String
        let count: Int
    }

    func testRoundTrips() throws {
        let original = Body(name: "hello", count: 3)
        let payload = try Packet.Payload(encoding: original, userInfo: [:])
        XCTAssertEqual(try payload.decode(as: Body.self), original)
    }

    // MARK: shape

    func testTheObjectIsADictionaryWithExactlyOneEntryNamedPayload() throws {
        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1), userInfo: [:])
        XCTAssertEqual(xpc_get_type(payload.object), XPC_TYPE_DICTIONARY)
        XCTAssertEqual(xpc_dictionary_get_count(payload.object), 1)
        XCTAssertNotNil(xpc_dictionary_get_value(payload.object, "payload"))
    }

    /// The fact that changes everything above this layer: the encoded body is one
    /// `xpc_data` blob, so no field of the value is an xpc entry and no key name in
    /// the spec is an xpc dictionary key.
    func testTheBodyIsAnOverlayEnvelopeWhoseCodableBodyIsAByteStream() throws {
        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1), userInfo: [:])
        let envelope = try XCTUnwrap(xpc_dictionary_get_value(payload.object, "payload"))
        let body = try XCTUnwrap(xpc_dictionary_get_value(envelope, OverlayEnvelope.body))
        XCTAssertEqual(xpc_get_type(body), XPC_TYPE_DATA,
                       "got \(String(cString: xpc_type_get_name(xpc_get_type(body))))")
        XCTAssertNil(xpc_dictionary_get_value(envelope, "name"),
                     "no field of the value should appear as an xpc entry")
    }

    func testTheOverlayEnvelopeCarriesItsCoderVersion() throws {
        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1), userInfo: [:])
        let envelope = try XCTUnwrap(xpc_dictionary_get_value(payload.object, "payload"))
        let version = try XCTUnwrap(
            xpc_dictionary_get_value(envelope, OverlayEnvelope.coderVersion))
        XCTAssertEqual(xpc_get_type(version), XPC_TYPE_INT64)
        XCTAssertEqual(xpc_int64_get_value(version), 1)
    }

    /// A top-level array is what a `RemoteInvocationResponse` *is*, and under the old
    /// native-xpc reading it could not be a body at all. There is no such restriction
    /// on a byte stream, so `PacketCodingError.bodyIsNotADictionary` has nothing left
    /// to describe.
    func testANonDictionaryTopLevelValueIsFine() throws {
        XCTAssertEqual(try Packet.Payload(encoding: 42, userInfo: [:]).decode(as: Int.self), 42)
        XCTAssertEqual(try Packet.Payload(encoding: [1, 2, 3], userInfo: [:]).decode(as: [Int].self),
                       [1, 2, 3])
    }

    // MARK: userInfo

    func testUserInfoReachesTheEncoder() throws {
        let key = CodingUserInfoKey(rawValue: "test.marker")!

        struct Probe: Codable {
            let seen: String
            init(seen: String) { self.seen = seen }
            init(from decoder: any Decoder) throws {
                seen = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .seen)
            }
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                let marker = CodingUserInfoKey(rawValue: "test.marker")!
                try container.encode(encoder.userInfo[marker] as? String ?? "absent",
                                     forKey: .seen)
            }
            enum Key: String, CodingKey { case seen }
        }

        let payload = try Packet.Payload(encoding: Probe(seen: ""), userInfo: [key: "present"])
        XCTAssertEqual(try payload.decode(as: Probe.self).seen, "present")
    }

    func testUserInfoReachesTheDecoder() throws {
        let key = CodingUserInfoKey(rawValue: "test.marker")!

        struct Probe: Decodable {
            let seen: String
            init(from decoder: any Decoder) throws {
                seen = decoder.userInfo[CodingUserInfoKey(rawValue: "test.marker")!]
                    as? String ?? "absent"
            }
        }

        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1), userInfo: [:])
        let probe = try payload.decode(as: Probe.self, userInfo: [key: "present"])
        // The mechanism identity relies on: it is how an `ActorID` codes itself
        // against its session.
        XCTAssertEqual(probe.seen, "present")
    }

    // MARK: failure

    func testDecodingTheWrongTypeThrows() throws {
        struct Other: Codable { let totallyDifferent: [String] }
        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1), userInfo: [:])
        XCTAssertThrowsError(try payload.decode(as: Other.self))
    }

    func testDecodingAPayloadWithNoBodyThrows() {
        let payload = Packet.Payload(unchecked: xpc_dictionary_create(nil, nil, 0))
        XCTAssertThrowsError(try payload.decode(as: Body.self)) { error in
            XCTAssertEqual(error as? PacketCodingError, .payloadHasNoBody)
        }
    }
}
