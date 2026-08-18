import XCTest
@testable import XPCActors

/// Deliberately `internal`, not `private`. A `private` or `fileprivate` type mangles
/// with a `$<process address>yXZ` discriminator that `_typeByName` cannot resolve, so it
/// has no round trip to test -- and no peer could resolve it either.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
struct Sample: Codable, Equatable { let n: Int }

@available(macOS 26, *)
final class TypeNameTests: XCTestCase {

    func testAConcreteTypeRoundTrips() throws {
        let mangled = try XCTUnwrap(TypeName.mangled(for: Sample.self))
        let recovered = try XCTUnwrap(TypeName.type(for: mangled))
        XCTAssertTrue(recovered == Sample.self)
    }

    func testGenericAndStdlibTypesRoundTrip() throws {
        for type in [Int.self as Any.Type, String.self, [Int].self, [String: Int].self, Sample?.self] {
            let mangled = try XCTUnwrap(TypeName.mangled(for: type), "\(type)")
            XCTAssertTrue(TypeName.type(for: mangled) == type, "\(type)")
        }
    }

    /// The cache must be a cache, not a second source of truth: asking twice has to
    /// give the same answer, including for a name that does not resolve.
    func testRepeatedLookupsAgree() throws {
        let mangled = try XCTUnwrap(TypeName.mangled(for: Sample.self))
        XCTAssertEqual(TypeName.mangled(for: Sample.self), mangled)
        XCTAssertTrue(TypeName.type(for: mangled) == TypeName.type(for: mangled))
    }

    func testAnUnresolvableNameReturnsNilTwice() {
        XCTAssertNil(TypeName.type(for: "not a mangled name"))
        XCTAssertNil(TypeName.type(for: "not a mangled name"))
    }
}
