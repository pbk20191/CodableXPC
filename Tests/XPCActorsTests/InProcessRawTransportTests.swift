import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class InProcessRawTransportTests: XCTestCase {

    private func notification(_ marker: UInt64) throws -> Packet {
        let header = try XCTUnwrap(PacketHeader(version: .v1, kind: .notification, seq: nil))
        let body = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(body, "marker", marker)
        return Packet(header: header, payload: Packet.Payload(unchecked: body))
    }

    func testPacketCrossesToTheOtherEnd() throws {
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        let received = expectation(description: "b receives")
        b.setPacketHandler { packet in
            XCTAssertEqual(Packet.uint64(packet.payload.object, "marker"), 99)
            received.fulfill()
        }
        try a.activate()
        try b.activate()
        try a.send(packet: notification(99))
        wait(for: [received], timeout: 2)
    }

    func testDeliveryIsBidirectional() throws {
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        let atA = expectation(description: "a receives")
        a.setPacketHandler { _ in atA.fulfill() }
        try a.activate()
        try b.activate()
        try b.send(packet: notification(1))
        wait(for: [atA], timeout: 2)
    }

    func testHandlerCanReplyWithoutRecursingIntoTheSender() throws {
        // Delivery must hop queues. If it did not, a handler that sends a reply
        // would recurse into the sender's stack and deadlock under the lock.
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        let done = expectation(description: "reply arrives")
        // Build both packets up front: the handler closure is @Sendable and must
        // not capture the XCTestCase.
        let outbound = try notification(1)
        let replyPacket = try notification(2)
        b.setPacketHandler { [weak b] _ in
            try? b?.send(packet: replyPacket)
        }
        a.setPacketHandler { packet in
            XCTAssertEqual(Packet.uint64(packet.payload.object, "marker"), 2)
            done.fulfill()
        }
        try a.activate()
        try b.activate()
        try a.send(packet: outbound)
        wait(for: [done], timeout: 2)
    }

    func testSendAfterCancelThrows() throws {
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        try a.activate()
        try b.activate()
        a.cancel(reason: "test over")
        XCTAssertThrowsError(try a.send(packet: notification(1))) { error in
            XCTAssertEqual(
                error as? RawTransportError,
                .rawTransportCancelled(message: "test over")
            )
        }
    }

    func testCancellingOneEndStopsDeliveryToTheOther() throws {
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        b.setPacketHandler { _ in XCTFail("must not deliver after cancel") }
        try a.activate()
        try b.activate()
        b.cancel(reason: "gone")
        XCTAssertThrowsError(try a.send(packet: notification(1)))
    }

    func testSendBeforeActivateThrows() throws {
        let (a, _) = InProcessRawTransport.makePair(debugName: "test")
        XCTAssertThrowsError(try a.send(packet: notification(1)))
    }
}
