import XCTest
import GRPCCore
import Synchronization
@testable import GRPCXPCTransport

/// Task 9: cancellation, deadlines, graceful shutdown, peer death -- plus the handler-completion
/// termination path (Task 8's A3 finding), which is a lifecycle path and so lives here.
///
/// Every test is bounded per Task 6's reviewed pattern (see `XPCServerTransportTests`'s doc
/// comment): the work runs on its own `Task`, accumulates into that task's own locals, publishes
/// through a single `Mutex` write, and fulfils an `XCTestExpectation` the body then
/// `await fulfillment(of:timeout:)`s. That is not stylistic in *this* file above all others: every
/// failure mode here is "something never happens", and an unbounded lifecycle test hangs the whole
/// suite with no diagnosis.
/// Free functions rather than methods on the test case: they are called from inside `Task { }`
/// bodies, and a method would capture the (non-`Sendable`) `XCTestCase` along with it.
@available(macOS 15.0, *)
private func descriptor(_ method: String = "M") -> MethodDescriptor {
    MethodDescriptor(fullyQualifiedService: "pkg.S", method: method)
}

@available(macOS 15.0, *)
private func timeout(_ duration: Duration) -> CallOptions {
    var options = CallOptions.defaults
    options.timeout = duration
    return options
}

@available(macOS 15.0, *)
final class LifecycleTests: XCTestCase {

    /// What a server handler observed about how its RPC ended. Filled in entirely inside the
    /// handler's own task and published with one `Mutex` write.
    private struct ServerOutcome: Sendable {
        var inboundError: RPCError.Code?
        var inboundEndedCleanly = false
        var messagesRead = 0
    }


    // MARK: - A3: a handler that returns early must not strand the peer's writer

    /// A handler that reads one message and returns leaves the rest of the RPC's request half with
    /// nobody to pull it. Before `XPCConnection.streamHandlerFinished(_:)` existed, nothing on that
    /// path retired the stream: its registry entry stayed, its `CreditLedger` kept withholding up to
    /// a full window of credit replies, and the peer -- still writing -- parked in `write` forever
    /// (measured: 33 of 200 messages through, then a hang). Handler completion is a termination
    /// path, so it has to release credit exactly as `halfClose`, `cancel` and connection death do.
    func testAnEarlyReturningHandlerDoesNotStrandThePeersWriter() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let listenTask = Task {
            try await server.listen { stream, _ in
                // One message, then return -- no drain, no status, no half-close.
                do { for try await _ in stream.inbound { break } } catch { return }
            }
        }
        defer { listenTask.cancel() }

        let total = 200
        let sent = Mutex(0)
        let writerReturned = expectation(description: "every write returned")
        let writer = Task {
            try? await client.withStream(descriptor: descriptor(), options: .defaults) { stream, _ in
                for i in 0..<total {
                    try await stream.outbound.write(.message([UInt8(i & 0xFF)]))
                    sent.withLock { $0 += 1 }
                }
            }
            writerReturned.fulfill()
        }
        defer { writer.cancel() }

        await fulfillment(of: [writerReturned], timeout: 10)
        XCTAssertEqual(sent.withLock { $0 }, total,
                       "a peer writing to a stream whose handler has returned must keep making "
                       + "progress -- \(sent.withLock { $0 }) of \(total) writes completed, so the "
                       + "finished handler is still pinning that stream's withheld credit")
    }

    // MARK: - Peer cancel

    /// A `.cancel` frame from the peer must fail that stream locally with `RPCError(.cancelled)`
    /// *and* fire the RPC's own cancellation handle. The handle matters independently of the inbound
    /// failure: a handler that is writing, or awaiting something else entirely, is not sitting in
    /// `for try await ... in stream.inbound` and would otherwise never learn the RPC is over.
    func testAPeerCancelFailsTheServersInboundAndFiresItsCancellationHandle() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let outcomeBox = Mutex<ServerOutcome?>(nil)
        let handlerReturned = expectation(description: "the server handler returned")
        let handleFired = expectation(description: "the RPC's cancellation handle fired")
        let listenTask = Task {
            try await server.listen { stream, context in
                var outcome = ServerOutcome()
                await withRPCCancellationHandler {
                    do {
                        for try await part in stream.inbound {
                            if case .message = part { outcome.messagesRead += 1 }
                        }
                        outcome.inboundEndedCleanly = true
                    } catch let error as RPCError {
                        outcome.inboundError = error.code
                    } catch {
                        outcome.inboundError = nil
                    }
                } onCancelRPC: {
                    handleFired.fulfill()
                }
                XCTAssertTrue(context.cancellation.isCancelled,
                              "the context's cancellation handle must report the peer's cancel")
                outcomeBox.withLock { $0 = outcome }
                handlerReturned.fulfill()
            }
        }
        defer { listenTask.cancel() }

        let clientDone = expectation(description: "the client's call returned")
        let clientTask = Task {
            try? await client.withStream(descriptor: descriptor(), options: .defaults) { stream, _ in
                try await stream.outbound.write(.message([1]))
                // `finish(throwing:)` is the writer's cancel path: it sends `.cancel` to the peer.
                await stream.outbound.finish(throwing: RPCError(code: .cancelled, message: "by hand"))
            }
            clientDone.fulfill()
        }
        defer { clientTask.cancel() }

        await fulfillment(of: [clientDone, handleFired, handlerReturned], timeout: 5)
        let outcome = outcomeBox.withLock { $0 }
        XCTAssertEqual(outcome?.inboundError, .cancelled,
                       "a peer `.cancel` must fail the server's inbound with .cancelled, not end it "
                       + "cleanly (ended cleanly: \(outcome?.inboundEndedCleanly ?? false))")
    }

    // MARK: - Peer death

    /// The peer process going away (here: its `XPCSession` being cancelled, which is what
    /// `XPCConnection.deinit` does) must fail every stream on the connection with
    /// `RPCError(.unavailable)` rather than leave them awaiting frames that can no longer arrive.
    func testPeerDeathFailsEveryStreamWithUnavailable() async throws {
        let harness = XPCPairHarness()
        var pair: (XPCConnection, XPCConnection)? = try await harness.connectPair()
        let serverConn = pair!.1                     // kept alive; only the *client* dies below
        let server = XPCServerTransport(connection: serverConn)

        let outcomeBox = Mutex<ServerOutcome?>(nil)
        let handlerReturned = expectation(description: "the server handler returned")
        let handleFired = expectation(description: "the RPC's cancellation handle fired")
        let messageArrived = expectation(description: "the server read the first request message")
        let listenTask = Task {
            try await server.listen { stream, _ in
                var outcome = ServerOutcome()
                await withRPCCancellationHandler {
                    do {
                        for try await part in stream.inbound {
                            if case .message = part {
                                outcome.messagesRead += 1
                                messageArrived.fulfill()
                            }
                        }
                        outcome.inboundEndedCleanly = true
                    } catch let error as RPCError {
                        outcome.inboundError = error.code
                    } catch { }
                } onCancelRPC: {
                    handleFired.fulfill()
                }
                outcomeBox.withLock { $0 = outcome }
                handlerReturned.fulfill()
            }
        }
        defer { listenTask.cancel() }

        // A raw client stream, deliberately *not* wrapped in an `XPCClientTransport`: the transport
        // would hold the connection and this test needs the connection to be the only strong
        // reference, so that dropping it really does cancel the session.
        let (sid, clientStream) = pair!.0.openClientStream(descriptor: descriptor())
        try pair!.0.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))
        try await clientStream.outbound.write(.message([9]))
        await fulfillment(of: [messageArrived], timeout: 5)

        pair = nil                                    // the client session is cancelled: peer death

        await fulfillment(of: [handleFired, handlerReturned], timeout: 5)
        XCTAssertEqual(outcomeBox.withLock { $0 }?.inboundError, .unavailable,
                       "peer death must fail the stream with .unavailable")
    }

    /// The peer-death case Task 8's probe C makes non-obvious: libxpc silently drops the reply
    /// handlers of a cancelled session, so a writer parked for credit when the peer dies gets no
    /// reply, no error and no callback -- the connection has to fail its own outstanding credits or
    /// that writer hangs forever. This is the *peer's* death (the session cancellation handler),
    /// which `BackpressureTests`' analogue -- where the local connection is deinitialized -- does
    /// not cover.
    func testPeerDeathFailsAWriterParkedOnCredit() async throws {
        let window = 3
        var pair: (XPCConnection, XPCConnection)? =
            try await XPCPairHarness().connectPair(creditWindow: window)
        let serverConn = pair!.1

        var iterator = serverConn.acceptedStreams.makeAsyncIterator()
        let (sid, clientStream) = pair!.0.openClientStream(descriptor: descriptor())
        try pair!.0.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))
        let next = await iterator.next()
        let accepted = try XCTUnwrap(next)

        // Nobody pulls the client's inbound sequence, so the server's writer gets no credit back:
        // fill the window, then park.
        for _ in 0..<window {
            try await accepted.stream.outbound.write(.message([1]))
        }
        let outcome = Mutex<String?>(nil)
        let settled = expectation(description: "the parked server write settled")
        Task {
            do {
                try await accepted.stream.outbound.write(.message([2]))
                outcome.withLock { $0 = "returned successfully" }
            } catch let error as RPCError {
                outcome.withLock { $0 = "RPCError(\(error.code))" }
            } catch {
                outcome.withLock { $0 = "\(error)" }
            }
            settled.fulfill()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(outcome.withLock { $0 }, "the write should still be parked on credit here")

        pair = nil                                    // peer death, with a reply outstanding
        _ = clientStream

        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(outcome.withLock { $0 }, "RPCError(unavailable)",
                       "a writer parked on credit must fail when the peer dies -- libxpc will "
                       + "never resolve its reply handler, so nothing else can wake it")
    }

    /// Error shaping: after the peer is gone, a send fails with libxpc's own error (an
    /// `XPCRichError` about an invalid connection). Everything above this layer -- gRPC's client and
    /// server machinery, and every caller in this transport -- speaks `RPCError`, so the transport
    /// has to shape it rather than leak it.
    func testASendAfterPeerDeathFailsWithAnRPCErrorNotALibxpcError() async throws {
        var pair: (XPCConnection, XPCConnection)? = try await XPCPairHarness().connectPair()
        let serverConn = pair!.1
        pair = nil                                    // the client session is cancelled

        // The send may succeed until libxpc notices the peer is gone, so poll -- bounded -- for the
        // first failure and assert on its *shape*.
        var thrown: (any Error)?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, thrown == nil {
            do {
                try serverConn.send(.cancel(1, reason: "probe"))
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                thrown = error
            }
        }

        let error = try XCTUnwrap(thrown as? RPCError,
                                 "a send to a dead peer must fail as an RPCError; got "
                                 + "\(String(describing: thrown))")
        XCTAssertEqual(error.code, .unavailable)
    }

    // MARK: - Deadlines

    /// `CallOptions.timeout` must expire the call on both sides: the local half fails with
    /// `.deadlineExceeded` (which is what unblocks a client parked on an inbound sequence the peer
    /// never terminates), and a `.cancel` frame tells the peer to stop, which fails the server's
    /// inbound with `.cancelled`.
    func testADeadlineExpiresTheCallOnBothSides() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let outcomeBox = Mutex<ServerOutcome?>(nil)
        let handlerReturned = expectation(description: "the server handler returned")
        let listenTask = Task {
            try await server.listen { stream, _ in
                var outcome = ServerOutcome()
                do {
                    // Never writes a status: the client can only be released by its deadline.
                    for try await part in stream.inbound {
                        if case .message = part { outcome.messagesRead += 1 }
                    }
                    outcome.inboundEndedCleanly = true
                } catch let error as RPCError {
                    outcome.inboundError = error.code
                } catch { }
                outcomeBox.withLock { $0 = outcome }
                handlerReturned.fulfill()
            }
        }
        defer { listenTask.cancel() }

        let clientError = Mutex<String?>(nil)
        let clientReturned = expectation(description: "the client's call returned")
        let clientTask = Task {
            do {
                try await client.withStream(descriptor: descriptor(),
                                            options: timeout(.milliseconds(250))) { stream, _ in
                    try await stream.outbound.write(.message([1]))
                    // Waits for a response the server never sends.
                    for try await _ in stream.inbound { }
                }
                clientError.withLock { $0 = "returned successfully" }
            } catch let error as RPCError {
                clientError.withLock { $0 = "RPCError(\(error.code))" }
            } catch {
                clientError.withLock { $0 = "\(error)" }
            }
            clientReturned.fulfill()
        }
        defer { clientTask.cancel() }

        await fulfillment(of: [clientReturned, handlerReturned], timeout: 5)
        XCTAssertEqual(clientError.withLock { $0 }, "RPCError(deadlineExceeded)",
                       "an expired deadline must fail the local half with .deadlineExceeded")
        XCTAssertEqual(outcomeBox.withLock { $0 }?.inboundError, .cancelled,
                       "an expired deadline must also cancel the peer's half of the RPC")
        XCTAssertEqual(client.firedDeadlines.withLock { $0 }, 1)
    }

    /// A deadline timer must not outlive its RPC. A leaked one is not merely a sleeping task: it
    /// would eventually send a `.cancel` for a `StreamID` that is no longer this call's. The
    /// assertion is the negative -- the timer never fired -- observed well past the deadline of a
    /// call that completed long before it.
    func testACompletedCallLeavesNoDeadlineTimerBehind() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let listenTask = Task {
            try await server.listen { stream, _ in
                do { for try await _ in stream.inbound { } } catch { return }
                try? await stream.outbound.write(.status(Status(code: .ok, message: ""), Metadata()))
                await stream.outbound.finish()
            }
        }
        defer { listenTask.cancel() }

        let completed = expectation(description: "the call completed inside its deadline")
        let clientTask = Task {
            try? await client.withStream(descriptor: descriptor(),
                                         options: timeout(.milliseconds(200))) { stream, _ in
                try await stream.outbound.write(.message([1]))
                await stream.outbound.finish()
                for try await _ in stream.inbound { }
            }
            completed.fulfill()
        }
        defer { clientTask.cancel() }
        await fulfillment(of: [completed], timeout: 5)

        // Well past the 200 ms deadline of a call that has already returned.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(client.firedDeadlines.withLock { $0 }, 0,
                       "the deadline timer of a completed call must be cancelled, not left to fire "
                       + "against a stream id that is no longer that call's")
    }

    // MARK: - Graceful shutdown

    /// `beginGracefulShutdown()` sends `.goAway` and refuses new streams. Both halves are checked:
    /// the client stops opening streams once the `.goAway` lands, and `listen()` -- with nothing in
    /// flight to drain -- returns.
    func testGracefulShutdownRefusesNewStreams() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let listenReturned = expectation(description: "listen() returned")
        let listenTask = Task {
            try? await server.listen { _, _ in }
            listenReturned.fulfill()
        }
        defer { listenTask.cancel() }
        try await Task.sleep(nanoseconds: 50_000_000)   // let listen() start accepting

        server.beginGracefulShutdown()
        await fulfillment(of: [listenReturned], timeout: 5)

        // `.goAway` is a real frame over a real session, so wait for it to land rather than
        // assuming `beginGracefulShutdown()` returning means the client has heard about it.
        let clientNoticed = await waitUntilTrue { clientConn.isDraining }
        XCTAssertTrue(clientNoticed, "the client must observe the peer's goAway")

        do {
            try await client.withStream(descriptor: descriptor(), options: .defaults) { _, _ in }
            XCTFail("a new stream must be refused once the peer has sent goAway")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }

    /// The other half of "refuses new streams": a peer that opens a stream anyway -- because its
    /// `.openStream` crossed the `.goAway` in flight, or because it simply ignores it -- must be
    /// refused *on the wire* with a terminal `.status(.unavailable)`, not left waiting for a stream
    /// this side will never accept.
    func testADrainingServerRefusesAnOpenStreamWithAnUnavailableStatus() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)

        let listenTask = Task { try? await server.listen { _, _ in } }
        defer { listenTask.cancel() }
        try await Task.sleep(nanoseconds: 50_000_000)
        server.beginGracefulShutdown()

        // A raw `.openStream`, sent straight at the draining server.
        let (sid, stream) = clientConn.openClientStream(descriptor: descriptor())
        try clientConn.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))

        let statusBox = Mutex<Status?>(nil)
        let refused = expectation(description: "the client's stream was refused")
        let reader = Task {
            do {
                for try await part in stream.inbound {
                    if case .status(let status, _) = part { statusBox.withLock { $0 = status } }
                }
            } catch { }
            refused.fulfill()
        }
        defer { reader.cancel() }

        await fulfillment(of: [refused], timeout: 5)
        XCTAssertEqual(statusBox.withLock { $0 }?.code, .unavailable,
                       "a draining server must answer a new openStream with a terminal "
                       + ".status(.unavailable) rather than dropping it")
    }

    /// The drain itself, which is what `beginGracefulShutdown()` previously did *not* do -- it called
    /// `connection.failAll(...)`, i.e. failed the in-flight streams, which is the opposite of
    /// draining them. Four things are asserted together because they are one behaviour:
    ///
    /// 1. the in-flight RPC's cancellation handle fires -- shutdown *asks* handlers to wind up;
    /// 2. it is only a request, and the RPC keeps *working*: the client sends a second message
    ///    **after** the shutdown began, the handler receives it and echoes it back. This is the
    ///    assertion that distinguishes draining from failing -- on a failed stream that second
    ///    message has nowhere to land and no echo ever comes;
    /// 3. the handler finishes its RPC properly and its `.ok` status reaches the client;
    /// 4. `listen()` does not return until that handler has returned.
    func testGracefulShutdownDrainsAnInFlightHandlerRatherThanFailingIt() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let shutdownBegun = TestGate()      // released once the graceful shutdown has started
        let handlerStarted = expectation(description: "the handler is in flight")
        let handleFired = expectation(description: "shutdown reached the RPC's cancellation handle")
        let handlerReturned = expectation(description: "the handler returned")
        let listenReturned = expectation(description: "listen() returned")
        // Also tracked as a plain flag: the negative check below has to observe "listen() has *not*
        // returned yet", and an `XCTestExpectation` may only be waited on once, so it cannot serve
        // both that check and the positive one at the end.
        let listenHasReturned = Mutex(false)

        let listenTask = Task {
            try? await server.listen { stream, context in
                var echoed = 0
                await withRPCCancellationHandler {
                    do {
                        for try await part in stream.inbound {
                            guard case .message(let bytes) = part else { continue }
                            if echoed == 0 { handlerStarted.fulfill() }
                            // Deliberately ignores the cancellation signal and keeps serving the
                            // RPC: a graceful shutdown must not cut this off.
                            try? await stream.outbound.write(.message(bytes))
                            echoed += 1
                        }
                    } catch { }
                    try? await stream.outbound.write(
                        .status(Status(code: .ok, message: ""), Metadata()))
                    await stream.outbound.finish()
                } onCancelRPC: {
                    handleFired.fulfill()
                }
                _ = context
                handlerReturned.fulfill()
            }
            listenHasReturned.withLock { $0 = true }
            listenReturned.fulfill()
        }
        defer { listenTask.cancel() }

        let received = Mutex<[[UInt8]]>([])
        let statusBox = Mutex<Status?>(nil)
        let clientReturned = expectation(description: "the client's call returned")
        let clientTask = Task {
            try? await client.withStream(descriptor: descriptor(), options: .defaults) { stream, _ in
                try await stream.outbound.write(.message([1]))
                // The second message is written *after* the shutdown has begun, on a stream that
                // was already in flight when it did.
                await shutdownBegun.wait()
                try await stream.outbound.write(.message([2]))
                await stream.outbound.finish()
                for try await part in stream.inbound {
                    switch part {
                    case .message(let bytes): received.withLock { $0.append(bytes) }
                    case .status(let status, _): statusBox.withLock { $0 = status }
                    default: break
                    }
                }
            }
            clientReturned.fulfill()
        }
        defer { clientTask.cancel() }

        await fulfillment(of: [handlerStarted], timeout: 5)
        server.beginGracefulShutdown()
        await fulfillment(of: [handleFired], timeout: 5)

        // (4) The drain must still be waiting on the handler, which has not been released yet.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(listenHasReturned.withLock { $0 },
                       "listen() must not return while a handler is still in flight -- that is a "
                       + "forced shutdown, not a drain")

        shutdownBegun.openForever()
        await fulfillment(of: [handlerReturned, clientReturned, listenReturned], timeout: 5)
        XCTAssertEqual(received.withLock { $0 }, [[1], [2]],
                       "an in-flight RPC must keep working across a graceful shutdown -- the second "
                       + "message was sent after the shutdown began and must still be served")
        XCTAssertEqual(statusBox.withLock { $0 }?.code, .ok,
                       "and it must be allowed to complete with its own status")
    }
}
