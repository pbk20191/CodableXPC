import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class GRPCMessageFramingTests: XCTestCase {

    /// The standard envelope: 1 byte compressed-flag (0), then 4 bytes big-endian length.
    func testFramingProducesTheStandardFiveBytePrefix() {
        let framed = GRPCMessageFraming.frame(GRPCSwiftData([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual([UInt8](framed), [0x00, 0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC])
    }

    func testAnEmptyPayloadStillCarriesThePrefix() {
        XCTAssertEqual([UInt8](GRPCMessageFraming.frame(GRPCSwiftData([]))), [0x00, 0x00, 0x00, 0x00, 0x00])
    }

    func testRoundTrip() throws {
        let payload = GRPCSwiftData(Array(UInt8(0)..<200))
        XCTAssertEqual(try GRPCMessageFraming.unframe(GRPCMessageFraming.frame(payload)), payload)
    }

    /// Length is big-endian, so a payload longer than 255 bytes must not fit in the last byte.
    func testLengthIsBigEndian() {
        let framed = GRPCMessageFraming.frame(GRPCSwiftData(repeating: 7, count: 300))
        XCTAssertEqual([UInt8](framed.prefix(5)), [0x00, 0x00, 0x00, 0x01, 0x2C])
    }

    func testATruncatedFrameIsRejected() {
        XCTAssertThrowsError(try GRPCMessageFraming.unframe(GRPCSwiftData([0x00, 0x00, 0x00])))
    }

    /// Declared length longer than the bytes present.
    func testALengthMismatchIsRejected() {
        XCTAssertThrowsError(
            try GRPCMessageFraming.unframe(GRPCSwiftData([0x00, 0x00, 0x00, 0x00, 0x09, 0x01])))
    }

    /// Compression is not implemented in v1; a set flag must be refused, not ignored.
    func testACompressedFlagIsRejected() {
        XCTAssertThrowsError(
            try GRPCMessageFraming.unframe(GRPCSwiftData([0x01, 0x00, 0x00, 0x00, 0x01, 0x41])))
    }
}
