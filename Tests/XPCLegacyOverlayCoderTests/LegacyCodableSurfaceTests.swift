import XCTest
@testable import XPCLegacyOverlayCoder

private struct Scalars: Codable, Equatable {
    let flag: Bool
    let small: Int8
    let wide: UInt32
    let name: String
    let ratio: Double
}
private struct Inner: Codable, Equatable { let value: Int }
private struct Outer: Codable, Equatable {
    let inner: Inner
    let list: [Int]
    let optional: String?
}

/// Round trips through the reconstructed grammar. Apple is not in the loop here —
/// macOS 27 ships the newer coder — so these prove internal consistency and that
/// the shapes the grammar calls for actually appear, not byte compatibility.
final class LegacyCodableSurfaceTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let body = try XPCLegacyOverlayEncoder().encode(value)
        return try XPCLegacyOverlayDecoder().decode(T.self, from: body)
    }

    func testScalars() throws {
        let value = Scalars(flag: true, small: -8, wide: 70_000, name: "legacy", ratio: -0.25)
        XCTAssertEqual(try roundTrip(value), value)
    }

    func testNestedAndAbsentOptional() throws {
        let value = Outer(inner: Inner(value: 9), list: [1, 2, 3], optional: nil)
        XCTAssertEqual(try roundTrip(value), value)
    }

    func testPresentOptional() throws {
        let value = Outer(inner: Inner(value: -1), list: [], optional: "here")
        XCTAssertEqual(try roundTrip(value), value)
    }

    func testTopLevelArray() throws {
        XCTAssertEqual(try roundTrip([Inner(value: 1), Inner(value: 2)]),
                       [Inner(value: 1), Inner(value: 2)])
    }

    func testDataIsAnOrdinaryByteRun() throws {
        // No out-of-line path in this generation: Data goes through its stock
        // Codable conformance and becomes an unkeyed run of UInt8.
        struct Holder: Codable, Equatable { let blob: Data }
        let value = Holder(blob: Data([1, 2, 3]))
        XCTAssertEqual(try roundTrip(value), value)

        let tree = try XPCLegacyOverlayEncoder().tree(value)
        guard case .keyed(let entries) = tree,
              case .unkeyed(let bytes)? = entries.first(where: { $0.key == "blob" })?.value
        else { return XCTFail("expected blob to be an unkeyed container, got \(tree)") }
        XCTAssertEqual(bytes, [.uint8(1), .uint8(2), .uint8(3)])
    }

    func testSingleValueContainerIsTransparent() throws {
        // A newtype over Int must encode as a bare Int, with no container framing.
        struct Wrapped: Codable, Equatable {
            let n: Int
            init(_ n: Int) { self.n = n }
            init(from decoder: Decoder) throws {
                n = try decoder.singleValueContainer().decode(Int.self)
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                try c.encode(n)
            }
        }
        XCTAssertEqual(try XPCLegacyOverlayEncoder().tree(Wrapped(7)), .int(7))
        XCTAssertEqual(try roundTrip(Wrapped(7)), Wrapped(7))
    }

    func testDuplicateKeyThrowsRatherThanTrapping() throws {
        // Apple traps here. Throwing is better behaviour for the same programmer
        // error and does not change the format.
        struct Twice: Encodable {
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: K.self)
                try c.encode(1, forKey: .a)
                try c.encode(2, forKey: .a)
            }
            enum K: String, CodingKey { case a }
        }
        XCTAssertThrowsError(try XPCLegacyOverlayEncoder().encode(Twice())) { error in
            XCTAssertEqual(error as? LegacyOverlayEncodingError, .duplicateKey("a"))
        }
    }

    func testWidthMismatchThrows() throws {
        // Exact tag match, as in both generations: an Int64 does not satisfy Int32.
        let body = LegacyOverlayStreamWriter.serialize(
            .keyed([.init(key: "n", value: .int64(1))]))
        struct Narrow: Codable { let n: Int32 }
        XCTAssertThrowsError(try XPCLegacyOverlayDecoder().decode(Narrow.self, from: body))
    }

    func testDecodeNilAcceptsBothEncodingsOfNothing() throws {
        struct Holder: Codable, Equatable { let a: String? }
        for nothing in [LegacyOverlayValue.null, .optionalNone] {
            let body = LegacyOverlayStreamWriter.serialize(.keyed([.init(key: "a", value: nothing)]))
            XCTAssertEqual(try XPCLegacyOverlayDecoder().decode(Holder.self, from: body),
                           Holder(a: nil))
        }
    }
}
