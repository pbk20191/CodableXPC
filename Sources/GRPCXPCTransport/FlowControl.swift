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
/// var remaining = charge          // §O4/§O5: min(payload.count, FlowControl.initialWindow)
/// while remaining > 0 { remaining -= try await window.reserve(upTo: remaining) }
/// ```
///
/// Partial rather than all-or-nothing for two reasons, and **neither of them is "so an oversize
/// message can be sent"**: an op body is atomic (§O2 has no chunking), so looping `reserve` on a
/// payload larger than the window would still park with nothing on the wire for the peer to
/// consume. That deadlock is closed by the *charge* instead -- §O4/§O5 charge a message
/// `min(payload.count, 65_535)`, computed identically on both sides from a length both already
/// know, so nothing can ever be charged more than the window it must fit in. What partial
/// reservation buys is:
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
        case failed(any Error)
    }

    private struct State {
        /// Unreserved bytes. Never negative. Bounded by `FlowControl.maxWindow` on every
        /// peer-driven path, because ``FlowControlWindow/grant(_:)`` refuses any credit that would
        /// breach it. ``FlowControlWindow/release(_:)`` is the one exception and deliberately so:
        /// it returns bytes that were already *inside* this window, so refusing them would destroy
        /// window rather than protect it. It can therefore push `available` above the ceiling, but
        /// only by as much as a peer over-granted while a reservation was outstanding -- and the
        /// peer's *next* credit is then rejected as the protocol error it is.
        var available: Int
        /// Every waiter that has taken a token and not yet been picked up by its own `reserve`.
        var slots: [UInt64: Slot] = [:]
        /// Tokens of the waiters still `.pending`, in arrival order -- the FIFO discipline, and
        /// the *only* set `grant`/`fail` walk. A token leaves `order` the instant its slot leaves
        /// `.pending`; a terminal slot lingers in `slots` until its own `reserve` collects it.
        var order: [UInt64] = []
        var nextToken: UInt64 = 0
        /// Sticky. Set by ``fail(_:)``; later reservations throw it rather than parking forever.
        var failure: (any Error)?

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
        case failed(any Error)
        case parked(UInt64)
    }

    /// Reserves up to `requested` bytes of window, suspending while the window is empty.
    ///
    /// - Parameter requested: how many bytes of the sender's *charge* remain unreserved. Must be
    ///   at least 1 -- a zero-byte reservation has nothing to wait for and no meaning, so it traps
    ///   rather than quietly returning. **A zero-length message is legal and common**
    ///   (`google.protobuf.Empty`): §O4 charges it nothing, and it must simply not reach this call.
    ///   The `while remaining > 0` loop in the type's doc comment already skips it; a straight-line
    ///   `reserve(upTo: payload.count)` does not, and would trap.
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
    func grant(_ bytes: UInt32) throws {
        var toResume: [(continuation: CheckedContinuation<Int, any Error>, bytes: Int)] = []

        try state.withLock { s in
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
    /// Racing ``grant(_:)`` is well-defined in both directions, because both only transition slots
    /// that are still `.pending`: a waiter that `grant` already resolved keeps its `.granted(k)`
    /// and still returns `k` from `reserve` (the alternative -- failing it -- would drop bytes the
    /// window has already deducted, which is exactly L1). Its sender then discovers the failure on
    /// its next reservation, or from the substrate when the send fails.
    func fail(_ error: any Error) {
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
/// §O4/§O5 charge a message `min(payload.count, FlowControl.initialWindow)`, and that clamped
/// number -- not `payload.count` -- is what belongs in ``consumed(_:)``. Both sides compute it from
/// a length both already know, so it needs no negotiation and no protocol change, and it is the
/// caller's job (Task 6's mux) to apply the identical clamp on the send side when reserving and on
/// the receive side when crediting. **The symmetry is the whole point**: credit that does not match
/// what was charged silently grows or shrinks the window. An oversize message is thereby capped at
/// exactly one window's worth, which is what makes oversize messages serialise one at a time per
/// stream instead of deadlocking a sender that could never reserve their full length.
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
    /// - Parameter bytes: the message's **charge** -- `min(payload.count, initial)` per §O4/§O5,
    ///   not its raw length. See the type's doc comment; the send side must clamp identically.
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
}
