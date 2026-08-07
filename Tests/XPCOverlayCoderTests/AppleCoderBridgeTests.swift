#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCOverlayCoder

@available(macOS 15, macCatalyst 18, *)
private struct Reading: Codable, Equatable {
    let name: String
    let samples: [Int32]
    let ratio: Double
}

/// Apple's decoder, reached in-process, run on envelopes this package assembled.
///
/// The existing endpoint test proves the same thing through a live `XPCListener`
/// and `XPCSession`. This is stricter in one way that matters: the framework will
/// only send a message it approves of, so a live round trip cannot check what
/// Apple does with a *malformed* envelope. Here the dictionary is handed over
/// directly, so a missing key or a wrong version can be checked too.
@available(macOS 15, macCatalyst 18, *)
final class AppleCoderBridgeTests: XCTestCase {

    private let value = Reading(name: "cabin", samples: [3, -4, 5], ratio: 0.5)

    override func setUpWithError() throws {
        try XCTSkipUnless(AppleCoderBridge.isAvailable,
                          "XPCReceivedMessage.init(dictionary:) no longer resolves")
    }

    func testAppleDecodesAnEnvelopeWeAssembled() throws {
        let message = try XPCOverlayEncoder().message(value)
        XCTAssertEqual(try AppleCoderBridge.decode(Reading.self, from: message), value)
    }

    func testEveryEnvelopeKeyIsWritten() throws {
        let message = try XPCOverlayEncoder().message(value, isSync: true)

        // The five keys the disassembly of XPCReceivedMessage.encodeMessage writes.
        for key in [OverlayEnvelope.body, OverlayEnvelope.coderVersion,
                    OverlayEnvelope.isSync, OverlayEnvelope.outOfLine,
                    OverlayEnvelope.outOfLineObjects] {
            XCTAssertNotNil(xpc_dictionary_get_value(message, key), "missing \(key)")
        }
        XCTAssertEqual(xpc_dictionary_get_int64(message, OverlayEnvelope.coderVersion),
                       OverlayWireFormat.coderVersion)
        XCTAssertTrue(xpc_dictionary_get_bool(message, OverlayEnvelope.isSync))
    }

    func testOurPartsMatchWhatWeWrote() throws {
        let message = try XPCOverlayEncoder().message(value, isSync: true)
        let parts = try OverlayEnvelope.parts(of: message)

        XCTAssertEqual(parts.coderVersion, OverlayWireFormat.coderVersion)
        XCTAssertTrue(parts.isSync)
        XCTAssertEqual(try XPCOverlayDecoder().decode(Reading.self, from: message), value)
    }

    func testAppleRejectsALegacyEnvelopeAsAnOldCoder() throws {
        // No _CodableCoderVersion, which is exactly how the older overlay wrote
        // every message. Apple's own words for this case are worth pinning.
        let message = try XPCLegacyOverlayEncoder().message(value)

        XCTAssertThrowsError(try AppleCoderBridge.decode(Reading.self, from: message)) {
            XCTAssertTrue("\($0)".contains("old XPC coder"),
                          "expected the old-coder rejection, got \($0)")
        }
    }

    func testOurDecoderRejectsAVersionlessEnvelopeToo() throws {
        let message = try XPCLegacyOverlayEncoder().message(value)

        XCTAssertThrowsError(try XPCOverlayDecoder().decode(Reading.self, from: message)) {
            XCTAssertEqual($0 as? OverlayCoderError,
                           .missingEnvelopeKey(OverlayEnvelope.coderVersion))
        }
    }

    func testTheLegacyReaderRejectsANewEnvelope() throws {
        // The detection only works in this direction: a legacy body announces
        // nothing about itself, so the newer key is the only tell.
        let message = try XPCOverlayEncoder().message(value)

        XCTAssertThrowsError(try XPCLegacyOverlayDecoder().decode(Reading.self, from: message)) {
            XCTAssertEqual($0 as? LegacyOverlayCoderError, .notALegacyMessage)
        }
    }

    func testAMessageWithNoBodyIsReportedAsSuch() {
        let empty = xpc_dictionary_create(nil, nil, 0)
        XCTAssertThrowsError(try OverlayEnvelope.parts(of: empty)) {
            XCTAssertEqual($0 as? OverlayCoderError, .missingEnvelopeKey(OverlayEnvelope.body))
        }
    }
}
#endif
