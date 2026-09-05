import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

/// The forceful side of the lifecycle: a `cancel` op, and **peer death**.
///
/// Contract line 9 is one sentence -- peer death fails every stream with `.unavailable` and wakes
/// every parked flow-control waiter -- and it has four separable claims, one test each:
///
/// * it fails the streams, with `.unavailable`;
/// * it wakes a writer parked on a **window**, which no stream-level failure reaches if the writer
///   is parked on the *connection* window;
/// * it fires **exactly once**;
/// * it never fires for one's own `cancel()`.
///
/// The last two are measured at the `XPCPipe` layer, because there is no transport-level observable
/// for either: `RPCTransportCore.peerDied()` is private, and `failAll` is idempotent, so a second
/// firing would leave no trace above the pipe. The probe is a **dialled** pipe with a counting
/// `onPeerDeath`, which is allowed and safe -- see the note on
/// ``testPeerDeathFiresExactlyOnceAndNeverForOnesOwnCancel()``. No second *accept* path is built
/// anywhere in this file.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class TeardownTests: XCTestCase {

    // =======================================================================================
    // MARK: - A cancel op crosses the wire and carries its reason
    // =======================================================================================

    /// A client that abandons a call must reach the peer as a `cancel` op, firing the handler's
    /// `ServerContext.cancellation` handle.
    ///
    /// This is the deterministic proof of the mechanism ``DeadlineTests`` cannot isolate: there is
    /// no deadline here, so no server-side timer competes, and nothing in the window between the
    /// abandonment and the assertion can cancel an RPC except the `cancel` op itself -- the
    /// connection is up, neither side is draining, and no deadline exists. `withStream`'s
    /// `defer { core.clientCallFinished(id) }` is what sends it: the *presence of a table entry* at
    /// that moment is the definition of "the call did not complete", so a closure that simply
    /// returns early is an abandonment.
    ///
    /// # Measured: the peer's inbound ends **cleanly**, and the handle is the only signal
    ///
    /// The first version of this test asserted that the handler's inbound threw `.cancelled`
    /// carrying the client's reason text. It does not, and the reason is structural rather than a
    /// bug. `withStream` ends with an **unconditional** `await stream.outbound.finish()` -- "the
    /// opened stream is closed after the closure is finished" is its documented contract, and
    /// `GRPCInProcessTransport.Client.withStream` does the identical thing on its throwing path --
    /// so the peer receives `halfClose` *before* the `cancel`. `halfClose` ends the server's
    /// inbound legitimately; the `cancel` that follows finds the continuation already finished, so
    /// its error is dropped and its **reason is not observable at the raw seam at all**.
    ///
    /// What the `cancel` still does is fire the `cancellationObserver`, which
    /// `XPCServerTransport.run` bound to the `RPCCancellationHandle`. So:
    ///
    /// * `inbound-ended` is asserted as the *expected* outcome, not tolerated as an unknown;
    /// * the handle firing is the assertion that the `cancel` op crossed at all. Nothing before
    ///   this had exercised that wiring.
    ///
    /// The consequence for a raw-seam handler -- that reading only `stream.inbound` cannot
    /// distinguish "the client finished its request" from "the client aborted" -- is recorded in
    /// the task report as an observation. It matches the reference transport, and the gRPC runtime
    /// above uses the handle (`withRPCCancellationHandler`), so it is not visible through
    /// `GRPCServer`.
    func testAClientAbandoningACallFiresThePeersCancellationHandle() throws {
        try runBounded("abandoned call fires the peer's handle", timeout: 20) {
            let sawMessage = Observed(false)
            let endedWith = Observed<String?>(nil)
            let handleWasCancelled = Observed(false)

            let handler: RawSeamHandler = { stream, context in
                do {
                    for try await part in stream.inbound {
                        if case .message = part { sawMessage.set() }
                    }
                    endedWith.mutate { $0 = "inbound-ended" }
                } catch let error as RPCError {
                    endedWith.mutate { $0 = "\(error.code)|\(error.message)" }
                } catch {
                    endedWith.mutate { $0 = "\(type(of: error))" }
                }
                // Suspends until the RPC is cancelled -- the handle's own async property, so no
                // polling and no race with the order in which `removeStream`'s two effects land.
                // If the `cancel` op never arrives this never resumes, the flag stays false, and
                // the wait below reports it.
                try? await context.cancellation.cancelled
                if context.cancellation.isCancelled { handleWasCancelled.set() }
            }

            // **Every wait happens inside the harness body.** Measured while writing this test:
            // `withTransports`' teardown cancels the client's XPC session within microseconds of
            // the body returning, and a blob already handed to libxpc is *not* delivered past that
            // cancel -- the handler never even saw the request. A test that observes the peer after
            // the body has returned observes nothing.
            try await XPCPairHarness.withTransports(
                streamHandler: handler, expectingRoughTeardown: true
            ) { pair in
                // Writes a message, never half-closes explicitly, and returns. The stream is
                // therefore still in the table when `withStream`'s `defer` runs, which is what
                // makes this an abandonment rather than a completion.
                try await pair.client.withStream(
                    descriptor: LifecycleMethods.parking, options: .defaults
                ) { stream, _ in
                    try await stream.outbound.write(.metadata([:]))
                    try await stream.outbound.write(.message(lifecyclePayload(200)))
                }

                try await waitUntil("the handler to receive the request") { sawMessage.isSet }
                try await waitUntil("the peer's cancellation handle to fire") {
                    handleWasCancelled.isSet
                }
            }

            XCTAssertEqual(
                endedWith.value, "inbound-ended",
                "the peer's inbound must end cleanly: `withStream`'s mandatory finish() sends "
                    + "halfClose before the cancel, so the cancel's error is dropped. A different "
                    + "value here means the ordering changed and this test's premise no longer "
                    + "holds.")
            XCTAssertTrue(
                handleWasCancelled.isSet,
                "the abandoned call's `cancel` op never reached the peer's cancellation handle: "
                    + "the setCancellationObserver wiring in XPCServerTransport.run is not "
                    + "connected")
        }
    }

    // =======================================================================================
    // MARK: - Peer death fails every stream
    // =======================================================================================

    /// Peer death fails every open stream with `.unavailable`, and the server keeps serving.
    ///
    /// # How the peer is killed, and why not by cancelling `connect()`
    ///
    /// The far end is hung up at the substrate: `clientPipe.cancel()`, which cancels the XPC
    /// session and nothing else. That is what a peer process dying looks like from the server's
    /// side, and it is the only way to produce it here.
    ///
    /// The obvious alternative -- cancel the client's `connect()` task -- was tried first and
    /// **does not test peer death**, for a reason worth recording: `failAll` empties the stream
    /// table, so when the aborted `withStream` unwinds, `clientCallFinished` finds no entry and
    /// sends no `cancel`, while the unconditional `await stream.outbound.finish()` on the way out
    /// still emits `halfClose`. The server therefore sees a **clean end of request**, its handler's
    /// inbound ends normally, and the stream is retired before the session dies. Measured: the
    /// handler reported `inbound-ended`. That is reported as a finding in the task report; it is
    /// not what this test is about.
    ///
    /// # What "retires the connection" can and cannot be asserted as
    ///
    /// `Acceptor.retire(_:)` is `private`, and so is the dictionary it removes from, so the call
    /// itself is not observable from a test. What *is* observable brackets it tightly:
    /// `retire(core)` is the **unconditional next statement** after the per-connection child task's
    /// inner accept loop ends, so
    ///
    /// * the handler on the dead connection ended (asserted: `.unavailable`), therefore
    /// * its stream group drained, therefore the inner `for await … in core.acceptedStreams`
    ///   loop ended, therefore `retire(core)` ran;
    /// * and `listen()` is **still running**, asserted by serving a *second* client on the same
    ///   listener end to end -- the property a long-lived server actually needs, and the thing that
    ///   would break if peer death took the whole `listen()` down with it.
    ///
    /// The remaining unobservable is whether the dictionary entry was removed (a slow leak of one
    /// dead core per disconnected peer). It is reported as untested rather than claimed.
    func testPeerDeathFailsEveryStreamAndTheServerKeepsServing() throws {
        try runBounded("peer death fails streams", timeout: 20) {
            let pair = try InspectableXPCPair.make(label: "peerDeath")

            let parkingSaw = Observed(false)
            let parkingEndedWith = Observed<String?>(nil)
            let echoSaw = Observed(false)

            // One handler, two behaviours, routed on the method -- not on call order, which would
            // be an assumption about scheduling rather than a fact about the request.
            let handler: RawSeamHandler = { stream, context in
                let isParking = context.descriptor == LifecycleMethods.parking
                do {
                    for try await part in stream.inbound {
                        if case .message = part {
                            if isParking { parkingSaw.set() } else { echoSaw.set() }
                        }
                    }
                    if !isParking {
                        try await stream.outbound.write(.message(lifecyclePayload(999)))
                        try await stream.outbound.write(
                            .status(Status(code: .ok, message: ""), [:]))
                        await stream.outbound.finish()
                    }
                    if isParking { parkingEndedWith.mutate { $0 = "inbound-ended" } }
                } catch let error as RPCError {
                    if isParking {
                        parkingEndedWith.mutate { $0 = "\(error.code)|\(error.message)" }
                    }
                } catch {
                    if isParking { parkingEndedWith.mutate { $0 = "\(type(of: error))" } }
                }
            }

            let listenTask = Task { try await pair.server.listen(streamHandler: handler) }
            let connectTask = Task { try await pair.client.connect() }

            // An RPC parked on the server, so peer death has a live stream to fail.
            let callTask = Task {
                try? await pair.client.withStream(
                    descriptor: LifecycleMethods.parking, options: .defaults
                ) { stream, _ in
                    try await stream.outbound.write(.metadata([:]))
                    try await stream.outbound.write(.message(lifecyclePayload(210)))
                    for try await _ in stream.inbound {}
                }
            }
            try await waitUntil("the parked handler to receive the request") { parkingSaw.isSet }

            // The peer dies.
            pair.clientPipe.cancel()

            try await waitUntil("the server's handler to be failed by peer death") {
                parkingEndedWith.value != nil
            }
            let serverSaw = parkingEndedWith.value ?? ""
            XCTAssertTrue(
                serverSaw.hasPrefix("unavailable|"),
                "peer death must fail every open stream with .unavailable: " + serverSaw)
            XCTAssertTrue(
                serverSaw.contains("no longer available"),
                "the failure must be peer death's, not a drain's, a halfClose's or a cancel's: "
                    + serverSaw)

            // The client's own call is still parked -- a pipe deliberately does not report its own
            // `cancel()` as peer death -- so `failAll` has to come from somewhere, and cancelling
            // `connect()` is the lever that provides it.
            connectTask.cancel()
            _ = try? await connectTask.value
            _ = await callTask.value

            // `listen()` survived: a second peer is served end to end on the same listener.
            let second = try pair.server.connectingClient()
            let secondConnect = Task { try await second.connect() }
            let replies = try await second.completeOneEchoRPC(payload: lifecyclePayload(211))
            XCTAssertEqual(
                replies, [String(decoding: Array(lifecyclePayload(999)), as: UTF8.self)],
                "listen() must survive one connection's peer death and keep serving")
            XCTAssertTrue(echoSaw.isSet)

            second.beginGracefulShutdown()
            _ = try? await secondConnect.value
            pair.server.beginGracefulShutdown()
            _ = try? await listenTask.value
        }
    }

    // =======================================================================================
    // MARK: - Peer death wakes a writer parked on a window
    // =======================================================================================

    /// Peer death must wake a writer **parked on a flow-control window**, including one parked on
    /// the *connection* window.
    ///
    /// This is contract line 9's second clause and the one with a real failure mode: `failAll`
    /// fails each stream's own `sendWindow` *and* `connectionSendWindow`, and a sender parked on
    /// the connection window is not reachable through any stream's window -- so failing only the
    /// per-stream windows leaves it suspended forever, waiting for credit that can never arrive.
    /// The symptom is a permanent hang, which is why this test is bounded and why a bound is not
    /// optional here.
    ///
    /// # Getting a writer genuinely parked
    ///
    /// The initial window is 65 535 bytes and the handler below **never reads**, so it emits no
    /// `credit`. The writer therefore sends the first 65 535 bytes' worth and parks on the next
    /// message. Two 40 000-byte messages are enough: the first fits, the second cannot, and the
    /// reservation order is stream-then-connection, so it parks on the *stream* window with the
    /// connection window already partly consumed. A third message on a *second* stream is what
    /// parks on the connection window -- both are opened here, so whichever window is the one that
    /// would be missed, a waiter is sitting on it.
    ///
    /// Sizing past the window is deliberate and is the only place this slice touches flow control;
    /// the *enforcement* of the window, and its 65 535/65 536 boundary, belong to slice 3.
    func testPeerDeathWakesWritersParkedOnBothWindows() throws {
        try runBounded("peer death wakes parked writers", timeout: 20) {
            let pair = try XPCTransportPair.make()

            let handlersEntered = Observed(0)
            // Never reads, never writes, never returns until it is torn down: no `credit` op ever
            // leaves this server, which is what makes the client's window run dry.
            let stall = OneShotGate()
            let handler: RawSeamHandler = { _, _ in
                _ = handlersEntered.mutate { count -> Int in
                    count += 1
                    return count
                }
                await stall.wait()
            }

            let listenTask = Task { try await pair.server.listen(streamHandler: handler) }
            let connectTask = Task { try await pair.client.connect() }

            let big = GRPCSwiftData([UInt8](repeating: 0x5A, count: 40_000))
            let outcomes = Observed<[String]>([])
            let parked = Observed(0)

            func writer(_ index: Int) -> Task<Void, Never> {
                Task {
                    do {
                        try await pair.client.withStream(
                            descriptor: LifecycleMethods.parking, options: .defaults
                        ) { stream, _ in
                            try await stream.outbound.write(.metadata([:]))
                            // Keeps writing until a window refuses to grant. The counter is bumped
                            // before each write, so the test can tell "parked" from "not started".
                            for _ in 0..<8 {
                                _ = parked.mutate { count -> Int in
                                    count += 1
                                    return count
                                }
                                try await stream.outbound.write(.message(big))
                            }
                        }
                        outcomes.append("stream \(index): completed")
                    } catch let error as RPCError {
                        outcomes.append("stream \(index): \(error.code)")
                    } catch {
                        outcomes.append("stream \(index): \(type(of: error))")
                    }
                }
            }

            let writers = [writer(1), writer(2)]

            // Both streams are accepted and both writers have got as far as they can. 8 × 40 000
            // bytes per stream against a 65 535-byte window means neither can finish, so once the
            // count stops rising they are parked -- on the stream window, the connection window, or
            // both.
            try await waitUntil("both streams to be accepted") { handlersEntered.value == 2 }
            try await waitUntil("the writers to run out of credit") { parked.value >= 3 }
            try await Task.sleep(for: negativeAssertionSettleWindow)
            XCTAssertTrue(
                outcomes.value.isEmpty,
                "a writer finished before the window ran dry, so nothing was parked and this test "
                    + "would prove nothing: \(outcomes.value)")

            // Kill the peer.
            connectTask.cancel()

            // The assertion: both writers are released. A window that was not failed leaves its
            // waiter suspended forever and `runBounded` reports the hang.
            for task in writers { await task.value }
            _ = try? await connectTask.value

            let observed = outcomes.value.sorted()
            XCTAssertEqual(observed.count, 2, "not every parked writer was released: \(observed)")
            for entry in observed {
                XCTAssertTrue(
                    entry.hasSuffix(": unavailable"),
                    "a writer woken by a connection teardown must see .unavailable: " + entry)
            }

            stall.open()
            pair.server.beginGracefulShutdown()
            _ = try? await listenTask.value
        }
    }

    // =======================================================================================
    // MARK: - Peer death fires exactly once, and never for one's own cancel
    // =======================================================================================

    /// `onPeerDeath` fires **exactly once** when the far end goes away, and **never** when this side
    /// hangs up.
    ///
    /// # Why this one is measured at the pipe
    ///
    /// There is no transport-level observable for either claim. `RPCTransportCore.peerDied()` is
    /// private, and all it does is `failAll`, which is idempotent -- so a second firing changes
    /// nothing a test above the pipe could see. Counting requires an `onPeerDeath` of one's own.
    ///
    /// That is allowed here and only here: this is a **dialled** pipe, built by
    /// `XPCPipe.connecting(to:queue:building:)`, with no `RPCTransportCore` behind it -- so nothing
    /// else has installed handlers on it, and `XPCPipe`'s set-once `precondition` (the hazard that
    /// forbids calling `onReceive`/`onPeerDeath` on a *core's* pipe) is satisfied rather than
    /// tripped. There is no accept path here: the far end is `XPCServerTransport.anonymous()`,
    /// whose `Acceptor` remains the only accept path in the package.
    ///
    /// The peer is killed by **releasing the server transport**, whose `deinit` closes every
    /// connection and then cancels the listener. That is also the only way to observe the
    /// `deinit`-driven teardown from outside, and it pins the ordering `deinit` documents
    /// (connections first, listener second).
    func testPeerDeathFiresExactlyOnceAndNeverForOnesOwnCancel() throws {
        try runBounded("peer death fires once", timeout: 20) {
            let deaths = Observed(0)
            let received = Observed(0)

            let pipe: XPCPipe
            do {
                let server = try XPCServerTransport.anonymous()
                guard let endpoint = server.endpoint else {
                    XCTFail("an anonymous XPCServerTransport must have an endpoint")
                    return
                }
                let queue = DispatchSerialQueue(
                    label: "GRPCXPCTransportTests.peerDeathCount.client")
                pipe = try XPCPipe.connecting(to: endpoint, queue: queue) { pipe in
                    pipe.onReceive { _ in
                        _ = received.mutate { count -> Int in
                            count += 1
                            return count
                        }
                    }
                    pipe.onPeerDeath {
                        _ = deaths.mutate { count -> Int in
                            count += 1
                            return count
                        }
                    }
                }

                // One blob, so the listener's incoming-session closure runs and a real session
                // is accepted -- without it there is nothing on the far end to lose, and the
                // accepted-session teardown path would go unexercised.
                //
                // **A valid op, not arbitrary bytes.** `goAway(lastStreamID: 0)` is the cheapest
                // op with no side effect worth naming: it sets `peerDraining` on the server's core
                // and nothing else. Sending undecodable bytes would make the server fail the
                // connection and cancel its own session, which is *also* a peer death for us --
                // and would leave the test unable to say which teardown it had measured.
                try pipe.send(
                    pipe.prepare(CompactWireCodec().encode([.goAway(lastStreamID: 0)])))
                XCTAssertEqual(
                    deaths.value, 0,
                    "the far end died before the test killed it")
                // Nothing observable marks "the session has been accepted" from this side (the
                // server sends nothing in reply, by design -- §O4 uses explicit `credit` ops, so
                // the XPC reply channel is unused in both directions). A settle window, ~1000x a
                // whole pair's lifetime, is what stands in for it.
                try await Task.sleep(for: negativeAssertionSettleWindow)
                XCTAssertEqual(received.value, 0, "the server replied, which it never does")

                // Released on leaving this scope: `deinit` closes every connection, then cancels
                // the listener -- the ordering `XPCServerTransport.deinit` documents.
                withExtendedLifetime(server) {}
            }

            // The far end is gone by now, one way or the other.
            try await waitUntil("onPeerDeath to fire") { deaths.value >= 1 }
            XCTAssertEqual(
                deaths.value, 1,
                "onPeerDeath must fire exactly once, however many teardown events libxpc reports")

            // Our own hang-up must not be reported as the peer dying: `cancel()` clears the
            // handlers under the lock *before* it calls `session.cancel`, and libxpc invokes the
            // cancellation handler for our own cancel too.
            pipe.cancel()
            pipe.cancel()
            try await Task.sleep(for: negativeAssertionSettleWindow)
            XCTAssertEqual(
                deaths.value, 1,
                "cancel() reported this side's own hang-up as peer death")
        }
    }

    /// A pipe must **never** report its own `cancel()` as peer death, with the far end still very
    /// much alive.
    ///
    /// The negative control for the test above. The server is held alive throughout, so a firing
    /// `onPeerDeath` can only have come from our own cancel.
    ///
    /// # Measured: the clear-*before*-cancel ordering is not what makes this work
    ///
    /// `XPCPipe.cancel()` clears the handlers and only then calls `session.cancel(reason:)`, and its
    /// comment presents that order as the reason a local hang-up is not reported. Swapping the two
    /// lines leaves this test green (mutation M19): `Delivery.peerDied()` dispatches the handler
    /// through `queue.async`, so the lookup happens after `shutDown()` either way. The ordering is
    /// belt-and-braces; **the clearing itself is load-bearing** -- leaving `onPeerDeath` installed
    /// in `Delivery.shutDown()` (M19b) makes this test fail with `1` death instead of `0`.
    func testAPipeNeverReportsItsOwnCancelAsPeerDeath() throws {
        try runBounded("own cancel is not peer death", timeout: 20) {
            let deaths = Observed(0)
            let server = try XPCServerTransport.anonymous()
            guard let endpoint = server.endpoint else {
                XCTFail("an anonymous XPCServerTransport must have an endpoint")
                return
            }
            let queue = DispatchSerialQueue(label: "GRPCXPCTransportTests.ownCancel.client")
            let pipe = try XPCPipe.connecting(to: endpoint, queue: queue) { pipe in
                pipe.onPeerDeath {
                    _ = deaths.mutate { count -> Int in
                        count += 1
                        return count
                    }
                }
            }

            pipe.cancel()
            try await Task.sleep(for: negativeAssertionSettleWindow)
            XCTAssertEqual(
                deaths.value, 0,
                "a pipe reported its own cancel() as peer death -- libxpc invokes the session's "
                    + "cancellation handler for a local cancel too, and cancel() must clear the "
                    + "handlers before it calls it")

            // The server outlives the assertion, so nothing above can be attributed to it going
            // away.
            withExtendedLifetime(server) {}
            withExtendedLifetime(pipe) {}
        }
    }

    // =======================================================================================
    // MARK: - A failure on an inbound sequence is terminal
    // =======================================================================================

    /// The unit-level floor under every teardown test above: once ``InboundContinuation`` has
    /// carried a failure, **nothing follows it**.
    ///
    /// # Why this needs its own test rather than riding on the integration tests
    ///
    /// The inbound parts used to travel as `AsyncThrowingStream<Part, any Error>`, where
    /// `finish(throwing:)` made this true by construction. They now travel as
    /// `AsyncStream<Result<Part, RPCError>>`, where the error is an ordinary element and the buffer
    /// is perfectly willing to accept more after it. `InboundContinuation` is what puts the
    /// guarantee back, and the tests above would not notice if it stopped holding: they assert that
    /// a consumer *sees* the failure, which a stream that also delivered trailing junk after it
    /// would still satisfy.
    ///
    /// Both halves of the invariant are asserted from the consumer's side, which is the only side
    /// that matters:
    ///
    /// * a `yield` after the failure is dropped -- **not** trapped, deliberately, because `deliver`
    ///   races `removeStream` off the pipe's queue and that interleaving is legal (see the type's
    ///   own documentation);
    /// * a second `finish(throwing:)` cannot append a second failure or overwrite the first.
    ///
    /// The parts already buffered *before* the failure must still arrive -- that is the property
    /// the `Result`-as-element shape gets for free, and asserting it here is what stops a future
    /// "make failure terminal" change from over-reaching into discarding the buffer.
    func testAFailureIsTheLastThingAnInboundSequenceDelivers() throws {
        try runBounded("a failure is terminal", timeout: 20) {
            let (stream, continuation) = InboundContinuation<RPCRequestPart<GRPCSwiftData>>
                .makeStream()

            let first = RPCError(code: .internalError, message: "the first and only failure")
            let second = RPCError(code: .unavailable, message: "a second failure, which must not "
                + "reach the consumer")

            continuation.yield(.metadata([:]))
            continuation.finish(throwing: first)
            // Everything from here on must be invisible to the consumer.
            continuation.yield(.message([1, 2, 3]))
            continuation.finish(throwing: second)
            continuation.finish()

            var delivered: [Result<RPCRequestPart<GRPCSwiftData>, RPCError>] = []
            for await element in stream { delivered.append(element) }

            XCTAssertEqual(
                delivered.count, 2,
                "the consumer must see exactly the part buffered before the failure and then the "
                    + "failure; got \(delivered.count) element(s)")

            guard delivered.count == 2 else { return }

            guard case .success(.metadata) = delivered[0] else {
                XCTFail(
                    "a part buffered before the failure must still be delivered -- the error is an "
                        + "element behind it in the same buffer, not a signal that races it")
                return
            }
            guard case .failure(let observed) = delivered[1] else {
                XCTFail("the failure must be the last element delivered")
                return
            }
            XCTAssertEqual(
                observed.code, first.code,
                "the *first* failure is the terminal one; a later finish(throwing:) must not "
                    + "replace it")
            XCTAssertEqual(observed.message, first.message)
        }
    }

    /// A clean end is terminal in the same way: a stream that has already finished normally cannot
    /// be given an error afterwards.
    ///
    /// This is the ordering `RPCTransportCore` actually relies on. `deliver(_:toStream:)` finishes
    /// the sequence the moment the decoder reports the remote end, and the `retireIfComplete(_:)`
    /// immediately after reaches `removeStream` -- which calls `finishInbound` again. If a late
    /// error could still be appended there, every cleanly completed RPC would be at the mercy of
    /// whatever the teardown path happened to be holding, and a handler that had already succeeded
    /// would see a cancellation.
    func testACleanEndCannotLaterBeTurnedIntoAFailure() throws {
        try runBounded("a clean end is terminal", timeout: 20) {
            let (stream, continuation) = InboundContinuation<RPCRequestPart<GRPCSwiftData>>
                .makeStream()

            continuation.yield(.metadata([:]))
            continuation.finish()
            continuation.finish(
                throwing: RPCError(code: .cancelled, message: "a late cancel, arriving after the "
                    + "stream had already completed cleanly"))

            var delivered: [Result<RPCRequestPart<GRPCSwiftData>, RPCError>] = []
            for await element in stream { delivered.append(element) }

            XCTAssertEqual(
                delivered.count, 1,
                "a cleanly ended sequence must deliver its buffered part and nothing else; got "
                    + "\(delivered.count) element(s)")
            guard case .success(.metadata) = delivered.first else {
                XCTFail("a clean end must not be retro-fitted with an error")
                return
            }
        }
    }
}
