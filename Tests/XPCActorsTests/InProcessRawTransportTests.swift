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

    func testDeliveryDoesNotRunInlineOnSend() throws {
        // The decisive check: a correct implementation returns from send() with the
        // packet merely enqueued, so the handler can observe that send() already
        // finished. An implementation that delivers inline runs this handler while
        // send() is still on the stack, so the signal never arrives and the wait
        // times out. Deliberately a timed wait rather than an unbounded one -- a
        // regression here should fail the suite, not hang it.
        let (a, b) = InProcessRawTransport.makePair(debugName: "test")
        let sendReturned = DispatchSemaphore(value: 0)
        let delivered = expectation(description: "handler ran")
        let outbound = try notification(1)

        b.setPacketHandler { _ in
            XCTAssertEqual(
                sendReturned.wait(timeout: .now() + 2), .success,
                "handler ran before send() returned -- delivery was inline"
            )
            delivered.fulfill()
        }
        try a.activate()
        try b.activate()

        try a.send(packet: outbound)
        sendReturned.signal()
        wait(for: [delivered], timeout: 5)
    }

    func testActivateAfterCancelThrows() throws {
        let (a, _) = InProcessRawTransport.makePair(debugName: "test")
        a.cancel(reason: "gone")
        XCTAssertThrowsError(try a.activate()) { error in
            XCTAssertEqual(error as? RawTransportError, .rawTransportCancelled(message: "gone"))
        }
    }

    func testSecondCancelKeepsTheFirstReason() throws {
        // The reason is the diagnostic a caller sees; a late second cancel must not
        // overwrite the one that actually explains why the pipe died.
        let (a, _) = InProcessRawTransport.makePair(debugName: "test")
        a.cancel(reason: "first")
        a.cancel(reason: "second")
        XCTAssertThrowsError(try a.send(packet: notification(1))) { error in
            XCTAssertEqual(error as? RawTransportError, .rawTransportCancelled(message: "first"))
        }
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
