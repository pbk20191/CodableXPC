import XCTest
import GRPCCore
@testable import GRPCXPCTransport

/// Byte-exact vectors hand-computed from RFC 7541 §6.2.2 (Literal Header Field without
/// Indexing, new name) and §5.1/§5.2 (prefix-integer and string-literal encoding).
///
/// This codec speaks only the literal-only HPACK subset: no dynamic table, no static-table
/// indexing, no Huffman coding. Everything it emits is still valid HPACK any conformant decoder
/// accepts; everything outside that subset is a decode-time rejection, not a best-effort parse.
@available(macOS 15.0, *)
final class HPACKLiteralCodecTests: XCTestCase {

    // MARK: - Byte-exact encode vectors

    /// `00` = literal without indexing, new name (index 0).
    /// `07` + ":method" (7 bytes, no Huffman) is the name; `04` + "POST" is the value.
    func testMethodFieldIsByteExact() {
        let encoded = HPACKLiteralCodec.encode([(":method", "POST")])
        XCTAssertEqual([UInt8](encoded), [
            0x00, 0x07, 0x3a, 0x6d, 0x65, 0x74, 0x68, 0x6f, 0x64, 0x04, 0x50, 0x4f, 0x53, 0x54,
        ])
    }

    /// `00` | `0b` + "grpc-status" (11 bytes) | `01` + "0".
    func testGRPCStatusFieldIsByteExact() {
        let encoded = HPACKLiteralCodec.encode([("grpc-status", "0")])
        XCTAssertEqual([UInt8](encoded), [
            0x00, 0x0b, 0x67, 0x72, 0x70, 0x63, 0x2d, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x01, 0x30,
        ])
    }

    /// A 300-byte value's length prefix: 127 fits in the 7-bit prefix maximum, so the prefix
    /// byte is all-ones (`7F`) and the remainder (300 - 127 = 173) follows as LEB128:
    /// 173 = 0x2D | continuation, then 1 -> `AD 01`.
    func test300ByteValueLengthEncodesAsExtendedPrefixInteger() {
        let value = String(repeating: "x", count: 300)
        let encoded = [UInt8](HPACKLiteralCodec.encode([("x-long", value)]))
        // `00` | `06` "x-long" | `7F AD 01` <300 'x' bytes>
        let nameLen = 6
        let lengthPrefixStart = 1 + 1 + nameLen // field-type byte + name-length byte + name bytes
        XCTAssertEqual(Array(encoded[lengthPrefixStart..<(lengthPrefixStart + 3)]), [0x7F, 0xAD, 0x01])
        XCTAssertEqual(encoded.count, lengthPrefixStart + 3 + 300)
    }

    /// Multi-field ordering must be preserved byte-for-byte, not just set-equal.
    func testMultiFieldOrderingIsPreserved() {
        let fields: [HTTPField] = [(":method", "POST"), ("grpc-status", "0")]
        let expected = [UInt8](HPACKLiteralCodec.encode([(":method", "POST")]))
                      + [UInt8](HPACKLiteralCodec.encode([("grpc-status", "0")]))
        XCTAssertEqual([UInt8](HPACKLiteralCodec.encode(fields)), expected)
    }

    /// The encoder lowercases names, per HTTP/2's requirement that header field names be
    /// lowercase on the wire (RFC 9113 §8.2).
    func testEncoderLowercasesNames() {
        let decoded = try! HPACKLiteralCodec.decode(HPACKLiteralCodec.encode([("Content-Type", "application/grpc")]))
        XCTAssertEqual(decoded.map(\.name), ["content-type"])
    }

    // MARK: - Round trip

    func testRoundTripOfARealisticGRPCRequestHeaderList() throws {
        let fields: [HTTPField] = [
            (":method", "POST"),
            (":scheme", "https"),
            (":path", "/routeguide.RouteGuide/GetFeature"),
            (":authority", "localhost"),
            ("content-type", "application/grpc"),
            ("te", "trailers"),
            ("grpc-timeout", "10S"),
            ("grpc-encoding", "identity"),
        ]
        let decoded = try HPACKLiteralCodec.decode(HPACKLiteralCodec.encode(fields))
        assertFieldsEqual(decoded, fields)
    }

    // MARK: - Decode acceptance

    /// `10` = literal *never indexed*, new name (index 0). Semantically distinct from `00`
    /// (without indexing) at real HTTP/2 intermediaries, but this codec has no dynamic table
    /// either way, so it must decode identically.
    func testNeverIndexedPrefixIsAccepted() throws {
        var block = Data()
        block.append(0x10)                                  // never indexed, index 0
        block.append(0x06); block.append(contentsOf: Array("x-test".utf8))
        block.append(0x01); block.append(contentsOf: Array("y".utf8))
        let decoded = try HPACKLiteralCodec.decode(GRPCSwiftData(viewing: block))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, "x-test")
        XCTAssertEqual(decoded[0].value, "y")
    }

    // MARK: - Decode rejections

    /// `82` = indexed header field representation (top bit set) -- a static/dynamic-table
    /// reference this codec never produces and must not silently misinterpret.
    func testIndexedFieldIsRejected() {
        XCTAssertThrowsError(try HPACKLiteralCodec.decode(GRPCSwiftData([0x82]))) { error in
            guard let rpcError = error as? RPCError else { return XCTFail("expected RPCError, got \(error)") }
            XCTAssertEqual(rpcError.code, .unimplemented)
            XCTAssertTrue(rpcError.message.localizedCaseInsensitiveContains("indexed"))
            XCTAssertTrue(rpcError.message.localizedCaseInsensitiveContains("literal"))
        }
    }

    /// `40` = literal header field *with incremental indexing* -- would mutate a dynamic table
    /// this codec does not have.
    func testIncrementalIndexingIsRejected() {
        XCTAssertThrowsError(try HPACKLiteralCodec.decode(GRPCSwiftData([0x40]))) { error in
            guard let rpcError = error as? RPCError else { return XCTFail("expected RPCError, got \(error)") }
            XCTAssertEqual(rpcError.code, .unimplemented)
            XCTAssertTrue(rpcError.message.localizedCaseInsensitiveContains("incremental"))
        }
    }

    /// `20` = dynamic table size update -- dynamic-table state this codec never maintains.
    func testDynamicTableSizeUpdateIsRejected() {
        XCTAssertThrowsError(try HPACKLiteralCodec.decode(GRPCSwiftData([0x20]))) { error in
            guard let rpcError = error as? RPCError else { return XCTFail("expected RPCError, got \(error)") }
            XCTAssertEqual(rpcError.code, .unimplemented)
            XCTAssertTrue(rpcError.message.localizedCaseInsensitiveContains("table"))
        }
    }

    /// Huffman-coded string: H bit (0x80) set on a name's length-prefix byte.
    func testHuffmanCodedStringIsRejected() {
        var block = Data()
        block.append(0x00)          // without indexing, index 0
        block.append(0x81)          // H=1, length=1 -- Huffman-coded name
        block.append(0xFF)
        XCTAssertThrowsError(try HPACKLiteralCodec.decode(GRPCSwiftData(viewing: block))) { error in
            guard let rpcError = error as? RPCError else { return XCTFail("expected RPCError, got \(error)") }
            XCTAssertEqual(rpcError.code, .unimplemented)
            XCTAssertTrue(rpcError.message.localizedCaseInsensitiveContains("huffman"))
        }
    }

    /// A literal whose name is delivered by *index* into the static table (top 4 bits still
    /// `0000`/`0001`, but the index itself is nonzero) needs a static table this codec doesn't
    /// have, so it must be rejected rather than guessed at.
    func testIndexedNameReferenceIsRejected() {
        // 0x0F = without-indexing prefix (4 bits) with index 15 (the 4-bit prefix maximum,
        // signalling an extended index follows) -- definitely not index 0.
        XCTAssertThrowsError(try HPACKLiteralCodec.decode(GRPCSwiftData([0x0F, 0x00]))) { error in
            guard let rpcError = error as? RPCError else { return XCTFail("expected RPCError, got \(error)") }
            XCTAssertTrue(rpcError.message.localizedCaseInsensitiveContains("index"))
        }
    }

    // MARK: - The non-zero-offset regression (see HTTP2FrameTests.testDecodeFromANonZeroOffsetBuffer)

    /// Production inputs to `decode` are always a slice of a received HEADERS frame's payload,
    /// never a freshly allocated buffer starting at 0. `startIndex` must never be assumed to be 0.
    func testDecodeFromANonZeroOffsetBuffer() throws {
        let fields: [HTTPField] = [(":method", "POST"), ("grpc-status", "0")]
        var wire = Data([0xFF, 0xEE, 0xDD])                 // junk bytes ahead of the real block
        wire.append(HPACKLiteralCodec.encode(fields).data)
        let sliced = wire[3...]
        XCTAssertEqual(sliced.startIndex, 3)

        let decoded = try HPACKLiteralCodec.decode(GRPCSwiftData(viewing: sliced))
        assertFieldsEqual(decoded, fields)
    }

    // MARK: - Integer helpers, tested directly

    func testWriteIntFitsInPrefixWhenBelowMaximum() {
        var out = Data()
        HPACKLiteralCodec.writeInt(10, prefixBits: 7, firstByteBits: 0x00, into: &out)
        XCTAssertEqual([UInt8](out), [0x0A])
    }

    func testWriteIntAtExactlyThePrefixMaximumStillExtends() {
        // RFC 7541 §5.1: even when the remainder is exactly 0, the all-ones prefix is followed
        // by an explicit 0x00 continuation byte -- the extended form is triggered by reaching
        // the prefix maximum, not by whether anything nonzero remains.
        var out = Data()
        HPACKLiteralCodec.writeInt(127, prefixBits: 7, firstByteBits: 0x00, into: &out)
        XCTAssertEqual([UInt8](out), [0x7F, 0x00])
    }

    func testWriteIntMergesFirstByteBits() {
        var out = Data()
        HPACKLiteralCodec.writeInt(5, prefixBits: 4, firstByteBits: 0x20, into: &out)
        XCTAssertEqual([UInt8](out), [0x25])
    }

    func testReadIntRoundTripsThroughWriteInt() throws {
        for value in [0, 1, 15, 127, 128, 173, 300, 16_384] {
            var out = Data()
            HPACKLiteralCodec.writeInt(value, prefixBits: 7, firstByteBits: 0x00, into: &out)
            var offset = 0
            let block = GRPCSwiftData(viewing: out)
            let read = try HPACKLiteralCodec.readInt(prefixBits: 7, block: block, offset: &offset)
            XCTAssertEqual(read, value, "round trip failed for \(value)")
            XCTAssertEqual(offset, out.count)
        }
    }

    func testReadIntStartsFromAGivenOffsetAndAdvancesIt() throws {
        let block = GRPCSwiftData([0xFF, 0x0A])  // junk byte, then a single-byte integer (10)
        var offset = 1
        let value = try HPACKLiteralCodec.readInt(prefixBits: 7, block: block, offset: &offset)
        XCTAssertEqual(value, 10)
        XCTAssertEqual(offset, 2)
    }

    func testReadIntThrowsOnTruncatedContinuation() {
        // 0x7F signals "extended form follows" but no continuation byte is present.
        var offset = 0
        XCTAssertThrowsError(
            try HPACKLiteralCodec.readInt(prefixBits: 7, block: GRPCSwiftData([0x7F]), offset: &offset))
    }

    /// A malicious/corrupt peer that never clears the continuation bit must not spin forever or
    /// silently wrap `Int` -- it must be rejected.
    func testReadIntThrowsOnAPathologicallyLongContinuation() {
        var block: [UInt8] = [0x7F]
        block.append(contentsOf: Array(repeating: UInt8(0xFF), count: 32)) // continuation bit always set
        var offset = 0
        XCTAssertThrowsError(
            try HPACKLiteralCodec.readInt(prefixBits: 7, block: GRPCSwiftData(block), offset: &offset))
    }

    // MARK: - Helpers

    private func assertFieldsEqual(_ actual: [HTTPField], _ expected: [HTTPField],
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a.name, e.name, file: file, line: line)
            XCTAssertEqual(a.value, e.value, file: file, line: line)
        }
    }
}
