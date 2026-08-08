#if canImport(Darwin)
import XCTest
import XPC
@testable import XPCOverlayCoder

/// The interop question this package exists to answer, asked of Apple directly.
///
/// The XPCDistributed work
/// (`docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md`) had a
/// standing worry that every discriminator on its wire -- `SharedActorKey.WireCode`,
/// the response tag, `basePriority`, `priority` -- is a small unsigned integer whose
/// xpc representation was assumed rather than checked. Resolving it turned out to
/// answer a larger question at the same time, recorded in the spec under
/// *What actually carries an XPCDistributed body*: those values never reach an xpc
/// integer at all. `XPCDictionary.encode(_:forKey:withUserInfo:)` -- the call
/// `Packet.Payload.init(encoding:userInfo:)` makes -- routes through
/// `XPCReceivedMessage.encodeMessage`, so the body is an **overlay byte stream**, and
/// signedness is the stream's business rather than xpc's.
///
/// What remains worth pinning is the end-to-end fact: a message this package encodes,
/// containing a small unsigned integer, decodes in Apple's own coder. `AppleCoderBridge`
/// runs Apple's decoder in-process, so this is Apple answering, not a model of it.
@available(macOS 15, macCatalyst 18, *)
private struct SmallUnsigned: Codable, Equatable {
    let tag: UInt8
    let alsoSigned: Int64
}

@available(macOS 15, macCatalyst 18, *)
final class AppleDecoderIntegerToleranceTests: XCTestCase {

    private let value = SmallUnsigned(tag: 2, alsoSigned: -9)

    override func setUpWithError() throws {
        try XCTSkipUnless(AppleCoderBridge.isAvailable,
                          "XPCReceivedMessage.init(dictionary:) no longer resolves")
    }

    func testAppleDecodesASmallUnsignedIntegerWeEncoded() throws {
        let message = try XPCOverlayEncoder().message(value)
        XCTAssertEqual(try AppleCoderBridge.decode(SmallUnsigned.self, from: message),
                       value)
    }

    /// And the reason the xpc-level signedness question was the wrong question: the
    /// body is one `xpc_data` blob. No field of the encoded value appears as an xpc
    /// integer, so nothing about it can be int64-versus-uint64.
    func testTheEncodedBodyIsAByteStreamAndNotAnXPCStructure() throws {
        let message = try XPCOverlayEncoder().message(value)
        let body = try XCTUnwrap(xpc_dictionary_get_value(message, OverlayEnvelope.body))
        XCTAssertEqual(xpc_get_type(body), XPC_TYPE_DATA,
                       "got \(String(cString: xpc_type_get_name(xpc_get_type(body))))")
        XCTAssertNil(xpc_dictionary_get_value(message, "tag"),
                     "no field of the value should appear as a top-level xpc entry")
    }
}
#endif
