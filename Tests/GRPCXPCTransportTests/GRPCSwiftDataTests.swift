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

    // ---------------------------------------------------------------------------------------
    // MARK: - The other side of the borrow: mutation
    // ---------------------------------------------------------------------------------------

    /// The borrow is **read-only as far as libxpc is concerned**, and nothing above this type
    /// enforces that: `GRPCContiguousBytes` requires `withUnsafeMutableBytes`, `GRPCSwiftData` is
    /// `public`, and an application handler is free to mutate a message body it received.
    ///
    /// Forwarding straight to `Data.withUnsafeMutableBytes` hands out a writable pointer into the
    /// live `xpc_object_t`'s storage: `Data(bytesNoCopy:deallocator:)` believes it owns the buffer,
    /// so its copy-on-write never fires for the sole reference to it. That is `EXC_BAD_ACCESS` if
    /// the out-of-line mapping is read-only, and silent corruption of every other view of the same
    /// blob if it is not.
    ///
    /// 128 bytes because the borrow itself only exists at 15 and above (see
    /// `testASmallPayloadIsCopiedIntoInlineStorage`): below that `Data` has already copied and the
    /// test would pass for a reason that has nothing to do with the fix.
    func testMutatingAReceivedBodyDoesNotWriteLibxpcsBuffer() {
        let object = makeXPCData(Array(0..<128))
        let libxpcBase = xpc_data_get_bytes_ptr(object)!.assumingMemoryBound(to: UInt8.self)

        var received = GRPCSwiftData(from: object)
        XCTAssertEqual(
            received.withUnsafeBytes { $0.baseAddress }, UnsafeRawPointer(libxpcBase),
            "the premise: this value must be borrowing libxpc's buffer before it is mutated")

        received.withUnsafeMutableBytes { $0[0] = 0xFF }

        XCTAssertEqual(libxpcBase[0], 0, "the mutation was written into libxpc's own buffer")
        XCTAssertEqual(Array(received).first, 0xFF, "…and the caller's mutation was lost")
        XCTAssertNotEqual(
            received.withUnsafeBytes { $0.baseAddress }, UnsafeRawPointer(libxpcBase),
            "after the copy the value must no longer reference libxpc's buffer at all")

        // The copy happens once. A second mutation goes straight to the now-owned storage, and
        // still must not reach libxpc.
        received.withUnsafeMutableBytes { $0[1] = 0xEE }
        XCTAssertEqual(libxpcBase[1], 1)
        XCTAssertEqual(Array(received.prefix(3)), [0xFF, 0xEE, 2])

        // Unchanged everywhere else: the rest of the payload survived the copy verbatim.
        XCTAssertEqual(Array(received.suffix(3)), [125, 126, 127])
    }

    /// The shape the transport actually produces: `CompactWireCodec.decode` hands each op's body
    /// out as a **slice** of the received blob, and the blob `Data` itself does not outlive the
    /// decode. The slice is then the sole reference to libxpc's storage, so it writes through in
    /// exactly the same way — measured, not assumed, since a slice whose parent is still alive
    /// happens to copy on mutation and would have hidden this.
    ///
    /// The copy must **keep the body's index base**: a decoded body starts at the op header's
    /// length, not at `0` (`testASlicedBodyKeepsItsParentIndices`), and a mutation that silently
    /// rebased it would move indices out from under a caller that had already read `startIndex`.
    func testMutatingASlicedBodyNeitherWritesThroughNorRebasesIt() {
        let headerLength = 10
        let object = makeXPCData([UInt8](repeating: 0xEE, count: headerLength) + Array(0..<64))
        let libxpcBase = xpc_data_get_bytes_ptr(object)!.assumingMemoryBound(to: UInt8.self)

        // The parent blob is deliberately not kept alive past this line — that is the codec's own
        // shape, and it is what makes the slice the sole reference to the borrowed storage.
        var body = GRPCSwiftData(
            viewing: GRPCSwiftData(from: object).data[headerLength..<(headerLength + 64)])
        XCTAssertEqual(body.startIndex, headerLength)

        body.withUnsafeMutableBytes { $0[0] = 0xFF }

        XCTAssertEqual(libxpcBase[headerLength], 0, "the mutation reached libxpc's buffer")
        XCTAssertEqual(body[body.startIndex], 0xFF)
        XCTAssertEqual(
            body.startIndex, headerLength,
            "the copy rebased the body to zero; a decoded body's indices are the blob's")
        XCTAssertEqual(body.count, 64)
        XCTAssertEqual(Array(body.suffix(2)), [62, 63])
    }

    /// Where the bytes live is not part of the value: a borrowed payload and an owned one with the
    /// same bytes must compare equal. Pinned because the borrow is tracked in a stored property,
    /// and a synthesized `==` would have compared that too.
    func testEqualityIgnoresWhetherTheStorageIsBorrowed() {
        let bytes = Array<UInt8>(0..<32)
        let borrowed = GRPCSwiftData(from: makeXPCData(bytes))
        XCTAssertEqual(borrowed, GRPCSwiftData(bytes))
        XCTAssertNotEqual(borrowed, GRPCSwiftData(bytes.dropLast()))
    }
}
