#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCLegacyOverlayCoder

@available(macOS 15, macCatalyst 18, *)
private struct Referral: Codable, Equatable {
    let label: String
    let endpoint: XPCEndpoint
}

/// A live `XPCEndpoint` through the reconstructed legacy coder.
///
/// The bytes cannot be checked against Apple — macOS 27 ships the newer coder —
/// but these tests are not only self-consistency. The code that puts the endpoint
/// into the side array is Apple's own `XPCEndpoint.encode(to:)`, running here,
/// driven by this module's `userInfo`. So the mechanism is verified even though
/// the surrounding grammar is not.
///
/// The iOS 18 disassembly shows `XPCCodableObject.encode(to:)` doing exactly what
/// the iOS 26 build does: read `userInfo`, project the `xpcCodable` key, throw
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
