#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCOverlayCoder

private struct Reading: Codable, Equatable {
    let name: String
    let count: Int
    let blob: Data
}

/// One surface over three formats that share nothing but a lineage.
@available(macOS 15, macCatalyst 18, *)
final class GenerationRoutingTests: XCTestCase {

    private let value = Reading(name: "cabin", count: 3, blob: Data([1, 2, 3]))

    func testEachGenerationRoundTripsThroughTheFacade() throws {
        for generation in XPCOverlayGeneration.allCases {
            let message = try XPCOverlayMessageEncoder(generation: generation).message(value)
            let back = try XPCOverlayMessageDecoder(generation: generation)
                .decode(Reading.self, from: message)
            XCTAssertEqual(back, value, "\(generation) failed to round trip")
        }
    }

    func testTheEnvelopesDifferAsTheGenerationsDo() throws {
        func keys(_ m: xpc_object_t) -> Set<String> {
            var found: Set<String> = []
            xpc_dictionary_apply(m) { k, _ in found.insert(String(cString: k)); return true }
            return found
        }
        let seventeen = try XPCOverlayMessageEncoder(generation: .iOS17).message(value)
        let eighteen = try XPCOverlayMessageEncoder(generation: .iOS18).message(value)
        let twentySix = try XPCOverlayMessageEncoder(generation: .iOS26).message(value)

        XCTAssertEqual(keys(seventeen), ["_CodableBody", "_CodableIsSync"])
        XCTAssertEqual(keys(eighteen), ["_CodableBody", "_CodableIsSync", "_CodableOutOfLine"])
        XCTAssertEqual(keys(twentySix).count, 5)
        XCTAssertTrue(keys(twentySix).contains("_CodableCoderVersion"))
    }

    /// Detection reads the one thing a message says about itself.
    func testDetectionSeparatesTheRewriteAndNothingFiner() throws {
        let twentySix = try XPCOverlayMessageEncoder(generation: .iOS26).message(value)
        XCTAssertEqual(XPCOverlayMessageDecoder.detectGeneration(of: twentySix), .iOS26)

        // Both older builds look the same, so detection answers with the newer of
        // the two rather than guessing.
        for old in [XPCOverlayGeneration.iOS17, .iOS18] {
            let message = try XPCOverlayMessageEncoder(generation: old).message(value)
            XCTAssertEqual(XPCOverlayMessageDecoder.detectGeneration(of: message), .iOS18)
        }
    }

    func testAnUndeclaredDecoderFollowsTheDetection() throws {
        let message = try XPCOverlayMessageEncoder(generation: .iOS26).message(value)
        XCTAssertEqual(try XPCOverlayMessageDecoder().decode(Reading.self, from: message), value)
    }

    /// Where detection cannot help, being wrong fails rather than lying: iOS 17
    /// puts `Data` in the stream and iOS 18 puts an index there.
    func testTheOlderPairDoNotReadEachOthersData() throws {
        let seventeen = try XPCOverlayMessageEncoder(generation: .iOS17).message(value)
        XCTAssertThrowsError(try XPCOverlayMessageDecoder(generation: .iOS18)
            .decode(Reading.self, from: seventeen))
    }
}
#endif
