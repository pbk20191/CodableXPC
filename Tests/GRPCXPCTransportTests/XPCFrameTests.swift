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
