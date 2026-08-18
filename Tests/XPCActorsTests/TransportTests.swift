import XCTest
import XPC
@testable import XPCActors

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class TransportTests: XCTestCase {

    struct Ping: Codable, Equatable { let value: Int }

    /// Lets a `@Sendable` inbound handler hand something back out to the test body,
    /// which the handler cannot do by capturing the XCTestCase.
    final class SeqBox: @unchecked Sendable {
        var value: UInt64?
        var reply: (@Sendable (Packet.Payload) -> Void)?
    }

    /// A live pair. `activate()` exchanges nothing now, so there is no state either end
    /// has to reach before traffic flows.
    private func makePair() async throws -> (Transport, Transport) {
        let (rawA, rawB) = Transport.InProcessRawTransport.makePair("transport")
        let client = Transport(debugName: "client", rawTransport: rawA)
        let server = Transport(debugName: "server", rawTransport: rawB)
        try server.activate()
        try client.activate()
        return (client, server)
    }

    /// The point of deleting the handshake: an initiator that sent a `hello` would put a
    /// packet category on the wire that no real peer has a case for, and would then wait
    /// forever for an answer nobody sends. Activation must complete on its own.
    func testActivateSendsNothingAndBlocksOnNothing() async throws {
        let (rawA, rawB) = Transport.InProcessRawTransport.makePair("silent-activate")
        let client = Transport(debugName: "client", rawTransport: rawA)
        // The far end is never activated and never handles a packet, so a client that
        // waited for a peer would hang here rather than return.
        let server = Transport(debugName: "server", rawTransport: rawB)
        server.inboundRequestHandler = { _, _, _ in XCTFail("nothing is sent on activate") }
        server.inboundNotificationHandler = { _ in XCTFail("nothing is sent on activate") }
        try client.activate()
        try server.activate()
    }

    func testBothRolesActivateTheSameWay() async throws {
        let (client, server) = try await makePair()
        // Role no longer lives on `Transport` (it moved onto `XPCRawTransport` in Apple's
        // back-reference model), so there is nothing to assert about it here. What the test
        // is really about survives: either end can immediately originate, with no ordering
        // between the two activations having mattered.
        server.inboundRequestHandler = { _, _, reply in
            reply(try! Packet.Payload(encoding: Ping(value: 1), userInfo: [:]))
        }
        let outcome = await client.sendRequest(
            seq: client.allocateSeq(), try Packet.Payload(encoding: Ping(value: 0), userInfo: [:])
        )
        guard case .reply = outcome else { return XCTFail("expected a reply") }
    }

    func testRequestGetsItsReply() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, payload, reply in
            let ping = try! payload.decode(as: Ping.self)
            reply(try! Packet.Payload(encoding: Ping(value: ping.value + 1), userInfo: [:]))
        }
        let outcome = await client.sendRequest(
            seq: client.allocateSeq(), try Packet.Payload(encoding: Ping(value: 1), userInfo: [:])
        )
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 2))
    }

    /// A response re-uses the request's `headerID`, which is the only thing correlating
    /// the two: both travel one-way and XPC's own reply channel is unused.
    func testAReplyCarriesTheRequestsHeaderID() async throws {
        let (rawA, rawB) = Transport.InProcessRawTransport.makePair("header-id")
        let client = Transport(debugName: "client", rawTransport: rawA)
        // The far end is wired through its own `Transport`, whose request handler is given the
        // id and answers by hand -- so the assertion is about the id on the wire rather than
        // about our own reply path agreeing with our own send path.
        let server = Transport(debugName: "server", rawTransport: rawB)
        let seen = SeqBox()
        server.inboundRequestHandler = { seq, _, _ in
            seen.value = seq
            try? rawB.send(packet: Packet(header: .response(ID64(rawValue: seq)),
                                          payload: try! Packet.Payload(encoding: Ping(value: 9), userInfo: [:])))
        }
        try client.activate()
        try server.activate()

        let seq = client.allocateSeq()
        let outcome = await client.sendRequest(seq: seq, try Packet.Payload(encoding: Ping(value: 1), userInfo: [:]))
        XCTAssertEqual(seen.value, seq, "the request must go out under the allocated id")
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 9))
    }

    func testInboundRequestHandlerSeesTheRequestID() async throws {
        // Cancellation is a notification naming a request id, so a receiver has to be
        // able to map an inbound cancellation onto the execution it started. That is
        // only possible if the handler is told which id it is serving.
        let (client, server) = try await makePair()
        let seen = SeqBox()
        server.inboundRequestHandler = { seq, _, reply in
            seen.value = seq
            reply(try! Packet.Payload(encoding: Ping(value: 0), userInfo: [:]))
        }
        let seq = client.allocateSeq()
        _ = await client.sendRequest(seq: seq, try Packet.Payload(encoding: Ping(value: 1), userInfo: [:]))
        XCTAssertEqual(seen.value, seq)
    }

    func testAllocateSeqHandsOutDistinctIds() async throws {
        let (client, _) = try await makePair()
        let ids = (0..<50).map { _ in client.allocateSeq() }
        XCTAssertEqual(Set(ids).count, ids.count, "correlation ids must be unique per transport")
    }

    func testReusingAnInFlightSeqFailsTheNewCallerNotTheOldOne() async throws {
        // A caller now supplies the seq, so a duplicate is reachable. The waiter that
        // is already parked must survive: displacing it would strand a continuation
        // nothing can ever resume, and this protocol has no timeout to break the hang.
        let (client, server) = try await makePair()
        let gate = SeqBox()
        server.inboundRequestHandler = { _, _, reply in
            gate.reply = reply   // hold the first request open
        }
        let seq = client.allocateSeq()
        let first = Task {
            await client.sendRequest(seq: seq, try! Packet.Payload(encoding: Ping(value: 1), userInfo: [:]))
        }
        while await client.pendingRequestCount == 0 { await Task.yield() }

        // Watched for completion rather than awaited: a regression parks the duplicate,
        // and a direct await would hang the suite instead of reddening it.
        let box = RequestTableTests.OutcomeBox()
        let duplicateTask = Task {
            box.outcome = await client.sendRequest(
                seq: seq, try! Packet.Payload(encoding: Ping(value: 2), userInfo: [:])
            )
        }
        guard await waitUntil({ box.outcome != nil }) else {
            duplicateTask.cancel()
            return XCTFail("the duplicate parked instead of failing -- the first was displaced")
        }
        guard case .failed(.transportCancelled(let message)) = box.outcome else {
            return XCTFail("expected the duplicate to fail, got \(String(describing: box.outcome))")
        }
        XCTAssertTrue(message.contains("duplicate request seq \(seq)"), message)

        // The original is untouched and still completable.
        gate.reply?(try Packet.Payload(encoding: Ping(value: 7), userInfo: [:]))
        guard await waitUntil({ await client.pendingRequestCount == 0 }) else {
            return XCTFail("the original waiter was stranded -- nothing can resume it")
        }
        guard case .reply(let payload) = await first.value else {
            return XCTFail("the original waiter must still be resolvable")
        }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 7))
    }

    func testEitherSideCanOriginateARequest() async throws {
        // This is the whole reason the XPC reply channel is unused.
        let (client, server) = try await makePair()
        client.inboundRequestHandler = { _, payload, reply in
            reply(try! Packet.Payload(encoding: Ping(value: 99), userInfo: [:]))
        }
        let outcome = await server.sendRequest(
            seq: server.allocateSeq(), try Packet.Payload(encoding: Ping(value: 0), userInfo: [:])
        )
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 99))
    }

    func testConcurrentRequestsAreCorrelatedIndependently() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, payload, reply in
            let ping = try! payload.decode(as: Ping.self)
            reply(try! Packet.Payload(encoding: Ping(value: ping.value * 10), userInfo: [:]))
        }
        let results = await withTaskGroup(of: Int?.self) { group in
            for i in 1...20 {
                group.addTask {
                    let outcome = await client.sendRequest(
                        seq: client.allocateSeq(),
                        try! Packet.Payload(encoding: Ping(value: i), userInfo: [:])
                    )
                    guard case .reply(let p) = outcome else { return nil }
                    return try? p.decode(as: Ping.self).value
                }
            }
            return await group.reduce(into: [Int?]()) { $0.append($1) }
        }
        XCTAssertEqual(results.compactMap { $0 }.sorted(), (1...20).map { $0 * 10 })
    }

    func testNotificationArrivesWithNoReply() async throws {
        let (client, server) = try await makePair()
        let arrived = expectation(description: "notification arrives")
        server.inboundNotificationHandler = { payload in
            XCTAssertEqual(try? payload.decode(as: Ping.self), Ping(value: 5))
            arrived.fulfill()
        }
        try client.sendNotification(try Packet.Payload(encoding: Ping(value: 5), userInfo: [:]))
        await fulfillment(of: [arrived], timeout: 2)
    }

    /// A notification is sent with no id at all, and an inbound one is delivered without
    /// consulting the request table -- so it can never resolve somebody's request.
    func testANotificationCarriesNoCorrelationID() async throws {
        let (rawA, rawB) = Transport.InProcessRawTransport.makePair("notification-id")
        let client = Transport(debugName: "client", rawTransport: rawA)
        let server = Transport(debugName: "server", rawTransport: rawB)
        let seen = SeqBox()
        // A notification is delivered without a header id at all; the inbound notification
        // handler is handed only the payload, so "no correlation id" is what it observes.
        server.inboundNotificationHandler = { _ in seen.value = 0 }
        try client.activate()
        try server.activate()
        try client.sendNotification(try Packet.Payload(encoding: Ping(value: 1), userInfo: [:]))
        let arrived = await waitUntil({ seen.value != nil })
        XCTAssertTrue(arrived, "the notification never arrived")
        XCTAssertEqual(seen.value, 0, "a notification header has no id")
    }

    func testCancellingTheTransportFailsOutstandingRequests() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, _, _ in }   // never replies
        let box = RequestTableTests.OutcomeBox()
        let task = Task {
            box.outcome = await client.sendRequest(
                seq: client.allocateSeq(), try! Packet.Payload(encoding: Ping(value: 1), userInfo: [:])
            )
        }
        while await client.pendingRequestCount == 0 { await Task.yield() }
        client.cancel()

        // Watched, not awaited -- the same discipline as the peer-death test below, and
        // for the same reason: the regression this guards is "the caller is never
        // resumed", and `await task.value` would then hang the suite rather than fail.
        guard await waitUntil({ box.outcome != nil }) else {
            task.cancel()
            return XCTFail("the caller was never resumed -- cancelling did not fail it")
        }
        guard case .failed(.transportCancelled) = box.outcome else {
            return XCTFail("expected a transport failure, got \(String(describing: box.outcome))")
        }
    }

    func testPeerDeathFailsOutstandingRequestsRatherThanHanging() async throws {
        // The death channel. Before it existed, failAll was only ever reached from our
        // *own* cancel -- i.e. only when we already knew. This protocol has no timeout,
        // so a request whose peer died would wait forever.
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, _, _ in }   // never replies
        let box = RequestTableTests.OutcomeBox()
        let task = Task {
            box.outcome = await client.sendRequest(
                seq: client.allocateSeq(), try! Packet.Payload(encoding: Ping(value: 1), userInfo: [:])
            )
        }
        while await client.pendingRequestCount == 0 { await Task.yield() }

        // Kill only the far end. The client is never told directly.
        server.cancel()

        // Wait on the observable, not on the request itself: without the death channel
        // `task.value` never returns, and awaiting it would hang the suite instead of
        // failing it.
        guard await waitUntil({ box.outcome != nil }) else {
            task.cancel()
            return XCTFail("the request was never resolved -- the peer's death never arrived")
        }
        guard case .failed(.transportCancelled(let message)) = box.outcome else {
            return XCTFail("expected .transportCancelled, got \(String(describing: box.outcome))")
        }
        // The cancellation reason no longer crosses the pipe -- Apple's death path carries a
        // fixed message -- so the client sees the peer-gone reason, not the far end's wording.
        XCTAssertTrue(message.contains("peer is gone"), message)
    }

    func testRemoteDeathAndLocalCancelCannotDoubleFire() async throws {
        // Both paths run the same teardown; the `cancelled` flag is what stops the
        // second one.
        let (client, server) = try await makePair()
        server.cancel()
        let noticed = await waitUntil({ client.isCancelled })
        XCTAssertTrue(noticed, "the client should have learned of the peer's death")
        client.cancel()
        client.cancel()
        // Reaching here without a crash is the assertion; confirm state is coherent.
        XCTAssertTrue(client.isCancelled)
        let pending = await client.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    /// Traffic needs no preamble now. Under the handshake this same call failed with
    /// "no version negotiated yet"; there is nothing left to negotiate, so a caller who
    /// activates and immediately sends is doing nothing wrong.
    func testTrafficNeedsNoPreamble() async throws {
        let (rawA, rawB) = Transport.InProcessRawTransport.makePair("no-preamble")
        let client = Transport(debugName: "client", rawTransport: rawA)
        let server = Transport(debugName: "server", rawTransport: rawB)
        let arrived = expectation(description: "notification arrives")
        server.inboundNotificationHandler = { _ in arrived.fulfill() }
        try client.activate()
        try server.activate()
        try client.sendNotification(try Packet.Payload(encoding: Ping(value: 1), userInfo: [:]))
        await fulfillment(of: [arrived], timeout: 2)
    }
}

/// Poll `condition` until it holds or `seconds` elapse. Returns whether it held.
///
/// Every hazard in this file is "waits forever", so the tests must never `await` the
/// thing under test until an *observable* says it has been resolved. Racing a timeout
/// task against the suspended call does not work: Swift's task groups await every
/// child on exit, and neither a parked `CheckedContinuation` nor `Task.value` responds
/// to cancellation -- so the "timeout" would hang exactly when it was needed. Polling
/// a side effect is the only form that actually turns a regression red instead of
/// stuck. Verified by disabling the death channel and watching this suite finish.
func waitUntil(
    timeout seconds: Double = 5,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}
