import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class TransportTests: XCTestCase {

    struct Ping: Codable, Equatable { let value: Int }

    /// Lets a `@Sendable` inbound handler hand something back out to the test body,
    /// which the handler cannot do by capturing the XCTestCase.
    final class SeqBox: @unchecked Sendable {
        var value: UInt64?
        var reply: (@Sendable (Packet.Payload) -> Void)?
    }

    /// A negotiated pair, ready for traffic.
    private func makePair() async throws -> (Transport, Transport) {
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "transport")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        let server = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        try await server.activate()
        try await client.activate()
        return (client, server)
    }

    func testNegotiationAgreesOnCurrentVersion() async throws {
        let (client, server) = try await makePair()
        XCTAssertEqual(client.negotiatedVersion, .current)
        XCTAssertEqual(server.negotiatedVersion, .current)
    }

    func testRequestGetsItsReply() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, payload, reply in
            let ping = try! payload.decode(as: Ping.self)
            reply(try! Packet.Payload(encoding: Ping(value: ping.value + 1)))
        }
        let outcome = await client.sendRequest(
            seq: client.allocateSeq(), try Packet.Payload(encoding: Ping(value: 1))
        )
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 2))
    }

    func testInboundRequestHandlerSeesTheRequestSeq() async throws {
        // Phase B's cancellation is a notification naming a requestSeq, so a receiver
        // has to be able to map an inbound cancellation onto the execution it started.
        // That is only possible if the handler is told which seq it is serving.
        let (client, server) = try await makePair()
        let seen = SeqBox()
        server.inboundRequestHandler = { seq, _, reply in
            seen.value = seq
            reply(try! Packet.Payload(encoding: Ping(value: 0)))
        }
        let seq = client.allocateSeq()
        _ = await client.sendRequest(seq: seq, try Packet.Payload(encoding: Ping(value: 1)))
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
            await client.sendRequest(seq: seq, try! Packet.Payload(encoding: Ping(value: 1)))
        }
        while await client.pendingRequestCount == 0 { await Task.yield() }

        // Watched for completion rather than awaited: a regression parks the duplicate,
        // and a direct await would hang the suite instead of reddening it.
        let box = RequestTableTests.OutcomeBox()
        let duplicateTask = Task {
            box.outcome = await client.sendRequest(
                seq: seq, try! Packet.Payload(encoding: Ping(value: 2))
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
        gate.reply?(try Packet.Payload(encoding: Ping(value: 7)))
        guard await waitUntil({ await client.pendingRequestCount == 0 }) else {
            return XCTFail("the original waiter was stranded -- nothing can resume it")
        }
        guard case .reply(let payload) = await first.value else {
            return XCTFail("the original waiter must still be resolvable")
        }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 7))
    }

    func testConcurrentActivateFailsTheSecondCallerRatherThanStrandingTheFirst() async throws {
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "double-activate")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        let server = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        // Deliberately never activated, so the responder cannot answer and the first
        // activate() stays parked on its helloWaiter.
        _ = server

        let first = Task { try await client.activate() }
        while !client.hasOutstandingHelloWaiter { await Task.yield() }
        do {
            try await client.activate()
            XCTFail("the second activate() must not succeed")
        } catch {
            XCTAssertTrue("\(error)".contains("already in progress"), "\(error)")
        }
        // The first caller was not displaced: it is still parked, and cancelling is
        // what resolves it.
        client.cancel(reason: "test over")
        do {
            try await first.value
            XCTFail("the first activate() should have failed on cancellation")
        } catch {
            // Expected: the parked waiter was resumed, not stranded.
        }
    }

    func testEitherSideCanOriginateARequest() async throws {
        // This is the whole reason the XPC reply channel is unused.
        let (client, server) = try await makePair()
        client.inboundRequestHandler = { _, payload, reply in
            reply(try! Packet.Payload(encoding: Ping(value: 99)))
        }
        let outcome = await server.sendRequest(
            seq: server.allocateSeq(), try Packet.Payload(encoding: Ping(value: 0))
        )
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 99))
    }

    func testConcurrentRequestsAreCorrelatedIndependently() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, payload, reply in
            let ping = try! payload.decode(as: Ping.self)
            reply(try! Packet.Payload(encoding: Ping(value: ping.value * 10)))
        }
        let results = await withTaskGroup(of: Int?.self) { group in
            for i in 1...20 {
                group.addTask {
                    let outcome = await client.sendRequest(
                        seq: client.allocateSeq(),
                        try! Packet.Payload(encoding: Ping(value: i))
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
        try client.sendNotification(try Packet.Payload(encoding: Ping(value: 5)))
        await fulfillment(of: [arrived], timeout: 2)
    }

    func testCancellingTheTransportFailsOutstandingRequests() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, _, _ in }   // never replies
        let task = Task {
            await client.sendRequest(
                seq: client.allocateSeq(), try! Packet.Payload(encoding: Ping(value: 1))
            )
        }
        while await client.pendingRequestCount == 0 { await Task.yield() }
        client.cancel(reason: "shutting down")
        guard case .failed(.transportCancelled) = await task.value else {
            return XCTFail("expected a transport failure")
        }
    }

    func testPeerDeathFailsOutstandingRequestsRatherThanHanging() async throws {
        // The death channel. Before it existed, failAll was only ever reached from our
        // *own* cancel -- i.e. only when we already knew. This protocol has no timeout,
        // so a request whose peer died would wait forever.
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, _, _ in }   // never replies
        let task = Task {
            await client.sendRequest(
                seq: client.allocateSeq(), try! Packet.Payload(encoding: Ping(value: 1))
            )
        }
        while await client.pendingRequestCount == 0 { await Task.yield() }

        // Kill only the far end. The client is never told directly.
        server.cancel(reason: "peer went away")

        // Wait on the observable, not on the request itself: without the death channel
        // `task.value` never returns, and awaiting it would hang the suite instead of
        // failing it.
        guard await waitUntil({ await client.pendingRequestCount == 0 }) else {
            return XCTFail("the request was never resolved -- the peer's death never arrived")
        }
        let outcome = await task.value
        guard case .failed(.transportCancelled(let message)) = outcome else {
            return XCTFail("expected .transportCancelled, got \(outcome)")
        }
        XCTAssertTrue(message.contains("peer went away"), message)
    }

    func testPeerDeathUnblocksAnActivateAwaitingHelloAck() async throws {
        // Same hazard on the setup path: activate() parks on helloWaiter with no
        // timeout behind it.
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "death-during-hello")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        let server = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        // A responder that never activates never answers hello.
        let task = Task { try await client.activate() }
        while !client.hasOutstandingHelloWaiter { await Task.yield() }

        server.cancel(reason: "peer went away")

        // `helloWaiter` is a plain CheckedContinuation with no cancellation handler, so
        // if it is never resumed nothing can break the wait. Confirm it was resumed
        // before awaiting the task, or the failure mode is a hung suite.
        guard await waitUntil({ !client.hasOutstandingHelloWaiter }) else {
            return XCTFail("activate() is still parked -- the peer's death never arrived")
        }
        do {
            try await task.value
            XCTFail("activate() should have failed once the peer died")
        } catch let error as SetupError {
            XCTAssertTrue(error.message.contains("peer went away"), error.message)
        }
    }

    func testRemoteDeathAndLocalCancelCannotDoubleFire() async throws {
        // Both paths run the same teardown; the `cancelled` flag is what stops the
        // second one. Resuming helloWaiter twice would trap outright.
        let (client, server) = try await makePair()
        server.cancel(reason: "peer went away")
        let noticed = await waitUntil({ client.isCancelled })
        XCTAssertTrue(noticed, "the client should have learned of the peer's death")
        client.cancel(reason: "and now us too")
        client.cancel(reason: "again")
        // Reaching here without a crash is the assertion; confirm state is coherent.
        XCTAssertTrue(client.isCancelled)
        let pending = await client.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    func testTrafficBeforeNegotiationIsRejected() async throws {
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "unnegotiated")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        _ = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        // No activate() -- no version has been agreed.
        XCTAssertThrowsError(try client.sendNotification(try Packet.Payload(encoding: Ping(value: 1))))
    }

    func testPacketWithWrongVersionCancelsTheSession() async throws {
        // Spec: a receiver that sees a version mismatch cancels rather than trying to
        // interpret the body. Dropping is strictly worse -- with no timeout it hangs
        // the sender.
        let (client, server) = try await makePair()
        server.inboundNotificationHandler = { _ in XCTFail("must not deliver") }
        // Forge a packet claiming a version nobody negotiated.
        let header = try XCTUnwrap(
            PacketHeader(version: ProtocolVersion(rawValue: 77), kind: .notification, seq: nil)
        )
        let forged = Packet(header: header, payload: try Packet.Payload(encoding: Ping(value: 1)))
        // handleReceived is synchronous on this white-box path, so there is nothing to
        // wait for; a sleep here would only pretend there were.
        server.handleReceived(packet: forged)
        XCTAssertTrue(server.isCancelled, "a version mismatch must cancel, not drop")
        // The far end learns too: the raw pipe is unlinked synchronously by the
        // responder's cancel, so the client's next send fails rather than hanging.
        let outcome = await client.sendRequest(
            seq: client.allocateSeq(), try Packet.Payload(encoding: Ping(value: 1))
        )
        guard case .failed = outcome else {
            return XCTFail("the cancelled session must not still serve requests")
        }
    }

    func testNegotiationFailureSurfacesAsAnErrorRatherThanHanging() async throws {
        // A responder with nothing in common must say so. If it only cancels itself,
        // activate() has no timeout to fall back on and suspends forever.
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "mismatch")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        let server = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        try await server.activate()

        // Drive the responder with a hello it cannot satisfy, bypassing the client's
        // own well-formed hello.
        let header = try XCTUnwrap(PacketHeader(version: .unnegotiated, kind: .hello, seq: nil))
        let impossible = Packet(
            header: header,
            payload: try Packet.Payload(encoding: HelloBody(min: 5, max: 2))
        )
        server.handleReceived(packet: impossible)

        do {
            try await client.activate()
            XCTFail("activate() should have thrown, not agreed a version")
        } catch {
            XCTAssertNil(client.negotiatedVersion)
        }
    }

    func testSecondHelloOnALiveSessionIsIgnored() async throws {
        // A buggy or hostile peer must not be able to kill an established session
        // mid-flight by sending an unsatisfiable hello: the no-overlap path cancels.
        let (client, server) = try await makePair()
        let header = try XCTUnwrap(PacketHeader(version: .unnegotiated, kind: .hello, seq: nil))
        let impossible = Packet(
            header: header,
            payload: try Packet.Payload(encoding: HelloBody(min: 500, max: 900))
        )
        server.handleReceived(packet: impossible)

        XCTAssertFalse(server.isCancelled, "an established session must survive a late hello")
        XCTAssertEqual(server.negotiatedVersion, .current)

        // And it still works.
        server.inboundRequestHandler = { _, _, reply in
            reply(try! Packet.Payload(encoding: Ping(value: 3)))
        }
        let outcome = await client.sendRequest(
            seq: client.allocateSeq(), try Packet.Payload(encoding: Ping(value: 1))
        )
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 3))
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
