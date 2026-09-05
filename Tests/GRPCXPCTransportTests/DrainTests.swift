import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

/// The graceful drain, on **both** sides: `goAway` on the wire, new streams refused with the code
/// the protocol assigns, in-flight work allowed to finish, and `connect()`/`listen()` released only
/// when it has.
///
/// Two things in this file are worth knowing before reading it.
///
/// **`goAway`'s two directions are not equally observable.** A *server* → *client* `goAway` lands
/// in the client's `RPCTransportCore` and is directly readable through ``InspectableXPCPair`` --
/// `isDraining` flips, `liveStreamCount` proves the connection was not merely torn down, and the
/// next `withStream` reports the peer's drain rather than a local one. A *client* → *server*
/// `goAway` sets `peerDraining` on a core built inside `XPCServerTransport.Acceptor`, which is
/// private and unreachable from a test; by design it also has no other effect (contract line 8's
/// directionality: it must **not** refuse inbound `openStream`s, must not finish
/// `acceptedStreams`, must not disturb open streams -- so there is nothing else to observe).
/// ``testLocalDrainAfterInboundGoAwayStillFinishesTheAcceptLoop()`` therefore reaches it through
/// its *consequence* rather than its flag, and is the one test here that needs a settle window
/// instead of a condition.
///
/// **A drained server closes its connections quickly.** `beginGracefulShutdown()` finishes the
/// accept sequences, so with nothing in flight `listen()` reaches its tail -- `closeAll()` then
/// `listener.cancel()` -- within microseconds, and the client then sees *peer death* rather than
/// the `goAway` that preceded it. Every test here that wants to observe the drain itself holds one
/// handler in flight to keep the connection alive while it looks.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class DrainTests: XCTestCase {

    // =======================================================================================
    // MARK: - Refusals: the right code, from the right side
    // =======================================================================================

    /// A **local** shutdown refuses new streams with `.failedPrecondition`.
    ///
    /// `withStream`'s own documentation assigns `.failedPrecondition` to "the transport is closing
    /// or has been closed" and reserves `.unavailable` for "temporarily not possible... may be
    /// possible after some backoff". This transport has no reconnect, so a local shutdown is
    /// permanent and `.unavailable` would be telling the caller to retry something that will never
    /// work. `InProcessTransport+Client` reports the same condition the same way.
    ///
    /// The code is asserted, not merely "it threw": the local gate and the peer-drain check are
    /// two *different* refusals two lines apart in `withStream`, and the whole point of `500fcbb`'s
    /// last nit was that a local shutdown landing in the window between them was being reported as
    /// the peer's. A test that accepted either code could not tell them apart.
    ///
    /// # Measured: the two gates are redundant, and no test can tell which one fired
    ///
    /// Removing the local gate alone leaves the test green (mutation M2) -- `core.isDraining`'s
    /// branch re-reads the local phase and produces the *same* `localShutdownRefusal`. Breaking that
    /// re-read alone also leaves it green (M2b), because the local gate fires first. Only removing
    /// both discriminates (M2c: `.unavailable`). That is a property of the design -- both gates
    /// deliberately share one constant -- not a weakness in the assertion, and it is recorded so a
    /// future reader does not mistake this test for a check on *which* gate refused.
    ///
    /// `expectingRoughTeardown: true` is a margin, not a mask: measured, this test also passes with
    /// it `false`. It is kept because the body deliberately leaves the client shut down, which is
    /// exactly the shape the flag exists for, and a teardown that goes rough under load should not
    /// fail a test whose property held.
    func testALocalShutdownRefusesNewStreamsWithFailedPrecondition() throws {
        try runBounded("local shutdown refuses", timeout: 20) {
            try await XPCPairHarness.withTransports(
                streamHandler: RawSeamHandlers.echoing(), expectingRoughTeardown: true
            ) { pair in
                // Proves the transport was working before it was shut down, so the refusal below
                // is the shutdown's and not a broken connection's.
                let bodies = try await pair.client.completeOneEchoRPC(payload: lifecyclePayload(10))
                XCTAssertEqual(
                    bodies,
                    ["echo:" + String(decoding: Array(lifecyclePayload(10)), as: UTF8.self)])

                pair.client.beginGracefulShutdown()

                do {
                    _ = try await pair.client.completeOneEchoRPC(payload: lifecyclePayload(11))
                    XCTFail("withStream must refuse a new call after a local shutdown")
                } catch let error as RPCError {
                    XCTAssertEqual(
                        error.code, .failedPrecondition,
                        "a local shutdown is permanent, so the refusal must be "
                            + ".failedPrecondition and not the retryable .unavailable")
                    XCTAssertTrue(
                        error.message.contains("this transport has begun shutting down"),
                        "the refusal must be the local gate's, not the peer-drain check's: "
                            + error.message)
                }
            }
        }
    }

    /// A local shutdown is not blamed on the peer **from inside `beginGracefulShutdown()` itself**
    /// -- the one window the test above cannot reach.
    ///
    /// ``testALocalShutdownRefusesNewStreamsWithFailedPrecondition()`` calls
    /// `beginGracefulShutdown()` and then opens a stream, so by the time it looks, both of the
    /// shutdown's two writes have landed. But they are two writes, not one, and they are not
    /// ordered by anything the type system can see:
    ///
    /// * `core.beginDraining()` sets the mux's `localDraining` (which makes `core.isDraining` true
    ///   for the rest of this connection's life), and
    /// * `state.phase`/`localShutdownRequested` records that **this side** is the one shutting
    ///   down, which is what tells `withStream` whose fault it is.
    ///
    /// With the mux's flag landing first, a `withStream` running in between passed the local gate
    /// (nothing said "shutting down" yet), saw `core.isDraining`, re-read the local state, still
    /// found nothing -- and refused with the *peer's* code and the peer's message: `.unavailable`,
    /// "the peer sent goAway". That is a retryable, backoff-and-try-again answer for a shutdown
    /// this process asked for and will never revoke, and `withStream`'s own contract gives the two
    /// codes distinct meanings, so it is a lie a caller acts on rather than a cosmetic mislabel.
    ///
    /// # Why this is deterministic and not a race the test hopes to win
    ///
    /// `beginDraining()` sets `localDraining` under the registry lock and *then* puts `goAway` on
    /// the wire through `pipe.send`. So a `TestPipe` whose ``TestPipe/onEachSend(_:)`` hook blocks
    /// stops the shutdown at precisely the instant the window exists -- mux draining, transport
    /// bookkeeping unfinished -- and holds it there until the probe has had its answer. Nothing
    /// here is timing-dependent, retried, or load-sensitive: the window is *held open*, not
    /// sampled. (This suite has been burned once by a retry-until-it-races design that turned out
    /// to be sampling a warmth-dependent distribution.)
    ///
    /// The shutdown runs on a `DispatchQueue.global()` thread rather than in a `Task` for the
    /// blocking's sake: it parks that thread inside the hook, and parking one of the cooperative
    /// pool's threads instead would risk starving the probe that is supposed to release it.
    ///
    /// The assertion is on the *outcome* -- the code and the message a caller sees -- not on which
    /// of `withStream`'s two gates produced it. Both gates deliberately share one constant (see
    /// the note on the test above), and which one fires is an implementation detail; "a local
    /// shutdown never reads as the peer's" is the property.
    func testALocalDrainIsNotBlamedOnThePeerFromInsideTheShutdown() throws {
        let pipe = TestPipe(label: "shutdownFlagOrder")
        let core = TestPipeCore(pipe: pipe, codec: CompactWireCodec(), role: .client)
        // `RPCClientTransportCore` rather than `XPCClientTransport`, and that is forced rather than
        // chosen: the public façade is bound to `XPCPipe` (a public type cannot be generic over
        // the internal `MessagePipe`/`WireCodec` seams -- see `XPCClientTransport`'s own doc for
        // the two compiler errors), and this test's whole method is a substrate whose `send` can
        // be frozen. The subject is unchanged: every gate, flag and refusal below belongs to
        // `RPCClientTransportCore`, which is the entire implementation the façade forwards to, not a
        // copy of it.
        let transport = RPCClientTransportCore(core: core)

        let drainIsMidFlight = OneShotGate()
        let probeHasItsAnswer = DispatchSemaphore(value: 0)

        pipe.onEachSend { _ in
            drainIsMidFlight.open()
            // Bounded, so a regression that never releases this cannot hang the suite (L8) --
            // `runBounded` bounds the test's own task, not this thread.
            _ = probeHasItsAnswer.wait(timeout: .now() + 15)
        }

        let refusal = try runBounded("a local drain must not be blamed on the peer", timeout: 20) {
            () -> RPCError? in
            DispatchQueue.global().async { transport.beginGracefulShutdown() }
            await drainIsMidFlight.wait()
            defer { probeHasItsAnswer.signal() }

            do {
                _ = try await transport.withStream(
                    descriptor: LifecycleMethods.echo, options: .defaults
                ) { _, _ in }
                return nil
            } catch let error as RPCError {
                return error
            }
        }

        guard let refusal else {
            XCTFail("withStream must refuse a new call once a local shutdown has begun")
            return
        }
        XCTAssertEqual(
            refusal.code, .failedPrecondition,
            "a local shutdown is permanent, so even mid-shutdown the refusal must be "
                + ".failedPrecondition and not the retryable .unavailable")
        XCTAssertTrue(
            refusal.message.contains("this transport has begun shutting down"),
            "the refusal must name this side's shutdown, not the peer's goAway: " + refusal.message)
    }

    /// The **peer's** `goAway` refuses new streams with `.unavailable`, and does not disturb the
    /// stream already open.
    ///
    /// This is the test that proves `goAway` reaches the wire at all. Three assertions make it
    /// specific rather than a "something went wrong" test:
    ///
    /// * `clientCore.isDraining` flips -- which on this side can only come from the inbound
    ///   `goAway`, since the client shut nothing down;
    /// * `clientCore.liveStreamCount == 1` at that moment. `isDraining` is the disjunction
    ///   `isClosed || localDraining || peerDraining`, so without this the test would also pass if
    ///   the connection had simply been **torn down** -- `failAll` empties the table, so a live
    ///   entry is proof it was not;
    /// * the refusal carries the *peer*-drain message, not the local one.
    ///
    /// Then the parked handler is released and the in-flight call completes with the handler's
    /// reply: a peer's drain lets the RPCs already running finish, which is the whole difference
    /// between a drain and a teardown.
    func testAPeerGoAwayRefusesNewStreamsWithUnavailableAndSparesTheOpenStream() throws {
        try runBounded("peer goAway refuses", timeout: 20) {
            let pair = try InspectableXPCPair.make(label: "peerGoAway")

            let handlerStarted = Observed(false)
            let handlerFinished = Observed(false)
            let release = OneShotGate()
            let handler = RawSeamHandlers.releasable(
                started: handlerStarted, release: release, finished: handlerFinished)

            let callOutcome = Observed<Result<[String], any Error>?>(nil)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pair.server.listen(streamHandler: handler) }
                group.addTask { try await pair.client.connect() }
                group.addTask {
                    do {
                        let bodies = try await pair.client.completeOneEchoRPC(
                            descriptor: LifecycleMethods.parking)
                        callOutcome.mutate { $0 = .success(bodies) }
                    } catch {
                        callOutcome.mutate { $0 = .failure(error) }
                    }
                }

                try await waitUntil("the handler to have drained the request") {
                    handlerStarted.isSet
                }

                // The server drains. Its `goAway` goes out on every live connection; the handler
                // in flight above is what keeps this connection open long enough to see it.
                pair.server.beginGracefulShutdown()

                try await waitUntil("the client's core to see the peer's goAway") {
                    pair.clientCore.isDraining
                }
                XCTAssertEqual(
                    pair.clientCore.liveStreamCount, 1,
                    "isDraining is true but the stream table is empty, so this was a teardown "
                        + "rather than a goAway -- the assertion below would prove nothing")

                do {
                    _ = try await pair.client.completeOneEchoRPC(payload: lifecyclePayload(21))
                    XCTFail("withStream must refuse a new call once the peer has sent goAway")
                } catch let error as RPCError {
                    XCTAssertEqual(
                        error.code, .unavailable,
                        "the peer's drain is retryable on another connection, so .unavailable")
                    XCTAssertTrue(
                        error.message.contains("the peer sent goAway"),
                        "the refusal must be attributed to the peer, not to a local shutdown "
                            + "that never happened: " + error.message)
                }

                release.open()
                try await waitUntil("the drained handler to finish") { handlerFinished.isSet }
                try await waitUntil("the in-flight call to complete") {
                    callOutcome.value != nil
                }

                pair.client.beginGracefulShutdown()
                try await group.waitForAll()
            }

            switch callOutcome.value {
            case .success(let bodies):
                XCTAssertEqual(
                    bodies, [String(decoding: Array(lifecyclePayload(999)), as: UTF8.self)],
                    "the call open when the peer began draining must complete, carrying the "
                        + "handler's reply -- a drain finishes in-flight work, it does not fail it")
            case .failure(let error):
                XCTFail("the peer's drain failed an in-flight call instead of draining it: \(error)")
            case nil:
                XCTFail("the in-flight call never finished")
            }
        }
    }

    // =======================================================================================
    // MARK: - listen() is the server's drain barrier
    // =======================================================================================

    /// `beginGracefulShutdown()` on the server must let the handler already running finish, and
    /// `listen()` must return only afterwards.
    ///
    /// The server-side counterpart of case 38, and the same shape: a negative assertion (`listen()`
    /// has **not** returned after a settle window) sandwiched between "the handler is parked" and
    /// "the handler completed". `beginGracefulShutdown()` fires every in-flight RPC's cancellation
    /// handle as a *request* to wind up; this handler ignores it, which is the documented,
    /// supported behaviour ("a handler that ignores it runs to completion") and the harder case for
    /// the drain to get right.
    func testGracefulShutdownDrainsAnInFlightHandlerAndOnlyThenReleasesListen() throws {
        try runBounded("server drain waits for its handler", timeout: 20) {
            let pair = try XPCTransportPair.make()

            let handlerStarted = Observed(false)
            let handlerFinished = Observed(false)
            let release = OneShotGate()
            let handler = RawSeamHandlers.releasable(
                started: handlerStarted, release: release, finished: handlerFinished)

            let listenReturned = Observed(false)
            let callOutcome = Observed<Result<[String], any Error>?>(nil)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await pair.server.listen(streamHandler: handler)
                    listenReturned.set()
                }
                group.addTask { try await pair.client.connect() }
                group.addTask {
                    do {
                        let bodies = try await pair.client.completeOneEchoRPC(
                            descriptor: LifecycleMethods.parking)
                        callOutcome.mutate { $0 = .success(bodies) }
                    } catch {
                        callOutcome.mutate { $0 = .failure(error) }
                    }
                }

                try await waitUntil("the handler to have drained the request") {
                    handlerStarted.isSet
                }

                pair.server.beginGracefulShutdown()

                try await Task.sleep(for: negativeAssertionSettleWindow)
                XCTAssertFalse(
                    listenReturned.isSet,
                    "listen() returned while a handler was still running: the server's drain is "
                        + "not a drain barrier")
                XCTAssertFalse(
                    handlerFinished.isSet,
                    "the handler finished on its own -- the negative assertion above proved "
                        + "nothing")

                release.open()
                try await waitUntil("listen() to return once its last handler finished") {
                    listenReturned.isSet
                }
                XCTAssertTrue(
                    handlerFinished.isSet,
                    "listen() returned but the handler never completed: it was failed rather "
                        + "than drained")

                pair.client.beginGracefulShutdown()
                try await group.waitForAll()
            }

            if case .failure(let error) = callOutcome.value {
                XCTFail("the drained call failed instead of completing: \(error)")
            }
        }
    }

    /// **The Task 6 fix, exercised for the first time.** A local drain that arrives *after* an
    /// inbound `goAway` must still finish the accept sequence, or `listen()` never returns.
    ///
    /// Until Task 6's review, an inbound `goAway` and a local `beginDraining()` shared one
    /// `Phase = .draining`. The consequence was that `beginDraining()` -- whose job includes
    /// `acceptedContinuation.finish()`, the thing that ends `listen()`'s inner accept loop -- saw
    /// the connection as already draining and returned early. The fix split the two flags;
    /// `beginDraining()` now guards on `localDraining` alone. **Task 7 is the first caller and
    /// nothing has ever exercised it**, which is why this test exists.
    ///
    /// # Why the `goAway` is sent by `clientCore.beginDraining()` and not by the client transport
    ///
    /// This was the trap in writing it. `pair.client.beginGracefulShutdown()` sends the `goAway`
    /// *and* -- with nothing in flight -- completes the drain, whose tail calls `core.close()` and
    /// cancels the XPC session. The server then sees **peer death**, and `failAll` finishes the
    /// accept sequence itself. So `listen()` would return even with the bug present, and the test
    /// would be green against exactly the defect it was written for. Calling
    /// `clientCore.beginDraining()` directly puts `goAway` on the wire and touches nothing else:
    /// the session stays open, and finishing the accept sequence is left as the server's own job,
    /// which is the property under test.
    ///
    /// # The one settle window in this file
    ///
    /// A client → server `goAway` sets `peerDraining` on a core inside the private `Acceptor`, and
    /// contract line 8 requires it to have no other effect -- so there is nothing to poll. The
    /// window is ~1000× the ~265 µs a whole listener→dial→accept→RPC→drain cycle costs on this
    /// substrate, and the mutation table records that reinstating the Task 6 bug makes this test
    /// hang rather than pass, which is the evidence that the window is long enough.
    func testLocalDrainAfterInboundGoAwayStillFinishesTheAcceptLoop() throws {
        try runBounded("local drain after inbound goAway", timeout: 20) {
            let pair = try InspectableXPCPair.make(label: "goAwayThenLocalDrain")
            let listenReturned = Observed(false)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await pair.server.listen(streamHandler: RawSeamHandlers.echoing())
                    listenReturned.set()
                }
                group.addTask { try await pair.client.connect() }

                // Establishes the connection: the listener's incoming-session closure runs on the
                // first blob, so without an RPC there is no server-side core to send `goAway` to.
                _ = try await pair.client.completeOneEchoRPC(payload: lifecyclePayload(30))

                // `goAway` only. The session stays open; nothing else on the client changes.
                pair.clientCore.beginDraining()
                try await Task.sleep(for: negativeAssertionSettleWindow)

                // The local drain, arriving second. With the Task 6 bug this is a no-op and the
                // accept sequence is never finished.
                pair.server.beginGracefulShutdown()

                try await waitUntil(
                    "listen() to return after a local drain that followed an inbound goAway",
                    timeout: .seconds(5)
                ) { listenReturned.isSet }

                pair.client.beginGracefulShutdown()
                try await group.waitForAll()
            }
        }
    }

    // =======================================================================================
    // MARK: - A draining server turns new peers away
    // =======================================================================================

    /// After `beginGracefulShutdown()`, a **new** connection is refused -- and refused the safe
    /// way, with `XPCPipe.rejecting`, which creates no `XPCSession` at all.
    ///
    /// The failure mode this guards is a process death rather than a wrong answer: accepting a
    /// session and then dropping or cancelling it inside the listener's incoming-session closure is
    /// `_xpc_api_misuse`. So "the process is still here to run the assertion" is half of what this
    /// test measures.
    ///
    /// A handler is parked on the *first* connection throughout, because otherwise the drained
    /// `listen()` reaches its tail and cancels the listener -- and a dial to a cancelled listener
    /// never reaches `Acceptor.accept` at all, so the refusal path would go unexercised.
    func testADrainingServerRefusesANewConnectionWithoutTrapping() throws {
        try runBounded("draining server refuses a new peer", timeout: 20) {
            let pair = try XPCTransportPair.make()

            let handlerStarted = Observed(false)
            let handlerFinished = Observed(false)
            let release = OneShotGate()
            let handler = RawSeamHandlers.releasable(
                started: handlerStarted, release: release, finished: handlerFinished)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pair.server.listen(streamHandler: handler) }
                group.addTask { try await pair.client.connect() }
                group.addTask {
                    _ = try? await pair.client.completeOneEchoRPC(
                        descriptor: LifecycleMethods.parking)
                }

                try await waitUntil("the first handler to be parked") { handlerStarted.isSet }
                pair.server.beginGracefulShutdown()

                // A second peer, dialling the same (still live) listener.
                let latecomer = try pair.server.connectingClient()
                let latecomerConnect = Task { try await latecomer.connect() }
                do {
                    _ = try await latecomer.completeOneEchoRPC(payload: lifecyclePayload(40))
                    XCTFail("a draining server must not serve a peer that arrived after the drain")
                } catch let error as RPCError {
                    XCTAssertEqual(
                        error.code, .unavailable,
                        "a refused connection must reach the dialling client as .unavailable, "
                            + "never as a trap or a hang: \(error.message)")
                }
                latecomerConnect.cancel()
                _ = try? await latecomerConnect.value

                release.open()
                try await waitUntil("the first handler to finish") { handlerFinished.isSet }

                pair.client.beginGracefulShutdown()
                try await group.waitForAll()
            }
        }
    }

    // =======================================================================================
    // MARK: - L7's remaining shutdown arms
    // =======================================================================================

    /// A second, concurrent `connect()` throws instead of clobbering the first's continuation, and
    /// a `connect()` made *after* the shutdown returns immediately instead of parking on a drain
    /// that already happened.
    ///
    /// Both arms in one test because they are one property of one state machine, and because the
    /// first one's failure mode used to be a leaked continuation ("SWIFT TASK CONTINUATION MISUSE")
    /// with the original caller parked forever -- i.e. a hang, which needs the bound either way.
    func testASecondConnectThrowsAndAPostShutdownConnectReturnsAtOnce() throws {
        try runBounded("connect()'s refusals", timeout: 20) {
            let pair = try XPCTransportPair.make()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pair.server.listen(streamHandler: RawSeamHandlers.echoing()) }
                group.addTask { try await pair.client.connect() }

                // Ordering: the first `connect()` must be parked before the second is made.
                // One completed RPC is proof enough -- it cannot happen before `connect()` runs
                // in any ordering that matters, and it also establishes the connection.
                _ = try await pair.client.completeOneEchoRPC(payload: lifecyclePayload(50))

                do {
                    try await pair.client.connect()
                    XCTFail("a second concurrent connect() must not be allowed to park")
                } catch let error as RPCError {
                    XCTAssertEqual(error.code, .failedPrecondition)
                    XCTAssertTrue(
                        error.message.contains("already running"),
                        "the refusal must name the concurrency, not something else: "
                            + error.message)
                }

                pair.client.beginGracefulShutdown()
                pair.server.beginGracefulShutdown()
                try await group.waitForAll()
            }

            // After the shutdown: returns, promptly, and does not throw. `runBounded`'s timeout is
            // what would catch a park-forever regression.
            try await pair.client.connect()
        }
    }

    /// A second, concurrent `listen()` throws, and a `listen()` after the shutdown returns
    /// immediately.
    func testASecondListenThrowsAndAPostShutdownListenReturnsAtOnce() throws {
        try runBounded("listen()'s refusals", timeout: 20) {
            let pair = try XPCTransportPair.make()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pair.server.listen(streamHandler: RawSeamHandlers.echoing()) }
                group.addTask { try await pair.client.connect() }

                _ = try await pair.client.completeOneEchoRPC(payload: lifecyclePayload(60))

                do {
                    try await pair.server.listen(streamHandler: RawSeamHandlers.echoing())
                    XCTFail("a second concurrent listen() must be refused")
                } catch let error as RPCError {
                    XCTAssertEqual(error.code, .failedPrecondition)
                    XCTAssertTrue(
                        error.message.contains("already running"),
                        "the refusal must name the concurrency: " + error.message)
                }

                pair.client.beginGracefulShutdown()
                pair.server.beginGracefulShutdown()
                try await group.waitForAll()
            }

            try await pair.server.listen(streamHandler: RawSeamHandlers.echoing())
        }
    }

    /// A second `beginGracefulShutdown()` on either side is safe, **and its failure mode is a
    /// trap, not an assertion**: resuming one `CheckedContinuation` twice traps the process, so a
    /// double-resume regression crashes this test rather than failing it. That is the point of
    /// running it at all.
    ///
    /// Four shutdowns, in the order most likely to find a bug: client twice, then server twice,
    /// then both again after `connect()`/`listen()` have already returned.
    ///
    /// # Measured: the idempotence guard is not what makes this safe
    ///
    /// Deleting `beginGracefulShutdown`'s `guard !state.isShuttingDown` leaves this green (mutation
    /// M10): the second call finds `.shutDown`, whose `parked` is `nil` by construction, so there is
    /// no continuation left to resume twice. What prevents the double resume is that **the phase
    /// transition empties the slot**, and the guard is defence in depth. Forcing an actual double
    /// resume (M10b, `continuation.resume()` twice in `complete(_:)`) does kill the process --
    /// `SWIFT TASK CONTINUATION MISUSE: connect() tried to resume its continuation more than once`
    /// -- which is the evidence that this test would catch the real regression.
    func testDoubleAndTripleGracefulShutdownIsSafeOnBothSides() throws {
        try runBounded("repeated shutdown", timeout: 20) {
            let pair = try XPCTransportPair.make()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pair.server.listen(streamHandler: RawSeamHandlers.echoing()) }
                group.addTask { try await pair.client.connect() }

                _ = try await pair.client.completeOneEchoRPC(payload: lifecyclePayload(70))

                pair.client.beginGracefulShutdown()
                pair.client.beginGracefulShutdown()
                pair.server.beginGracefulShutdown()
                pair.server.beginGracefulShutdown()
                try await group.waitForAll()
            }

            pair.client.beginGracefulShutdown()
            pair.server.beginGracefulShutdown()
        }
    }

    /// Cancelling `listen()`'s own task unblocks it and it **returns rather than throwing**.
    ///
    /// Not a style point: `GRPCServer.serve()` wraps *any* error thrown by `listen` in a
    /// `RuntimeError(code: .transportError, ...)`, so a `CancellationError` here would be reported
    /// to the application as a transport failure for what was an ordinary cancelled shutdown.
    /// The client's `connect()` has the same obligation and
    /// ``ClientLifecycleTests/testCancellingConnectFailsInFlightStreams()`` asserts it there.
    func testCancellingListenReturnsRatherThanThrowing() throws {
        try runBounded("cancelling listen()", timeout: 20) {
            let pair = try XPCTransportPair.make()

            let listenTask = Task {
                try await pair.server.listen(streamHandler: RawSeamHandlers.echoing())
            }
            let connectTask = Task { try await pair.client.connect() }

            _ = try await pair.client.completeOneEchoRPC(payload: lifecyclePayload(80))

            listenTask.cancel()
            do {
                try await listenTask.value
            } catch {
                XCTFail("listen() threw on cancellation instead of returning: \(error)")
            }

            pair.client.beginGracefulShutdown()
            connectTask.cancel()
            _ = try? await connectTask.value
        }
    }
}
