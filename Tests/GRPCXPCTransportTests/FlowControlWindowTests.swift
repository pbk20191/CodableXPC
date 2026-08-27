import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// `FlowControlWindow`, `WindowAccountant` and `FlowControl.charge(for:window:)` on their own, with
// no mux, no codec and no substrate. Task 3 shipped this file's subject with **no tests at all** --
// its §6 lists fourteen -- on the grounds that the properties were measured by throwaway probes
// that were then deleted. These are the load-bearing ones, plus the charge rule, which is the one
// definition both sides of the transport must call.
//
// Everything here is bounded (L8) by `runBounded`; the two stress cases get a larger budget than
// the default because they are stress cases, not because they are expected to be slow.

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class FlowControlWindowTests: XCTestCase {

    /// A distinguishable error for the `fail(_:)` paths, so an assertion cannot pass on some other
    /// error the window synthesised.
    private struct ProbeFailure: Error, Equatable {}

    // =======================================================================================
    // MARK: - L1: the grant/cancel race
    // =======================================================================================

    /// **The L1 regression test.** A grant racing a cancellation must never lose a byte.
    ///
    /// The previous design stored `granted` and `cancelled` as two independent flags and depended
    /// on the waiter testing them in the right order; a real session measured **1–14 permits lost
    /// per 3 000 races** before the fix. Bytes lost this way are invisible everywhere else on the
    /// type's surface until enough have leaked that the window wedges at zero and the stream stalls
    /// forever, which is exactly why `available`/`waiterCount` exist.
    ///
    /// # The invariant, and why it is the whole assertion
    ///
    /// Each round has exactly one byte in play. Whatever happens, that byte is in exactly one of
    /// two places when the round ends -- returned to the sender, or back in the window:
    ///
    /// ```
    /// reserved + window.available == 1        for every round, no exceptions
    /// ```
    ///
    /// A lost byte breaks it in one direction (`0 + 0`); a double-spend breaks it in the other
    /// (`1 + 1`). `waiterCount == 0` catches the third failure mode, a waiter resolved by neither.
    ///
    /// # Why it actually races
    ///
    /// `grant(1)` runs on this thread while `task.cancel()` runs on a global queue, and **neither
    /// waits for the waiter to park** -- the interesting window is between the reserving task
    /// taking its token and installing its continuation, and a test that waited for
    /// `waiterCount == 1` would never enter it. The count of rounds that genuinely cancelled is
    /// asserted below: **a race that never races proves nothing**, and this test would otherwise
    /// degrade silently into "3 000 uncontended grants" if the scheduler ever changed.
    func testAGrantCancelRaceNeverLosesBytes() throws {
        let rounds = 3_000

        struct Outcome: Sendable {
            var cancelled = 0
            var granted = 0
            var violations: [String] = []
        }

        let outcome = try runBounded("the grant/cancel race", timeout: 120) { () -> Outcome in
            var outcome = Outcome()

            for round in 0..<rounds {
                let window = FlowControlWindow(initial: 0)
                let task = Task.detached { try await window.reserve(upTo: 1) }

                // Two resolutions, two threads, no synchronisation between them. This is the race.
                DispatchQueue.global().async { task.cancel() }
                try window.grant(1)

                var reserved = 0
                switch await task.result {
                case .success(let bytes):
                    outcome.granted += 1
                    reserved = bytes
                    if bytes != 1 {
                        outcome.violations.append(
                            "round \(round): reserve returned \(bytes), must be exactly 1")
                    }
                case .failure(let error):
                    if error is CancellationError {
                        outcome.cancelled += 1
                    } else {
                        outcome.violations.append(
                            "round \(round): reserve threw \(type(of: error)) (\(error)); only "
                                + "CancellationError is legal here")
                    }
                }

                let available = window.available
                if reserved + available != 1 {
                    outcome.violations.append(
                        "round \(round): reserved \(reserved) + available \(available) != 1 -- "
                            + (reserved + available == 0
                                ? "a byte was LOST (this is L1)" : "a byte was DOUBLE-SPENT"))
                }
                if window.waiterCount != 0 {
                    outcome.violations.append(
                        "round \(round): \(window.waiterCount) waiter(s) left unresolved")
                }
                // Stop early rather than accumulate 3 000 copies of the same failure.
                if outcome.violations.count > 5 { break }
            }
            return outcome
        }

        XCTAssertEqual(
            outcome.violations, [],
            "the grant/cancel race lost or double-spent bytes; this is L1 and it is a stall "
                + "waiting to happen")

        // L9: the race must have actually raced. Task 3's probes measured ~22 % of rounds landing
        // in the take-token/park gap (1 134 and 1 108 out of 5 000). A floor of 30 in 3 000 is two
        // orders of magnitude below that and still rules out "the cancellation never won a single
        // round", which is the shape in which this test would stop testing anything.
        XCTAssertGreaterThanOrEqual(
            outcome.cancelled, 30,
            "only \(outcome.cancelled) of \(rounds) rounds were resolved by the cancellation, so "
                + "this test did not exercise the grant/cancel race at all -- it measured "
                + "\(outcome.granted) uncontended grants. Re-tune the race, do not lower this bound.")
        XCTAssertGreaterThanOrEqual(
            outcome.granted, 30,
            "only \(outcome.granted) of \(rounds) rounds were resolved by the grant; the race is "
                + "one-sided and the grant-wins direction is untested")
    }

    // =======================================================================================
    // MARK: - L2: peer-controlled arithmetic
    // =======================================================================================

    /// L2 and §O4's ceiling. `bytes` is peer input, and the previous design looped `0..<n` over it:
    /// one credit of `UInt32.max` spent a measured **450 seconds inside the mutex**, blocking every
    /// sender and the connection's own teardown, for the price of a single op.
    ///
    /// Three separate claims, because three separate things could break:
    ///
    /// 1. `grant(UInt32.max)` **throws** rather than wrapping or saturating;
    /// 2. it leaves the window **byte-for-byte unchanged** -- the check runs before `available` is
    ///    touched, so a rejected credit is not half-applied;
    /// 3. it is **O(1)**, asserted as wall-clock, which is the only way the 450-second failure mode
    ///    is observable at all.
    ///
    /// Then the boundary: a credit taking the window to exactly 2³¹−1 is legal and the very next
    /// byte is not.
    func testAHugeCreditIsRejectedInConstantTimeAndTheCeilingIsExact() throws {
        let window = FlowControlWindow(initial: 0)

        let clock = ContinuousClock()
        let start = clock.now
        var rejection: (any Error)?
        do {
            try window.grant(UInt32.max)
        } catch {
            rejection = error
        }
        let elapsed = clock.now - start
        XCTAssertEqual(
            (rejection as? RPCError)?.code, .internalError,
            "a credit above §O4's ceiling is a protocol error by the peer; got "
                + "\(rejection.map { "\($0)" } ?? "no error at all")")
        XCTAssertEqual(
            window.available, 0,
            "a rejected credit must leave the window exactly as it was; this one was half-applied")
        // The old design's equivalent took 450 s. Anything under a millisecond is O(1) by any
        // reading; 100 ms is a bound loose enough to survive a loaded CI machine and still three
        // and a half orders of magnitude short of a loop over 4 294 967 295.
        XCTAssertLessThan(
            elapsed, .milliseconds(100),
            "grant(UInt32.max) took \(elapsed); the peer's magnitude is driving a loop (L2)")

        // The ceiling is exact at the boundary, from both sides.
        XCTAssertNoThrow(try window.grant(UInt32(FlowControl.maxWindow)))
        XCTAssertEqual(window.available, FlowControl.maxWindow)
        XCTAssertThrowsError(try window.grant(1)) { error in
            XCTAssertEqual((error as? RPCError)?.code, .internalError)
        }
        XCTAssertEqual(
            window.available, FlowControl.maxWindow,
            "the one-byte overshoot must not have been banked")
    }

    // =======================================================================================
    // MARK: - release: the give-back, and what it deliberately does not check
    // =======================================================================================

    /// `release(_:)` is the give-back for a reservation that was taken and not sent, and it must
    /// **not** be validated against §O4's ceiling.
    ///
    /// That ceiling bounds what the *peer* may add. These bytes were already inside this window, so
    /// refusing them would destroy window rather than protect it -- and the case is reachable
    /// without any misbehaviour: the peer may credit up to the ceiling while a reservation is
    /// outstanding, and the give-back then lands on a window already at 2³¹−1. Behind a `try?`
    /// (which is what `grant` would have forced) those bytes would be silently destroyed.
    ///
    /// The test also pins the two documented non-behaviours in the same place, because both are
    /// things a future reader would otherwise be tempted to "fix":
    ///
    /// * the overshoot makes the **next** credit's rejection *conservative rather than diagnostic*
    ///   -- it may land on an honest credit, and that is the accepted trade;
    /// * **over-release is not detected.** `release` beyond what was reserved inflates the window.
    ///   Task 3 §5.1 decided that deliberately (a hot-path outstanding-bytes counter catches
    ///   nothing a caller-side `precondition` catches better); this case exists so the omission is
    ///   visible and deliberate rather than discovered.
    func testReleaseNeverValidatesAgainstTheCeiling() throws {
        try runBounded("release and the ceiling") {
            let window = FlowControlWindow(initial: 10)
            let reserved = try await window.reserve(upTo: 10)
            XCTAssertEqual(reserved, 10)
            XCTAssertEqual(window.available, 0)

            // The peer credits to the ceiling while the 10-byte reservation is still outstanding.
            try window.grant(UInt32(FlowControl.maxWindow))
            XCTAssertEqual(window.available, FlowControl.maxWindow)

            // The give-back. `grant` would have thrown here; `release` must not.
            window.release(reserved)
            XCTAssertEqual(
                window.available, FlowControl.maxWindow + 10,
                "a give-back must return every byte even when it pushes the window past §O4's "
                    + "peer-facing ceiling -- the ceiling bounds the peer, not us")

            // And the peer's next credit is still rejected. Conservative, not diagnostic: the
            // overshoot is ours.
            XCTAssertThrowsError(try window.grant(1))

            // release(0) is a no-op, not a wake-up and not an error.
            window.release(0)
            XCTAssertEqual(window.available, FlowControl.maxWindow + 10)
        }

        // Over-release is accepted and inflates the window. Pinned as documented non-behaviour.
        let loose = FlowControlWindow(initial: 100)
        loose.release(10_000)
        XCTAssertEqual(
            loose.available, 10_100,
            "Task 3 §5.1: over-release is a caller bug this type deliberately does not detect. If "
                + "this assertion ever fails because a check was added, that is a decision to "
                + "record, not a test to update silently.")

        // On a failed window the bytes are dropped, exactly as credit is.
        let dead = FlowControlWindow(initial: 0)
        dead.fail(ProbeFailure())
        dead.release(50)
        XCTAssertEqual(
            dead.available, 0,
            "a failed window is dead for good; nothing can reserve from it, so a give-back has "
                + "nowhere to go")
    }

    // =======================================================================================
    // MARK: - Cancellation before the park
    // =======================================================================================

    /// A `reserve` entered by a task that is **already** cancelled must throw, not park.
    ///
    /// It leans entirely on `withTaskCancellationHandler` running `onCancel` before the operation
    /// body when the task is already cancelled. Task 3's reviewer verified that holds today and
    /// noted that **nothing pins it** -- and if it ever changed, a cancelled sender would park
    /// forever on an empty window, which is a hang with no error and nothing to point at.
    ///
    /// The window is deliberately empty (`initial: 0`), so the fast path cannot serve the request
    /// and the only two possible outcomes are "throws" and "hangs". `runBounded` turns the second
    /// into a named failure rather than a stuck suite.
    ///
    /// Determinism, rather than a race: the task busy-waits on `Task.isCancelled` before it calls
    /// `reserve` at all, so `reserve` is provably entered post-cancellation on every run.
    func testReserveOnAnAlreadyCancelledTaskThrowsRatherThanParks() throws {
        try runBounded("reserve on a cancelled task", timeout: 10) {
            let window = FlowControlWindow(initial: 0)

            let task = Task.detached { () -> Int in
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
                return try await window.reserve(upTo: 1)
            }
            task.cancel()

            switch await task.result {
            case .success(let bytes):
                XCTFail(
                    "reserve returned \(bytes) from an empty window to an already-cancelled task")
            case .failure(let error):
                XCTAssertTrue(
                    error is CancellationError,
                    "expected CancellationError, got \(type(of: error)): \(error)")
            }

            XCTAssertEqual(
                window.waiterCount, 0,
                "a cancelled reservation must leave no waiter behind in the FIFO")
            XCTAssertEqual(
                window.available, 0,
                "nothing was granted, so nothing may have been added to the window")
        }
    }

    // =======================================================================================
    // MARK: - Reentrancy (L7's cheapest possible check)
    // =======================================================================================

    /// Calls `reserve`, `grant`, `release` and `fail` from the continuation a `grant` resumed.
    ///
    /// This is the cheapest possible check that **no resume ever migrates back under the lock**
    /// (L7): if one did, the first reentrant call here would deadlock instantly against a mutex the
    /// resuming thread still holds. There is no assertion that could report that -- the failure
    /// mode is a hang, which is why `runBounded` is the observation and the timeout is short.
    ///
    /// The sequence also pins two ordinary properties on the way past: a reentrant `reserve` is
    /// served from the credit the reentrant `grant` just added, and `fail` is sticky enough that
    /// the *next* `reserve` throws the same error rather than parking.
    func testReentrancyFromAResumedWaiter() throws {
        let log = try runBounded("reentrancy from a resumed waiter", timeout: 10) { () -> [String] in
            let window = FlowControlWindow(initial: 0)

            let task = Task.detached { () -> [String] in
                var log: [String] = []
                // Parks: the window is empty.
                log.append("first=\(try await window.reserve(upTo: 5))")
                // Everything from here runs in the continuation `grant` resumed.
                try window.grant(4)
                let second = try await window.reserve(upTo: 4)
                log.append("second=\(second)")
                window.release(second)
                window.fail(ProbeFailure())
                do {
                    _ = try await window.reserve(upTo: 1)
                    log.append("third=returned")
                } catch {
                    log.append("third=\(type(of: error))")
                }
                return log
            }

            try await waitUntil("the waiter parked") { window.waiterCount == 1 }
            try window.grant(5)
            return try await task.value
        }

        XCTAssertEqual(
            log,
            ["first=5", "second=4", "third=ProbeFailure"],
            "a reentrant reserve/grant/release/fail from a resumed waiter must all complete, and "
                + "fail must be sticky")
    }

    // =======================================================================================
    // MARK: - The charge rule (§O4/§O5)
    // =======================================================================================

    /// `FlowControl.charge(for:window:)` is the **single definition both sides must call**, and a
    /// mismatch drifts the window silently until a stall with nothing to point at.
    ///
    /// This case is the arithmetic half: it round-trips a set of payload lengths chosen to sit on
    /// every boundary the formula has -- the floor, the clamp, and the values either side of the
    /// window -- through **reserve on the send side and credit on the receive side**, and asserts
    /// the window comes back to exactly where it started. Any divergence between the two clamps
    /// leaves it somewhere else.
    ///
    /// The mux half -- that production code really calls this function on both paths rather than
    /// two agreeing copies -- is
    /// `ReceiveWindowTests.testTheCreditEmittedForAnOversizeMessageIsTheChargeNotTheLength`, which
    /// reads the `credit` op the core actually put on the wire.
    func testTheChargeRuleIsOneDefinitionBothSidesCall() throws {
        // 0 exercises the floor; 65 535 the clamp's boundary; 65 536 and above the clamp itself.
        let lengths = [0, 1, 14, 15, 999, 65_534, 65_535, 65_536, 100_000, 16 * 1024 * 1024]

        for length in lengths {
            let charge = FlowControl.charge(for: length)
            XCTAssertEqual(
                charge, max(1, min(length, FlowControl.initialWindow)),
                "charge(for: \(length)) is not max(1, min(length, window))")
            XCTAssertGreaterThanOrEqual(
                charge, 1, "§O4's floor: every message costs at least one byte of window")
            XCTAssertLessThanOrEqual(
                charge, FlowControl.initialWindow,
                "§O4's clamp: a charge above the window it must fit in could never be reserved")
        }

        try runBounded("the charge round trip") {
            for length in lengths {
                let charge = FlowControl.charge(for: length)

                // Send side: the reservation loop from `FlowControlWindow`'s own doc comment.
                let window = FlowControlWindow()
                var remaining = charge
                while remaining > 0 { remaining -= try await window.reserve(upTo: remaining) }
                XCTAssertEqual(
                    window.available, FlowControl.initialWindow - charge,
                    "length \(length): the reservation did not take exactly the charge")

                // Receive side: the accountant is fed the **charge**, not the length. `flush()`
                // stands in for the later deliveries a long-lived ledger would batch behind.
                var accountant = WindowAccountant()
                var credited = 0
                if let credit = accountant.consumed(charge) { credited += Int(credit) }
                if let credit = accountant.flush() { credited += Int(credit) }
                XCTAssertEqual(
                    credited, charge,
                    "length \(length): the receive side credited \(credited) for a charge of "
                        + "\(charge) -- the two clamps have drifted")

                try window.grant(UInt32(credited))
                XCTAssertEqual(
                    window.available, FlowControl.initialWindow,
                    "length \(length): the window did not return to \(FlowControl.initialWindow) "
                        + "after one message round-tripped; this is the silent drift the one-"
                        + "definition rule exists to prevent")
            }
        }
    }

    /// The `window:` parameter, which exists because `FlowControlWindow(initial:)` accepts any size
    /// and a charge computed against the *default* window would park forever on a smaller one.
    ///
    /// §O5 deviation 1 fixes every production window at `initialWindow`, so this bites tests and
    /// any future per-stream sizing rather than shipping code -- which is exactly why it needs a
    /// test rather than a reader's confidence.
    func testAnOversizeChargeAgainstASmallWindowIsStillReservable() throws {
        XCTAssertEqual(FlowControl.charge(for: 100_000, window: 1_000), 1_000)
        XCTAssertEqual(FlowControl.charge(for: 0, window: 1_000), 1)
        XCTAssertEqual(
            FlowControl.charge(for: 100_000, window: 0), 1,
            "with a zero-sized window the floor wins; the degenerate case returns 1 rather than "
                + "trapping, and nothing in the transport builds such a window")

        try runBounded("an oversize charge against a small window") {
            let window = FlowControlWindow(initial: 1_000)
            let charge = FlowControl.charge(for: 100_000, window: window.initial)
            var remaining = charge
            while remaining > 0 { remaining -= try await window.reserve(upTo: remaining) }
            XCTAssertEqual(window.available, 0)
            XCTAssertEqual(
                charge, 1_000,
                "the charge must be clamped to the window it must fit in, or this reservation "
                    + "could never complete")
        }
    }

    /// §O4's batching, and the one place the accountant's optionality is load-bearing.
    ///
    /// Batching is why `consumed(_:)` returns `nil` most of the time; a test that only ever fed it
    /// large values would never see that. The threshold is half the initial window, the remainder is
    /// carried, and `flush()` is the escape for the one moment there is no later delivery.
    func testTheAccountantBatchesAtHalfTheWindowAndCarriesTheRemainder() {
        var accountant = WindowAccountant()
        let threshold = FlowControl.initialWindow / 2   // 32 767

        XCTAssertNil(accountant.consumed(0), "consuming nothing owes the peer nothing")
        XCTAssertNil(
            accountant.consumed(threshold - 1),
            "one byte below the threshold must still batch")

        // The crossing emits everything accumulated, not just the last delivery.
        XCTAssertEqual(
            accountant.consumed(1), UInt32(threshold),
            "the credit at the crossing is the whole accumulation")

        // ... and the remainder is carried rather than emitted or dropped.
        XCTAssertNil(accountant.consumed(10))
        XCTAssertEqual(
            accountant.flush(), 10,
            "flush emits the carried remainder regardless of the threshold")
        XCTAssertNil(accountant.flush(), "a flushed ledger owes nothing")

        // A degenerate window still makes progress rather than emitting zero-byte credits.
        var tiny = WindowAccountant(initial: 1)
        XCTAssertEqual(tiny.consumed(1), 1)
    }
}
