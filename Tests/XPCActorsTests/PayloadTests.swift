import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class PayloadTests: XCTestCase {

    struct Body: Codable, Equatable {
        let name: String
        let count: Int
    }

    func testRoundTrips() throws {
        let original = Body(name: "hello", count: 3)
        let payload = try Packet.Payload(encoding: original)
        XCTAssertEqual(try payload.decode(as: Body.self), original)
    }

    func testEncodesToADictionary() throws {
        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1))
        XCTAssertEqual(xpc_get_type(payload.object), XPC_TYPE_DICTIONARY)
    }

    func testTopLevelNonDictionaryIsRejected() {
        // Every body in this protocol is a struct. A bare Int would encode to an
        // xpc int64, which the envelope's `body` slot cannot hold.
        XCTAssertThrowsError(try Packet.Payload(encoding: 42)) { error in
            XCTAssertEqual(error as? PacketCodingError, .bodyIsNotADictionary)
        }
    }

    func testUserInfoReachesTheEncoder() throws {
        let key = CodingUserInfoKey(rawValue: "test.marker")!

        struct Probe: Encodable {
            let key: CodingUserInfoKey
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Key.self)
                try container.encode(encoder.userInfo[key] as? String ?? "absent", forKey: .seen)
            }
            enum Key: String, CodingKey { case seen }
        }

        let payload = try Packet.Payload(encoding: Probe(key: key), userInfo: [key: "present"])
        XCTAssertEqual(normalizedDescription(payload.object), "{seen=string(present)}")
    }

    func testUserInfoReachesTheDecoder() throws {
        let key = CodingUserInfoKey(rawValue: "test.marker")!

        struct Probe: Decodable {
            let seen: String
            init(from decoder: Decoder) throws {
                seen = decoder.userInfo[CodingUserInfoKey(rawValue: "test.marker")!] as? String ?? "absent"
            }
        }

        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1))
        let probe = try payload.decode(as: Probe.self, userInfo: [key: "present"])
        // This is the mechanism Phase B relies on to inject the session so that
        // ActorID can encode itself as a SharedActorKey.
        XCTAssertEqual(probe.seen, "present")
    }

    func testDecodingTheWrongTypeThrows() throws {
        struct Other: Codable { let totallyDifferent: [String] }
        let payload = try Packet.Payload(encoding: Body(name: "x", count: 1))
        XCTAssertThrowsError(try payload.decode(as: Other.self))
    }
}
