import XCTest
import GRPCCore
@testable import GRPCXPCTransport

/// Byte-exact vectors hand-computed from RFC 9113 §4.1 (frame header) and §6 (frame types).
/// Frame header layout: 3-byte length | 1-byte type | 1-byte flags | 4-byte stream id (top bit reserved).
@available(macOS 15.0, *)
final class HTTP2FrameTests: XCTestCase {

    // MARK: - Byte-exact vectors

    /// DATA, stream 1, END_STREAM, payload = 5 zero bytes (an empty length-prefixed message).
    /// header = 00 00 05 | 00 | 01 | 00 00 00 01
    func testDATAFrameIsByteExact() {
        let frame = HTTP2Frame(kind: .data, flags: .endStream, streamID: 1,
                                payload: GRPCSwiftData([0x00, 0x00, 0x00, 0x00, 0x00]))
        let encoded = HTTP2FrameCodec.encode([frame])
        XCTAssertEqual([UInt8](encoded), [
            0x00, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00,
        ])
    }

    /// WINDOW_UPDATE, stream 0, increment 65535: 00 00 04 | 08 | 00 | 00 00 00 00 | 00 00 ff ff
    func testWINDOWUPDATEFrameIsByteExact() {
        let frame = HTTP2Frame(kind: .windowUpdate, flags: [], streamID: 0,
                                payload: GRPCSwiftData([0x00, 0x00, 0xFF, 0xFF]))
        let encoded = HTTP2FrameCodec.encode([frame])
        XCTAssertEqual([UInt8](encoded), [
            0x00, 0x00, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0xFF, 0xFF,
        ])
    }

    /// RST_STREAM, stream 3, CANCEL: 00 00 04 | 03 | 00 | 00 00 00 03 | 00 00 00 08
    func testRSTSTREAMFrameIsByteExact() {
        let frame = HTTP2Frame(kind: .rstStream, flags: [], streamID: 3,
                                payload: GRPCSwiftData([0x00, 0x00, 0x00, 0x08]))
        let encoded = HTTP2FrameCodec.encode([frame])
        XCTAssertEqual([UInt8](encoded), [
            0x00, 0x00, 0x04, 0x03, 0x00, 0x00, 0x00, 0x00, 0x03,
            0x00, 0x00, 0x00, 0x08,
        ])
    }

    // MARK: - Round-trip

    /// Every `Kind` case survives an encode/decode round trip unchanged.
    func testRoundTripOfEveryKind() throws {
        let frames: [HTTP2Frame] = [
            HTTP2Frame(kind: .data, flags: .endStream, streamID: 1,
                       payload: GRPCSwiftData([0x01, 0x02, 0x03])),
            HTTP2Frame(kind: .headers, flags: [.endHeaders, .endStream], streamID: 3,
                       payload: GRPCSwiftData([0xAA, 0xBB])),
            HTTP2Frame(kind: .rstStream, flags: [], streamID: 5,
                       payload: GRPCSwiftData([0x00, 0x00, 0x00, 0x08])),
            HTTP2Frame(kind: .goAway, flags: [], streamID: 0,
                       payload: GRPCSwiftData([0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00])),
            HTTP2Frame(kind: .windowUpdate, flags: [], streamID: 0,
                       payload: GRPCSwiftData([0x00, 0x00, 0xFF, 0xFF])),
        ]
        for frame in frames {
            let decoded = try HTTP2FrameCodec.decodeAll(HTTP2FrameCodec.encode([frame]))
            XCTAssertEqual(decoded, [frame])
        }
    }

    /// Several frames concatenated on the wire decode back out in the same order.
    func testMultipleConcatenatedFramesDecodeInOrder() throws {
        let frames: [HTTP2Frame] = [
            HTTP2Frame(kind: .headers, flags: .endHeaders, streamID: 1,
                       payload: GRPCSwiftData([0x01])),
            HTTP2Frame(kind: .data, flags: [], streamID: 1,
                       payload: GRPCSwiftData([0x02, 0x03])),
            HTTP2Frame(kind: .data, flags: .endStream, streamID: 1,
                       payload: GRPCSwiftData([])),
        ]
        let blob = HTTP2FrameCodec.encode(frames)
        XCTAssertEqual(try HTTP2FrameCodec.decodeAll(blob), frames)
    }

    // MARK: - Unknown types and flags (RFC 9113 §4.1: MUST ignore and discard)

    /// An unknown frame type (0x6, PING, which this codec's `Kind` does not model) between two
    /// known frames is skipped and discarded, not an error -- both known frames survive.
    func testUnknownFrameTypeIsSkippedBetweenKnownFrames() throws {
        let first = HTTP2Frame(kind: .headers, flags: .endHeaders, streamID: 1,
                                payload: GRPCSwiftData([0x10]))
        let last = HTTP2Frame(kind: .data, flags: .endStream, streamID: 1,
                               payload: GRPCSwiftData([0x20, 0x21]))
        var blob = Data(HTTP2FrameCodec.encode([first]).data)
        // A hand-built PING frame (type 0x6): 8-byte opaque payload, stream 0.
        blob.append(contentsOf: [
            0x00, 0x00, 0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF,
        ])
        blob.append(HTTP2FrameCodec.encode([last]).data)
        let decoded = try HTTP2FrameCodec.decodeAll(GRPCSwiftData(viewing: blob))
        XCTAssertEqual(decoded, [first, last])
    }

    /// Flag bits this codec does not name (e.g. 0x2, PADDED) round-trip through the raw byte --
    /// they are neither stripped nor rejected -- while the named bits remain independently
    /// testable via `contains`.
    func testUnknownFlagBitsArePreservedButMaskable() throws {
        let frame = HTTP2Frame(kind: .data, flags: HTTP2Frame.Flags(rawValue: 0x1 | 0x2),
                                streamID: 1, payload: GRPCSwiftData([0x01]))
        let decoded = try HTTP2FrameCodec.decodeAll(HTTP2FrameCodec.encode([frame]))
        XCTAssertEqual(decoded, [frame])
        XCTAssertEqual(decoded[0].flags.rawValue, 0x3)
        XCTAssertTrue(decoded[0].flags.contains(.endStream))
        XCTAssertFalse(decoded[0].flags.contains(.endHeaders))
    }

    // MARK: - Errors

    /// A trailing frame whose declared length runs past the end of the blob throws.
    func testTruncatedTailThrows() {
        let full = HTTP2FrameCodec.encode([
            HTTP2Frame(kind: .data, flags: [], streamID: 1, payload: GRPCSwiftData([0x01, 0x02, 0x03])),
        ])
        let truncated = GRPCSwiftData(Array([UInt8](full).dropLast(2)))
        XCTAssertThrowsError(try HTTP2FrameCodec.decodeAll(truncated))
    }

    /// A header so short it doesn't even contain the fixed 9-byte frame header throws.
    func testTruncatedHeaderThrows() {
        XCTAssertThrowsError(try HTTP2FrameCodec.decodeAll(GRPCSwiftData([0x00, 0x00, 0x04, 0x03])))
    }

    /// RST_STREAM's payload is fixed at 4 bytes (the error code); any other length is malformed.
    func testRSTSTREAMWithWrongPayloadLengthThrows() {
        // Length field claims 5 bytes with a 5-byte payload present, but RST_STREAM must be 4.
        let blob: GRPCSwiftData = [
            0x00, 0x00, 0x05, 0x03, 0x00, 0x00, 0x00, 0x00, 0x03,
            0x00, 0x00, 0x00, 0x08, 0x00,
        ]
        XCTAssertThrowsError(try HTTP2FrameCodec.decodeAll(blob))
    }

    /// WINDOW_UPDATE's payload is fixed at 4 bytes (the increment); any other length is malformed.
    func testWINDOWUPDATEWithWrongPayloadLengthThrows() {
        let blob: GRPCSwiftData = [
            0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xFF,
        ]
        XCTAssertThrowsError(try HTTP2FrameCodec.decodeAll(blob))
    }

    /// A declared length beyond `maxFramePayload` is rejected outright.
    func testLengthOverMaxFramePayloadThrows() {
        var blob = Data()
        let length = HTTP2FrameCodec.maxFramePayload + 1
        blob.append(UInt8((length >> 16) & 0xFF))
        blob.append(UInt8((length >> 8) & 0xFF))
        blob.append(UInt8(length & 0xFF))
        blob.append(0x00) // DATA
        blob.append(0x00) // no flags
        blob.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // stream 1
        blob.append(Data(repeating: 0x00, count: length))
        XCTAssertThrowsError(try HTTP2FrameCodec.decodeAll(GRPCSwiftData(viewing: blob)))
    }

    /// The reserved top bit of the stream identifier is masked off on decode, per RFC 9113 §4.1.
    func testStreamIDTopBitIsMaskedOnDecode() throws {
        let blob: GRPCSwiftData = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x01,
        ]
        let decoded = try HTTP2FrameCodec.decodeAll(blob)
        XCTAssertEqual(decoded, [HTTP2Frame(kind: .data, flags: [], streamID: 1, payload: GRPCSwiftData([]))])
    }

    /// `encode` masks the top bit of an out-of-range stream id rather than corrupting the wire.
    func testEncodeMasksStreamIDTopBit() {
        let frame = HTTP2Frame(kind: .data, flags: [], streamID: 0x8000_0001, payload: GRPCSwiftData([]))
        let encoded = HTTP2FrameCodec.encode([frame])
        XCTAssertEqual([UInt8](encoded), [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
    }

    /// An empty blob has zero complete frames -- not an error.
    func testEmptyBlobDecodesToNoFrames() throws {
        XCTAssertEqual(try HTTP2FrameCodec.decodeAll(GRPCSwiftData([])), [HTTP2Frame]())
    }

    // MARK: - HTTP2ErrorCode

    /// `HTTP2ErrorCode` is a raw-value struct, not an enum: RFC 9113 §7 requires unknown error
    /// codes to be treated as INTERNAL_ERROR rather than rejected outright, which only a
    /// non-exhaustive raw type allows for.
    func testHTTP2ErrorCodeAcceptsUnknownRawValues() {
        let unknown = HTTP2ErrorCode(rawValue: 0xFFFF)
        XCTAssertEqual(unknown.rawValue, 0xFFFF)
        XCTAssertNotEqual(unknown, .internalError)
        XCTAssertEqual(HTTP2ErrorCode.cancel.rawValue, 0x8)
        XCTAssertEqual(HTTP2ErrorCode.compressionError.rawValue, 0x9)
    }
}
