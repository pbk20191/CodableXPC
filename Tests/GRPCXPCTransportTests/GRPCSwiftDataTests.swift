import XCTest
import Foundation
import XPC
import CodableXPC
@testable import GRPCXPCTransport

/// `GRPCSwiftData` exists for one reason: to carry a gRPC payload without copying it in or out of
/// libxpc. These tests assert that property directly — by comparing base addresses — because a
/// version that quietly copies would pass every behavioural test in the suite.
@available(macOS 15.0, *)
final class GRPCSwiftDataTests: XCTestCase {

    private func makeXPCData(_ bytes: [UInt8]) -> xpc_object_t {
        bytes.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
    }

    /// The inbound half: wrapping an `xpc_data` must *reference* libxpc's buffer, not duplicate it.
    func testWrappingAnXPCDataDoesNotCopy() {
        let object = makeXPCData(Array(0..<128))
        let libxpcBase = xpc_data_get_bytes_ptr(object)

        let wrapped = GRPCSwiftData(from: object)
        let wrappedBase = wrapped.withUnsafeBytes { $0.baseAddress }

        XCTAssertEqual(wrappedBase, libxpcBase, "the payload was copied out of the xpc_data")
        XCTAssertEqual(wrapped.count, 128)
    }

    /// The borrowed buffer must outlive the caller's reference to the `xpc_object_t` — that is what
    /// the custom deallocator is for. Without it this reads freed memory.
    func testTheBorrowedBufferSurvivesTheOriginalXPCReference() {
        func detach() -> GRPCSwiftData {
            let object = makeXPCData([9, 8, 7, 6])
            return GRPCSwiftData(from: object)
        }
        let survived = detach()
        for _ in 0..<64 { _ = Data(repeating: 0xAA, count: 1 << 16) }   // churn the allocator
        XCTAssertEqual(Array(survived), [9, 8, 7, 6])
    }

    /// The `Codable` path goes through `XPCNativeObject`, so a decoded payload must still reference
    /// the received buffer. Decoding through `Data` instead would hit `XPCDecoder`'s
    /// `Data(bytes:count:)` and copy the whole message.
    func testDecodingKeepsReferencingTheReceivedBuffer() throws {
        let payload = GRPCSwiftData(Array(0..<200))
        let encoded = try XPCEncoder().encode(payload)
        let receivedBase = xpc_data_get_bytes_ptr(encoded)

        let decoded = try XPCDecoder().decode(GRPCSwiftData.self, from: encoded)
        let decodedBase = decoded.withUnsafeBytes { $0.baseAddress }

        XCTAssertEqual(decodedBase, receivedBase, "decoding copied the payload")
        XCTAssertEqual(Array(decoded), Array(0..<200))
    }

    /// Unframing slices, so the payload handed to gRPC is still a view onto the received frame.
    ///
    /// The payload here is deliberately larger than `Data`'s 14-byte inline-storage threshold
    /// (measured): below it `Data` copies the value into the struct regardless of what it is given,
    /// so a small-payload version of this test would fail for a reason that has nothing to do with
    /// the transport. `testASmallPayloadIsCopiedIntoInlineStorage` pins that boundary instead.
    func testUnframingSlicesRatherThanCopying() throws {
        let payload = GRPCSwiftData(Array(0..<64))
        let object = GRPCMessageFraming.frame(payload).createXPCRepresentation()
        let received = GRPCSwiftData(from: object)
        let frameBase = received.withUnsafeBytes { $0.baseAddress }

        let sliced = try GRPCMessageFraming.unframe(received)
        let payloadBase = sliced.withUnsafeBytes { $0.baseAddress }

        XCTAssertEqual(payloadBase, frameBase?.advanced(by: GRPCMessageFraming.prefixLength),
                       "the payload was copied out of the frame instead of sliced")
        XCTAssertEqual(Array(sliced), Array(0..<64))
    }

    /// The boundary, measured rather than assumed: at 15 bytes and above the wrapper references
    /// libxpc's buffer; at 14 and below `Data` puts the value in inline storage and copies. Pinned
    /// so the caveat in `init(from:)`'s documentation cannot drift away from the behaviour.
    func testASmallPayloadIsCopiedIntoInlineStorage() {
        func referencesLibxpc(byteCount: Int) -> Bool {
            let object = makeXPCData([UInt8](repeating: 7, count: byteCount))
            let libxpcBase = xpc_data_get_bytes_ptr(object)
            return GRPCSwiftData(from: object).withUnsafeBytes { $0.baseAddress } == libxpcBase
        }
        XCTAssertFalse(referencesLibxpc(byteCount: 14), "14 bytes should land in inline storage")
        XCTAssertTrue(referencesLibxpc(byteCount: 15), "15 bytes should reference libxpc's buffer")
        XCTAssertTrue(referencesLibxpc(byteCount: 64 * 1024))
    }

    /// An empty payload has nothing to borrow; it must still round-trip rather than trap.
    func testAnEmptyPayloadRoundTrips() throws {
        let empty = GRPCSwiftData([])
        let decoded = try XPCDecoder().decode(
            GRPCSwiftData.self, from: try XPCEncoder().encode(empty))
        XCTAssertEqual(decoded.count, 0)
        XCTAssertEqual(Array(try GRPCMessageFraming.unframe(GRPCMessageFraming.frame(empty))), [])
    }

    /// A slice does not rebase to zero — the type documents this, so pin it.
    func testAnUnframedPayloadKeepsItsParentIndices() throws {
        let payload = try GRPCMessageFraming.unframe(
            GRPCMessageFraming.frame(GRPCSwiftData([1, 2, 3])))
        XCTAssertEqual(payload.startIndex, GRPCMessageFraming.prefixLength)
        XCTAssertEqual(Array(payload), [1, 2, 3])
    }
}
