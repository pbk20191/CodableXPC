import XCTest
import XPC
@testable import XPCOverlayCoder

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
        let encoded = try XPCLegacyOverlayEncoder().encode(value)
        return try XPCLegacyOverlayDecoder().decode(
            T.self, from: encoded.body, outOfLineObjects: encoded.outOfLineObjects)
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

    func testDataGoesOutOfLineNotIntoTheStream() throws {
        // This test used to assert the opposite, on a reading of the disassembly.
        // Apple's own iOS 18 coder, run in a 18.6 simulator, settles it: `Data`
        // is appended to the side array as an `xpc_data` and the stream carries
        // an integer index. It is the only type that does this.
        struct Holder: Codable, Equatable { let blob: Data }
        let value = Holder(blob: Data([1, 2, 3]))
        let encoded = try XPCLegacyOverlayEncoder().encode(value)

        guard case .keyed(let entries) = encoded.tree,
              let slot = entries.first(where: { $0.key == "blob" })?.value
        else { return XCTFail("expected a blob entry, got \(encoded.tree)") }
        XCTAssertEqual(slot, .int(0))

        XCTAssertEqual(encoded.outOfLineObjects.count, 1)
        XCTAssertEqual(xpc_get_type(encoded.outOfLineObjects[0]), XPC_TYPE_DATA)

        XCTAssertEqual(try XPCLegacyOverlayDecoder().decode(
            Holder.self, from: encoded.body,
            outOfLineObjects: encoded.outOfLineObjects), value)
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
        XCTAssertEqual(try XPCLegacyOverlayEncoder().encode(Wrapped(7)).tree, .int(7))
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
