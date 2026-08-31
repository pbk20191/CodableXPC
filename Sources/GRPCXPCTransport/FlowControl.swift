import GRPCCore
import Synchronization

// ===========================================================================================
// MARK: - Tunables
// ===========================================================================================

/// Flow-control constants (§O4).
///
/// Byte-based credit, initial window 65 535 per stream *and* per connection -- exactly HTTP/2's
/// defaults. Not because this transport is HTTP/2 (it is an op stream; see ``RPCOp``), but because
/// those numbers and that shape are well-tested: a non-zero initial window is what keeps two peers
/// that each write a burst before they read from deadlocking on each other's first credit.
///
/// Only `message` bodies consume window. The control ops -- `metadata`, `halfClose`, `status`,
/// `cancel`, `credit`, `goAway` -- are never flow-controlled, so a stalled window can never starve
/// a stream's terminal op. That is load-bearing, not incidental: if `status` or `cancel` had to
/// wait for credit, a peer that stopped reading could make a stream unclosable.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum FlowControl {
    /// §O4: the initial window, in bytes, for each stream and for the connection.
    static let initialWindow = 65_535

    /// §O4: "a credit that would take a window above 2³¹−1 is a protocol error". HTTP/2's
    /// `SETTINGS_MAX_WINDOW_SIZE`; here it is the bound that keeps a peer's `UInt32` credit from
    /// growing a window without limit.
    static let maxWindow = Int(Int32.max)

    /// §O4/§O5: what a `message` costs its stream and connection windows.
    ///
    /// **Clamped above, floored below: `max(1, min(payloadLength, window))`.** Two independent
    /// rules, each closing a measured hole, and both peers derive the value from a payload length
    /// both already know -- so it needs no negotiation and no protocol change.
    ///
    /// # The clamp (upper bound): an oversize message must stay reservable
    ///
    /// An op body is atomic (§O2 has no chunking), so a charge above the window could never be
    /// reserved: the sender would park forever with nothing on the wire for the peer to consume.
    /// Clamping to the window makes an oversize message serialise the *connection* -- head-of-line
    /// blocking -- instead of deadlocking it.
    ///
    /// # The floor (lower bound): a zero-length message must not be free
    ///
    /// A `message` op costs **at least one byte of window even when its payload is empty**. Added
    /// per §O4's amendment after Task 6's review: without it, a zero-length `message` -- legal, and
    /// `google.protobuf.Empty` makes it common -- is a ten-byte wire op that buys the receiver
    /// unbounded buffering for free, and it *survives* §O4's receive-side enforcement rule because
    /// a correct enforcement still charges it nothing. Flooring keeps one counter meaningful
    /// instead of needing a second one that counts messages rather than bytes.
    ///
    /// Note what the floor changes for callers: `charge(for:)` now returns `>= 1` for **every**
    /// `message`, so a `if charge > 0` test at a call site means "is this part flow-controlled?",
    /// not "is the payload non-empty?" -- and ``FlowControlWindow/reserve(upTo:)``'s "at least 1
    /// byte" precondition becomes unreachable by construction for message sends rather than
    /// something a caller must remember to guard.
    ///
    /// # One definition
    ///
    /// **The send side and the receive side MUST call this same function.** Reserving with one
    /// clamp and crediting with another -- or with a hand-inlined copy of the formula that later
    /// drifts -- makes credit stop matching charge, and the window then grows or shrinks silently
    /// until a stream stalls with no visible cause. That is the entire reason this is a function
    /// and not a sentence in a doc comment. The floor makes that doubly true: a receiver that
    /// clamped but did not floor would credit 0 for a message the sender paid 1 for, and the
    /// window would leak one byte per empty message.
    ///
    /// - Parameter window: the window this charge must fit in. Defaults to ``initialWindow``,
    ///   which is what §O5 deviation 1 fixes production windows at; pass a `FlowControlWindow`'s
    ///   own `initial` for any window sized differently, or the clamp stops matching the window
    ///   and an oversize message parks forever. **Must be at least 1** for the result to be
    ///   reservable at all: with `window == 0` the floor wins and returns 1, which no such window
    ///   could ever grant. Nothing in this transport builds a zero-sized window (§O5 deviation 1
    ///   fixes every one of them at ``initialWindow``); the degenerate case is called out here
    ///   rather than trapped so this stays a pure function.
    static func charge(for payloadLength: Int, window: Int = initialWindow) -> Int {
        max(1, min(payloadLength, window))
    }
}

// ===========================================================================================
// MARK: - Sender side
// ===========================================================================================

/// One flow-control window's worth of send credit: the sender-side half of §O4.
///
/// One instance per stream and one per connection. **This type does not know which it is** --
/// §O4's "reserve from the stream window then the connection window, always in that order, so two
/// streams cannot deadlock each other" is a rule about the *sequence of calls*, and it belongs to
/// the multiplexer that owns both windows. Do not grow a two-window coordinator in here.
///
/// # The reservation loop
///
/// ``reserve(upTo:)`` returns a **partial** reservation -- at least 1 byte, at most `requested`,
/// whatever the window can spare right now -- and suspends only while the window is genuinely
/// empty. A sender therefore loops:
///
/// ```swift
/// var remaining = FlowControl.charge(for: payload.count, window: window.initial)
/// while remaining > 0 { remaining -= try await window.reserve(upTo: remaining) }
/// ```
///
/// Partial rather than all-or-nothing for two reasons, and **neither of them is "so an oversize
/// message can be sent"**: an op body is atomic (§O2 has no chunking), so looping `reserve` on a
/// payload larger than the window would still park with nothing on the wire for the peer to
/// consume. That deadlock is closed by the *charge* instead -- see ``FlowControl/charge(for:window:)``,
/// which both sides call so that nothing can ever be charged more than the window it must fit in.
/// What partial reservation buys is:
///
/// - **Progress and fairness** when several senders share one window: a 60 KB sender does not sit
///   on an all-or-nothing claim while 8 KB of credit trickles in and every other sender starves
///   behind it. Each takes what is there and comes back.
/// - **No contiguity requirement**: a reservation can be assembled from several small grants,
///   which is exactly the shape credit arrives in (the peer credits per message consumed).
///
/// # Suspension, not blocking
///
/// A waiter suspends its *task*; no thread is ever blocked. The caller is a gRPC handler on the
/// cooperative pool, and blocking one of those threads can deadlock the pool. Waiters are FIFO, so
/// a starved sender cannot be indefinitely overtaken by later arrivals.
///
/// # Reservations are spent, or explicitly given back -- never leaked
///
/// The window is replenished by the peer's `credit` ops, which the peer sends as it consumes what
/// it received. So a reservation that is taken and then not sent is gone from the window: the peer
/// will never credit bytes it never received.
///
/// Two ordinary paths strand a reservation, and neither is exotic. §O4 has a sender reserve from
/// the stream window *then* the connection window, so any failure or cancellation of the second
/// leaves the first stranded; and ``reserve(upTo:)`` deliberately hands bytes to a task that was
/// cancelled a moment earlier (that is L1 -- dropping the grant instead would shrink the window
/// permanently), so every mid-send cancellation strands whatever it had reserved.
///
/// **``release(_:)`` is the give-back for exactly those cases.** Do not reach for ``fail(_:)``:
/// failing the *connection* window because one stream's send went wrong kills every other stream
/// on that connection. `fail` is for a window that is genuinely dead. And do not use ``grant(_:)``
/// either -- it validates against §O4's peer-facing ceiling, which a give-back can trip through no
/// fault of the caller (the peer may have granted while the reservation was outstanding).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class FlowControlWindow: Sendable {

    // =======================================================================================
    // MARK: - State
    // =======================================================================================

    /// One waiter's slot, and **the reason a grant racing a cancellation cannot lose bytes**.
    ///
    /// This is a single-assignment cell, not a bag of flags: a slot starts `.pending` and every
    /// resolution path (`grant`, `fail`, cancellation) is a `.pending → terminal` transition
    /// guarded by `case .pending` under the lock, so the *first* writer wins and no later writer
    /// can overwrite it. L1 -- "check granted before cancelled" -- is therefore not an ordering
    /// this file has to remember to get right: there are not two independent flags to order. There
    /// is one resolution, and a cancellation that arrives after `.granted(k)` simply finds a slot
    /// that is no longer `.pending` and does nothing.
    ///
    /// The other half of the invariant is that `.granted(k)` and `available -= k` happen in the
    /// *same* `withLock`: bytes leave the window exactly when a slot becomes their owner, so a
    /// grant is never in flight without an owner obliged to return it (see ``reserve(upTo:)``,
    /// which returns `k` even to a task that was cancelled in the interim).
    ///
    /// # Why the continuation's failure type is `any Error` and not `RPCError`
    ///
    /// **One blocker, and it is a behaviour question rather than a typing one.** An earlier round
    /// named three -- `.failed`'s payload, ``fail(_:)``'s parameter, and `onCancel`'s
    /// `CancellationError` -- and said the second was forced from above, because
    /// ``RPCTransportCore/failAll(_:)`` took `any Error`. Two of those three are gone: the whole
    /// failure chain (`failAll`, `failConnection`, `removeStream(_:failingInboundWith:_:)`,
    /// ``fail(_:)``, `.failed`, `State.failure`, `Admission.failed`) is now `RPCError`, because a
    /// trace of every call site found every one of them already constructing an `RPCError` literal
    /// -- the two that passed a variable through resolve to `RPCError` literals one hop away, and
    /// the two `catch`-derived paths *wrap* the caught value as `cause:` rather than forwarding it.
    /// Nothing was widened to make that fit.
    ///
    /// What remains is `onCancel`. ``reserve(upTo:)`` throws **two unrelated error identities on
    /// purpose**: the window's `RPCError` when it died, and `CancellationError` when the waiting
    /// task was cancelled. `any Error` is their only common type, so any narrower slot -- a
    /// two-case enum, or `CancellationError` rewritten as `RPCError(code: .cancelled)` -- changes
    /// what a cancelled sender *observes*. `FlowControlWindowTests` asserts that identity directly
    /// (`error is CancellationError`, in four places), so this is a decision about the transport's
    /// behaviour and not a re-spelling of it. Left as it is deliberately, and now for a reason that
    /// is entirely about cancellation rather than half about plumbing.
    private enum Slot {
        /// Waiting. `continuation` is `nil` in the window between taking a token and actually
        /// parking; a resolution landing in that window is remembered by the terminal cases below
        /// and picked up when the waiter arrives.
        case pending(requested: Int, continuation: CheckedContinuation<Int, any Error>?)
        /// Resolved by ``grant(_:)``: `bytes` have **already been deducted** from `available` and
        /// belong to this waiter. Terminal -- nothing may overwrite it, or those bytes are lost
        /// from the window forever.
        case granted(Int)
        /// Resolved by cancellation before the waiter parked. Holds no bytes. Terminal.
        case cancelled
        /// Resolved by ``fail(_:)`` before the waiter parked. Holds no bytes. Terminal.
        case failed(RPCError)
    }

    private struct State {
        /// Unreserved bytes. Never negative. Bounded by `FlowControl.maxWindow` on every
        /// peer-driven path, because ``FlowControlWindow/grant(_:)`` refuses any credit that would
        /// breach it. ``FlowControlWindow/release(_:)`` is the one exception and deliberately so:
        /// it returns bytes that were already *inside* this window, so refusing them would destroy
        /// window rather than protect it. It can therefore push `available` above the ceiling, but
        /// only by as much as a peer over-granted while a reservation was outstanding. The check on
        /// the next credit then becomes **conservative rather than diagnostic**: the overshoot is
        /// ours, so the credit it rejects may well be an honest one. That is the right trade (it
        /// only arises against a peer that had already inflated the window to the ceiling), but do
        /// not read such a rejection as proof the peer misbehaved.
        var available: Int
        /// Every waiter that has taken a token and not yet been picked up by its own `reserve`.
        var slots: [UInt64: Slot] = [:]
        /// Tokens of the waiters still `.pending`, in arrival order -- the FIFO discipline, and
        /// the *only* set `grant`/`fail` walk. A token leaves `order` the instant its slot leaves
        /// `.pending`; a terminal slot lingers in `slots` until its own `reserve` collects it.
        var order: [UInt64] = []
        var nextToken: UInt64 = 0
        /// Sticky. Set by ``fail(_:)``; later reservations throw it rather than parking forever.
        var failure: RPCError?

        /// Removes `token` from the FIFO. Linear in the number of *waiters*, which is the number
        /// of concurrent senders on this window -- never a peer-supplied count.
        mutating func removeFromOrder(_ token: UInt64) {
            if let index = order.firstIndex(of: token) { order.remove(at: index) }
        }

        /// Adds `addition` bytes to the window and hands them to the parked senders, oldest first.
        ///
        /// The single wake-up path, shared by ``FlowControlWindow/grant(_:)`` (peer credit) and
        /// ``FlowControlWindow/release(_:)`` (a give-back). Shared deliberately: the FIFO walk is
        /// where L1's "deduct and assign ownership in one step" invariant lives, and a second copy
        /// of it is a second chance to get it wrong.
        ///
        /// **Returns** the continuations to resume rather than resuming them, because this runs
        /// under the lock and resuming under the lock is L7's bug. The caller resumes after
        /// `withLock` returns.
        ///
        /// O(waiters), never O(`addition`): the loop is bounded by `order.count` and every
        /// iteration removes exactly one token from `order`. That is what keeps a peer-supplied
        /// credit from driving a loop at all (L2).
        mutating func bank(_ addition: Int) -> [(continuation: CheckedContinuation<Int, any Error>, bytes: Int)] {
            available += addition
            var toResume: [(continuation: CheckedContinuation<Int, any Error>, bytes: Int)] = []
            while available > 0, let token = order.first {
                order.removeFirst()
                guard case .pending(let requested, let parked) = slots[token] else {
                    // Defensive-unreachable: `order` holds only `.pending` tokens. Every path that
                    // resolves a waiter removes its token from `order` in the same lock hold --
                    // including `onCancel`, which is why a cancelled waiter can never be offered
                    // credit it would refuse. Kept as a `continue` rather than a trap because the
                    // safe response to an impossible state here is to skip, not to kill a
                    // connection; the `fail`-walks-`order` argument depends on this invariant, so
                    // do not read this branch as evidence that `order` may hold anything else.
                    continue
                }
                let take = min(requested, available)
                // Deduction and ownership in one step: from here on `take` belongs to this waiter
                // and to nothing else. See `Slot`.
                available -= take
                if let parked {
                    slots[token] = nil
                    toResume.append((parked, take))
                } else {
                    slots[token] = .granted(take)
                }
            }
            return toResume
        }
    }

    /// The nominal window size this was created with. Carried for the caller's benefit (a
    /// `WindowAccountant` on the peer's receive side is sized to match); nothing here branches on
    /// it, because the *current* window is `available` plus whatever is reserved.
    let initial: Int

    private let state: Mutex<State>

    init(initial: Int = FlowControl.initialWindow) {
        precondition(
            initial >= 0 && initial <= FlowControl.maxWindow,
            "a flow-control window must start within 0...\(FlowControl.maxWindow); got \(initial)")
        self.initial = initial
        self.state = Mutex(State(available: initial))
    }

    // =======================================================================================
    // MARK: - Observation
    // =======================================================================================

    /// Bytes reservable right now, as a **snapshot**.
    ///
    /// Deliberately advisory. It can be stale before the getter returns -- a peer's `credit` may
    /// land, or another sender may reserve, in the same instant -- so nothing may branch on it:
    /// `if window.available >= n { send(n) }` is a race, and ``reserve(upTo:)`` is the only way to
    /// obtain window. What it *is* good for is assertions and diagnostics, and it has to exist for
    /// them: bytes lost to a grant/cancel race (L1) are invisible from every other part of this
    /// surface until enough have been lost that the window wedges at zero and the stream stalls
    /// forever. This is the only place that failure mode is observable before it is fatal.
    ///
    /// **After ``fail(_:)`` this number stops meaning "reservable".** It is frozen at whatever the
    /// window held, while every ``reserve(upTo:)`` throws without ever reading it. A teardown test
    /// should assert on the error senders receive, not on this.
    var available: Int { state.withLock { $0.available } }

    /// How many senders are still unresolved -- parked, or between taking a token and parking.
    /// Diagnostics only, for the same reason as ``available``: a test proving "no waiter was left
    /// behind" needs to be able to see one.
    ///
    /// **This counts unresolved waiters, not un-woken tasks**, and after ``fail(_:)`` the two
    /// differ: `fail` resolves every waiter, so this reads 0 immediately, while a waiter that had
    /// not yet parked still holds a `.failed` slot and does not throw until its own `reserve`
    /// reaches the park. Post-teardown -- which is exactly when a test is tempted to ask -- 0 here
    /// means "nobody is still waiting for credit", not "every sender has returned". `await` the
    /// senders for that.
    var waiterCount: Int { state.withLock { $0.order.count } }

    // =======================================================================================
    // MARK: - Reserve
    // =======================================================================================

    private enum Admission {
        case reserved(Int)
        case failed(RPCError)
        case parked(UInt64)
    }

    /// Reserves up to `requested` bytes of window, suspending while the window is empty.
    ///
    /// - Parameter requested: how many bytes of the sender's *charge* remain unreserved. Must be
    ///   at least 1 -- a zero-byte reservation has nothing to wait for and no meaning, so it traps
    ///   rather than quietly returning. **A zero-length message can no longer produce one.**
    ///   (Corrected with §O4's floor: this doc previously said "§O4 charges a zero-length message
    ///   nothing, and it must simply not reach this call". That was true and is now not --
    ///   ``FlowControl/charge(for:window:)`` floors at 1, so `google.protobuf.Empty` charges 1
    ///   byte and reaches this call legitimately.) The trap still guards the real caller bug it
    ///   always guarded: a straight-line `reserve(upTo: someRemaining)` where `someRemaining` has
    ///   already reached 0, i.e. a loop written without the `while remaining > 0` test in the
    ///   type's doc comment.
    /// - Returns: a **partial** reservation: at least 1, at most `requested`. The caller loops
    ///   until it has reserved everything it needs (see the type's doc comment).
    /// - Throws: the window's failure (`RPCError(code: .unavailable)` when the connection is torn
    ///   down), or `CancellationError` if the task is cancelled while suspended and no grant had
    ///   already been handed to it. **Never returns 0, and never throws away a grant it was
    ///   given** -- see ``Slot``.
    func reserve(upTo requested: Int) async throws -> Int {
        precondition(requested >= 1, "reserve(upTo:) needs at least 1 byte; got \(requested)")

        let admission: Admission = state.withLock { s in
            if let failure = s.failure { return .failed(failure) }
            // `order.isEmpty` keeps a fresh caller from overtaking an already-parked sender.
            if s.order.isEmpty && s.available > 0 {
                let take = min(requested, s.available)
                s.available -= take
                return .reserved(take)
            }
            s.nextToken += 1
            let token = s.nextToken
            s.slots[token] = .pending(requested: requested, continuation: nil)
            s.order.append(token)
            return .parked(token)
        }

        switch admission {
        case .reserved(let bytes):
            return bytes
        case .failed(let error):
            throw error
        case .parked(let token):
            return try await park(token)
        }
    }

    /// Suspends until `token`'s slot resolves, then reports what it resolved to.
    ///
    /// Both halves of the cancellation dance resolve the *same* single-assignment slot, which is
    /// what makes the race benign in either direction: if `onCancel` runs first it writes
    /// `.cancelled` and this body observes it; if `grant` runs first it writes `.granted(k)` and
    /// `onCancel` finds a non-`.pending` slot and leaves it alone.
    private func park(_ token: UInt64) async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
                let immediate: Result<Int, any Error>? = state.withLock { s in
                    guard let slot = s.slots[token] else {
                        // Impossible: only this function removes a slot belonging to a waiter that
                        // has not parked, and this function runs once per token. Trap rather than
                        // invent a reservation -- a fabricated 0 would violate the contract and a
                        // fabricated non-zero would conjure window out of nothing.
                        preconditionFailure("flow-control slot \(token) vanished before its waiter parked")
                    }
                    switch slot {
                    case .granted(let bytes):
                        // Already ours. The bytes left `available` when this case was written, so
                        // dropping them here -- because the task was cancelled a moment ago, say --
                        // would shrink the window permanently (L1: measured 1-14 permits lost per
                        // 3 000 races in the previous design, ending in a stream stalled forever).
                        s.slots[token] = nil
                        return .success(bytes)
                    case .cancelled:
                        s.slots[token] = nil
                        return .failure(CancellationError())
                    case .failed(let error):
                        s.slots[token] = nil
                        return .failure(error)
                    case .pending(let requested, let parked):
                        precondition(parked == nil, "flow-control slot \(token) parked twice")
                        s.slots[token] = .pending(requested: requested, continuation: continuation)
                        return nil
                    }
                }
                // L7: resumed outside the lock. `withLock` has returned by here, in every branch.
                switch immediate {
                case .success(let bytes): continuation.resume(returning: bytes)
                case .failure(let error): continuation.resume(throwing: error)
                case nil: break   // parked; `grant` or `fail` resumes it
                }
            }
        } onCancel: {
            let continuation = state.withLock { s -> CheckedContinuation<Int, any Error>? in
                // Not `.pending` any more (or already collected) means someone else resolved this
                // waiter first, and their resolution stands. This is the whole of L1's ordering:
                // the check is "is the slot still unresolved", not "which flag is set".
                guard case .pending(_, let parked) = s.slots[token] else { return nil }
                if let parked {
                    s.slots[token] = nil
                    s.removeFromOrder(token)
                    return parked
                }
                // Cancellation beat the park: remember it, and take the token out of the FIFO so
                // no grant is ever handed to a waiter that will refuse it.
                s.slots[token] = .cancelled
                s.removeFromOrder(token)
                return nil
            }
            // L7.
            continuation?.resume(throwing: CancellationError())
        }
    }

    // =======================================================================================
    // MARK: - Grant
    // =======================================================================================

    /// Applies `bytes` of peer-sent credit (an `RPCOp.credit`), waking waiters in FIFO order.
    ///
    /// **O(1) in the peer's number, unconditionally (L2).** `bytes` is peer-controlled input, and
    /// the previous design looped `0..<n` over it: one credit of `UInt32.max` spent a measured
    /// 450 seconds *inside* the mutex, blocking every sender and the connection's own teardown --
    /// a denial of service costing the peer a single op. Here the peer's magnitude only ever
    /// participates in a comparison and an addition; the only loop is `State.bank`'s walk over the
    /// *waiters* (a local quantity: one per concurrent sender on this window), which retires one
    /// waiter per iteration, so no value of `bytes` can make it run longer.
    ///
    /// The overflow check is done in `Int64` so it cannot itself wrap on any width of `Int`, and
    /// it happens *before* `available` is touched: a rejected credit leaves the window exactly as
    /// it was. Note the ceiling is measured against `available` alone, not against `available`
    /// plus the reservations currently outstanding -- it is a bound on what the *peer* may add,
    /// which is why giving a reservation back goes through ``release(_:)`` and not through here.
    ///
    /// - Throws: `RPCError(code: .internalError)` if the credit would take the window above
    ///   §O4's 2³¹−1 ceiling -- a protocol violation by the peer.
    func grant(_ bytes: UInt32) throws(RPCError) {
        var toResume: [(continuation: CheckedContinuation<Int, any Error>, bytes: Int)] = []

        try state.withLock { s throws(RPCError) in
            // Validate the peer's number whatever the window's state: a protocol violation is a
            // protocol violation, and the connection should hear about it.
            let total = Int64(s.available) + Int64(bytes)
            guard total <= Int64(FlowControl.maxWindow) else {
                throw RPCError(
                    code: .internalError,
                    message: "credit of \(bytes) byte(s) would take the flow-control window to "
                        + "\(total), above the \(FlowControl.maxWindow) (2^31-1) maximum")
            }
            // A failed window is dead for good (the failure is sticky), so there is no waiter left
            // to wake and no future reservation to serve: the credit is discarded rather than
            // banked. Note the peer's number was still validated above -- a protocol violation is
            // worth reporting even on a window that is going away.
            guard s.failure == nil else { return }

            toResume = s.bank(Int(bytes))
        }

        // L7: every resume happens after the lock is released, and a waiter appears in `toResume`
        // only if this call was the one that removed its slot -- so it is resumed exactly once.
        for (continuation, bytes) in toResume { continuation.resume(returning: bytes) }
    }

    // =======================================================================================
    // MARK: - Release
    // =======================================================================================

    /// Gives an unspent reservation back to the window.
    ///
    /// The counterpart to ``reserve(upTo:)`` for bytes that were reserved and then not sent. Two
    /// ordinary paths produce those, both of them consequences of rules this transport keeps
    /// elsewhere:
    ///
    /// - §O4 reserves the stream window *then* the connection window. If the second throws or is
    ///   cancelled, the first reservation is stranded and belongs here.
    /// - L1 requires ``reserve(upTo:)`` to hand bytes even to a task cancelled an instant earlier,
    ///   so a mid-send RPC cancellation always strands whatever it had taken.
    ///
    /// **Not ``grant(_:)``.** These bytes were already inside this window, so they cannot breach
    /// §O4's ceiling by arriving back and must not be validated against it -- that ceiling bounds
    /// what the *peer* may add. Checking it here would let a peer that credited while the
    /// reservation was outstanding turn an honest give-back into a spurious protocol error, or
    /// (worse, behind a `try?`) silently destroy the bytes.
    ///
    /// **Not ``fail(_:)``.** Failing a window because one send went wrong is right only when the
    /// window is genuinely dead; doing it to the *connection* window over one stream's stranded
    /// reservation would tear down every other stream sharing it.
    ///
    /// Waiters are woken through the same FIFO walk `grant` uses, with the same
    /// resume-outside-the-lock discipline. On a failed window the bytes are dropped, exactly as
    /// credit is: nothing can reserve from it again.
    ///
    /// # What the caller owes: never release more than you reserved and did not send
    ///
    /// This is not checked. A negative count traps and zero is a no-op, but `release(10_000)`
    /// against a 100-byte window that lent out 10 is accepted and leaves `available` at 10 090.
    /// Deliberately: every caller is in-process transport code, and a running "outstanding" counter
    /// on the hot path would catch nothing a caller-side `precondition` does not catch better.
    ///
    /// The obligation is still absolute. Over-releasing invents window the peer never authorised
    /// and defeats backpressure **silently** -- the receiver is then handed more than it agreed to
    /// buffer, with no error anywhere. Note the asymmetry: this file makes that failure impossible
    /// to reach from the *peer* (``grant(_:)`` validates every byte the peer sends), so a careless
    /// in-process caller is the only way in.
    ///
    /// # Not to be confused with the legacy `CreditWindow.release(_:)`
    ///
    /// `Backpressure.swift`'s `CreditWindow` -- deleted by Task 7 with the rest of the
    /// reply-as-credit stack, and named here because the confusion outlived the code -- also had a
    /// `release(_:)`, and it meant the **opposite** end of the exchange: "a credit reply arrived
    /// from the peer", i.e. the equivalent of this type's ``grant(_:)``, not of this method. This
    /// `release` never touches peer input at all; it only hands back bytes this side reserved and
    /// did not spend.
    func release(_ bytes: Int) {
        precondition(bytes >= 0, "release(_:) takes a byte count; got \(bytes)")
        guard bytes > 0 else { return }

        var toResume: [(continuation: CheckedContinuation<Int, any Error>, bytes: Int)] = []
        state.withLock { s in
            guard s.failure == nil else { return }
            toResume = s.bank(bytes)
        }
        // L7.
        for (continuation, bytes) in toResume { continuation.resume(returning: bytes) }
    }

    // =======================================================================================
    // MARK: - Fail
    // =======================================================================================

    /// Breaks the window permanently: every parked sender throws `error`, and so does every later
    /// ``reserve(upTo:)``. Sticky, and idempotent after the first call.
    ///
    /// This is what keeps a credit-starved sender from hanging when the connection dies: once the
    /// substrate is gone, no `credit` op will ever arrive, so nothing else would wake those tasks.
    /// Pass `RPCError(code: .unavailable)` for a teardown.
    ///
    /// **`RPCError`, not `any Error`.** Every caller -- ``RPCTransportCore/failAll(_:)``,
    /// `removeStream`, and the two tests -- already had one; nothing was ever narrowed or wrapped
    /// to make that fit. The value is stored verbatim in `State.failure` and rethrown verbatim by
    /// ``reserve(upTo:)``, so what a torn-down sender observes is unchanged by the typing. What a
    /// *cancelled* sender observes is a separate question and is still `CancellationError` -- see
    /// ``Slot``.
    ///
    /// Racing ``grant(_:)`` is well-defined in both directions, because both only transition slots
    /// that are still `.pending`: a waiter that `grant` already resolved keeps its `.granted(k)`
    /// and still returns `k` from `reserve` (the alternative -- failing it -- would drop bytes the
    /// window has already deducted, which is exactly L1). Its sender then discovers the failure on
    /// its next reservation, or from the substrate when the send fails.
    func fail(_ error: RPCError) {
        var toResume: [CheckedContinuation<Int, any Error>] = []

        state.withLock { s in
            if s.failure == nil { s.failure = error }
            // `order` holds exactly the still-`.pending` waiters; iterating it (rather than
            // `slots`) is what keeps a `.granted` slot from being clobbered.
            for token in s.order {
                guard case .pending(_, let parked) = s.slots[token] else { continue }
                if let parked {
                    s.slots[token] = nil
                    toResume.append(parked)
                } else {
                    s.slots[token] = .failed(error)
                }
            }
            s.order.removeAll()
        }

        // L7.
        for continuation in toResume { continuation.resume(throwing: error) }
    }
}

// ===========================================================================================
// MARK: - Receiver side
// ===========================================================================================

/// The receive-side ledger for one window: how much credit this side owes the peer, and when to
/// send it (§O4).
///
/// One per stream plus one for the connection, mirroring the sender's ``FlowControlWindow``s. §O4
/// replenishes **on consumption**, not on arrival: when a message is delivered to the application's
/// async iterator, its charge is `consumed` on both this stream's accountant and the connection's,
/// and whatever they return is sent as an `RPCOp.credit`. Crediting on *arrival* instead would make
/// the window measure the receive buffer rather than the application's appetite, which is the one
/// thing flow control exists to avoid.
///
/// # It takes the charge, not the payload length
///
/// A message's charge is ``FlowControl/charge(for:window:)``, and that -- not `payload.count` -- is
/// what belongs in ``consumed(_:)``. **Call the function; do not re-derive it.** The symmetry is the
/// whole point: the send side reserves the charge and the receive side credits the charge, so if
/// the two ever compute it differently the window grows or shrinks silently until a stream stalls
/// with nothing to point at. One definition, called twice, is what makes that impossible; two
/// hand-inlined clamps that must agree forever is the bug the rule was introduced to prevent.
///
/// An oversize message is thereby capped at exactly one window's worth. Note what that costs: the
/// cap is the entire **connection** window as well as the entire stream window, so an oversize
/// message serialises the *connection* -- every other stream's `message` op waits behind it until
/// the receiving application consumes. That is head-of-line blocking, not deadlock, and §O4's
/// stream-then-connection reservation order is what keeps it that way: two concurrent oversize
/// senders queue on the connection window's FIFO rather than hold-and-wait against each other. Do
/// not read "one at a time" as "other streams are unaffected" -- a retry or a timeout sized against
/// that reading will be wrong.
///
/// # Why `consumed` may return nil
///
/// Credit is batched: the accountant accumulates and only returns a value once the un-credited
/// total reaches **half the initial window** (then carries the remainder). This is HTTP/2's
/// standard practice -- one `WINDOW_UPDATE` per N messages rather than per message -- and it is why
/// the return type is optional at all.
///
/// Batching does not leak window, and that -- not any headroom claim -- is why it is safe. The
/// tempting argument, that the sender is always left `initial / 2` of headroom because
/// `available == initial - accumulated`, is **false**: it omits what has been received but not yet
/// pulled by the application. The true relation is the inequality `available ≤ initial -
/// accumulated`, and a sender really can sit at `available == 0` while `accumulated` is still one
/// byte below the threshold -- because the receiving application is holding messages it has not
/// consumed. That is not a stall to fix; it is backpressure working. The safety property is
/// conservation: `accumulated` monotonically absorbs every consumed byte, and the emitted credit
/// equals exactly what was consumed and is subtracted from the accumulation, so no byte is credited
/// twice and none is dropped. An application that keeps draining therefore always releases the
/// window it is holding.
///
/// # Lifetime
///
/// **The connection accountant must be created once per connection and outlive every stream on
/// it.** There is deliberately no flush: up to `threshold - 1` bytes sit un-credited at any moment,
/// which is harmless for a long-lived ledger that will cross the threshold on its next delivery,
/// and fatal for a short-lived one. A per-stream *connection* accountant would strand up to 32 766
/// bytes of the connection window per stream and wedge the connection after a handful of RPCs.
/// Per-*stream* accountants are fine to discard with their stream: the stream's window dies with
/// it, and §O4 credits the connection window through the connection's own accountant.
///
/// Not a class and not `Sendable` on purpose: this is plain accounting with no synchronisation of
/// its own, owned by whatever already serialises message delivery (the pipe's serial queue).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct WindowAccountant {

    /// Bytes consumed but not yet credited to the peer.
    private var accumulated = 0

    /// The batching threshold: half the initial window, and at least 1 so a degenerate window
    /// still makes progress instead of returning a zero-byte credit for every message.
    private let threshold: Int

    init(initial: Int = FlowControl.initialWindow) {
        precondition(
            initial >= 0 && initial <= FlowControl.maxWindow,
            "a flow-control window must start within 0...\(FlowControl.maxWindow); got \(initial)")
        self.threshold = max(1, initial / 2)
    }

    /// Records one message delivered to the application.
    ///
    /// - Parameter bytes: the message's **charge** -- ``FlowControl/charge(for:window:)``, not its
    ///   raw length, and not a hand-written clamp that happens to agree with it today. The send
    ///   side reserves the value that same call returns.
    /// - Returns: the credit to send to the peer right now, or `nil` while the accumulation is
    ///   still below half the initial window. A returned value is subtracted from the
    ///   accumulation, so nothing is ever credited twice.
    mutating func consumed(_ bytes: Int) -> UInt32? {
        precondition(bytes >= 0, "consumed(_:) takes a byte count; got \(bytes)")
        accumulated += bytes
        guard accumulated >= threshold else { return nil }
        // Clamped so one enormous delivery cannot produce a credit the peer must reject (§O4's
        // 2^31-1 ceiling) -- the remainder stays accumulated and goes out with the next message.
        let credit = min(accumulated, FlowControl.maxWindow)
        accumulated -= credit
        return UInt32(credit)
    }

    /// Emits everything accumulated **regardless of the threshold**, for the one moment when
    /// there is no future delivery to carry a remainder: the stream this ledger belongs to is
    /// being removed.
    ///
    /// ``consumed(_:)``'s batching is safe precisely because a long-lived ledger crosses the
    /// threshold on some later delivery (see the type's "Lifetime" note). At a removal that
    /// promise expires: up to `threshold - 1` bytes -- as much as 32 766 with the default window
    /// -- would sit accumulated forever, permanently shrinking the peer's window by that much per
    /// removed stream. That is the same class of bug as L3's stranded charge, one layer down, and
    /// it is why the connection ledger's flush at removal has to ignore the threshold rather than
    /// merely be *offered* the bytes.
    ///
    /// - Returns: the credit to send now, or `nil` if nothing is accumulated. Clamped to §O4's
    ///   2³¹−1 ceiling exactly as ``consumed(_:)`` is, so an enormous accumulation needs a second
    ///   call rather than producing a credit the peer must reject.
    /// - Note: not "reset". The remainder above the ceiling stays accumulated, and the accountant
    ///   remains usable -- calling this on the **connection** ledger is normal and happens on
    ///   every stream removal; it does not retire the ledger.
    mutating func flush() -> UInt32? {
        guard accumulated > 0 else { return nil }
        let credit = min(accumulated, FlowControl.maxWindow)
        accumulated -= credit
        return UInt32(credit)
    }
}
