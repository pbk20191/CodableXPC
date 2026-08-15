import XCTest
@testable import XPCActors

/// The negative cache was peer-controlled, permanent, and wrong twice over.
///
/// `TypeName` kept a `Set<String>` of names that failed to resolve, so a repeated
/// unknown name would not cost a runtime lookup each time. Under this protocol's
/// actual threat model that reasoning is inverted: the names are **chosen by the
/// peer**. `SwiftType.type` reads `TypeName.type(for:)` with a string that arrived on
/// the wire — an invocation's `errorType`, `returnType`, `protocolStub` and every
/// generic substitution — so a peer sending distinct garbage grows the set without
/// bound, forever, and the cache only ever helped the case where a peer repeats *one*
/// name.
///
/// It was also a correctness bug independent of any peer. A name that fails to resolve
/// before its framework is `dlopen`ed stayed nil for the life of the process, so a
/// lazily-loaded type could never become resolvable.
///
/// Both were recorded as needing triage when `TypeName` was first written, and the
/// second and third peer-reachable defects found in this package were of exactly this
/// shape: a field a peer controls, whose unbounded or out-of-range values nobody had
/// enumerated.
@available(macOS 26, *)
final class TypeNameNegativeCacheTests: XCTestCase {

    /// Distinct unresolvable names must not accumulate.
    ///
    /// Phrased against the observable — repeated lookups still answer correctly and
    /// cheaply — rather than against the absent field, so it keeps meaning if the
    /// implementation ever grows a *bounded* cache instead.
    func testUnresolvableNamesDoNotAccumulate() {
        let before = TypeName.unresolvableCacheCount
        for i in 0..<5_000 {
            XCTAssertNil(TypeName.type(for: "$s_not_a_real_mangled_name_\(i)"))
        }
        let after = TypeName.unresolvableCacheCount
        XCTAssertLessThanOrEqual(
            after - before, 1_000,
            "a peer chooses these names; 5000 distinct ones must not retain 5000 entries")
    }

    /// The answer itself is unchanged — this is about what is retained, not what is
    /// returned.
    func testAnUnresolvableNameStillAnswersNilEveryTime() {
        let name = "$s_definitely_not_a_type_\(UUID().uuidString)"
        XCTAssertNil(TypeName.type(for: name))
        XCTAssertNil(TypeName.type(for: name))
        XCTAssertNil(TypeName.type(for: name))
    }

    /// A failure on one name does not poison a different one.
    ///
    /// **Weaker than it looks, and deliberately labelled so.** The real `dlopen` case —
    /// name X fails, X's framework loads, X now resolves — cannot be staged here, and
    /// this test does *not* cover it: it passes against the old negative cache too,
    /// because the near-miss and the real name are different keys. What actually
    /// establishes the `dlopen` property is
    /// ``testUnresolvableNamesDoNotAccumulate`` — there is no memo, so every lookup is
    /// a fresh `_typeByName`. This one is kept for the cheaper adjacent property, not
    /// as evidence for that one.
    func testAPreviousFailureDoesNotPoisonALaterSuccess() throws {
        let mangled = try XCTUnwrap(TypeName.mangled(for: LateResolver.self))

        // Fail on a near-miss first, so the failure path has definitely run.
        XCTAssertNil(TypeName.type(for: mangled + "_no_such_suffix"))

        let resolved = try XCTUnwrap(TypeName.type(for: mangled))
        XCTAssertTrue(resolved == LateResolver.self)
    }

    /// Resolved names are still cached — the positive direction is bounded by the
    /// number of types actually in the process, which no peer controls.
    func testResolvedNamesAreStillRemembered() throws {
        let mangled = try XCTUnwrap(TypeName.mangled(for: LateResolver.self))
        let first = try XCTUnwrap(TypeName.type(for: mangled))
        let second = try XCTUnwrap(TypeName.type(for: mangled))
        XCTAssertTrue(first == second)
    }
}

/// Internal, not `private`: a `private` type's mangled name carries a process-address
/// discriminator and does not resolve at all.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
struct LateResolver: Codable {}
