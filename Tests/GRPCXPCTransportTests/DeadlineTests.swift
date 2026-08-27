import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

/// L12: **exactly one timer per deadline-bearing RPC**, owned by the stream's registry entry,
/// cancelled by every path that removes the entry.
///
/// The old build armed a second, `Task.sleep`-based timer in `withStream` on top of the core's
/// `DispatchSourceTimer`. That is gone, and these three tests are what the claim rests on: the
/// deadline fires and is *reported as a deadline* on both sides; a call that completes inside its
/// deadline leaves nothing behind; and an absurd deadline saturates rather than trapping.
///
/// # Measured while writing this file: **the server's stream is torn down by a race, and it is not
/// the race the code comments imply**
///
/// Both ends arm a timer from the same deadline -- the client in `openStream`, the server in
/// `openInbound` from the wire's `grpc-timeout`. The *caller's* view is unambiguous: the client's
/// timer is armed strictly earlier (the server's cannot be armed until the blob carrying the
/// `openStream` op has crossed) and both are set to the same interval, so the client's always fires
/// first and the caller always sees `.deadlineExceeded`.
///
/// **Which mechanism ends the *server's* stream, however, is a coin flip.** Let `L` be the one-way
/// delivery of the `openStream` blob and `L'` the one-way delivery of the client's `cancel`. The
/// server's own timer fires at `T0 + L + D`; the client's `cancel` arrives at `T0 + D + L'`. The
/// deadline `D` cancels out, so the winner is whichever of `L` and `L'` is smaller -- two
/// comparable one-way blob deliveries on the same substrate. `GRPCWireHeaders`' round-*up* cannot
/// break the tie either: for any deadline under 100 s the wire value is exact to the microsecond.
///
/// Measured: **20 runs, the server's own timer won 20/20** -- so the code comment on
/// `installDeadline` ("the client's own timer ... normally fires first and is what surfaces
/// `.deadlineExceeded` to the caller") is right about the caller and, on this substrate, wrong about
/// the server. It is a comment, not behaviour, and either winner is correct: both name the deadline
/// and both tear exactly one stream down. It is recorded because a reader would otherwise expect
/// the `cancel` op.
///
/// The consequence for this file: ``testTheDeadlineFiresAndTheCallerSeesDeadlineExceeded()``
/// asserts the caller's code strictly and the *peer's* teardown by the property both mechanisms
/// share -- that it names the deadline. The `cancel`-op path is proven separately and
/// deterministically, with no competing timer, by
/// ``TeardownTests/testAClientAbandoningACallReachesThePeerAsACancelOp()``.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class DeadlineTests: XCTestCase {

    /// Long enough that the RPC is genuinely established and parked before it fires, short enough
    /// to leave the bounded runner plenty of room.
    private static let deadline: Duration = .milliseconds(250)

    /// `CallOptions` is a struct with a `var`, and a `var` captured by a `@Sendable` closure is a
    /// Swift 6 error -- so the value is assembled here and captured as a `let`.
    private static func options(timeout: Duration) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = timeout
        return options
    }

    // =======================================================================================
    // MARK: - The deadline fires, and both sides say so
    // =======================================================================================

    /// `CallOptions.timeout` expiring must surface to the caller as `.deadlineExceeded` **and**
    /// reach the peer as a `cancel` naming the deadline.
    ///
    /// Both halves are asserted, but not with the same strictness, and the file comment explains
    /// why:
    ///
    /// * **the caller's code is asserted exactly.** `.deadlineExceeded` comes from the local
    ///   `removeStream(failingInboundWith:)` and nothing else in this transport produces it, so
    ///   seeing it proves the deadline timer fired rather than the connection breaking.
    /// * **the peer's teardown is asserted by what both mechanisms have in common** -- that its
    ///   reason names the deadline. Either the client's `cancel` op arrived (`.cancelled` +
    ///   `"deadline exceeded"`) or the server's own wire-derived timer fired first
    ///   (`.deadlineExceeded` + `"exceeded its deadline"`); measured, it is always the latter on
    ///   this substrate. Asserting one of the two would be asserting a race.
    ///
    /// The message is asserted, not only the code: a code-only assertion on the peer would pass on
    /// peer death or an abandoned call, neither of which has anything to do with a deadline.
    ///
    /// The handler parks and writes nothing at all, so the only thing that can end this call is the
    /// deadline. If it never fired, `runBounded` would report the hang.
    func testTheDeadlineFiresAndTheCallerSeesDeadlineExceeded() throws {
        try runBounded("deadline fires", timeout: 20) {
            let sawMessage = Observed(false)
            let endedWith = Observed<String?>(nil)
            let handler = RawSeamHandlers.parking(sawMessage: sawMessage, endedWith: endedWith)

            let options = Self.options(timeout: Self.deadline)

            let caught: (any Error)? = try await XPCPairHarness.withTransports(
                streamHandler: handler, expectingRoughTeardown: true
            ) { pair in
                do {
                    _ = try await pair.client.withStream(
                        descriptor: LifecycleMethods.parking, options: options
                    ) { stream, _ in
                        try await stream.outbound.write(.metadata([:]))
                        try await stream.outbound.write(.message(lifecyclePayload(100)))
                        // Never half-closed and never answered: the deadline is the only exit.
                        for try await _ in stream.inbound {}
                    }
                    return nil
                } catch {
                    return error
                }
            }

            let rpcError = caught as? RPCError
            XCTAssertEqual(
                rpcError?.code, .deadlineExceeded,
                "the caller must see .deadlineExceeded, not whatever the teardown produced: "
                    + String(describing: caught))
            XCTAssertTrue(
                rpcError?.message.contains("exceeded its deadline") ?? false,
                "the error must be the deadline timer's: \(String(describing: rpcError?.message))")

            XCTAssertTrue(
                sawMessage.isSet,
                "the handler never received the request, so the peer-side assertion below would "
                    + "be about a stream that was never really open")
            try await waitUntil("the peer's stream to be torn down by the deadline's cancel") {
                endedWith.value != nil
            }
            let peerSaw = endedWith.value ?? ""
            XCTAssertTrue(
                peerSaw.hasPrefix("cancelled|") || peerSaw.hasPrefix("deadlineExceeded|"),
                "the peer's stream must be torn down by the deadline -- as an inbound `cancel` "
                    + "(§O5.3's abort op, `.cancelled`) or by its own wire-derived timer "
                    + "(`.deadlineExceeded`). Anything else means it ended for an unrelated "
                    + "reason: \(peerSaw)")
            XCTAssertTrue(
                peerSaw.contains("deadline exceeded") || peerSaw.contains("exceeded its deadline"),
                "the peer's teardown must name the deadline. Neither code alone is enough: "
                    + ".cancelled is also what an abandoned call produces, and a code-only "
                    + "assertion would pass on peer death: \(peerSaw)")
        }
    }

    // =======================================================================================
    // MARK: - A completed call leaves nothing behind
    // =======================================================================================

    /// A call that completes well inside its deadline must leave **no table entry**, and the
    /// connection must still be healthy after the deadline instant has passed.
    ///
    /// `liveStreamCount == 0` is the observable the backlog prescribes, and the reason is worth
    /// stating: **a timer cannot outlive its entry.** The `DispatchSourceTimer` is stored *in* the
    /// `StreamEntry` and every path that removes the entry -- `removeStream`, `failAll` -- cancels
    /// it first, so "no entry" is exactly "no armed timer". There is no separate counter to read,
    /// and there deliberately is not one.
    ///
    /// What this test cannot observe, stated so it is not mistaken for a gap in the assertions: a
    /// **stale timer firing** would send nothing. Its handler calls `removeStream(id, …)`, which
    /// takes the entry out of the table under the lock and returns `false` if it is absent --
    /// before building any op. So "no late `cancel` op on the wire" is true by construction on this
    /// code path and is not independently observable from the peer. The second RPC below is what
    /// covers the residual risk behaviourally: it is issued *after* the first call's deadline
    /// instant has passed, so anything the expired timer did to the connection would break it.
    ///
    /// # Measured: retirement of a completed stream is doubly covered
    ///
    /// The backlog proposed "skip `clientCallFinished` and require a residual entry" as this test's
    /// discriminating mutation. It does not discriminate (M14): a *cleanly completed* stream is
    /// already retired by its terminator path, and `clientCallFinished` finds nothing -- which is
    /// what its own doc comment says. Removing the terminator path instead also fails to
    /// discriminate (M14b), because then the `defer` covers it. Removing **both** does
    /// (M14c: `liveStreamCount == 1`). So the assertion is sound and the redundancy is the design.
    func testACompletedCallLeavesNoDeadlineTimerBehind() throws {
        try runBounded("completed call leaves no timer", timeout: 20) {
            let pair = try InspectableXPCPair.make(label: "deadlineCleanup")

            let options = Self.options(timeout: Self.deadline)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await pair.server.listen(streamHandler: RawSeamHandlers.echoing())
                }
                group.addTask { try await pair.client.connect() }

                let first = try await pair.client.completeOneEchoRPC(
                    payload: lifecyclePayload(110), options: options)
                XCTAssertEqual(
                    first, ["echo:" + String(decoding: Array(lifecyclePayload(110)), as: UTF8.self)],
                    "the call must complete on its merits before anything is claimed about its "
                        + "timer")
                XCTAssertEqual(
                    pair.clientCore.liveStreamCount, 0,
                    "a completed call left a table entry behind -- and with it an armed deadline "
                        + "timer, since the timer is owned by the entry")

                // Past the deadline instant of the call that already finished.
                try await Task.sleep(for: Self.deadline + .milliseconds(150))

                XCTAssertEqual(
                    pair.clientCore.liveStreamCount, 0,
                    "a table entry appeared after the deadline of a completed call")

                // A second call on the same connection, issued after the expired deadline: if the
                // stale timer had disturbed anything, this is what notices.
                let second = try await pair.client.completeOneEchoRPC(
                    payload: lifecyclePayload(111), options: options)
                XCTAssertEqual(
                    second,
                    ["echo:" + String(decoding: Array(lifecyclePayload(111)), as: UTF8.self)],
                    "the connection was damaged by the first call's expired deadline")
                XCTAssertEqual(pair.clientCore.liveStreamCount, 0)

                pair.client.beginGracefulShutdown()
                pair.server.beginGracefulShutdown()
                try await group.waitForAll()
            }
        }
    }

    // =======================================================================================
    // MARK: - An absurd deadline saturates rather than trapping
    // =======================================================================================

    /// A deadline far past what `DispatchTime` can express must **saturate**, not trap.
    ///
    /// `RPCTransportCore.dispatchInterval(for:)` clamps to `.nanoseconds(Int.max)`, and the value
    /// that reaches libdispatch is therefore `DispatchTime.now() + .nanoseconds(Int.max)` -- which
    /// was *believed* to saturate to `DISPATCH_TIME_FOREVER` and had never been confirmed. This
    /// confirms it, twice over, because two different inputs reach the same clamp by different
    /// routes:
    ///
    /// * `.nanoseconds(Int64.max)` -- no overflow anywhere in `dispatchInterval`; the sum lands on
    ///   `Int64.max` exactly and `Int(clamping:)` is the identity. This is the literal
    ///   `.nanoseconds(Int.max)` case the brief names.
    /// * `.seconds(Int64.max)` -- `seconds * 1_000_000_000` overflows, so the *early return* branch
    ///   produces `.nanoseconds(Int.max)` instead. A test using only one of the two would leave the
    ///   other branch unrun.
    ///
    /// Both then complete an ordinary RPC, which proves three separate things did not go wrong: the
    /// arithmetic did not trap, `GRPCWireHeaders.encodeTimeout` saturated instead of overflowing
    /// (an 8-digit `TimeoutValue` cannot hold either value, so it clamps at the coarsest unit), and
    /// the timer did not fire immediately -- a deadline that had wrapped to a *past* instant would
    /// kill the call before it could complete, which is the failure mode this is really guarding.
    ///
    /// A trap here is a process death, so this test's real assertion is that the suite is still
    /// running when it returns.
    ///
    /// # Measured: `DispatchTime + interval` saturates for more than one interval shape
    ///
    /// Replacing the clamp with `.seconds(Int(clamping: components.seconds))` -- i.e. handing
    /// libdispatch `Int.max` *seconds* -- also does not trap (mutation M15), so this test does not
    /// discriminate the clamp's particular form; the platform saturates either way. What it does
    /// discriminate is a clamp that lands in the *past* or at zero: `.nanoseconds(0)` (M15b) fires
    /// the deadline immediately and the RPC dies with
    /// `unavailable: "stream 1 is no longer open on this connection"`. That is the failure mode
    /// worth guarding -- an absurd deadline must mean "never", never "now".
    func testAnAbsurdlyLargeDeadlineSaturatesRatherThanTrapping() throws {
        for (label, timeout) in [
            ("nanoseconds(Int64.max)", Duration.nanoseconds(Int64.max)),
            ("seconds(Int64.max)", Duration.seconds(Int64.max)),
        ] {
            try runBounded("absurd deadline: \(label)", timeout: 20) {
                let options = Self.options(timeout: timeout)

                let bodies = try await XPCPairHarness.withTransports(
                    streamHandler: RawSeamHandlers.echoing()
                ) { pair in
                    try await pair.client.completeOneEchoRPC(
                        payload: lifecyclePayload(120), options: options)
                }
                XCTAssertEqual(
                    bodies,
                    ["echo:" + String(decoding: Array(lifecyclePayload(120)), as: UTF8.self)],
                    "an RPC with a \(label) deadline must complete normally: a saturating clamp "
                        + "means 'effectively never', and a wrapped one would have fired at once")
            }
        }
    }
}
