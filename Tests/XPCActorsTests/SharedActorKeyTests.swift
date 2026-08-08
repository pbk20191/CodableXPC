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
    //
    // Apple's shipping `SharedActorKey.encode(to:)` writes an *unkeyed* two-element
    // container -- `[ <WireCode as UInt8>, <payload> ]` -- never a keyed dictionary.
    // These pin that shape byte for byte; see the wire-format spec's "SharedActorKey --
    // an unkeyed pair, not synthesized coding".

    func testTheEncodedFormIsPinned() throws {
        XCTAssertEqual(
            try encoded(.exported(SwiftType(mangledTypeName: "Sample"))),
            "[uint64(0),dict{mangledTypeName=string(Sample)}]")
        XCTAssertEqual(
            try encoded(.exportedRawValue("primary")),
            "[uint64(1),string(primary)]")
        XCTAssertEqual(
            try encoded(.dynamic(ID64(rawValue: 7))),
            "[uint64(2),dict{value=uint64(7)}]")
    }

    func testEachCaseEncodesExactlyTwoElements() throws {
        for key in [
            SharedActorKey.exported(SwiftType(mangledTypeName: "Sample")),
            .exportedRawValue("primary"),
            .dynamic(ID64(rawValue: 7)),
        ] {
            let object = try XPCEncoder().encode(key)
            XCTAssertEqual(xpc_get_type(object), XPC_TYPE_ARRAY)
            XCTAssertEqual(xpc_array_get_count(object), 2)
        }
    }

    // MARK: round trip

    func testEveryKindRoundTrips() throws {
        for key in [
            SharedActorKey.exported(SwiftType(mangledTypeName: "A")),
            .exportedRawValue("b"),
            .dynamic(ID64(rawValue: .max)),
        ] {
            let object = try XPCEncoder().encode(key)
            XCTAssertEqual(try XPCDecoder().decode(SharedActorKey.self, from: object), key)
        }
    }

    // MARK: rejection
    //
    // The container is unkeyed, so there is no payload key for a decoder to fall back
    // on -- these all still have to fail rather than guess.

    func testAnUnknownWireCodeIsRejected() throws {
        let object = xpc_array_create(nil, 0)
        xpc_array_append_value(object, xpc_uint64_create(99))
        xpc_array_append_value(object, xpc_string_create("Sample"))
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }

    func testATruncatedArrayIsRejected() throws {
        // Just the wire code, no payload element behind it.
        let object = xpc_array_create(nil, 0)
        xpc_array_append_value(object, xpc_uint64_create(0))
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }

    func testAPayloadOfTheWrongTypeIsRejected() throws {
        // Wire code 1 (`exportedRawValue`) promises a bare String payload; give it a
        // uint64 instead of guessing which case was intended.
        let object = xpc_array_create(nil, 0)
        xpc_array_append_value(object, xpc_uint64_create(1))
        xpc_array_append_value(object, xpc_uint64_create(42))
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }

    func testADynamicPayloadThatIsNotAnID64DictionaryIsRejected() throws {
        // Wire code 2 (`dynamic`) promises an ID64, `{ "value": <UInt64> }`; a bare
        // uint64 (the old wire shape) must not decode as one.
        let object = xpc_array_create(nil, 0)
        xpc_array_append_value(object, xpc_uint64_create(2))
        xpc_array_append_value(object, xpc_uint64_create(7))
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }
}
