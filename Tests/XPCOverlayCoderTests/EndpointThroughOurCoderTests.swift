#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCOverlayCoder

@available(macOS 15, macCatalyst 18, *)
private struct Referral: Codable, Equatable {
    let label: String
    let endpoint: XPCEndpoint
}

/// A live `XPCEndpoint` encoded by this module and decoded by Apple's.
///
/// It works without any access to `XPCCodableObject`, which is unreachable SPI.
/// Apple's `XPCEndpoint.encode(to:)` only wants an array in `userInfo` under a
/// particular key; supplying one is the whole trick.
@available(macOS 15, macCatalyst 18, *)
final class EndpointThroughOurCoderTests: XCTestCase {

    func testTheKeyMatchesApples() {
        // Equality is by rawValue, so a key built from the same string is their key.
        XCTAssertEqual(CodingUserInfoKey.xpcOverlayCodableObjects.rawValue, "_XPCCodable")
    }

    func testOurEncoderPutsTheEndpointInTheObjectArray() throws {
        let target = XPCListener(targetQueue: nil, options: .inactive) {
            $0.accept { (_: XPCDictionary) in nil }
        }
        try target.activate()
        defer { target.cancel() }

        let encoded = try XPCOverlayEncoder().encode(
            Referral(label: "forwarding", endpoint: target.endpoint))

        // The endpoint is not in the byte stream -- only an index to it is.
        XCTAssertEqual(encoded.outOfLineObjects.count, 1)
        XCTAssertEqual(xpc_get_type(encoded.outOfLineObjects[0]), XPC_TYPE_ENDPOINT)
    }

    func testOurOwnRoundTripOfAnEndpoint() throws {
        let target = XPCListener(targetQueue: nil, options: .inactive) {
            $0.accept { (_: XPCDictionary) in nil }
        }
        try target.activate()
        defer { target.cancel() }

        let encoded = try XPCOverlayEncoder().encode(
            Referral(label: "self", endpoint: target.endpoint))
        let back: Referral = try XPCOverlayDecoder().decode(
            Referral.self, from: encoded.body,
            outOfLine: encoded.outOfLine, outOfLineObjects: encoded.outOfLineObjects)
        XCTAssertEqual(back.label, "self")
    }

    func testAppleDecodesAnEndpointWeEncoded() throws {
        let target = XPCListener(targetQueue: nil, options: .inactive) {
            $0.accept { (_: XPCDictionary) in nil }
        }
        try target.activate()
        defer { target.cancel() }

        let arrived = XCTestExpectation(description: "Apple decoded the referral")
        let box = Box()

        let listener = XPCListener(targetQueue: nil, options: .inactive) { request in
            // Apple's decoder runs here, on our bytes.
            request.accept { (message: Referral) -> (any Encodable)? in
                box.value = message
                arrived.fulfill()
                return nil
            }
        }
        try listener.activate()
        defer { listener.cancel() }

        let session = try XPCSession(endpoint: listener.endpoint, options: .inactive)
        try session.activate()
        defer { session.cancel(reason: "done") }

        let encoded = try XPCOverlayEncoder().encode(
            Referral(label: "forwarding", endpoint: target.endpoint))

        let envelope = xpc_dictionary_create(nil, nil, 0)
        encoded.body.withUnsafeBytes {
            xpc_dictionary_set_data(envelope, OverlayEnvelope.body, $0.baseAddress, $0.count)
        }
        xpc_dictionary_set_int64(envelope, OverlayEnvelope.coderVersion,
                                 OverlayWireFormat.coderVersion)
        xpc_dictionary_set_bool(envelope, OverlayEnvelope.isSync, false)
        xpc_dictionary_set_value(envelope, OverlayEnvelope.outOfLine, xpc_array_create(nil, 0))

        let objects = xpc_array_create(nil, 0)
        for object in encoded.outOfLineObjects { xpc_array_append_value(objects, object) }
        xpc_dictionary_set_value(envelope, OverlayEnvelope.outOfLineObjects, objects)

        try session.send(message: XPCDictionary(envelope))
        wait(for: [arrived], timeout: 10)

        let received = try XCTUnwrap(box.value)
        XCTAssertEqual(received.label, "forwarding")
        // The recovered endpoint has to be usable, not merely present. Activate
        // before cancelling: libxpc traps on an inactive session's teardown.
        let proof = try XPCSession(endpoint: received.endpoint, options: .inactive)
        try proof.activate()
        proof.cancel(reason: "reachable")
    }

    private final class Box: @unchecked Sendable { var value: Referral? }
}
#endif
