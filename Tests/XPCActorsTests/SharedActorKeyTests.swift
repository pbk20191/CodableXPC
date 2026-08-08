import XCTest
import XPC
import CodableXPC
@testable import XPCActors

@available(macOS 14, *)
final class SharedActorKeyTests: XCTestCase {

    private func encoded(_ key: SharedActorKey) throws -> String {
        normalizedDescription(try XPCEncoder().encode(key))
    }

    // MARK: tier 1 — golden fixtures

    func testTheEncodedFormIsPinned() throws {
        XCTAssertEqual(try encoded(.type("Sample")), "{kind=uint64(0),type=string(Sample)}")
        XCTAssertEqual(try encoded(.name("primary")), "{kind=uint64(1),name=string(primary)}")
        XCTAssertEqual(try encoded(.dynamic(7)), "{id=uint64(7),kind=uint64(2)}")
    }

    func testEachKindWritesOnlyItsOwnPayloadKey() throws {
        let object = try XPCEncoder().encode(SharedActorKey.type("Sample"))
        XCTAssertNil(xpc_dictionary_get_value(object, "name"))
        XCTAssertNil(xpc_dictionary_get_value(object, "id"))
    }

    // MARK: round trip

    func testEveryKindRoundTrips() throws {
        for key in [SharedActorKey.type("A"), .name("b"), .dynamic(.max)] {
            let object = try XPCEncoder().encode(key)
            XCTAssertEqual(try XPCDecoder().decode(SharedActorKey.self, from: object), key)
        }
    }

    // MARK: rejection

    func testAnUnknownKindIsRejected() throws {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(object, "kind", 99)
        xpc_dictionary_set_string(object, "type", "Sample")
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }

    func testAKindWithoutItsPayloadIsRejected() throws {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(object, "kind", 0)
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }

    /// The discriminator decides, not the payload. A `kind` of 1 with only a `type`
    /// key present must fail rather than quietly decoding as `.type`.
    func testTheDiscriminatorIsAuthoritative() throws {
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(object, "kind", 1)
        xpc_dictionary_set_string(object, "type", "Sample")
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }
}
