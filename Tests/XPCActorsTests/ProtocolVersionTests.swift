import XCTest
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class ProtocolVersionTests: XCTestCase {

    func testUnnegotiatedIsZeroAndIsNotSupported() {
        XCTAssertEqual(ProtocolVersion.unnegotiated.rawValue, 0)
        // Zero is reserved to mean "no version agreed yet" on hello/helloAck.
        // If it ever became negotiable, a malformed packet would be indistinguishable
        // from a handshake packet.
        XCTAssertLessThan(ProtocolVersion.unnegotiated, ProtocolVersion.minimumSupported)
    }

    func testCurrentIsV1() {
        XCTAssertEqual(ProtocolVersion.current, .v1)
        XCTAssertEqual(ProtocolVersion.v1.rawValue, 1)
    }

    func testNegotiatePicksHighestCommonVersion() {
        XCTAssertEqual(ProtocolVersion.negotiate(peerMin: 1, peerMax: 1), .v1)
        XCTAssertEqual(ProtocolVersion.negotiate(peerMin: 1, peerMax: 99), .current)
    }

    func testNegotiateFailsWhenRangesDoNotOverlap() {
        // Peer is from the future and dropped support for everything we speak.
        XCTAssertNil(ProtocolVersion.negotiate(peerMin: 50, peerMax: 99))
        // Peer only speaks the reserved sentinel.
        XCTAssertNil(ProtocolVersion.negotiate(peerMin: 0, peerMax: 0))
    }

    func testNegotiateRejectsInvertedRange() {
        XCTAssertNil(ProtocolVersion.negotiate(peerMin: 9, peerMax: 1))
    }
}
