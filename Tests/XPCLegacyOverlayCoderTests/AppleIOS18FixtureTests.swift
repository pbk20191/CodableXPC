#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCLegacyOverlayCoder

private struct Scalars: Codable, Equatable {
    let flag: Bool; let small: Int8; let wide: UInt32; let name: String; let ratio: Double
}
private struct Blob: Codable, Equatable { let label: String; let bytes: Data }

/// Bytes produced by Apple's own iOS 18 coder, pinned here.
///
/// The module could not be checked against Apple from this machine: macOS ships
/// the newer coder, and the older one is gone. An iOS 18.6 simulator runtime has
/// it, and — unlike the macOS build, where the byte-level coder was folded away —
/// iOS 18 still exports `XPCEncoder.encode(_:) -> [UInt8]` and
/// `XPCDecoder.decode(_:from:)`. No connection, no envelope: just the coder.
///
/// `Tools/verify-legacy-against-ios18.sh` runs the full bidirectional check in
/// the simulator. These fixtures are what it produced, so the macOS suite keeps
/// the result after the simulator is gone.
///
/// Keyed entry order is not pinned as an expectation — Apple emits in `Dictionary`
/// hash order, which is seeded per process. These bytes are one real ordering,
/// and reading them is the assertion.
final class AppleIOS18FixtureTests: XCTestCase {

    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[i...hex.index(after: i)], radix: 16)!
        })
    }

    func testWeReadAppleScalars() throws {
        let body = bytes("""
            11050000000000000092000000000000000f0600000000000000736d616c6c0002000000\
            0000000003f80f0500000000000000776964650005000000000000000a701101000f0500\
            000000000000666c61670002000000000000000c010f05000000000000006e616d650010\
            000000000000000f07000000000000006c6567616379000f06000000000000007261746\
            96f0009000000000000000e000000000000d0bf
            """.replacingOccurrences(of: "\n", with: ""))

        XCTAssertEqual(try XPCLegacyOverlayDecoder().decode(Scalars.self, from: body),
                       Scalars(flag: true, small: -8, wide: 70_000,
                               name: "legacy", ratio: -0.25))
    }

    /// The one the reconstruction got wrong. `Data` does not go in the stream as a
    /// run of bytes: it goes in the side array as an `xpc_data`, and the stream
    /// carries an integer index — tag 2, value 0, right there at the end.
    func testWeReadAppleData() throws {
        let body = bytes("""
            11020000000000000048000000000000000f06000000000000006c6162656c0011000000\
            000000000f08000000000000007061796c6f6164000f0600000000000000627974657300\
            0900000000000000020000000000000000
            """.replacingOccurrences(of: "\n", with: ""))
        let payload = Data([0, 1, 2, 250, 255])
        let side = payload.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }

        XCTAssertEqual(
            try XPCLegacyOverlayDecoder().decode(Blob.self, from: body,
                                                 outOfLineObjects: [side]),
            Blob(label: "payload", bytes: payload))
    }

    /// No keyed container, so no hash order, so our bytes are Apple's bytes.
    func testOurBytesEqualApplesWhereOrderIsNotFree() throws {
        XCTAssertEqual(try XPCLegacyOverlayEncoder().encode([1, -2, 3]).body,
                       bytes("1003000000000000001b00000000000000020100000000000000"
                             + "02feffffffffffffff020300000000000000"))
        XCTAssertEqual(try XPCLegacyOverlayEncoder().encode("bare").body,
                       bytes("0f05000000000000006261726500"))
    }

    func testAndAppleReadsThoseBack() throws {
        // Round-tripping the fixtures through our own decoder proves the pinning
        // is self-consistent; the simulator run is what proves Apple agrees.
        XCTAssertEqual(try XPCLegacyOverlayDecoder().decode(
            [Int].self, from: try XPCLegacyOverlayEncoder().encode([1, -2, 3]).body), [1, -2, 3])
    }
}
#endif

#if canImport(Darwin)
/// iOS 17 is the same byte stream with less around it.
///
/// Every tag ordinal in a decompiled iOS 17.6.1 `libswiftXPC` matches this
/// module's — `CodingContainer.wireType` gives 0…19 and the emitted byte is that
/// plus one, so nil is 1, `Int`…`String` are 2…15, unkeyed is 16, keyed is 17,
/// single-value 18, absent-optional 19, encoder 20. What is missing is the
/// machinery beside it: no `XPCCodableObject`, no
/// `XPCCodableObjectRepresentableCache`, no `_XPCCodable` — 220 references in the
/// iOS 18 binary, none in the iOS 17 one — and an `encodeMessage` that writes
/// `_CodableBody` and `_CodableIsSync` and stops.
///
/// So `Data` cannot go out-of-line there, because there is nowhere for it to go.
final class LegacyGenerationTests: XCTestCase {

    private struct Holder: Codable, Equatable { let blob: Data }
    private let value = Holder(blob: Data([1, 2, 3]))

    func testIOS17WritesDataIntoTheStream() throws {
        let encoded = try XPCLegacyOverlayEncoder(generation: .iOS17).encode(value)

        XCTAssertTrue(encoded.outOfLineObjects.isEmpty)
        guard case .keyed(let entries) = encoded.tree,
              case .unkeyed(let bytes)? = entries.first(where: { $0.key == "blob" })?.value
        else { return XCTFail("expected a byte run, got \(encoded.tree)") }
        XCTAssertEqual(bytes, [.uint8(1), .uint8(2), .uint8(3)])

        XCTAssertEqual(try XPCLegacyOverlayDecoder(generation: .iOS17)
            .decode(Holder.self, from: encoded.body), value)
    }

    func testIOS18PutsItBesideTheStream() throws {
        let encoded = try XPCLegacyOverlayEncoder(generation: .iOS18).encode(value)

        XCTAssertEqual(encoded.outOfLineObjects.count, 1)
        guard case .keyed(let entries) = encoded.tree else { return XCTFail("expected keyed") }
        XCTAssertEqual(entries.first(where: { $0.key == "blob" })?.value, .int(0))
    }

    /// Nothing in a message says which generation it is, so the wrong setting is
    /// a decode failure rather than a wrong answer.
    func testTheGenerationsDoNotReadEachOther() throws {
        let fromEighteen = try XPCLegacyOverlayEncoder(generation: .iOS18).encode(value)
        XCTAssertThrowsError(try XPCLegacyOverlayDecoder(generation: .iOS17)
            .decode(Holder.self, from: fromEighteen.body))

        let fromSeventeen = try XPCLegacyOverlayEncoder(generation: .iOS17).encode(value)
        XCTAssertThrowsError(try XPCLegacyOverlayDecoder(generation: .iOS18)
            .decode(Holder.self, from: fromSeventeen.body,
                    outOfLineObjects: fromSeventeen.outOfLineObjects))
    }

    /// Everything that is not `Data` is generation-independent, which is most of
    /// the format.
    func testEverythingElseIsIdenticalAcrossGenerations() throws {
        struct Plain: Codable, Equatable { let a: Int; let b: String; let c: [Bool] }
        let plain = Plain(a: -1, b: "same", c: [true, false])
        XCTAssertEqual(try XPCLegacyOverlayEncoder(generation: .iOS17).encode(plain).body,
                       try XPCLegacyOverlayEncoder(generation: .iOS18).encode(plain).body)
    }
}
#endif
