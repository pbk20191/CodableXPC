#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCOverlayCoder

@available(macOS 15, macCatalyst 18, *)
private struct Referral: Codable, Equatable {
    let label: String
    let endpoint: XPCEndpoint
}

/// A live `XPCEndpoint` through the reconstructed legacy coder.
///
/// The bytes themselves are checked elsewhere, against Apple's own iOS 18 coder
/// in an 18.6 simulator — see `AppleIOS18FixtureTests`. What these tests add is
/// the mechanism: the code that puts the endpoint into the side array is Apple's
/// own `XPCEndpoint.encode(to:)`, running here, driven by this module's
/// `userInfo`.
///
/// The iOS 18 disassembly shows `XPCCodableObject.encode(to:)` doing exactly what
/// the newer build does: read `userInfo`, project the `xpcCodable` key, throw
/// `CodingUserInfoKeyNotFound` when it is missing, append to the array, and write
/// the pre-append count through a single-value container. Only the envelope key
/// holding the array differs — `_CodableOutOfLine` here, and in the newer format
/// `_CodableOutOfLine4CodableObject`.
@available(macOS 15, macCatalyst 18, *)
final class LegacyEndpointTests: XCTestCase {

    private func liveEndpoint() throws -> XPCEndpoint {
        let target = XPCListener(targetQueue: nil, options: .inactive) {
            $0.accept { (_: XPCDictionary) in nil }
        }
        try target.activate()
        addTeardownBlock { target.cancel() }
        return target.endpoint
    }

    /// An `iOS17` coder cannot carry one, and says so rather than writing a
    /// message the peer would misread.
    ///
    /// Nothing was lost by that: `XPCEndpoint` is macOS 15 / macCatalyst 18, so
    /// it shipped *with* the generation this module calls `.iOS18`, alongside the
    /// `XPCCodableObject` machinery that carries it. The iOS 17 binary mentions
    /// neither — 0 references against 20 and 259 — because in that release there
    /// was nothing to carry.
    func testTheOlderGenerationCannotCarryAnEndpoint() throws {
        let referral = Referral(label: "forwarding", endpoint: try liveEndpoint())

        XCTAssertThrowsError(
            try XPCLegacyOverlayEncoder(generation: .iOS17).encode(referral),
            "an iOS 17 message has no side array for an endpoint to go in")

        // And the generation that introduced it handles it fine.
        XCTAssertEqual(
            try XPCLegacyOverlayEncoder(generation: .iOS18).encode(referral)
                .outOfLineObjects.count, 1)
    }

    func testTheKeyMatchesApples() {
        // Equality is by rawValue, so a key built from the same string is their key.
        XCTAssertEqual(CodingUserInfoKey.xpcLegacyCodableObjects.rawValue, "_XPCCodable")
    }

    func testTheEndpointGoesToTheSideArrayAndNotTheStream() throws {
        let encoded = try XPCLegacyOverlayEncoder().encode(
            Referral(label: "forwarding", endpoint: try liveEndpoint()))

        XCTAssertEqual(encoded.outOfLineObjects.count, 1)
        XCTAssertEqual(xpc_get_type(encoded.outOfLineObjects[0]), XPC_TYPE_ENDPOINT)

        // What lands in the stream is an ordinary integer index, which is why the
        // tag table needs no case for an object reference.
        guard case .keyed(let entries) = encoded.tree,
              let slot = entries.first(where: { $0.key == "endpoint" })?.value
        else { return XCTFail("expected an endpoint entry, got \(encoded.tree)") }
        XCTAssertEqual(slot, .int(0))
    }

    func testRoundTripOfAnEndpoint() throws {
        let encoded = try XPCLegacyOverlayEncoder().encode(
            Referral(label: "self", endpoint: try liveEndpoint()))
        let back = try XPCLegacyOverlayDecoder().decode(
            Referral.self, from: encoded.body,
            outOfLineObjects: encoded.outOfLineObjects)

        XCTAssertEqual(back.label, "self")
        // The recovered endpoint has to be usable, not merely present. Activate
        // before cancelling: libxpc traps on an inactive session's teardown.
        let proof = try XPCSession(endpoint: back.endpoint, options: .inactive)
        try proof.activate()
        proof.cancel(reason: "reachable")
    }

    // There is no test for decoding a body whose index points into an array that
    // never arrived. It does not throw: `xpc_array_get_value` aborts the process on
    // an out-of-range index, so Apple's `XPCEndpoint.init(from:)` takes the whole
    // test runner down with SIGTRAP. Written as a test it killed the suite rather
    // than failing it. The behaviour is documented on the decoder instead.
}
#endif
