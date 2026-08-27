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
/// var remaining = payload.count
/// while remaining > 0 { remaining -= try await window.reserve(upTo: remaining) }
/// ```
///
/// Partial rather than all-or-nothing because an all-or-nothing reserve of a message larger than
/// the initial window could never be satisfied: the peer only replenishes as it *consumes*, and it
/// cannot consume a message this side has not finished sending.
///
/// # Suspension, not blocking
///
/// A waiter suspends its *task*; no thread is ever blocked. The caller is a gRPC handler on the
/// cooperative pool, and blocking one of those threads can deadlock the pool. Waiters are FIFO, so
/// a starved sender cannot be indefinitely overtaken by later arrivals.
///
/// # Reservations are spent, not returned
///
/// The window is replenished only by the peer's `credit` ops, which the peer sends as it consumes
/// what it received. A caller that reserves bytes and then does *not* send them has removed those
/// bytes from the window permanently -- so reserve immediately before the send, and if the send
/// then fails, fail the whole window (``fail(_:)``) rather than leaking the reservation. A caller
/// that genuinely needs to hand back an unspent reservation can do so with `try? grant(n)`; the
/// arithmetic is the same in both directions.
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
        /// Unreserved bytes. Invariant: `0 ... FlowControl.maxWindow`.
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
    var available: Int { state.withLock { $0.available } }

    /// How many senders are parked (or between taking a token and parking). Diagnostics only, for
    /// the same reason as ``available``: a test proving "no waiter was left behind" needs to be
    /// able to see one.
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
    /// - Parameter requested: how many bytes the sender still has to send. Must be at least 1.
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
    /// the previous design looped `0..<n` over it: one `release(UInt32.max)` spent a measured
    /// 450 seconds *inside* the mutex, blocking every sender and the connection's own teardown --
    /// a denial of service costing the peer a single op. Here the peer's magnitude only ever
    /// participates in a comparison and an addition. The wake-up loop below is bounded by the
    /// number of *waiters* (a local quantity: one per concurrent sender on this window), never by
    /// `bytes`, and each iteration retires exactly one waiter, so no value of `bytes` can make it
    /// run longer.
    ///
    /// The overflow check is done in `Int64` so it cannot itself wrap on any width of `Int`, and
    /// it happens *before* `available` is touched: a rejected credit leaves the window exactly as
    /// it was.
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

            s.available = Int(total)

            // Hand the new credit to the parked senders, oldest first. Bounded by `order.count`;
            // every iteration removes one token from `order`.
            while s.available > 0, let token = s.order.first {
                s.order.removeFirst()
                guard case .pending(let requested, let parked) = s.slots[token] else {
                    continue   // resolved by cancellation while it sat in the FIFO
                }
                let take = min(requested, s.available)
                // Deduction and ownership in one step: from here on `take` belongs to this waiter
                // and to nothing else. See `Slot`.
                s.available -= take
                if let parked {
                    s.slots[token] = nil
                    toResume.append((parked, take))
                } else {
                    s.slots[token] = .granted(take)
                }
            }
        }

        // L7: every resume happens after the lock is released, and a waiter appears in `toResume`
        // only if this call was the one that removed its slot -- so it is resumed exactly once.
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
/// async iterator, its byte count is `consumed` on both this stream's accountant and the
/// connection's, and whatever they return is sent as an `RPCOp.credit`. Crediting on *arrival*
/// instead would make the window measure the receive buffer rather than the application's appetite,
/// which is the one thing flow control exists to avoid.
///
/// # Why `consumed` may return nil
///
/// Credit is batched: the accountant accumulates and only returns a value once the unsent total
/// reaches **half the initial window** (then keeps the remainder). This is HTTP/2's standard
/// practice -- one `WINDOW_UPDATE` per N messages rather than per message -- and it is why the
/// return type is optional at all.
///
/// It cannot stall the sender. The two quantities are complements: at any moment the peer's
/// `available` plus this side's un-credited accumulation plus what is genuinely in flight equals
/// the window, so the accumulation reaches `initial / 2` exactly when the sender's `available` has
/// fallen to `initial / 2`. The sender is therefore always left at least 32 767 bytes of headroom
/// (at the default window) before any credit is owed to it, and the credit is sent well before it
/// could run dry.
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

    /// Records `bytes` delivered to the application.
    ///
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
