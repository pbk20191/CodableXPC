import XCTest
import XPC
import CodableXPC
@testable import XPCActors

/// `internal`, not `private`: a `private` type's mangled name embeds a process address
/// and does not resolve, which is exactly what `SwiftType(_:)` now refuses.
struct SwiftTypeSample: Codable {}

@available(macOS 14, *)
final class SwiftTypeTests: XCTestCase {


    // MARK: tier 1 — golden fixture
    //
    // Apple's `SwiftType.encode(to:)` opens a `singleValueContainer()` and writes the
    // mangled name as a bare String -- the struct's second stored field, `type`, is a
    // resolved-on-demand cache and never crosses. Pinned here rather than only through
    // `SharedActorKey`, because R2 puts `SwiftType` behind four more wire keys
    // (`protocolStub`, `genericSubsitutions`, `errorType`, `returnType`) where nothing
    // else would catch a regression to a keyed shape.

    func testTheEncodedFormIsABareString() throws {
        let object = try XPCEncoder().encode(SwiftType(mangledTypeName: "Sample"))
        XCTAssertEqual(xpc_get_type(object), XPC_TYPE_STRING)
        XCTAssertEqual(normalizedDescription(object), "string(Sample)")
    }

    func testItDecodesFromABarePeerString() throws {
        // Bytes built by hand, not by our own encoder.
        let object = xpc_string_create("Sample")
        XCTAssertEqual(try XPCDecoder().decode(SwiftType.self, from: object),
                       SwiftType(mangledTypeName: "Sample"))
    }

    func testADictionaryIsNotAcceptedAsASwiftType() throws {
        // The shape a synthesized conformance would have produced. It must not decode,
        // or a peer speaking the correct format and one speaking the old one would
        // silently interoperate in one direction.
        let object = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(object, "mangledTypeName", "Sample")
        XCTAssertThrowsError(try XPCDecoder().decode(SwiftType.self, from: object))
    }

    // MARK: resolution

    func testTypeResolvesAMangledNameToTheType() throws {
        let wrapped = try XCTUnwrap(SwiftType(SwiftTypeSample.self))
        XCTAssertTrue(wrapped.type == SwiftTypeSample.self)
    }

    func testTypeIsNilForANameThatResolvesToNothing() {
        let wrapped = SwiftType(mangledTypeName: "$s0not_a_real_mangled_name")
        XCTAssertNil(wrapped.type)
    }

    func testAnUnresolvableNameStillDecodes() throws {
        // Resolution failure is a later, separate failure -- decoding the wrapper must
        // not depend on this process having the peer's type loaded.
        let object = xpc_string_create("$s0not_a_real_mangled_name")
        let decoded = try XPCDecoder().decode(SwiftType.self, from: object)
        XCTAssertEqual(decoded.mangledTypeName, "$s0not_a_real_mangled_name")
        XCTAssertNil(decoded.type)
    }

    // MARK: identity

    func testEqualityIgnoresWhetherTheTypeHasBeenResolved() throws {
        let resolved = try XCTUnwrap(SwiftType(SwiftTypeSample.self))
        let fromWire = SwiftType(mangledTypeName: resolved.mangledTypeName)
        XCTAssertEqual(resolved, fromWire)
        XCTAssertEqual(resolved.hashValue, fromWire.hashValue)

        // And it is usable as a dictionary key across that boundary, which is what
        // `SharedActorKey`'s use of it requires.
        XCTAssertEqual([resolved: 1][fromWire], 1)
    }

    func testRoundTripPreservesTheName() throws {
        let original = try XCTUnwrap(SwiftType(SwiftTypeSample.self))
        let object = try XPCEncoder().encode(original)
        XCTAssertEqual(try XPCDecoder().decode(SwiftType.self, from: object), original)
    }
}
