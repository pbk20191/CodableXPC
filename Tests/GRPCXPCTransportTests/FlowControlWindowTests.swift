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
// **Every case here is bounded (L8) by `runBounded`, including the two that are otherwise wholly
// synchronous.** That was not true of the first version, and it mattered: the L2/O(1) case's only
// failure mode against a restored `0..<addition` loop is a hang (measured at 2 m 54 s), so an
// unbounded version of it reported *zero failures* while the mutation ran. A synchronous body with
// no suspension point still needs the bound whenever "it took far too long" is the failure.
//
// Budgets above the 5 s default are for size, not for expected slowness: measured, the whole file
// runs in ~150 ms.

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class FlowControlWindowTests: XCTestCase {

    /// A distinguishable failure for the `fail(_:)` paths, so an assertion cannot pass on some
    /// other error the window synthesised.
    ///
    /// This was a bespoke `private struct ProbeFailure: Error` and the assertions below keyed on
    /// its **type**. `FlowControlWindow.fail(_:)` now takes an `RPCError` -- a trace of every
    /// caller found all of them already constructing one -- so the probe is an `RPCError` and the
    /// assertions key on **identity** instead, which `RPCError`'s `Hashable` conformance gives for
    /// free. Just as distinguishing: the sticky failure is stored and rethrown verbatim, so
    /// `reserve` never substitutes an error of its own, and `.unknown` is a code no path in
    /// `FlowControl.swift` produces.
    private static let probeFailure = RPCError(
        code: .unknown, message: "FlowControlWindowTests probe failure")

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
    /// What one 3 000-round measurement saw. Judges nothing -- the assertions are in the test.
    private struct RaceOutcome: Sendable {
        var cancelled = 0
        var granted = 0
        var violations: [String] = []
    }

    /// The three resolution sequences ``orderedRound(_:)`` can set up. Two are deterministic in
    /// their outcome; the third is deterministic in its *call order* but not in which call wins, and
    /// says so.
    private enum RaceOrder: Sendable, CaseIterable {
        /// The waiter is **parked** (its token is in the FIFO), then `grant` resolves it, then a
        /// late `cancel` arrives. The waiter must keep the byte the grant already deducted for it,
        /// and the cancellation must find a non-`.pending` slot and do nothing. **Dropping the byte
        /// here is L1** -- measured at 1-14 permits lost per 3 000 in the previous design.
        case grantResolvesThenCancelArrives

        /// The task is cancelled at once, and has **provably resolved** (its `reserve` has already
        /// thrown) before `grant` runs. The byte must then stay **in the window**: `grant` must not
        /// hand it to a waiter that has already refused it, or it is gone for good.
        ///
        /// Deterministic whichever way the scheduler orders the cancellation against the task's
        /// start: cancel before entry, between taking the token and installing the handler, or
        /// after parking all resolve the same slot to `.cancelled` / `CancellationError`.
        case cancelResolvesThenGrantArrives

        /// The waiter is parked and both resolutions are then called back to back. **Which one
        /// resolves the slot is not observable from a test**: `waiterCount` sees the token in the
        /// FIFO but cannot see whether the continuation has been installed yet, and a `cancel`
        /// landing in that gap does nothing until the waiter arrives -- at which point the grant may
        /// already have won. So this case asserts the invariant and whichever consequence follows,
        /// and asserts nothing about which.
        ///
        /// Measured: the cancellation wins essentially always -- 200 of 200 rounds on one run, 198
        /// of 200 on another -- so this case reliably covers "a cancellation resolves a **parked**
        /// waiter", which is the one L1 direction the other two sequences do not reach. It is not
        /// asserted as such, because 198-of-200 is a distribution and an assertion has to be written
        /// against the set of reachable outcomes.
        case cancelCalledOnAParkedWaiter
    }

    /// One round in which the resolution sequence is **chosen rather than raced**.
    ///
    /// This is what carries L1 now. The stress loop below cannot: its winner mix turned out to be
    /// mostly a measurement of dispatch-pool cold-start rather than of the race (see the test's own
    /// note for the numbers), so a floor on that mix is not something a retry can make hold.
    ///
    /// # Why the first two cases are deterministic
    ///
    /// Both resolutions finish their work before returning: `Task.cancel()` runs
    /// `withTaskCancellationHandler`'s `onCancel` synchronously, and `grant(_:)` resolves the slot
    /// under its own lock. And `reserve` appends its token to the FIFO *before* it parks, so
    /// `waiterCount == 1` means "this round's waiter exists and is unresolved" -- enough to place
    /// the grant after it with certainty.
    ///
    /// - Returns: a description of what went wrong, or `nil`.
    private static func orderedRound(_ order: RaceOrder) async -> String? {
        let window = FlowControlWindow(initial: 0)
        let task = Task.detached { try await window.reserve(upTo: 1) }

        var reserved = 0
        var thrown: (any Error)?

        switch order {
        case .grantResolvesThenCancelArrives, .cancelCalledOnAParkedWaiter:
            // Yield rather than spin: the cooperative pool has to be free to run the task at all.
            while window.waiterCount == 0 { await Task.yield() }
            do {
                if order == .cancelCalledOnAParkedWaiter {
                    task.cancel()
                    try window.grant(1)
                } else {
                    try window.grant(1)
                    task.cancel()
                }
            } catch {
                return "\(order): grant(1) threw \(error)"
            }
            switch await task.result {
            case .success(let bytes): reserved = bytes
            case .failure(let error): thrown = error
            }

        case .cancelResolvesThenGrantArrives:
            task.cancel()
            // The waiter has resolved by the time this returns -- no grant is needed to release it,
            // which is the whole point of `reserve` throwing rather than parking on cancellation.
            switch await task.result {
            case .success(let bytes): reserved = bytes
            case .failure(let error): thrown = error
            }
            do { try window.grant(1) } catch { return "\(order): grant(1) threw \(error)" }
        }

        // The invariant, in every case: the one byte in play is either with the sender or in the
        // window, never neither and never both.
        let available = window.available
        if reserved + available != 1 {
            return "\(order): reserved \(reserved) + available \(available) != 1"
                + (reserved + available == 0
                    ? " -- a byte was LOST (this is L1)" : " -- a byte was DOUBLE-SPENT")
        }
        if window.waiterCount != 0 {
            return "\(order): \(window.waiterCount) waiter(s) left unresolved"
        }

        // Then the per-case consequence.
        switch order {
        case .grantResolvesThenCancelArrives:
            guard thrown == nil, reserved == 1 else {
                return "\(order): the waiter must keep the byte the grant already deducted for it; "
                    + "got " + (thrown.map { "\(type(of: $0))" } ?? "\(reserved)")
            }
        case .cancelResolvesThenGrantArrives:
            guard thrown is CancellationError else {
                return "\(order): expected CancellationError, got "
                    + (thrown.map { "\(type(of: $0))" } ?? "a reservation of \(reserved)")
            }
            guard available == 1 else {
                return "\(order): the byte must stay in the window rather than be handed to a "
                    + "waiter that already refused it; available == \(available)"
            }
        case .cancelCalledOnAParkedWaiter:
            // Either winner is legal; the consequence must match whichever it was.
            if thrown is CancellationError {
                guard available == 1 else {
                    return "\(order): the cancellation won, so the byte must be in the window; "
                        + "available == \(available)"
                }
            } else if thrown == nil {
                guard reserved == 1, available == 0 else {
                    return "\(order): the grant won, so the waiter must hold exactly the one byte; "
                        + "reserved \(reserved), available \(available)"
                }
            } else {
                return "\(order): reserve threw \(type(of: thrown!)); only CancellationError is "
                    + "legal here"
            }
        }
        return nil
    }

    /// One measurement of the grant/cancel race: `rounds` independent rounds, each with exactly one
    /// byte in play.
    ///
    /// A `static` method rather than a function nested in the test's `runBounded` closure, and that
    /// is not a style choice: nested inside the closure, the compiler resolved `task.result` (and
    /// `task.value`, and an explicitly-typed `Task<Int, any Error>`) as neither `async` nor
    /// `throwing`, and warned on the `await`/`try`/`catch` -- and this suite ships with zero
    /// warnings. At type scope the inference is unambiguous.
    private static func raceAttempt(rounds: Int) async throws -> RaceOutcome {
        var outcome = RaceOutcome()

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

    func testAGrantCancelRaceNeverLosesBytes() throws {
        /// Each iteration runs every `RaceOrder` once, so every resolution sequence is exercised
        /// this many times -- by construction, not by scheduling luck.
        let orderedIterations = 200
        let stressRounds = 3_000

        // ===================================================================================
        // Part 1: both resolution orders, made to hold rather than hoped for.
        // ===================================================================================
        //
        // This part is what makes the test mean something, and it replaces a floor on the stress
        // loop's winner mix. **The floor was not lowered; it was moved somewhere it is exact** --
        // 200 grant-wins and 200 cancel-wins, guaranteed rather than sampled, which is a stronger
        // bar than the 30-in-3 000 it replaces. See Part 2's note for the measurement that forced
        // the move, and `RaceOrder` for what each sequence must produce.
        let orderedViolations = try runBounded("every resolution sequence", timeout: 120) {
            () -> [String] in
            var violations: [String] = []
            for _ in 0..<orderedIterations {
                for order in RaceOrder.allCases {
                    if let violation = await Self.orderedRound(order) {
                        violations.append(violation)
                    }
                }
                if violations.count > 5 { break }
            }
            return violations
        }
        XCTAssertEqual(
            orderedViolations, [],
            "a grant and a cancellation resolving the same parked waiter lost or double-spent the "
                + "byte. This is L1 -- measured at 1-14 permits lost per 3 000 in the previous "
                + "design -- and it is a stream stalled forever waiting for credit that is already "
                + "gone from the window.")

        // ===================================================================================
        // Part 2: the unordered stress loop.
        // ===================================================================================
        //
        // 3 000 rounds with the two resolutions fired without any synchronisation between them, and
        // one byte in play per round. The invariant is the assertion:
        //
        //     reserved + available == 1        for every round, no exceptions
        //
        // A lost byte breaks it as `0 + 0`; a double-spend as `1 + 1`; and `waiterCount == 0`
        // catches a waiter resolved by neither.
        //
        // # What this part deliberately does NOT assert, and why
        //
        // It used to assert a floor on how many rounds the *cancellation* won, on the grounds that
        // a race which never races proves nothing. That reasoning is right and it is why Part 1
        // exists. But the floor could not hold, and the reason is worth recording rather than
        // tolerating: **the winner mix here is mostly a measurement of dispatch-pool cold-start, not
        // of the race.** `grant(1)` is straight-line code on this thread while the cancellation goes
        // through `DispatchQueue.global().async`, so the cancellation can only win when enqueuing it
        // yields this thread -- which is what a *cold* pool does. Measured, eight consecutive
        // attempts in one process:
        //
        //     cancellations: [1287, 6, 5, 4, 18, 10, 20, 11]      (of 3 000 rounds each)
        //
        // The first attempt races; every later one collapses to single digits because the pool is
        // warm. So the attempts are not independent draws, a bounded retry cannot rescue the
        // premise (it would turn a 1-in-20 flake into a hard failure after exhausting its budget),
        // and whether the *first* attempt in a process is cold depends on which tests ran before
        // it -- which is exactly the 1-in-20 flake slice 2's author caught.
        //
        // What is asserted instead is that every round resolved exactly once, which is
        // scheduling-independent, plus the invariant above on all 3 000 rounds. Both resolution
        // paths are covered exhaustively by Part 1.
        let outcome = try runBounded("the grant/cancel race", timeout: 120) { () -> RaceOutcome in
            try await Self.raceAttempt(rounds: stressRounds)
        }

        XCTAssertEqual(
            outcome.violations, [],
            "the grant/cancel race lost or double-spent bytes; this is L1 and it is a stall "
                + "waiting to happen")
        XCTAssertEqual(
            outcome.granted + outcome.cancelled, stressRounds,
            "every one of the \(stressRounds) rounds must resolve exactly once, by the grant or by "
                + "the cancellation and never by neither: \(outcome.granted) granted + "
                + "\(outcome.cancelled) cancelled")
    }

    // =======================================================================================
    // MARK: - L2: peer-controlled arithmetic
    // =======================================================================================

    /// L2 and §O4's ceiling. `bytes` is peer input, and the previous design looped `0..<n` over it:
    /// one credit of `UInt32.max` spent a measured **450 seconds inside the mutex**, blocking every
    /// sender and the connection's own teardown, for the price of a single op.
    ///
    /// Four separate claims, because four separate things could break:
    ///
    /// 1. `grant(UInt32.max)` **throws** rather than wrapping or saturating;
    /// 2. it leaves the window **byte-for-byte unchanged** -- the check runs before `available` is
    ///    touched, so a rejected credit is not half-applied;
    /// 3. **banking an *accepted* 2³¹−1 is O(1)**, asserted as wall clock;
    /// 4. the ceiling is exact at the boundary: to 2³¹−1 is legal and the very next byte is not.
    ///
    /// # Claim 3 has to be timed on the ACCEPTED call, and the first version of this test was not
    ///
    /// It timed `grant(UInt32.max)` only -- which `guard total <= maxWindow` **rejects before
    /// `State.bank(_:)` is ever reached**, so the timed call does no banking work at all. Measured
    /// by review: a literal `for _ in 0..<addition` loop inside `bank` -- L2's exact historical
    /// shape -- **survived the entire target**, because the one call that reaches `bank` with the
    /// peer's full magnitude (`grant(UInt32(maxWindow))`, below) was untimed. Under that loop it
    /// took **2 m 54 s** and the suite still reported zero failures.
    ///
    /// So the timing that matters is on the call that *succeeds*, and the case is now wrapped in
    /// `runBounded` as well: an O(n) `bank` blows the 100 ms assertion if it is slow, and the L8
    /// bound if it is catastrophic. Both instruments, because a loop's cost depends on the number
    /// the peer chose and the historical one was fatal at both scales.
    func testAHugeCreditIsRejectedInConstantTimeAndTheCeilingIsExact() throws {
        try runBounded("the huge-credit ceiling", timeout: 20) {
            let window = FlowControlWindow(initial: 0)
            let clock = ContinuousClock()

            // Claims 1 and 2: rejected, and the window untouched.
            let rejectStart = clock.now
            var rejection: (any Error)?
            do {
                try window.grant(UInt32.max)
            } catch {
                rejection = error
            }
            let rejectElapsed = clock.now - rejectStart
            XCTAssertEqual(
                (rejection as? RPCError)?.code, .internalError,
                "a credit above §O4's ceiling is a protocol error by the peer; got "
                    + "\(rejection.map { "\($0)" } ?? "no error at all")")
            XCTAssertEqual(
                window.available, 0,
                "a rejected credit must leave the window exactly as it was; this one was "
                    + "half-applied")
            // A rejection must also be O(1) -- validating in `Int64` is two operations -- but note
            // this call never reaches `bank`, so it cannot see a loop *there*. That is claim 3.
            XCTAssertLessThan(
                rejectElapsed, .milliseconds(100),
                "rejecting grant(UInt32.max) took \(rejectElapsed); even the validation is not O(1)")

            // **Claim 3: the accepted call.** This is the one that reaches `State.bank(_:)` with
            // 2³¹−1, and therefore the only place an O(peer's number) loop in the wake-up path is
            // observable. The old design's equivalent spent 450 s inside the mutex; a `bank` loop
            // measures 2 m 54 s. 100 ms is loose enough for a loaded machine and three orders of
            // magnitude short of either.
            let acceptStart = clock.now
            XCTAssertNoThrow(try window.grant(UInt32(FlowControl.maxWindow)))
            let acceptElapsed = clock.now - acceptStart
            XCTAssertLessThan(
                acceptElapsed, .milliseconds(100),
                "banking \(FlowControl.maxWindow) byte(s) took \(acceptElapsed); it must be one "
                    + "addition plus a walk over the *waiters*, never a loop over the peer's "
                    + "number (L2)")
            XCTAssertEqual(window.available, FlowControl.maxWindow)

            // Claim 4: the boundary, from the other side.
            XCTAssertThrowsError(try window.grant(1)) { error in
                XCTAssertEqual((error as? RPCError)?.code, .internalError)
            }
            XCTAssertEqual(
                window.available, FlowControl.maxWindow,
                "the one-byte overshoot must not have been banked")
        }
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
        dead.fail(Self.probeFailure)
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
                window.fail(Self.probeFailure)
                do {
                    _ = try await window.reserve(upTo: 1)
                    log.append("third=returned")
                } catch let error as RPCError where error == Self.probeFailure {
                    log.append("third=probeFailure")
                } catch {
                    log.append("third=\(type(of: error)): \(error)")
                }
                return log
            }

            try await waitUntil("the waiter parked") { window.waiterCount == 1 }
            try window.grant(5)
            return try await task.value
        }

        XCTAssertEqual(
            log,
            ["first=5", "second=4", "third=probeFailure"],
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
    func testTheAccountantBatchesAtHalfTheWindowAndCarriesTheRemainder() throws {
        try runBounded("the accountant's batching", timeout: 10) {
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
}
