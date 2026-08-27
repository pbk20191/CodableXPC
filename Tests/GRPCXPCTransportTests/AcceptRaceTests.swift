import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

/// **Case 37**, and the only test in this slice whose failure mode is a process death rather than a
/// failed assertion.
///
/// # This test found a Critical, and the Critical is fixed -- so it runs
///
/// It was committed behind an `XCTSkip` because its failure mode kills the whole test process. The
/// history below is kept verbatim, because the *reasoning* that let three reviews clear the defect
/// is the part worth not repeating.
///
/// `Acceptor.accept(_:)` used to decide, build, publish and return with its lock taken **twice**. A
/// `beginGracefulShutdown()` landing between the two locks took an `!admitted` arm whose comment
/// read:
///
/// > The connection is kept (releasing it here would cancel a session whose accept window is still
/// > open) and put straight into a drain instead: `beginDraining` sends `goAway` and finishes the
/// > core's own accept sequence, but never cancels the pipe, so it is safe in this window.
///
/// Both clauses were true and the conclusion did not follow. `beginDraining()` **sends** --
/// `sendControl([.goAway(lastStreamID:)])` -- and `xpc_session_send_message` on an accepted session
/// whose accept `Decision` has not yet been returned to libxpc is `_xpc_api_misuse`. The process
/// dies. Nothing anywhere had established that *sending* in that window is illegal; the disposal
/// matrix enumerated which **disposals** trap, and everyone inferred that a non-disposal must
/// therefore be fine.
///
/// **The fix, and why it is not just a moved call.** Measuring the alternatives showed that the
/// window is worse than anyone had assumed: a send or a cancel hopped onto the connection's own
/// queue from inside the accept closure traps (matrix rows A7/A10), and so does one performed by
/// another thread the instant the closure *returns* (A8/A9). **No instant the caller can name is
/// safe.** So `accept` now does the admission check, the build, the publish and the yield in **one**
/// critical section -- which deletes the `!admitted` state rather than relocating its work -- and
/// any connection whose accept window is not yet *provably* closed is held untouched in a separate
/// `pending` table that no teardown path may act on. The proof is the first message libxpc delivers
/// on the session (rows A11/A12, 200 runs each, no trap), surfaced as
/// `XPCPipe.onFirstDelivery(_:)`.
///
/// Measured, from the crash report of this very test (`EXC_BREAKPOINT` / `SIGTRAP`, exit 133):
///
/// ```
/// _xpc_api_misuse                              <- libxpc.dylib
/// xpc_session_send_message                     <- libxpc.dylib
/// XPCSession.send(message:)                    <- libswiftXPC.dylib
/// XPCPipe.send(_:)
/// RPCTransportCore.sendEncoded(_:)
/// RPCTransportCore.sendControl(_:)
/// RPCTransportCore.beginDraining()
/// XPCServerTransport.Acceptor.accept(_:)       <- the `!admitted` arm
/// closure #1 in static XPCServerTransport.anonymous()
/// ___xpc_listener_setup_connection_handlers_block_invoke <- libxpc.dylib
/// ```
///
/// Isolated from the transport entirely, as a platform fact, by row **A5** of the out-of-process
/// disposal matrix: sending inside the incoming-session closure exits 133, and sending immediately
/// *after* the `Decision` (row A6) is safe. `XPCPipe`'s disposal matrix documented that
/// *cancelling* in that window is illegal; **nothing anywhere said that sending is**, which is why
/// three reviews did not catch it.
///
/// The reproduction rate measured here was 1 in ~5–15 attempts of the sweep -- it failed within a
/// second -- which is what makes this suite running clean meaningful rather than merely quiet.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class AcceptRaceTests: XCTestCase {

    /// Races run: one fresh listener, one fresh dial and one fresh drain each.
    private static let attempts = 80

    /// Nanoseconds added per attempt, so the sweep spans 0 – 200 µs.
    private static let stepNanoseconds: UInt64 = 2_500

    /// Busy-waits `nanoseconds`, **on a Dispatch thread, never on the test's own**.
    ///
    /// Two measurements forced this shape:
    ///
    /// * `Task.sleep` is far too coarse. A 20 µs-step `Task.sleep` sweep produced 39 clean serves
    ///   and one pre-admission refusal and never landed in between -- a suspension's real latency
    ///   swamps the interval being swept.
    /// * spinning on the test's own cooperative thread starves the very task whose progress is
    ///   being raced: the drain then won **240/240** and nothing was ever served.
    private static func spin(nanoseconds: UInt64) {
        guard nanoseconds > 0 else { return }
        let target = DispatchTime.now().uptimeNanoseconds + nanoseconds
        while DispatchTime.now().uptimeNanoseconds < target {}
    }

    /// A session admitted as the drain begins must be **drained, not dropped**.
    ///
    /// # What this can and cannot assert, stated before the assertions
    ///
    /// The `!admitted` arm is **not distinguishable from outside the transport**, and pretending
    /// otherwise would be the mistake slice 1 caught in its own metadata test (a test whose
    /// assertion could not fail). Both that arm and an ordinary admit-then-drain leave the
    /// connection's core alive and `localDraining`, so both answer the queued `openStream` op with
    /// the same `status(.unavailable, "the server is draining and is not accepting new streams")`.
    /// Nothing a client can see separates them -- because by design nothing about the connection
    /// differs.
    ///
    /// So what this measures is the property the arm's comment actually claims, which is a *safety*
    /// property: **racing a drain against an inbound connection does not kill the process.** The
    /// assertions are
    ///
    /// * the process is still here -- implicit, and the reason the real body of this test is the
    ///   `attempts` races above the assertions rather than the assertions themselves. A cancel into
    ///   an open accept window is an unrecoverable `EXC_BREAKPOINT`;
    /// * every outcome is accounted for: a success, or a refusal this transport is known to
    ///   produce. An `internalError` or a `precondition` message shows up here, and a hang shows up
    ///   as the bounded runner's timeout;
    /// * the sweep **straddles** the race -- at least one peer refused *and* at least one served
    ///   across the run. Without this, a sweep that had drifted entirely to one side of the window
    ///   would pass while racing nothing at all, which is precisely the kind of test this project
    ///   does not want.
    func testASessionAdmittedAsDrainingBeginsIsDrainedNotDropped() throws {
        let served = Observed(0)
        let drainingRefusals = Observed(0)
        let refused = Observed(0)
        let unexpected = Observed<[String]>([])

        for attempt in 0..<Self.attempts {
            try runBounded("accept/drain race, attempt \(attempt)", timeout: 20) {
                let server = try XPCServerTransport.anonymous()
                let listenTask = Task {
                    try await server.listen(streamHandler: RawSeamHandlers.echoing())
                }

                // WARM-UP
                let warm = try server.connectingClient()
                let warmConnect = Task { try await warm.connect() }
                _ = try await warm.completeOneEchoRPC(payload: lifecyclePayload(299))

                let client = try server.connectingClient()
                let connectTask = Task { try await client.connect() }

                // The first blob is what wakes the listener's incoming-session closure.
                let callTask = Task { () -> (any Error)? in
                    do {
                        _ = try await client.completeOneEchoRPC(payload: lifecyclePayload(300))
                        return nil
                    } catch {
                        return error
                    }
                }

                let drainFired = OneShotGate()
                let delay = Self.stepNanoseconds * UInt64(attempt)
                DispatchQueue.global().async {
                    Self.spin(nanoseconds: delay)
                    server.beginGracefulShutdown()
                    drainFired.open()
                }

                switch await callTask.value {
                case nil:
                    served.mutate { $0 += 1 }
                case let error as RPCError where error.code == .unavailable:
                    if error.message.contains("the server is draining") {
                        drainingRefusals.mutate { $0 += 1 }
                    } else {
                        refused.mutate { $0 += 1 }
                    }
                case let error as RPCError where error.code == .failedPrecondition:
                    refused.mutate { $0 += 1 }
                case let error as RPCError:
                    unexpected.append("\(error.code): \(error.message)")
                case .some(let error):
                    unexpected.append("\(type(of: error)): \(error)")
                }

                // The drain must have happened before the teardown below, or a late
                // `beginGracefulShutdown` would run against an already-cancelled listener.
                await drainFired.wait()

                warm.beginGracefulShutdown()
                warmConnect.cancel()
                _ = try? await warmConnect.value
                client.beginGracefulShutdown()
                connectTask.cancel()
                _ = try? await connectTask.value
                _ = try? await listenTask.value
            }
        }

        XCTAssertEqual(
            unexpected.value, [],
            "a raced peer failed for a reason that is neither a refusal, a drain nor a success -- "
                + "which is what a mishandled accept window looks like short of a trap")
        XCTAssertGreaterThanOrEqual(
            served.value, 1,
            "no peer was served across the whole sweep, so the drain always won and the race was "
                + "never run (draining: \(drainingRefusals.value), refused: \(refused.value))")
        XCTAssertGreaterThanOrEqual(
            drainingRefusals.value + refused.value, 1,
            "no peer was turned away across the whole sweep, so the drain never raced anything "
                + "(served: \(served.value))")
    }
}
