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
/// # The caller's view is deterministic; **the peer's is a five-way race**, and this file says so
///
/// Both ends arm a timer from the same deadline -- the client in `openStream`, the server in
/// `openInbound` from the wire's `grpc-timeout`. The *caller's* view is unambiguous: the client's
/// timer is armed strictly earlier (the server's cannot be armed until the blob carrying the
/// `openStream` op has crossed) and both are set to the same interval, so the client's always fires
/// first and the caller always sees `.deadlineExceeded`. That is asserted strictly, and it is what
/// makes this a deadline test.
///
/// **What ends the *server's* stream is not determinate, and cannot be made so.** Once the client's
/// deadline has fired, five different things are racing to terminate the peer's inbound, and every
/// one of them is correct behaviour:
///
/// | # | route | what the handler observes |
/// |---|---|---|
/// | 1 | the server's own wire-derived deadline timer | `deadlineExceeded` + `"exceeded its deadline"` |
/// | 2 | the client's `cancel` op, from its `removeStream` | `cancelled` + `"deadline exceeded"` |
/// | 3 | the client's **mandatory `halfClose`** -- `withStream` ends with an unconditional `await stream.outbound.finish()` -- reaching the request decoder first | a **clean** end of inbound |
/// | 4 | peer death, once the harness cancels the client's session | `unavailable` + `"no longer available"` |
/// | 5 | the server's own teardown (`listen()`'s `closeAll`) | `unavailable` + `"closed locally"` |
///
/// Routes 1 and 2 differ by `L − δ − L'`, where `L` is the one-way delivery of the `openStream`
/// blob (which includes the whole cold accept path), `L'` the delivery of a steady-state blob, and
/// `δ` the client task's wake-up-and-send latency after its inbound is failed. **The deadline `D`
/// cancels out of that comparison entirely**, so the winner is decided by scheduling, not by the
/// deadline; and `GRPCWireHeaders`' round-*up* cannot break the tie, because for any deadline under
/// 100 s the wire value is exact to the microsecond. Route 3 is the same race one step further on:
/// the `cancel` (sent from the client's *pipe queue*, inside `removeStream`, immediately after
/// `finishInbound`) and the `halfClose` (sent from the client's *task*, once it has woken and
/// unwound into `withStream`'s tail) are two sends on two threads over one session, and libxpc
/// delivers them in whatever order it accepted them.
///
/// **Round 2 of this task existed because the assertion here enumerated only routes 1 and 2.** It
/// passed 20/20 unloaded, and failed roughly 1 run in 12 under full-target contention with
/// `inbound-ended` -- route 3. See §10 of the task report; the diagnosis, and the proof that route 3
/// is legitimate rather than a transport defect, are there. So the peer-side assertion now pins the
/// two properties that **are** load-independent -- the handler is not *stranded*, and it did not end
/// for a reason outside that table -- and deliberately does not pin *which* route won.
///
/// Nothing is lost by that. The `cancel`-op path with its reason intact is proven separately and
/// deterministically, with no competing timer, by
/// ``TeardownTests/testAClientAbandoningACallFiresThePeersCancellationHandle()``.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class DeadlineTests: XCTestCase {

    /// Long enough that the RPC is genuinely established and parked before it fires, short enough
    /// to leave the bounded runner plenty of room.
    private static let deadline: Duration = .milliseconds(250)

    /// Every prefix a *correct* peer-side termination can carry in this scenario, one per route in
    /// the table on this type. Written as an explicit list rather than as "anything at all" so the
    /// assertion still has teeth: an `internalError`, an `invalidArgument`, a `resourceExhausted`
    /// or a bare `CancellationError` at the peer would all fail it, and each of those *would* be a
    /// transport defect.
    ///
    /// `RawSeamHandlers.parking` reports `"<code>|<message>"` for a thrown `RPCError` and the
    /// literal `"inbound-ended"` for a clean end, so a prefix match on the code is the right shape.
    private static let legitimatePeerTerminations = [
        "deadlineExceeded|",  // 1: the server's own wire-derived timer
        "cancelled|",         // 2: the client's `cancel` op
        "inbound-ended",      // 3: the client's mandatory `halfClose` won the race
        "unavailable|",       // 4 and 5: peer death, or the server's own teardown
    ]

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
    /// Four assertions, three of them strict and load-independent, one deliberately tolerant:
    ///
    /// 1. **the caller's code, exactly.** `.deadlineExceeded` comes from the client's own
    ///    `removeStream(failingInboundWith:)` and nothing else in this transport produces it, so
    ///    seeing it -- with the timer's own message -- proves the deadline fired rather than the
    ///    connection breaking. This is what makes the case a deadline test at all.
    /// 2. **the request really crossed** (`sawMessage`), so the peer-side assertions are about a
    ///    stream that was genuinely open.
    /// 3. **the fired deadline retired its own entry**: `clientCore.liveStreamCount == 0`. A
    ///    deadline timer is owned by its `StreamEntry`, so no entry means no timer left armed --
    ///    the same observable ``testACompletedCallLeavesNoDeadlineTimerBehind()`` uses for a call
    ///    that *completed*, asserted here for one that *expired*. Deterministic: the caller's error
    ///    is that removal's own effect, so observing it means the removal has happened.
    /// 4. **the peer's handler terminated rather than being stranded**, and terminated for a reason
    ///    in the file comment's table. Which of the five routes won is **not** asserted -- that is
    ///    a scheduling race with no correct answer, and asserting it is what made round 1 of this
    ///    test flake at ~8 % under contention.
    ///
    /// The handler parks and writes nothing at all, so nothing but a teardown can end this call. If
    /// the deadline never fired, `runBounded` would report the hang.
    func testTheDeadlineFiresAndTheCallerSeesDeadlineExceeded() throws {
        try runBounded("deadline fires", timeout: 20) {
            let sawMessage = Observed(false)
            let endedWith = Observed<String?>(nil)
            let handler = RawSeamHandlers.parking(sawMessage: sawMessage, endedWith: endedWith)

            let options = Self.options(timeout: Self.deadline)

            // `InspectableXPCPair` rather than `withTransports`, for assertion 3: the client's
            // `RPCTransportCore` is private two layers down and `liveStreamCount` is the only
            // observable that says "the fired deadline retired its own entry".
            let pair = try InspectableXPCPair.make(label: "deadlineFires")

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pair.server.listen(streamHandler: handler) }
                group.addTask { try await pair.client.connect() }

                let caught: (any Error)?
                do {
                    _ = try await pair.client.withStream(
                        descriptor: LifecycleMethods.parking, options: options
                    ) { stream, _ in
                        try await stream.outbound.write(.metadata([:]))
                        try await stream.outbound.write(.message(lifecyclePayload(100)))
                        // Never half-closed by the closure and never answered: the deadline is the
                        // only exit. (`withStream`'s own tail then emits a `halfClose` regardless,
                        // which is route 3 of the file comment's table.)
                        for try await _ in stream.inbound {}
                    }
                    caught = nil
                } catch {
                    caught = error
                }

                // 1. The caller's view -- strict, and the reason this is a deadline test.
                let rpcError = caught as? RPCError
                XCTAssertEqual(
                    rpcError?.code, .deadlineExceeded,
                    "the caller must see .deadlineExceeded, not whatever the teardown produced: "
                        + String(describing: caught))
                XCTAssertTrue(
                    rpcError?.message.contains("exceeded its deadline") ?? false,
                    "the error must be the deadline timer's: "
                        + String(describing: rpcError?.message))

                // 2. The request really crossed.
                XCTAssertTrue(
                    sawMessage.isSet,
                    "the handler never received the request, so the peer-side assertion below "
                        + "would be about a stream that was never really open")

                // 3. The fired deadline retired its own entry, so no timer is left armed.
                XCTAssertEqual(
                    pair.clientCore.liveStreamCount, 0,
                    "an expired deadline left a table entry behind -- and with it an armed timer, "
                        + "since the timer is owned by the entry")

                // 4. The peer's handler is not stranded. This wait *is* the assertion; a deadline
                // that fired on the client and left the server's handler running forever is the
                // failure this catches, and it catches it as a named timeout.
                try await waitUntil("the peer's stream to terminate after the deadline fired") {
                    endedWith.value != nil
                }
                let peerSaw = endedWith.value ?? ""
                XCTAssertTrue(
                    Self.legitimatePeerTerminations.contains { peerSaw.hasPrefix($0) },
                    "the peer's stream ended for a reason outside the five legitimate routes in "
                        + "this file's table -- which is what a transport defect would look like "
                        + "here, since every correct route is enumerated: \(peerSaw)")

                pair.client.beginGracefulShutdown()
                pair.server.beginGracefulShutdown()
                try await group.waitForAll()
            }
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
