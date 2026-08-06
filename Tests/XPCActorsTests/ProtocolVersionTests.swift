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
        // A peer advertising the reserved sentinel as its floor still negotiates v1,
        // never 0. This pins the normative rule that 0 is never a negotiated result;
        // today it holds only because of the `Swift.max` against minimumSupported,
        // which a refactor could quietly drop.
        XCTAssertEqual(ProtocolVersion.negotiate(peerMin: 0, peerMax: 5), .v1)
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
