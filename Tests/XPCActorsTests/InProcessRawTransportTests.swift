import XCTest
import XPC
@testable import XPCActors

/// The in-process raw pair, exercised through the ``Transport`` it now delivers into.
///
/// In Apple's back-reference model an `InProcessRawTransport` has no handler and no queue of
/// its own: it is handed its parent ``Transport`` via `activate(linking:)` and delivers onto
/// that transport's queue, routing into `Transport.handleReceivedPacket`. So the pair is only
/// meaningful wired to a pair of transports, and these tests drive it that way -- what they
/// assert (delivery crosses, both ways, off the sender's stack, and stops on cancel) is
/// unchanged; only the seam they poke has moved up one layer.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class InProcessRawTransportTests: XCTestCase {

    private func payload(_ marker: UInt64) throws -> Packet.Payload {
        try Packet.Payload(encoding: marker, userInfo: [:])
    }

    private func notification(_ marker: UInt64) throws -> Packet {
        Packet(header: .notification, payload: try payload(marker))
    }

    /// A live, linked pair: two transports over the two ends of one in-process pipe.
    private func linkedPair()
    -> (a: Transport, b: Transport,
        rawA: Transport.InProcessRawTransport, rawB: Transport.InProcessRawTransport) {
        let (rawA, rawB) = Transport.InProcessRawTransport.makePair("test")
        let a = Transport(debugName: "a", rawTransport: rawA)
        let b = Transport(debugName: "b", rawTransport: rawB)
        try! rawA.activate(linking: a)
        try! rawB.activate(linking: b)
        return (a, b, rawA, rawB)
    }

    func testPacketCrossesToTheOtherEnd() throws {
        let (a, b, _, _) = linkedPair()
        let received = expectation(description: "b receives")
        b.inboundNotificationHandler = { payload in
            XCTAssertEqual(try? payload.decode(as: UInt64.self), 99)
            received.fulfill()
        }
        try a.sendNotification(try payload(99))
        wait(for: [received], timeout: 2)
    }

    func testDeliveryIsBidirectional() throws {
        let (a, b, _, _) = linkedPair()
        let atA = expectation(description: "a receives")
        a.inboundNotificationHandler = { _ in atA.fulfill() }
        try b.sendNotification(try payload(1))
        wait(for: [atA], timeout: 2)
    }

    func testHandlerCanReplyWithoutRecursingIntoTheSender() throws {
        // Delivery must hop queues. If it did not, a handler that sends a reply would
        // recurse into the sender's stack and deadlock under the lock.
        let (a, b, _, _) = linkedPair()
        let done = expectation(description: "reply arrives")
        let reply = try payload(2)
        b.inboundNotificationHandler = { _ in try? b.sendNotification(reply) }
        a.inboundNotificationHandler = { payload in
            XCTAssertEqual(try? payload.decode(as: UInt64.self), 2)
            done.fulfill()
        }
        try a.sendNotification(try payload(1))
        wait(for: [done], timeout: 2)
    }

    func testDeliveryDoesNotRunInlineOnSend() throws {
        // A correct implementation returns from send() with the packet merely enqueued, so
        // the handler can observe that send() already finished. Inline delivery would run the
        // handler while send() is still on the stack, so the signal never arrives.
        let (a, b, _, _) = linkedPair()
        let sendReturned = DispatchSemaphore(value: 0)
        let delivered = expectation(description: "handler ran")
        b.inboundNotificationHandler = { _ in
            XCTAssertEqual(
                sendReturned.wait(timeout: .now() + 2), .success,
                "handler ran before send() returned -- delivery was inline")
            delivered.fulfill()
        }
        try a.sendNotification(try payload(1))
        sendReturned.signal()
        wait(for: [delivered], timeout: 5)
    }

    func testSendAfterRawCancelThrows() throws {
        // **Reinterpreted** from the old `testActivateAfterCancelThrows`: the raw transport no
        // longer has a throwing `activate()`. What survives is that a cancelled raw end has no
        // remote to deliver to, so `send` throws.
        let (_, _, rawA, _) = linkedPair()
        rawA.cancel()
        XCTAssertThrowsError(try rawA.send(packet: notification(1))) { error in
            XCTAssertEqual(error as? RawTransportError,
                           .rawTransportCancelled(message: "InProcessRawTransport is cancelled"))
        }
    }

    func testCancelIsIdempotent() throws {
        // **Reinterpreted** from the old `testSecondCancelKeepsTheFirstReason`: there is no
        // reason to keep now. What survives is that a second cancel is harmless.
        let (a, _, rawA, _) = linkedPair()
        rawA.cancel()
        rawA.cancel()
        _ = a
    }

    func testSendAfterTransportCancelThrows() throws {
        let (a, _, rawA, _) = linkedPair()
        a.cancel()
        XCTAssertThrowsError(try rawA.send(packet: notification(1)))
    }

    func testCancellingOneEndStopsDeliveryToTheOther() async throws {
        let (a, b, _, rawB) = linkedPair()
        b.inboundNotificationHandler = { _ in XCTFail("must not deliver after cancel") }
        rawB.cancel()
        // Let the cancellation reach `a`'s end.
        _ = await waitUntil { a.isCancelled }
        // Whether the send throws (remote already unlinked) or is silently dropped (unlink not
        // yet observed on this end), the far handler must never run.
        try? a.sendNotification(try payload(1))
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testSendBeforeLinkingDeliversNothing() throws {
        // **Reinterpreted** from the old `testSendBeforeActivateThrows`: `activate(linking:)`
        // never throws, and a send before the *receiving* end is linked is dropped (its parent
        // transport is nil) rather than throwing.
        let (rawA, rawB) = Transport.InProcessRawTransport.makePair("test")
        let a = Transport(debugName: "a", rawTransport: rawA)
        try rawA.activate(linking: a)   // link only the sender
        let b = Transport(debugName: "b", rawTransport: rawB)
        b.inboundNotificationHandler = { _ in XCTFail("nothing should be delivered") }
        XCTAssertNoThrow(try a.sendNotification(try payload(1)))
        withExtendedLifetime(b) {}
    }
}
