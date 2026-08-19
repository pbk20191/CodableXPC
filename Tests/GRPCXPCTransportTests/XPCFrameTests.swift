import XCTest
import GRPCCore
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class XPCFrameTests: XCTestCase {
    func testWireMetadataRoundTripsStringAndBinary() {
        var md = Metadata()
        md.addString("v1", forKey: "k1")
        md.addString("v2", forKey: "k1")            // multi-value
        md.addBinary([0xDE, 0xAD], forKey: "k2-bin")
        let restored = WireMetadata(md).asMetadata()
        XCTAssertEqual(Array(restored[stringValues: "k1"]), ["v1", "v2"])
        XCTAssertEqual(Array(restored[binaryValues: "k2-bin"]).first, [0xDE, 0xAD])
    }
}

@available(macOS 15.0, *)
extension XPCFrameTests {
    func testEveryFrameKindRoundTripsThroughXPC() throws {
        var md = Metadata(); md.addString("x", forKey: "k")
        let frames: [XPCFrame] = [
            .openStream(1, method: "pkg.S/M", deadlineNanos: 1_000),
            .metadata(2, WireMetadata(md)),
            .message(3, seq: 7, bytes: Data([1, 2, 3])),
            .halfClose(4),
            .status(5, code: 0, message: "ok", trailers: WireMetadata(md)),
            .cancel(6, reason: "test"),
            .credit(7, n: 4),
            .goAway,
        ]
        for f in frames {
            let obj = try f.encodeToXPC()
            let back = try XPCFrame.decode(from: obj)
            XCTAssertEqual(f, back)   // XPCFrame: Equatable — add the conformance
        }
    }
}

@available(macOS 15.0, *)
extension XPCFrameTests {

    /// gRPC's own discriminator is the key suffix, not a private tag: `-bin` means the value is
    /// raw binary, anything else is UTF-8 text.
    func testTheBinSuffixDiscriminatesBinaryFromString() throws {
        var md = Metadata()
        md.addString("plain", forKey: "a")
        md.addBinary([0x00, 0xFF], forKey: "b-bin")
        let restored = WireMetadata(md).asMetadata()
        XCTAssertEqual(Array(restored[stringValues: "a"]), ["plain"])
        XCTAssertEqual(Array(restored[binaryValues: "b-bin"]).first, [0x00, 0xFF])
    }

    /// gRPC requires lowercase keys; a mixed-case key must normalize, not round-trip verbatim.
    func testKeysAreNormalizedToLowercase() throws {
        var md = Metadata()
        md.addString("v", forKey: "Mixed-Case")
        let restored = WireMetadata(md).asMetadata()
        XCTAssertEqual(Array(restored[stringValues: "mixed-case"]), ["v"])
    }

    /// Order and repeats survive, through the real xpc encoder this time.
    func testRepeatedKeysAndOrderSurviveTheXPCRoundTrip() throws {
        var md = Metadata()
        md.addString("1", forKey: "k")
        md.addString("2", forKey: "k")
        md.addBinary([0x09], forKey: "raw-bin")
        let frame = XPCFrame.metadata(1, WireMetadata(md))
        let back = try XPCFrame.decode(from: try frame.encodeToXPC())
        guard case .metadata(_, let wire) = back else { return XCTFail("wrong case: \(back)") }
        let restored = wire.asMetadata()
        XCTAssertEqual(Array(restored[stringValues: "k"]), ["1", "2"])
        XCTAssertEqual(Array(restored[binaryValues: "raw-bin"]).first, [0x09])
    }
}
