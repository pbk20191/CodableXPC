import XCTest
import Foundation
import XPC
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

    /// The two libxpc crossings, back to back: `createXPCRepresentation()` out and
    /// ``GRPCSwiftData/init(from:)`` back in. The value that comes back must still *reference* the
    /// `xpc_data` rather than duplicate it.
    ///
    /// This case used to go through `Codable`/`XPCNativeObject`, which was the outbound path while
    /// the payload rode inside an encoded value. It no longer does — the wire is now raw
    /// `xpc_data` under one dictionary key — so the same property is asserted over the crossings
    /// that survive.
    func testTheOutboundRepresentationIsStillBorrowableOnTheWayBackIn() {
        let payload = GRPCSwiftData(Array(0..<200))
        let crossed = payload.createXPCRepresentation()
        let receivedBase = xpc_data_get_bytes_ptr(crossed)

        let received = GRPCSwiftData(from: crossed)
        let receivedViewBase = received.withUnsafeBytes { $0.baseAddress }

        XCTAssertEqual(receivedViewBase, receivedBase, "the crossing copied the payload")
        XCTAssertEqual(Array(received), Array(0..<200))
    }

    /// A message body sliced out of a received blob is still a view onto that blob — the property
    /// `CompactWireCodec.decode` depends on when it hands each op's body out as
    /// `GRPCSwiftData(viewing: data[bodyStart..<bodyEnd])`.
    ///
    /// The payload here is deliberately larger than `Data`'s 14-byte inline-storage threshold
    /// (measured): below it `Data` copies the value into the struct regardless of what it is given,
    /// so a small-payload version of this test would fail for a reason that has nothing to do with
    /// the transport. `testASmallPayloadIsCopiedIntoInlineStorage` pins that boundary instead.
    ///
    /// This case used to drive the same property through `GRPCMessageFraming.unframe`, whose
    /// 5-byte length prefix the op wire format replaced with a 10-byte op header.
    func testSlicingABodyOutOfABlobDoesNotCopyIt() {
        let headerLength = 10
        let blobBytes = [UInt8](repeating: 0xEE, count: headerLength) + Array<UInt8>(0..<64)
        let object = GRPCSwiftData(blobBytes).createXPCRepresentation()
        let received = GRPCSwiftData(from: object)
        let blobBase = received.withUnsafeBytes { $0.baseAddress }

        let bodyStart = received.startIndex + headerLength
        let sliced = GRPCSwiftData(viewing: received.data[bodyStart..<received.endIndex])
        let bodyBase = sliced.withUnsafeBytes { $0.baseAddress }

        XCTAssertEqual(bodyBase, blobBase?.advanced(by: headerLength),
                       "the body was copied out of the blob instead of sliced")
        XCTAssertEqual(Array(sliced), Array<UInt8>(0..<64))
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

    /// An empty payload has nothing to borrow; it must still cross libxpc rather than trap.
    /// `init(from:)`'s `count > 0` guard is what makes this a copy of nothing instead of a buffer
    /// over a null pointer.
    func testAnEmptyPayloadRoundTrips() {
        let empty = GRPCSwiftData([])
        let received = GRPCSwiftData(from: empty.createXPCRepresentation())
        XCTAssertEqual(received.count, 0)
        XCTAssertEqual(Array(received), [])
    }

    /// A slice does not rebase to zero — the type documents this, so pin it. Subscripting a
    /// decoded body from a hardcoded `0` therefore traps, which is `Data`'s own contract.
    func testASlicedBodyKeepsItsParentIndices() {
        let blob = GRPCSwiftData([0xEE, 0xEE, 1, 2, 3])
        let body = GRPCSwiftData(viewing: blob.data[2..<5])
        XCTAssertEqual(body.startIndex, 2)
        XCTAssertEqual(Array(body), [1, 2, 3])
    }
}
