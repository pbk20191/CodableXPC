import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

/// `XPCClientTransport.connect()`'s lifecycle machine, and **the three tests this slice exists
/// for**.
///
/// Three fixes in `XPCClientTransport.swift` were written, reviewed twice and never run, because
/// nothing in the suite could observe them. Each of the first three tests below is the observation
/// its fix was missing, and each was checked the only way that settles the question:
///
/// | test | fixed in | must fail against | observed |
/// |---|---|---|---|
/// | ``testGracefulShutdownWaitsForInFlightRPCsBeforeConnectReturns()`` | `651eb30` | `d34ba16` | fails there, passes at `HEAD` |
/// | ``testCancellingConnectFailsInFlightStreams()`` | `651eb30` | `d34ba16` | fails there, passes at `HEAD` |
/// | ``testConnectReleasesTheXPCSessionOnReturn()`` | `500fcbb` | `651eb30` | fails there, passes at `HEAD` |
///
/// The before/after check *is* this file's L9 mutation, and it is the strongest kind available: a
/// hand-written mutation proves a test notices *some* change, while the real prior commit proves it
/// notices **the exact defect the fix was for**.
///
/// None of these can use ``XPCPairHarness/withTransports(streamHandler:expectingRoughTeardown:_:)``:
/// it runs `connect()` inside its own task group and shuts the pair down on the way out, so a test
/// whose subject is *when `connect()` returns* has to own the group. They use
/// ``XPCTransportPair/make()`` and drive both halves by hand.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class ClientLifecycleTests: XCTestCase {

    // =======================================================================================
    // MARK: - Case 38: the drain is a real barrier
    // =======================================================================================

    /// `beginGracefulShutdown()` must **not** release `connect()` while an RPC is still in flight.
    ///
    /// `ClientTransport.connect()`'s contract is *"the function exits when all open streams have
    /// been closed and new connections are no longer required"*, and `GRPCClient.runConnections()`
    /// is documented to return *"once `beginGracefulShutdown()` has been called and all in-flight
    /// RPCs have finished executing"*. Before `651eb30` this transport resumed the parked
    /// `connect()` the instant a shutdown was requested, which turns `runConnections()` into a
    /// false drain barrier: `await runConnections(); exit(0)` in an XPC service would have killed
    /// live RPCs.
    ///
    /// The shape, and every part of it is load-bearing:
    ///
    /// 1. a call is started and **parked** -- the handler has read the whole request and is waiting
    ///    on a gate this test holds, so the RPC is genuinely mid-flight rather than merely started;
    /// 2. `beginGracefulShutdown()`;
    /// 3. **the negative assertion** -- after a settle window three orders of magnitude longer than
    ///    a whole pair's lifetime, `connect()` must still be parked. This is the assertion that
    ///    fails against `d34ba16`;
    /// 4. the gate opens, the handler replies, the call completes;
    /// 5. `connect()` returns -- so the barrier is a barrier and not a deadlock. Without (5) a
    ///    `connect()` that simply never returned would also pass (3).
    ///
    /// The reply payload is asserted too, so a call that failed instead of completing cannot make
    /// (5) pass by the wrong route.
    func testGracefulShutdownWaitsForInFlightRPCsBeforeConnectReturns() throws {
        try runBounded("case 38: graceful drain waits", timeout: 20) {
            let pair = try XPCTransportPair.make()

            let handlerStarted = Observed(false)
            let handlerFinished = Observed(false)
            let release = OneShotGate()
            let handler = RawSeamHandlers.releasable(
                started: handlerStarted, release: release, finished: handlerFinished)

            let connectReturned = Observed(false)
            let callOutcome = Observed<Result<[String], any Error>?>(nil)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pair.server.listen(streamHandler: handler) }
                group.addTask {
                    try await pair.client.connect()
                    connectReturned.set()
                }
                group.addTask {
                    do {
                        let bodies = try await pair.client.completeOneEchoRPC(
                            descriptor: LifecycleMethods.parking)
                        callOutcome.mutate { $0 = .success(bodies) }
                    } catch {
                        callOutcome.mutate { $0 = .failure(error) }
                    }
                }

                // (1) The RPC is in flight: the handler has drained the request and is parked.
                try await waitUntil("the handler to have read the request") { handlerStarted.isSet }

                // (2)
                pair.client.beginGracefulShutdown()

                // (3) The assertion this test exists for. Sleeping rather than polling on purpose:
                // the property is "nothing happened", and the only way to observe that is to wait.
                try await Task.sleep(for: negativeAssertionSettleWindow)
                XCTAssertFalse(
                    connectReturned.isSet,
                    "connect() returned while an RPC was still in flight: beginGracefulShutdown() "
                        + "released the drain barrier instead of waiting for it. This is the "
                        + "contract breach fixed in 651eb30.")
                XCTAssertNil(
                    callOutcome.value,
                    "the in-flight call ended before the test released it -- the drain failed the "
                        + "call rather than draining it, so assertion (3) above proved nothing")

                // (4)
                release.open()

                // (5)
                try await waitUntil("connect() to return once the last call finished") {
                    connectReturned.isSet
                }

                pair.server.beginGracefulShutdown()
                try await group.waitForAll()
            }

            XCTAssertTrue(
                handlerFinished.isSet, "the drained handler did not run to completion")
            switch callOutcome.value {
            case .success(let bodies):
                XCTAssertEqual(
                    bodies, [String(decoding: Array(lifecyclePayload(999)), as: UTF8.self)],
                    "the drained call completed but did not carry the handler's reply")
            case .failure(let error):
                XCTFail("the drained call failed instead of completing: \(error)")
            case nil:
                XCTFail("the drained call never finished")
            }
        }
    }

    // =======================================================================================
    // MARK: - Case 39: cancelling connect() is the forceful lever
    // =======================================================================================

    /// Cancelling `connect()`'s task must **fail every in-flight stream**, not merely unpark
    /// `connect()`.
    ///
    /// `beginGracefulShutdown()`'s own documentation names this as *the* forceful lever -- "if you
    /// want to forcefully cancel all active streams then cancel the task running `connect()`" --
    /// and the reference implementation finishes every stream there. Before `651eb30` this
    /// transport's `onCancel` did nothing but resume the continuation, so an in-flight call was
    /// left suspended on a connection nobody was going to service: the failure mode is a **hang**,
    /// which is exactly why it survived two reviews and why this test is bounded.
    ///
    /// The call runs in an **unstructured `Task`** deliberately. A structured child of the same
    /// group as `connect()` would be cancelled by the runtime along with it, and the test would
    /// then pass against the broken code for a reason that has nothing to do with the transport.
    /// An unstructured task does not inherit cancellation, so the only thing that can end this
    /// call is the transport failing its stream.
    func testCancellingConnectFailsInFlightStreams() throws {
        try runBounded("case 39: cancelling connect fails streams", timeout: 20) {
            let pair = try XPCTransportPair.make()

            let handlerSawMessage = Observed(false)
            let handlerEndedWith = Observed<String?>(nil)
            let handler = RawSeamHandlers.parking(
                sawMessage: handlerSawMessage, endedWith: handlerEndedWith)

            let listenTask = Task { try await pair.server.listen(streamHandler: handler) }
            let connectTask = Task { try await pair.client.connect() }

            // Unstructured: nothing here may cancel this call except the transport itself.
            let callTask = Task { () -> Result<Void, any Error> in
                do {
                    try await pair.client.withStream(
                        descriptor: LifecycleMethods.parking, options: .defaults
                    ) { stream, _ in
                        try await stream.outbound.write(.metadata([:]))
                        try await stream.outbound.write(.message(lifecyclePayload(2)))
                        // Never half-closed, and the handler writes nothing, so this suspends
                        // until the transport ends it one way or another.
                        for try await _ in stream.inbound {}
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }

            try await waitUntil("the handler to have received the request message") {
                handlerSawMessage.isSet
            }

            // The forceful lever.
            connectTask.cancel()

            // If the fix is absent, `callTask` never completes and the bounded runner reports the
            // hang. That is the discrimination: `d34ba16` cannot get past this line.
            let outcome = await callTask.value

            switch outcome {
            case .success:
                XCTFail(
                    "the in-flight call completed successfully after connect() was cancelled -- "
                        + "the stream was never failed")
            case .failure(let error):
                let rpcError = error as? RPCError
                XCTAssertEqual(
                    rpcError?.code, .unavailable,
                    "cancelling connect() must fail in-flight streams with .unavailable; got "
                        + "\(error)")
                XCTAssertTrue(
                    rpcError?.message.contains("connect() task was cancelled") ?? false,
                    "the failure must be the one connect()'s cancellation handler produces, not a "
                        + "coincidental .unavailable from somewhere else: \(String(describing: rpcError?.message))")
            }

            // `connect()` returns rather than throwing on cancellation -- `runConnections()` wraps
            // any thrown error, cancellation included, in a `.transportError`.
            do {
                try await connectTask.value
            } catch {
                XCTFail("connect() threw on cancellation instead of returning: \(error)")
            }

            pair.server.beginGracefulShutdown()
            _ = try? await listenTask.value
        }
    }

    // =======================================================================================
    // MARK: - Case 40: connect()'s tail releases the XPC session
    // =======================================================================================

    /// A completed drain must **cancel the XPC session**, and it must do so *while the transport is
    /// still alive*.
    ///
    /// That last clause is the whole test. `XPCPipe.deinit` cancels the session too, so a version
    /// of this test that dropped the transport first would pass against the broken code and prove
    /// nothing. Round 2 (`651eb30`) claimed in four separate comments that cancellation reached the
    /// mux's teardown; it did not -- `core.failAll(_:)` fails streams and does not touch the pipe,
    /// and `grep 'core\.close'` over the file returned zero call sites. `500fcbb` put the close in
    /// `connect()`'s tail, the one point both exits pass through.
    ///
    /// # Why this test needs ``InspectableXPCPair``
    ///
    /// The observable is *the pipe*, and `XPCClientTransport.core` (and `RPCTransportCore.pipe`)
    /// are private -- so the client half is built by hand from the same two calls
    /// `XPCServerTransport.connectingClient()` makes. ``InspectableXPCPair`` carries that, and its
    /// doc comment carries the hazard-by-hazard argument for why doing so is safe.
    ///
    /// The assertion is `pipe.send(_:)`'s phase guard, whose message (`"is not running"`) is
    /// produced **only** by `cancel()` having run. A send that failed because the far end went away
    /// reports a different message ("the XPC connection is no longer available"), so this cannot
    /// pass on a dead peer instead of a cancelled session.
    func testConnectReleasesTheXPCSessionOnReturn() throws {
        try runBounded("case 40: connect() closes the session", timeout: 20) {
            let pair = try InspectableXPCPair.make(label: "case40")
            let server = pair.server
            let client = pair.client
            let core = pair.clientCore
            let pipe = pair.clientPipe

            let connectReturned = Observed(false)
            let handler = RawSeamHandlers.echoing()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await server.listen(streamHandler: handler) }
                group.addTask {
                    try await client.connect()
                    connectReturned.set()
                }

                // One real RPC, so the session is genuinely live and the listener's
                // incoming-session closure has run: a test that asserted a *cancelled* session
                // without first proving the session ever worked would be vacuous.
                let bodies = try await client.completeOneEchoRPC(payload: lifecyclePayload(3))
                XCTAssertEqual(
                    bodies, ["echo:" + String(decoding: Array(lifecyclePayload(3)), as: UTF8.self)],
                    "the session must be proven live before it is asserted dead")

                // A graceful drain with nothing in flight: `connect()` is parked, `liveCalls == 0`,
                // so the shutdown resumes it and its tail is what closes.
                client.beginGracefulShutdown()
                try await waitUntil("connect() to return after the drain") {
                    connectReturned.isSet
                }

                // **The assertion, with the transport, the core and the pipe all still alive.**
                var sendError: (any Error)?
                do {
                    try pipe.send(lifecyclePayload(4))
                } catch {
                    sendError = error
                }
                let rpcError = sendError as? RPCError
                XCTAssertEqual(
                    rpcError?.code, .unavailable,
                    "after connect() returned, the pipe must refuse to send: the XPC session was "
                        + "never cancelled. This is the leak fixed in 500fcbb.")
                XCTAssertTrue(
                    rpcError?.message.contains("is not running") ?? false,
                    "the refusal must come from the pipe's own phase guard (i.e. cancel() ran), "
                        + "not from a send that failed because the peer went away: "
                        + "\(String(describing: rpcError?.message))")

                // Keeps the three of them alive across the assertion above. Without this the
                // optimiser is free to release them earlier, and `deinit` would cancel the session
                // for us -- which is precisely the confound this test is built to exclude.
                withExtendedLifetime(client) {}
                withExtendedLifetime(core) {}
                withExtendedLifetime(pipe) {}

                server.beginGracefulShutdown()
                try await group.waitForAll()
            }
        }
    }
}
