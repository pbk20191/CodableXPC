import XCTest
@testable import XPCOverlayCoder

/// The fixtures are real bytes, captured from `XPCSession.send` on macOS 27 by
/// reading `_CodableBody` off the received message. They are the ground truth this
/// module is written against; if Apple changes the format these fail, which is the
/// point.
final class OverlayStreamTests: XCTestCase {

    private func bytes(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    func testKeyedContainerWithOneBool() throws {
        // struct Small: Codable { let a: Bool }   Small(a: true)
        let (root, containers) = try OverlayStreamReader.parse(
            bytes("13 0a 11 01 00 00 00 00 00 00 00 61 00 01"))
        XCTAssertEqual(root.kind, .keyed)
        XCTAssertEqual(root.items, [.key("a"), .bool(true)])
        XCTAssertTrue(containers.isEmpty)
    }

    func testKeyedContainerInterleavesKeysAndValues() throws {
        // struct Two: Codable { let a: Int8; let b: String }   Two(a: -1, b: "hi")
        let (root, _) = try OverlayStreamReader.parse(bytes(
            "13 0a 11 01 00 00 00 00 00 00 00 61 00 07 ff " +
            "11 01 00 00 00 00 00 00 00 62 00 03 02 00 00 00 00 00 00 00 68 69 00"))
        XCTAssertEqual(root.kind, .keyed)
        XCTAssertEqual(root.items, [.key("a"), .int8(-1), .key("b"), .string("hi")])
    }

    func testNestedContainerIsReferencedThenOpenedLater() throws {
        // struct Nested { let inner: Small; let n: UInt32 }  Nested(Small(false), 7)
        // The child's body follows the parent's, introduced by tag 0x15.
        let (root, containers) = try OverlayStreamReader.parse(bytes(
            "13 0a 11 05 00 00 00 00 00 00 00 69 6e 6e 65 72 00 14 00 00 00 00 " +
            "11 01 00 00 00 00 00 00 00 6e 00 0e 07 00 00 00 " +
            "15 13 0a 11 01 00 00 00 00 00 00 00 61 00 02"))
        XCTAssertEqual(root.items,
                       [.key("inner"), .containerReference(0), .key("n"), .uint32(7)])
        XCTAssertEqual(containers[0]?.kind, .keyed)
        XCTAssertEqual(containers[0]?.items, [.key("a"), .bool(false)])
    }

    func testArrayOfPrimitivesBecomesOneContainerPerElement() throws {
        // struct Arr { let xs: [UInt8] }   Arr(xs: [1, 2, 3])
        // Each element gets its own singleValue container -- Array.encode(to:) goes
        // through encode(_:) per element, not encode(contentsOf:), so this does NOT
        // take the out-of-line Data path that real Data does.
        let (root, containers) = try OverlayStreamReader.parse(bytes(
            "13 0a 11 02 00 00 00 00 00 00 00 78 73 00 14 00 00 00 00 " +
            "15 13 0b 14 01 00 00 00 14 02 00 00 00 14 03 00 00 00 " +
            "15 13 0c 0c 01 15 13 0c 0c 02 15 13 0c 0c 03"))
        XCTAssertEqual(root.items, [.key("xs"), .containerReference(0)])
        XCTAssertEqual(containers[0]?.kind, .unkeyed)
        XCTAssertEqual(containers[0]?.items,
                       [.containerReference(1), .containerReference(2), .containerReference(3)])
        XCTAssertEqual(containers[1]?.kind, .singleValue)
        XCTAssertEqual(containers[1]?.items, [.uint8(1)])
        XCTAssertEqual(containers[3]?.items, [.uint8(3)])
    }

    // MARK: rejection

    func testRejectsAnUnknownTag() {
        // Apple's decoder folds unknown bytes into its nil branch; this module does
        // not, because reading corruption as a valid nil is worse than failing.
        XCTAssertThrowsError(try OverlayStreamReader.parse(bytes("13 0a 7f"))) { error in
            XCTAssertEqual(error as? OverlayCoderError, .unknownTag(0x7f))
        }
    }

    func testRejectsADuplicateContainerReference() {
        XCTAssertThrowsError(try OverlayStreamReader.parse(
            bytes("13 0b 14 00 00 00 00 14 00 00 00 00"))) { error in
            XCTAssertEqual(error as? OverlayCoderError, .duplicateContainerReference(0))
        }
    }

    func testRejectsADanglingReference() {
        XCTAssertThrowsError(try OverlayStreamReader.parse(
            bytes("13 0b 14 00 00 00 00"))) { error in
            XCTAssertEqual(error as? OverlayCoderError, .danglingContainerReference(0))
        }
    }

    func testRejectsAnUnterminatedString() {
        XCTAssertThrowsError(try OverlayStreamReader.parse(
            bytes("13 0a 11 01 00 00 00 00 00 00 00 61 ff"))) { error in
            XCTAssertEqual(error as? OverlayCoderError, .stringNotTerminated)
        }
    }

    func testRejectsATruncatedStream() {
        XCTAssertThrowsError(try OverlayStreamReader.parse(bytes("13 0a 0e 07 00")))
    }
}

/// The version gate. An absent `_CodableCoderVersion` is the signature of the
/// iOS 18-era overlay, which wrote a native xpc tree rather than this byte stream —
/// a different format entirely, not a corrupt one.
final class OverlayVersionGateTests: XCTestCase {

    private struct Empty: Codable {}

    func testRejectsAMessageWithNoVersionKey() {
        XCTAssertThrowsError(
            try XPCOverlayDecoder().decode(Empty.self, from: Data([0x13, 0x0a]),
                                           outOfLine: [], coderVersion: nil)
        ) { error in
            XCTAssertEqual(error as? OverlayCoderError,
                           .missingEnvelopeKey("_CodableCoderVersion"))
        }
    }

    func testRejectsAFutureVersion() {
        XCTAssertThrowsError(
            try XPCOverlayDecoder().decode(Empty.self, from: Data([0x13, 0x0a]),
                                           outOfLine: [], coderVersion: 2)
        ) { error in
            XCTAssertEqual(error as? OverlayCoderError, .unsupportedCoderVersion(2))
        }
    }

    func testAcceptsVersionOne() throws {
        _ = try XPCOverlayDecoder().decode(Empty.self, from: Data([0x13, 0x0a]),
                                           outOfLine: [], coderVersion: 1)
    }
}

/// A primitive written through the *generic* `encode<T: Encodable>` overload.
///
/// That is what an existential reaches: opening `any Encodable` picks the generic
/// witness, not `encode(Int)`. The value then lands as a nested single-value
/// container node rather than as an inline value, and a decoder that reads only the
/// inline form cannot read its own encoder's output.
///
/// Found by the XPCDistributed transport work, whose invocation arguments are
/// `[any Codable]`. The corroboration that the *decoder* was the wrong half is in
/// `XPCActorsTests.PacketBodyTests`: Apple's own decoder reads these same bytes and
/// yields the same values.
final class OverlayGenericPrimitiveTests: XCTestCase {

    private struct Existential: Encodable {
        let values: [any Encodable]
        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        }
    }

    private struct KeyedExistential: Encodable {
        let value: any Encodable
        enum Key: String, CodingKey { case value }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(value, forKey: .value)
        }
    }

    private struct Pair: Decodable, Equatable {
        let number: Int
        let text: String
        init(number: Int, text: String) {
            self.number = number
            self.text = text
        }
        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            number = try container.decode(Int.self)
            text = try container.decode(String.self)
        }
    }

    private struct Single: Decodable, Equatable {
        let value: Int
        init(value: Int) { self.value = value }
    }

    func testAnUnkeyedGenericPrimitiveRoundTrips() throws {
        let encoded = try XPCOverlayEncoder().encode(
            Existential(values: [7 as Int, "hi" as String]))
        XCTAssertEqual(try XPCOverlayDecoder().decode(Pair.self, from: encoded.body),
                       Pair(number: 7, text: "hi"))
    }

    func testAKeyedGenericPrimitiveRoundTrips() throws {
        let encoded = try XPCOverlayEncoder().encode(KeyedExistential(value: 7 as Int))
        XCTAssertEqual(try XPCOverlayDecoder().decode(Single.self, from: encoded.body),
                       Single(value: 7))
    }
}
