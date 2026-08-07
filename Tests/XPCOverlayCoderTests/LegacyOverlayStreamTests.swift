import XCTest
@testable import XPCOverlayCoder

/// Unlike `XPCOverlayCoder`, these fixtures are **hand-built from the documented
/// grammar, not captured from a running system**. macOS 27 ships the newer coder,
/// so there is no way on this machine to obtain a real legacy message or to hand
/// ours to Apple's legacy decoder. That gap is real and is stated in the module
/// docs; what these tests establish is that the reader and writer agree with each
/// other and with the grammar as written down.
final class LegacyOverlayStreamTests: XCTestCase {

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    private func bytes(_ text: String) -> Data {
        Data(text.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    // MARK: grammar

    func testStringLengthIncludesTheTerminator() throws {
        // The one place the two formats differ in a way that silently corrupts
        // rather than fails: here the count is utf8 + 1, in the newer format it is
        // utf8 exactly.
        let encoded = LegacyOverlayStreamWriter.serialize(.string("hi"))
        XCTAssertEqual(hex(encoded), "0f 03 00 00 00 00 00 00 00 68 69 00")
        XCTAssertEqual(try LegacyOverlayStreamReader.parse(encoded), .string("hi"))
    }

    func testKeyedContainerLengthPrefixesEveryValue() throws {
        let value = LegacyOverlayValue.keyed([
            .init(key: "a", value: .int8(-1)),
            .init(key: "b", value: .bool(true)),
        ])
        let encoded = LegacyOverlayStreamWriter.serialize(value)
        // 11 = keyed, count 2, body length 0x2a = 42: two entries of 21 bytes each
        // (key tag 1 + length 8 + utf8 1 + NUL 1, then value length 8 + value 2).
        XCTAssertEqual(hex(encoded),
            "11 02 00 00 00 00 00 00 00 2a 00 00 00 00 00 00 00 " +
            "0f 02 00 00 00 00 00 00 00 61 00 02 00 00 00 00 00 00 00 03 ff " +
            "0f 02 00 00 00 00 00 00 00 62 00 02 00 00 00 00 00 00 00 0c 01")
        XCTAssertEqual(try LegacyOverlayStreamReader.parse(encoded), value)
    }

    func testUnkeyedContainerHasNoPerElementPrefix() throws {
        let value = LegacyOverlayValue.unkeyed([.uint8(1), .uint8(2)])
        let encoded = LegacyOverlayStreamWriter.serialize(value)
        XCTAssertEqual(hex(encoded),
            "10 02 00 00 00 00 00 00 00 04 00 00 00 00 00 00 00 08 01 08 02")
        XCTAssertEqual(try LegacyOverlayStreamReader.parse(encoded), value)
    }

    func testNilAndOptionalNoneAreDifferentEncodings() throws {
        // encodeNil() writes one byte; a nil Optional reaching the generic path
        // writes a marker plus a byte. Both mean nil, and Apple emits both.
        XCTAssertEqual(hex(LegacyOverlayStreamWriter.serialize(.null)), "01")
        XCTAssertEqual(hex(LegacyOverlayStreamWriter.serialize(.optionalNone)), "13 01")
        XCTAssertEqual(try LegacyOverlayStreamReader.parse(bytes("01")), .null)
        XCTAssertEqual(try LegacyOverlayStreamReader.parse(bytes("13 01")), .optionalNone)
    }

    func testEveryIntegerWidthKeepsItsOwnTag() throws {
        let widths: [LegacyOverlayValue] = [
            .int(-1), .int8(-1), .int16(-1), .int32(-1), .int64(-1),
            .uint(1), .uint8(1), .uint16(1), .uint32(1), .uint64(1),
        ]
        let tags = widths.map { LegacyOverlayStreamWriter.serialize($0).first! }
        XCTAssertEqual(tags, [2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        for value in widths {
            XCTAssertEqual(
                try LegacyOverlayStreamReader.parse(LegacyOverlayStreamWriter.serialize(value)),
                value)
        }
    }

    func testNestingRoundTrips() throws {
        let value = LegacyOverlayValue.keyed([
            .init(key: "inner", value: .keyed([.init(key: "n", value: .uint32(7))])),
            .init(key: "list", value: .unkeyed([.int(1), .string("two")])),
        ])
        XCTAssertEqual(
            try LegacyOverlayStreamReader.parse(LegacyOverlayStreamWriter.serialize(value)),
            value)
    }

    // MARK: rejection

    func testRejectsATagApplesEncoderNeverEmits() {
        // 18 and 20 are declared by Apple's encoder but never written; seeing one
        // means the stream is not what it claims to be.
        for tag in [UInt8(18), UInt8(20)] {
            XCTAssertThrowsError(try LegacyOverlayStreamReader.parse(Data([tag]))) { error in
                XCTAssertEqual(error as? LegacyOverlayCoderError, .unknownTag(tag))
            }
        }
    }

    func testADeclaredLengthCannotReachPastItsRegion() {
        // keyed, count 1, body length 0xFF -- far beyond the buffer.
        XCTAssertThrowsError(try LegacyOverlayStreamReader.parse(
            bytes("11 01 00 00 00 00 00 00 00 ff 00 00 00 00 00 00 00"))) { error in
            guard case .declaredLengthOverruns = error as? LegacyOverlayCoderError else {
                return XCTFail("expected an overrun, got \(error)")
            }
        }
    }

    func testRejectsAnUnterminatedString() {
        XCTAssertThrowsError(try LegacyOverlayStreamReader.parse(
            bytes("0f 03 00 00 00 00 00 00 00 68 69 ff"))) { error in
            XCTAssertEqual(error as? LegacyOverlayCoderError, .stringNotTerminated)
        }
    }

    func testRejectsTrailingBytes() {
        XCTAssertThrowsError(try LegacyOverlayStreamReader.parse(bytes("01 01"))) { error in
            XCTAssertEqual(error as? LegacyOverlayCoderError, .trailingBytes(1))
        }
    }
}
