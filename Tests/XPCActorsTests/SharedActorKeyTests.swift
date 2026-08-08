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
    // Both payload types are themselves single-value: `SwiftType` is a bare String and
    // `ID64` is a bare UInt64, so no case nests a dictionary. These pin that shape byte
    // for byte; see the wire-format spec's "SharedActorKey -- an unkeyed pair, not
    // synthesized coding" and "Verifying a container choice".

    func testTheEncodedFormIsPinned() throws {
        XCTAssertEqual(
            try encoded(.exported(SwiftType(mangledTypeName: "Sample"))),
            "[uint64(0),string(Sample)]")
        XCTAssertEqual(
            try encoded(.exportedRawValue("primary")),
            "[uint64(1),string(primary)]")
        XCTAssertEqual(
            try encoded(.dynamic(ID64(rawValue: 7))),
            "[uint64(2),uint64(7)]")
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

    func testAnExportedPayloadThatIsNotAStringIsRejected() throws {
        // Wire code 0 (`exported`) promises a `SwiftType`, which is a bare String; a
        // uint64 must not be coerced into one.
        let object = xpc_array_create(nil, 0)
        xpc_array_append_value(object, xpc_uint64_create(0))
        xpc_array_append_value(object, xpc_uint64_create(42))
        XCTAssertThrowsError(try XPCDecoder().decode(SharedActorKey.self, from: object))
    }

    // MARK: decoding bytes we did not write
    //
    // The round-trip tests above only prove our decoder inverts our encoder -- they
    // would still pass if both sides agreed on a shape Apple never sends. These build
    // the peer's bytes by hand and require that they decode.

    func testHandBuiltPeerBytesDecode() throws {
        let exported = xpc_array_create(nil, 0)
        xpc_array_append_value(exported, xpc_uint64_create(0))
        xpc_array_append_value(exported, xpc_string_create("Sample"))
        XCTAssertEqual(try XPCDecoder().decode(SharedActorKey.self, from: exported),
                       .exported(SwiftType(mangledTypeName: "Sample")))

        let raw = xpc_array_create(nil, 0)
        xpc_array_append_value(raw, xpc_uint64_create(1))
        xpc_array_append_value(raw, xpc_string_create("primary"))
        XCTAssertEqual(try XPCDecoder().decode(SharedActorKey.self, from: raw),
                       .exportedRawValue("primary"))

        // A bare uint64, not `{ "value": 7 }` -- the shape this test previously forbade.
        let dynamic = xpc_array_create(nil, 0)
        xpc_array_append_value(dynamic, xpc_uint64_create(2))
        xpc_array_append_value(dynamic, xpc_uint64_create(7))
        XCTAssertEqual(try XPCDecoder().decode(SharedActorKey.self, from: dynamic),
                       .dynamic(ID64(rawValue: 7)))
    }
}
