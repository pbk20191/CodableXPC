import XCTest
import GRPCCore
import Synchronization
import Dispatch
@testable import GRPCXPCTransport

/// Task 8: reply-as-credit backpressure.
///
/// Every test here is bounded per Task 6's reviewed pattern (see `XPCServerTransportTests`'s doc
/// comment): the work runs on its own `Task`, accumulates into that task's own locals, publishes
/// through a single `Mutex` write, and fulfils an `XCTestExpectation` the body then
/// `await fulfillment(of:timeout:)`s. That is not stylistic here -- the failure mode this whole
/// area produces is a *wedge*, not a wrong value, and an unbounded backpressure test hangs the
/// suite with no diagnosis at all.
@available(macOS 15.0, *)
final class BackpressureTests: XCTestCase {

    // MARK: - The primary target: a gated consumer bounds the writer's in-flight count

    /// A server that reads exactly one request message and then stops pulling must leave the
    /// client's writer suspended: `RPCWriter.write(_:)` is contractually "suspend until the
    /// element is accepted", so a producer of 200 messages against a stalled consumer must not
    /// get all 200 onto the wire.
    ///
    /// The bound asserted is `creditWindow + a small slack`, not merely "< 200": "fewer than all
    /// of them" would also pass on a transport that happens to be slow, whereas a bound tied to
    /// the window can only hold if the window is what stopped it.
    func testAGatedReaderSuspendsTheWriterWithinTheCreditWindow() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let gate = TestGate()
        let listenTask = Task {
            try await server.listen { stream, _ in
                do {
                    for try await part in stream.inbound {
                        if case .message = part { await gate.wait() }
                    }
                } catch { return }
            }
        }
        defer { listenTask.cancel(); server.beginGracefulShutdown() }

        let total = 200
        let accepted = Mutex(0)                    // writes that returned from `write(_:)`
        let allWritesReturned = expectation(description: "every write returned")
        let writer = Task {
            try? await client.withStream(
                descriptor: MethodDescriptor(fullyQualifiedService: "p.S", method: "M"),
                options: .defaults
            ) { stream, _ in
                for i in 0..<total {
                    try await stream.outbound.write(.message([UInt8(i & 0xFF)]))
                    accepted.withLock { $0 += 1 }
                }
            }
            allWritesReturned.fulfill()
        }
        defer { writer.cancel() }

        // Let the writer run until it can make no further progress. Polled rather than a single
        // sleep so the observation is "it stopped advancing", not "it hadn't finished yet".
        var previous = -1
        var stable = 0
        while stable < 3 {
            try await Task.sleep(nanoseconds: 60_000_000)
            let now = accepted.withLock { $0 }
            stable = (now == previous) ? stable + 1 : 0
            previous = now
        }
        let whileGated = accepted.withLock { $0 }

        // The gated reader pulled one message before parking, so one credit came back on top of
        // the initial window; +2 of slack covers that plus one in-flight reply.
        XCTAssertLessThanOrEqual(
            whileGated, XPCBackpressure.defaultCreditWindow + 2,
            "a gated reader must suspend the writer inside the credit window, but \(whileGated) "
            + "of \(total) writes were accepted -- backpressure is not being applied")
        XCTAssertGreaterThanOrEqual(
            whileGated, XPCBackpressure.defaultCreditWindow,
            "the writer must be allowed a full window of unacknowledged messages before it "
            + "suspends -- a smaller bound means the window is not being granted")

        // ...and once the reader drains, the suspended writer must resume and finish: a mechanism
        // that suspends but never resumes is not backpressure, it is a deadlock.
        gate.openForever()
        await fulfillment(of: [allWritesReturned], timeout: 10)
        XCTAssertEqual(accepted.withLock { $0 }, total,
                       "every write must complete once the consumer drains")
    }

    // MARK: - C4: credit flows in both directions

    /// The reverse direction, which is the one that silently does not work if credit is wired only
    /// into the request path: a slow *client* reader must suspend the *server*'s writer.
    func testASlowClientReaderSuspendsTheServersWriter() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let total = 200
        let serverAccepted = Mutex(0)              // server-side writes that returned
        let clientGate = TestGate()

        let listenTask = Task {
            try await server.listen { stream, _ in
                do {
                    for try await _ in stream.inbound { }          // drain the request half
                } catch { return }
                for i in 0..<total {
                    do { try await stream.outbound.write(.message([UInt8(i & 0xFF)])) }
                    catch { return }
                    serverAccepted.withLock { $0 += 1 }
                }
                try? await stream.outbound.write(.status(Status(code: .ok, message: ""), Metadata()))
            }
        }
        defer { listenTask.cancel(); server.beginGracefulShutdown() }

        let receivedBox = Mutex<Int?>(nil)
        let clientReturned = expectation(description: "client.withStream returned")
        let clientTask = Task {
            var received = 0
            try? await client.withStream(
                descriptor: MethodDescriptor(fullyQualifiedService: "p.S", method: "M"),
                options: .defaults
            ) { stream, _ in
                await stream.outbound.finish()                     // half-close immediately
                for try await part in stream.inbound {
                    if case .message = part {
                        received += 1
                        await clientGate.wait()                    // slow reader
                    }
                }
            }
            receivedBox.withLock { $0 = received }
            clientReturned.fulfill()
        }
        defer { clientTask.cancel() }

        var previous = -1
        var stable = 0
        while stable < 3 {
            try await Task.sleep(nanoseconds: 60_000_000)
            let now = serverAccepted.withLock { $0 }
            stable = (now == previous) ? stable + 1 : 0
            previous = now
        }
        let whileGated = serverAccepted.withLock { $0 }
        XCTAssertLessThanOrEqual(
            whileGated, XPCBackpressure.defaultCreditWindow + 2,
            "a slow client reader must suspend the server's writer (C4: credit must flow "
            + "service -> client too), but \(whileGated) of \(total) server writes were accepted")

        clientGate.openForever()
        await fulfillment(of: [clientReturned], timeout: 10)
        XCTAssertEqual(receivedBox.withLock { $0 }, total,
                       "the client must receive every message once it stops throttling")
    }

    // MARK: - Termination must never wait for credit that will never come

    /// `halfClose` and `.status` are sent one-way, so a stream can always terminate even while its
    /// message writer is suspended for want of credit. Without that, an RPC whose consumer stops
    /// reading could never be closed.
    func testTerminationSucceedsWhileTheWriterIsStarvedOfCredit() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()

        var iterator = serverConn.acceptedStreams.makeAsyncIterator()
        let (sid, clientStream) = clientConn.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "p.S", method: "M"))
        try clientConn.send(.openStream(sid, method: "p.S/M", deadlineNanos: nil))
        let next = await iterator.next()
        let accepted = try XCTUnwrap(next)

        // Nobody ever pulls `accepted.stream.inbound`, so no credit is ever granted. Fill the
        // window so the very next message write would suspend.
        for _ in 0..<XPCBackpressure.defaultCreditWindow {
            try await clientStream.outbound.write(.message([1]))
        }

        // Terminals must still go through, promptly, without any credit.
        let terminated = expectation(description: "the request half closed while starved")
        Task {
            await clientStream.outbound.finish()
            terminated.fulfill()
        }
        await fulfillment(of: [terminated], timeout: 5)

        // And the server side can close its own half too.
        let statusSent = expectation(description: "the response half sent a status while starved")
        Task {
            try? await accepted.stream.outbound.write(
                .status(Status(code: .ok, message: ""), Metadata()))
            statusSent.fulfill()
        }
        await fulfillment(of: [statusSent], timeout: 5)
    }

    /// A writer suspended for credit when the connection dies must *fail*, not hang: libxpc does
    /// not deliver anything to a reply handler whose session is cancelled (probed: cancelling a
    /// session with an outstanding reply never calls its reply handler at all), so the connection
    /// has to fail its own outstanding credits.
    func testASuspendedWriterFailsRatherThanHangingWhenTheConnectionGoesAway() async throws {
        var pair: (XPCConnection, XPCConnection)? = try await XPCPairHarness().connectPair()
        var iterator = pair!.1.acceptedStreams.makeAsyncIterator()
        let (sid, clientStream) = pair!.0.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "p.S", method: "M"))
        try pair!.0.send(.openStream(sid, method: "p.S/M", deadlineNanos: nil))
        _ = await iterator.next()

        for _ in 0..<XPCBackpressure.defaultCreditWindow {
            try await clientStream.outbound.write(.message([1]))
        }

        let outcome = Mutex<String?>(nil)
        let settled = expectation(description: "the starved write settled")
        Task {
            do {
                try await clientStream.outbound.write(.message([2]))
                outcome.withLock { $0 = "returned successfully" }
            } catch let error as RPCError {
                outcome.withLock { $0 = "RPCError(\(error.code))" }
            } catch {
                outcome.withLock { $0 = "\(error)" }
            }
            settled.fulfill()
        }
        // Give the write time to reach its suspended state, then drop the connections.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(outcome.withLock { $0 }, "the write should still be suspended at this point")
        pair = nil

        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(outcome.withLock { $0 }, "RPCError(unavailable)",
                       "a credit-starved write must fail when its connection goes away")
    }

    // MARK: - Direct proof that a write suspends, at an exact window

    /// The mechanism at the smallest scale, with no XPC in the way: `acquire()` must hand out
    /// exactly `capacity` permits and then genuinely *suspend*, and a `release` must resume the
    /// suspended caller. "The suite is green" would not distinguish this from a window that never
    /// blocks; observing the third `acquire()` still outstanding after the first two returned does.
    func testTheCreditWindowSuspendsAtCapacityAndResumesOnRelease() async throws {
        let window = CreditWindow(capacity: 2)
        try await window.acquire()
        try await window.acquire()

        let thirdReturned = expectation(description: "the third acquire returned")
        let state = Mutex(false)
        Task {
            try? await window.acquire()
            state.withLock { $0 = true }
            thirdReturned.fulfill()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(state.withLock { $0 },
                       "the third acquire must be suspended -- capacity is 2")

        window.release(1)
        await fulfillment(of: [thirdReturned], timeout: 5)
    }

    /// The same claim end-to-end over real XPC, at an exact configured window: with nobody pulling
    /// the inbound sequence, precisely `creditWindow` messages get through and the next one hangs.
    func testAConfiguredWindowIsTheExactBoundOnUnacknowledgedMessages() async throws {
        let window = 3
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair(creditWindow: window)
        var iterator = serverConn.acceptedStreams.makeAsyncIterator()
        let (sid, clientStream) = clientConn.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "p.S", method: "M"))
        try clientConn.send(.openStream(sid, method: "p.S/M", deadlineNanos: nil))
        let next = await iterator.next()
        let accepted = try XCTUnwrap(next)

        let sent = Mutex(0)
        let allSent = expectation(description: "all writes returned")
        let writer = Task {
            for _ in 0..<(window + 5) {
                try? await clientStream.outbound.write(.message([7]))
                sent.withLock { $0 += 1 }
            }
            allSent.fulfill()
        }
        defer { writer.cancel() }

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sent.withLock { $0 }, window,
                       "with nothing consuming, exactly the window may be unacknowledged")

        // Draining the server's inbound grants credit, message by message, and the writer finishes.
        let drain = Task {
            for try await _ in accepted.stream.inbound { }
        }
        defer { drain.cancel() }
        await fulfillment(of: [allSent], timeout: 10)
        XCTAssertEqual(sent.withLock { $0 }, window + 5)
    }

    /// Why the window must be **greater than one**: two peers that each write a burst before they
    /// read deadlock if a writer may only have one unacknowledged message in flight -- each is
    /// suspended in `write` waiting for a credit the other will produce only once it starts
    /// reading, which it does only after its own writes return. Run at window 1 the exchange
    /// wedges (asserted as an expectation that must *not* be fulfilled); at a window that covers
    /// the burst it completes.
    ///
    /// This is also the strongest available evidence that `write` really suspends: nothing else
    /// could wedge the window-1 run.
    func testAMutualBurstDeadlocksAtWindowOneAndNotAtTheDefault() async throws {
        let burst = 3

        /// Runs "both sides write `burst` messages before either reads" and reports whether the
        /// client's call completed within `timeout`.
        func exchangeCompletes(creditWindow: Int, timeout: TimeInterval) async throws -> Bool {
            let harness = XPCPairHarness()
            let (clientConn, serverConn) = try await harness.connectPair(creditWindow: creditWindow)
            let server = XPCServerTransport(connection: serverConn)
            let client = XPCClientTransport(connection: clientConn)

            let listenTask = Task {
                try await server.listen { stream, _ in
                    // Writes first, reads second -- the mirror image of the client below.
                    for i in 0..<burst {
                        do { try await stream.outbound.write(.message([UInt8(100 + i)])) }
                        catch { return }
                    }
                    do { for try await _ in stream.inbound { } } catch { return }
                    try? await stream.outbound.write(
                        .status(Status(code: .ok, message: ""), Metadata()))
                }
            }
            let done = expectation(description: "the mutual burst completed at window \(creditWindow)")
            let clientTask = Task {
                try? await client.withStream(
                    descriptor: MethodDescriptor(fullyQualifiedService: "p.S", method: "M"),
                    options: .defaults
                ) { stream, _ in
                    for i in 0..<burst {
                        try await stream.outbound.write(.message([UInt8(i)]))
                    }
                    await stream.outbound.finish()
                    for try await _ in stream.inbound { }
                }
                done.fulfill()
            }
            let result = await XCTWaiter().fulfillment(of: [done], timeout: timeout)
            // Cancelling unwedges a writer parked on credit (the acquire is cancellation-aware),
            // which is what lets this test tear its connections down instead of leaking them.
            clientTask.cancel()
            listenTask.cancel()
            server.beginGracefulShutdown()
            return result == .completed
        }

        let wedgedAtOne = try await exchangeCompletes(creditWindow: 1, timeout: 1.5)
        XCTAssertFalse(wedgedAtOne,
                       "a window of 1 must deadlock the mutual-burst exchange -- if it does not, "
                       + "writes are not actually suspending and the window is decorative")

        let completedAtDefault = try await exchangeCompletes(
            creditWindow: XPCBackpressure.defaultCreditWindow, timeout: 10)
        XCTAssertTrue(completedAtDefault,
                      "a window covering the burst must not deadlock -- this is what "
                      + "XPCBackpressure.defaultCreditWindow being > 1 buys")
    }

    // MARK: - A1: a cancel/release race must not lose a permit

    /// A permit handed to a waiter that is cancelled in the gap before it parks must not evaporate.
    ///
    /// `release` resolves a waiter that has taken a token but not yet parked by setting `granted`
    /// and dropping it from the FIFO -- the permit is now *that waiter's*. If cancellation lands in
    /// the same gap and `acquire()`'s park body tests `cancelled` before `granted`, the waiter
    /// throws and the permit is gone: the window shrinks by one, permanently, and enough repeats
    /// wedge the stream at zero for good. `acquire()`'s contract is "never returns without having
    /// taken a permit", so an already-granted permit must be honoured; the cancelled task observes
    /// its cancellation at the next suspension point instead.
    ///
    /// The invariant asserted is a strict accounting one, not a timing one, so the test cannot pass
    /// by luck: with capacity 1 and one permit already held, after the race *exactly one* of these
    /// holds -- the racing acquirer took the permit (so nothing is free), or it did not (so the
    /// permit is back in the window). Neither holding means the permit was lost.
    func testACancelReleaseRaceNeverLosesAPermit() async throws {
        let rounds = 3_000
        var lost = 0

        for _ in 0..<rounds {
            let window = CreditWindow(capacity: 1)
            try await window.acquire()          // the window's only permit is now held

            let acquired = Mutex(false)
            let waiter = Task.detached {
                do { try await window.acquire(); acquired.withLock { $0 = true } }
                catch { }
            }
            // The gap this is aiming at is a handful of instructions wide (between `acquire`
            // taking its token and its park body acquiring the lock), so the release is fired from
            // a *different* thread with a randomized stagger and the cancellation from this one.
            let spin = Int.random(in: 0..<64)
            let releaser = Task.detached {
                var sink = 0
                for i in 0..<spin { sink &+= i }
                _ = sink
                window.release(1)
            }
            waiter.cancel()
            _ = await waiter.result
            _ = await releaser.value

            // Both racers have settled, so the window's books must balance.
            let tookThePermit = acquired.withLock { $0 }
            let free = window.unusedPermits
            if tookThePermit ? free != 0 : free != 1 { lost += 1 }
        }

        XCTAssertEqual(lost, 0,
                       "\(lost) of \(rounds) cancel/release races lost a permit outright -- a "
                       + "window that shrinks on every such race eventually wedges at zero and "
                       + "stalls the stream forever")
    }

    // MARK: - A2: peer-supplied credit must not inflate the window, or spin the reply thread

    /// A single `release(n)` with an inflated `n` must not resume more writers than the window
    /// permits. The `available` path was clamped to `capacity`, but the *waiter* path handed out
    /// `n` permits unconditionally -- so at capacity 2, five parked writers and one `release(5)`
    /// put five messages in flight where two was the bound.
    func testInflatedCreditCannotResumeMoreWritersThanTheWindowAllows() async throws {
        let window = CreditWindow(capacity: 2)
        try await window.acquire()
        try await window.acquire()          // both permits held; the window is empty

        let resumed = Mutex(0)
        let parked = 5
        var waiters: [Task<Void, Never>] = []
        for _ in 0..<parked {
            waiters.append(Task { try? await window.acquire(); resumed.withLock { $0 += 1 } })
        }
        defer { waiters.forEach { $0.cancel() } }
        let allParked = await waitUntilTrue { window.waiterCount == parked }
        XCTAssertTrue(allParked, "all \(parked) writers must be parked before the race is set up")

        // What an untrusted peer controls: the `n` in its credit reply.
        window.release(parked)
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(resumed.withLock { $0 }, 2,
                       "a peer's inflated credit must resume at most a window's worth of writers "
                       + "-- more than that puts more messages in flight than the window bounds")
        XCTAssertEqual(window.unusedPermits, 0,
                       "over-credit must not leave phantom permits behind either")
    }

    /// The same inflated `n`, at the size an untrusted peer can actually send: a `UInt32` credit
    /// count must not turn `release` into a multi-minute spin *inside the state lock*, which blocks
    /// the reply-handler thread, every writer, and the connection's own failure paths.
    func testAHugeCreditCountCannotSpinTheReplyThread() async throws {
        let window = CreditWindow(capacity: 32)
        try await window.acquire()

        let start = ContinuousClock.now
        window.release(Int(UInt32.max))
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .milliseconds(100),
                          "release must be bounded by the window, not by the peer's credit count "
                          + "-- it took \(elapsed) for a single UInt32.max credit reply")
        XCTAssertLessThanOrEqual(window.unusedPermits, window.capacity)
    }

    /// And the boundary the untrusted value actually crosses: one credit reply acknowledges exactly
    /// one message (each credit-bearing send has its own reply), so it can only ever be worth one
    /// permit -- whatever `n` the peer writes into it.
    func testACreditReplyIsWorthOnePermitWhateverThePeerClaims() throws {
        let inflated = try XPCFrame.credit(0, n: 1_000).encodeToXPC()
        XCTAssertEqual(XPCConnection.permits(inCreditReply: XPCDictionary(inflated)), 1,
                       "a peer must not be able to mint window out of a credit reply's `n`")

        // The two degenerate replies keep their existing meaning: mis-reading a reply must never
        // *stall* a writer, so an undecodable or empty reply is still worth one permit.
        XCTAssertEqual(XPCConnection.permits(inCreditReply: XPCDictionary()), 1)
        let zero = try XPCFrame.credit(0, n: 0).encodeToXPC()
        XCTAssertEqual(XPCConnection.permits(inCreditReply: XPCDictionary(zero)), 1)
    }

    // MARK: - C1: the coarse valve's suspend/resume balance

    /// `DispatchQueue.resume()` without a matching `suspend()` traps, so the valve is a two-state
    /// machine rather than a counter: repeated closes and repeated opens must be no-ops. 50
    /// toggles plus doubled calls at each end; the assertion is really "the process is still
    /// alive", since over-resuming would have killed it.
    func testTheCoarseValveNeverOverResumes() throws {
        let queue = DispatchSerialQueue(label: "BackpressureTests.valve")
        let valve = ConnectionValve(queue: queue)

        XCTAssertFalse(valve.isClosed)
        XCTAssertFalse(valve.open(), "opening an already-open valve must be a no-op")
        XCTAssertFalse(valve.open())

        for _ in 0..<50 {
            XCTAssertTrue(valve.close())
            XCTAssertFalse(valve.close(), "closing an already-closed valve must be a no-op")
            XCTAssertTrue(valve.isClosed)
            XCTAssertTrue(valve.open())
            XCTAssertFalse(valve.open(), "opening an already-open valve must be a no-op")
            XCTAssertFalse(valve.isClosed)
        }

        // Left open, as it must be: the valve is off by default and must not be handed back
        // suspended (a suspended queue that nobody resumes never delivers another message).
        XCTAssertFalse(valve.isClosed)
    }

    /// The valve has to actually gate delivery, otherwise the balance test above is vacuous.
    /// Deliberately drives a queue this test owns rather than a live connection's queue: C2 says
    /// the controller must live outside the queue it suspends, and the test body is that outside.
    func testTheCoarseValveActuallyGatesDelivery() async throws {
        let queue = DispatchSerialQueue(label: "BackpressureTests.valve.gating")
        let valve = ConnectionValve(queue: queue)
        let ran = Mutex(false)

        XCTAssertTrue(valve.close())
        queue.async { ran.withLock { $0 = true } }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(ran.withLock { $0 }, "work must not run on a closed (suspended) queue")

        XCTAssertTrue(valve.open())
        let didRun = await waitUntilTrue { ran.withLock { $0 } }
        XCTAssertTrue(didRun, "work must run once the valve is opened again")
    }
}

/// A latch a consumer awaits: closed until `openForever()`, then permanently open. The production
/// analogue of a slow reader, kept in the tests because nothing in the transport needs it.
@available(macOS 15.0, *)
final class TestGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = state.withLock { s in
                if s.isOpen { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func openForever() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            let pending = s.waiters
            s.waiters = []
            return pending
        }
        waiters.forEach { $0.resume() }
    }
}
