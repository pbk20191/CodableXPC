import Dispatch
import Foundation
import Synchronization
import XPC

/// Flow-control tunables for the transport.
///
/// # Why the transport implements flow control at all
///
/// `RPCWriter.write(_:) async throws` is contractually "suspend until the element is accepted", and
/// gRPC exposes no window API a transport could borrow -- so the window has to be built here.
///
/// # The mechanism: reply-as-credit
///
/// A `.message` frame is sent as an XPC message **expecting a reply**, and that reply *is* the
/// flow-control credit. The receiving side does not produce the reply when the frame arrives; it
/// holds the received message (see ``CreditLedger``) and replies only once its consumer pulls the
/// element the frame carried. A writer that has a full window of unanswered messages suspends.
///
/// Every other frame kind (`openStream`, `metadata`, `halfClose`, `status`, `cancel`) is sent
/// one-way and consumes no credit. That is load-bearing, not incidental: a request's terminal
/// (`halfClose`) and a response's terminal (`.status`) must be sendable by a writer that is
/// *already* starved of credit, or an RPC whose consumer stopped reading could never be closed
/// (pinned by `BackpressureTests.testTerminationSucceedsWhileTheWriterIsStarvedOfCredit`).
///
/// # C3 -- granularity is connection-near, not per-stream (deviation D3)
///
/// The credit *accounting* here is per stream and per direction (one ``CreditWindow`` per
/// ``XPCOutboundWriter``, one ``CreditLedger`` per inbound ``StreamChannel``), but the *resource* it
/// rations is not: withholding a reply leaves an outstanding reply on the shared `XPCSession`, so a
/// stream with a stalled consumer shrinks the window available to every other stream on the same
/// connection. Streams are therefore not fully independent. That is an accepted v1 deviation (design
/// section 6/C3, deviation D3); true per-stream windows are a follow-up. What is *bounded* is what
/// matters for v1: the number of messages any one stalled stream can hold outstanding is at most
/// its window, so no stream can consume the connection without limit.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum XPCBackpressure {
    /// Initial per-stream, per-direction credit allowance, in **messages**.
    ///
    /// This must be **greater than one**, and that is the whole reason the number exists rather
    /// than the mechanism simply awaiting each reply in turn. With a window of one, a writer can
    /// have only a single unacknowledged message outstanding -- so a handler that writes a burst
    /// before it reads (or reads a burst before it writes) deadlocks against a peer doing the
    /// mirror image: each side is suspended in `write` waiting for a credit the other side will
    /// only produce once it starts reading, which it will only do after its own writes return.
    /// HTTP/2 avoids exactly this with a non-zero initial window (64 KiB); this is the same trick
    /// counted in messages instead of bytes.
    ///
    /// 32 is that 64 KiB expressed in messages at a ~2 KiB typical gRPC message: large enough that
    /// every burst the transport's own tests write (2, 3, and 200 messages) either fits entirely
    /// or is throttled well before exhausting memory, and small enough to still bound a runaway
    /// producer to a few tens of buffered messages per stream.
    ///
    /// Configurable per connection: `XPCConnection.init(session:role:queue:creditWindow:)` takes
    /// this as its default.
    static let defaultCreditWindow = 32
}

// MARK: - Write side: the per-stream credit window

/// One outbound stream direction's flow-control window: an async semaphore of
/// ``XPCBackpressure/defaultCreditWindow``-many permits, where a permit is "one message may be in
/// flight unacknowledged".
///
/// A writer ``acquire()``s before it sends and the credit reply ``release(_:)``s. Once the window is
/// empty, `acquire()` suspends -- which is what makes `RPCWriter.write(_:)` honour its "suspend
/// until accepted" contract.
///
/// Not a counter-with-a-condition-variable and not `DispatchSemaphore`: `acquire()` has to suspend
/// the *task*, never block the thread, because the caller is a gRPC handler on the cooperative pool
/// and blocking one of those threads can deadlock the pool. Waiters are FIFO so a starved writer
/// cannot be indefinitely overtaken.
///
/// Every waiter is identified by a token and lives in `waiters` until exactly one of four things
/// resolves it -- parked-then-granted, parked-then-failed, granted-before-it-parked, or cancelled --
/// so a resume can never be lost (a permanently parked writer) or delivered twice (which traps).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class CreditWindow: Sendable {
    /// A waiter's slot. `continuation` is `nil` between the moment the waiter takes a token and
    /// the moment it actually parks; `granted`/`cancelled` are how a resolution that lands inside
    /// that gap is remembered until the waiter arrives to pick it up.
    private struct Waiter {
        var continuation: CheckedContinuation<Void, any Error>?
        var granted = false
        var cancelled = false
    }

    private struct State {
        /// Permits not currently held by an in-flight message. Only ever grows when there is no
        /// waiter to hand the permit to directly.
        var available: Int
        var waiters: [UInt64: Waiter] = [:]
        /// `waiters`' keys in arrival order -- the FIFO discipline.
        var order: [UInt64] = []
        var nextToken: UInt64 = 0
        /// Set once the window is permanently broken (the connection died, or a credit reply
        /// failed). Sticky: later `acquire()`s throw immediately rather than parking forever.
        var failure: (any Error)?

        /// Drops a waiter that has been resolved by its own `acquire()`.
        mutating func retire(_ token: UInt64) {
            waiters[token] = nil
            if let index = order.firstIndex(of: token) { order.remove(at: index) }
        }
    }

    let capacity: Int
    private let state: Mutex<State>

    init(capacity: Int) {
        precondition(capacity >= 1,
                     "a credit window of 0 would suspend the first write forever; see "
                     + "XPCBackpressure.defaultCreditWindow for why it must also exceed 1")
        self.capacity = capacity
        self.state = Mutex(State(available: capacity))
    }

    private enum Admission {
        case granted
        case failed(any Error)
        case parked(UInt64)
    }

    /// Takes one permit, suspending until one is available.
    ///
    /// - Throws: the window's failure (an `RPCError(code: .unavailable)` from a dead connection or
    ///   a failed credit reply), or `CancellationError` if the calling task is cancelled while
    ///   suspended. Never returns without having taken a permit.
    func acquire() async throws {
        let admission: Admission = state.withLock { s in
            if let failure = s.failure { return .failed(failure) }
            // `order.isEmpty` keeps the fast path from overtaking an already-parked waiter.
            if s.order.isEmpty && s.available > 0 {
                s.available -= 1
                return .granted
            }
            s.nextToken += 1
            let token = s.nextToken
            s.waiters[token] = Waiter()
            s.order.append(token)
            return .parked(token)
        }

        switch admission {
        case .granted:
            return
        case .failed(let error):
            throw error
        case .parked(let token):
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let immediate: Result<Void, any Error>? = state.withLock { s in
                        // Unreachable-but-handled: nothing removes a waiter's slot without also
                        // resuming its stored continuation, and there is none stored yet.
                        guard var waiter = s.waiters[token] else { return .success(()) }
                        if let failure = s.failure { s.retire(token); return .failure(failure) }
                        if waiter.cancelled { s.retire(token); return .failure(CancellationError()) }
                        if waiter.granted { s.retire(token); return .success(()) }
                        waiter.continuation = continuation
                        s.waiters[token] = waiter
                        return nil
                    }
                    switch immediate {
                    case .success: continuation.resume()
                    case .failure(let error): continuation.resume(throwing: error)
                    case nil: break   // parked; a release or a failure resumes it
                    }
                }
            } onCancel: {
                let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                    guard var waiter = s.waiters[token] else { return nil }   // already resolved
                    if let parked = waiter.continuation { s.retire(token); return parked }
                    // Cancellation beat the park: remember it so the park resolves immediately.
                    waiter.cancelled = true
                    s.waiters[token] = waiter
                    return nil
                }
                continuation?.resume(throwing: CancellationError())
            }
        }
    }

    /// Returns `n` permits, handing each straight to the oldest waiting writer if there is one.
    ///
    /// Never exceeds ``capacity``: a peer that replies with more credit than it was owed cannot
    /// inflate this side's window (and so cannot defeat the bound the window exists to impose).
    func release(_ n: Int) {
        var toResume: [CheckedContinuation<Void, any Error>] = []
        state.withLock { s in
            for _ in 0..<max(0, n) {
                var handed = false
                while let token = s.order.first {
                    s.order.removeFirst()
                    guard var waiter = s.waiters[token] else { continue }
                    // A cancelled waiter's slot stays for its own `acquire()` to clear; the permit
                    // must go to someone still waiting for it.
                    if waiter.cancelled { continue }
                    if let continuation = waiter.continuation {
                        s.waiters[token] = nil
                        toResume.append(continuation)
                    } else {
                        waiter.granted = true
                        s.waiters[token] = waiter
                    }
                    handed = true
                    break
                }
                if !handed { s.available = min(capacity, s.available + 1) }
            }
        }
        toResume.forEach { $0.resume() }
    }

    /// Breaks the window permanently: every parked writer throws `error`, and so does every later
    /// `acquire()`. This is what keeps a credit-starved writer from hanging when the connection
    /// dies -- libxpc does **not** deliver anything to the reply handler of a cancelled session
    /// (verified by probe), so nothing else would ever wake those writers up.
    func fail(_ error: any Error) {
        var toResume: [CheckedContinuation<Void, any Error>] = []
        state.withLock { s in
            if s.failure == nil { s.failure = error }
            for token in s.waiters.keys {
                if let continuation = s.waiters[token]?.continuation {
                    s.waiters[token] = nil
                    toResume.append(continuation)
                }
                // A waiter that has not parked yet keeps its slot and sees `failure` when it does.
            }
            s.order.removeAll()
        }
        toResume.forEach { $0.resume(throwing: error) }
    }
}

// MARK: - Read side: the deferred credit replies

/// One received XPC message, held past the return of the incoming-message handler so its reply can
/// be produced later.
///
/// `@unchecked Sendable` because `XPCDictionary` is a public struct with no `Sendable` conformance,
/// while what it wraps is an immutable, refcounted, thread-safe `xpc_object_t`. Two things about
/// the deferral were verified against live XPC rather than assumed (see the task report):
/// returning `nil` from the incoming-message handler does not make libxpc synthesize a reply, so
/// the reply really is still ours to send afterwards; and `reply(_:)` works from an arbitrary
/// queue, at an arbitrary later time, with many messages outstanding and replied out of order.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private struct HeldReply: @unchecked Sendable {
    let message: XPCDictionary
}

/// One inbound stream's undelivered flow-control credit: the received `.message` frames whose XPC
/// replies are being *withheld* until this side's consumer pulls the elements they carried.
///
/// This is the read half of reply-as-credit. `hold(_:)` is called on the connection's serial queue
/// as each `.message` frame routes; `grantOne()` is called from the consumer's own task as each
/// message is pulled out of the inbound sequence (see ``CreditedInbound``). A consumer that stops
/// pulling therefore stops granting, and the peer's writer suspends.
///
/// Credit must never be withheld *forever*, or the peer's writer hangs instead of merely
/// throttling, so every way a stream can end grants whatever it is still holding: ``flush()`` on
/// the inbound sequence ending (cleanly or with an error), on `StreamChannel.failInbound`, and in
/// `deinit` as the backstop for a stream simply dropped mid-flight. After a flush the ledger stops
/// holding at all -- a late-arriving frame for a finished stream is credited immediately.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class CreditLedger: Sendable {
    private struct State {
        var held: [HeldReply] = []
        var isFlushed = false
    }

    private let streamID: StreamID
    private let state = Mutex(State())

    init(streamID: StreamID) { self.streamID = streamID }

    /// Withholds `message`'s reply until a consumer pulls the element it carried.
    func hold(_ message: XPCDictionary) {
        let grantImmediately: Bool = state.withLock { s in
            if s.isFlushed { return true }
            s.held.append(HeldReply(message: message))
            return false
        }
        if grantImmediately { grant(message) }
    }

    /// Grants one message's worth of credit back to the peer's writer. A no-op if nothing is held
    /// (the element pulled was not one this ledger is holding a reply for -- e.g. it arrived
    /// one-way, or the ledger has already been flushed).
    func grantOne() {
        let held = state.withLock { s -> HeldReply? in
            s.held.isEmpty ? nil : s.held.removeFirst()
        }
        if let held { grant(held.message) }
    }

    /// Grants everything still held and stops holding future replies.
    func flush() {
        let held = state.withLock { s -> [HeldReply] in
            s.isFlushed = true
            let pending = s.held
            s.held = []
            return pending
        }
        held.forEach { grant($0.message) }
    }

    deinit { flush() }

    private func grant(_ message: XPCDictionary) {
        // The credit travels as a real `.credit` frame rather than an empty reply so the reply is
        // self-describing on the wire and can carry a batched `n` later without a wire change.
        //
        // A failure to encode a two-field enum case is not a real possibility, but *stalling the
        // peer's writer* if it somehow happened would be: an empty reply still releases a permit
        // (see `XPCConnection.permits(inCreditReply:)`, which treats an undecodable reply as one),
        // so the fallback keeps the window moving rather than wedging the stream.
        if let object = try? XPCFrame.credit(streamID, n: 1).encodeToXPC() {
            message.reply(XPCDictionary(object))
        } else {
            message.reply(XPCDictionary())
        }
    }
}

/// An inbound part sequence that grants one credit each time its consumer pulls a message.
///
/// The demand signal has to come from the *pull*, not from delivery: a frame that has merely been
/// buffered has not been accepted by anyone, and crediting on arrival would make `write` never
/// suspend -- exactly the unbounded behaviour this task exists to remove. Wrapping the channel's
/// `AsyncThrowingStream` (rather than replacing it with a bespoke bounded buffer) keeps
/// `StreamChannel`'s reviewed ordering state machine and its "callers must invoke `accept` serially
/// per stream" contract untouched: this type only observes the hand-off to the consumer.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct CreditedInbound<Element: Sendable>: AsyncSequence, Sendable {
    typealias Failure = any Error

    let base: AsyncThrowingStream<Element, any Error>
    let ledger: CreditLedger
    /// True for the parts that were carried by a credit-bearing `.message` frame. Metadata and
    /// status parts arrive one-way and must not consume a held reply.
    let consumesCredit: @Sendable (Element) -> Bool

    func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), ledger: ledger, consumesCredit: consumesCredit)
    }

    struct Iterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<Element, any Error>.Iterator
        let ledger: CreditLedger
        let consumesCredit: @Sendable (Element) -> Bool

        mutating func next() async throws -> Element? {
            let element: Element?
            do {
                element = try await base.next()
            } catch {
                ledger.flush()   // the stream failed: never leave the peer's writer starved
                throw error
            }
            guard let element else {
                ledger.flush()   // the stream ended: same
                return nil
            }
            if consumesCredit(element) { ledger.grantOne() }
            return element
        }
    }
}

// MARK: - C1/C2: the coarse, connection-level delivery valve

/// `dispatch_suspend`/`dispatch_resume` on a connection's serial delivery queue: the blunt backstop
/// that stops *all* inbound delivery on a connection (design section 6, "coarse valve"). The
/// precise mechanism is the per-consumer credit above; this exists for a connection-wide pause
/// (memory pressure), and **nothing in the transport turns it on by itself**.
///
/// - C1 (suspend/resume balance): `DispatchQueue.resume()` without a matching `suspend()` traps
///   with `EXC_BAD_INSTRUCTION`, so the valve is a two-state machine under a lock -- never a
///   counter. `close()`/`open()` return whether they actually changed anything, and a repeated
///   call in either direction is a no-op rather than an unbalanced `suspend`/`resume`. Pinned by
///   `BackpressureTests.testTheCoarseValveNeverOverResumes` (50 toggles, doubled at both ends).
/// - C2 (never suspend a queue from within itself): code running *on* the queue cannot suspend it
///   and expect to resume itself -- the resume would be queued behind the suspension. The
///   `dispatchPrecondition(condition: .notOnQueue(queue))` in both methods makes that a loud trap
///   at the point of misuse instead of a silent wedge later, which is why the controller must live
///   off-actor: for an `XPCConnection`, whose serial queue *is* its isolation, "off-actor" means
///   any caller that is not itself running on that connection's queue.
///
/// One interaction to know before reaching for this: closing the valve also stops *credit replies*
/// from being delivered, because they arrive on the same queue. A connection paused this way will
/// therefore suspend its own writers as their windows drain -- which is the intended effect of a
/// whole-connection pause, but it does mean the valve is not a read-only throttle and must be
/// reopened by something that cannot itself be blocked by a suspended writer.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class ConnectionValve: Sendable {
    private enum State: Sendable { case running, suspended }

    private let state = Mutex<State>(.running)
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    var isClosed: Bool {
        state.withLock { if case .suspended = $0 { return true } else { return false } }
    }

    /// Suspends delivery. Returns `false` (and does nothing) if it was already closed.
    @discardableResult
    func close() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let shouldSuspend: Bool = state.withLock { current in
            if case .suspended = current { return false }
            current = .suspended
            return true
        }
        if shouldSuspend { queue.suspend() }
        return shouldSuspend
    }

    /// Resumes delivery. Returns `false` (and does nothing) if it was already open -- the call that
    /// would otherwise trap.
    @discardableResult
    func open() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let shouldResume: Bool = state.withLock { current in
            if case .running = current { return false }
            current = .running
            return true
        }
        if shouldResume { queue.resume() }
        return shouldResume
    }
}
