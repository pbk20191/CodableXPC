// Sources/XPCActors/ActivationEvent.swift
import Foundation
import Synchronization

/// A one-shot "it has happened" that a task can wait on, and that a waiter's priority
/// reaches through.
///
/// Apple's pair, at the width this module needs:
///
/// - `UnownedAwaitableEvent<Value>` is `{ future: Combine.Future<Value, Never>, promise }`.
///   `wait()` is `await future.value`; `post()` calls the stored promise.
/// - `OwnedAwaitableEvent<Success>` is `{ unownedAwaitableEvent, owningTask, posted: Fuse }`,
///   `~Copyable`, 33 bytes measured.
///
/// **`owningTask` is escalated and never awaited, and that is the load-bearing fact.**
/// `OwnedAwaitableEvent.wait()` (`0x2ad4eca00`) is: fast-path on the `posted` fuse;
/// otherwise install a `withTaskPriorityEscalationHandler`, read `Task.currentPriority`,
/// call `Task.escalatePriority(to:)` on `owningTask`, and then await *the embedded
/// unowned event's future* — one await, not a join. So the owning task is a task whose
/// priority a waiter lifts because it is the task that will eventually post; a waiter
/// never observes its result. Writing this as a join would have made a waiter's completion
/// depend on the owner *finishing*, which is a different and wrong thing.
///
/// No `Combine.Future` here: this is one latch and a list of parked continuations, which is
/// what the future is being used as. `posted` is Apple's `Fuse` verbatim -- a
/// `Synchronization.Atomic<Bool>` one-shot, read locklessly on the fast path (Apple's
/// `ldaprb`+`tbz`) and tripped once under the state lock; the parked continuations and the
/// ticketing live under a `Synchronization.Mutex`.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class ActivationEvent: @unchecked Sendable {

    /// Apple's `posted: Fuse` -- `{ value: Atomic<Bool> }`. The lockless fast path reads it
    /// directly; the authoritative one-shot trip happens under ``state`` so a slow-path
    /// waiter either appended before the trip (and is drained by `post()`) or re-reads
    /// `true` and never parks.
    private let posted: Atomic<Bool>

    private struct State {
        var waiters: [UnsafeContinuation<Void, Never>] = []
        /// Waiters that gave their own name at the door, so ``waitUnlessCancelled()`` can
        /// wake exactly one of them without disturbing the rest. Keyed rather than appended
        /// because cancellation is per-waiter and `post()` is for everybody.
        var keyedWaiters: [UInt64: UnsafeContinuation<Void, Never>] = [:]
        /// Waiters whose task was cancelled in the window between taking a ticket and
        /// parking. Without this the cancellation is simply lost and the waiter parks
        /// forever -- the classic `withTaskCancellationHandler` race, and the reason the
        /// handler cannot just look in `keyedWaiters` and give up when it finds nothing.
        var cancelledBeforeParking: Set<UInt64> = []
        var nextWaiterID: UInt64 = 0
        /// Apple's `OwnedAwaitableEvent.owningTask`. Escalated by ``wait()``, never awaited.
        ///
        /// A closure rather than a `Task`, because the concrete `Task<Success, Never>` that
        /// owns a real activation carries a `Success` this type has no business naming --
        /// Apple's is generic over exactly that (`Task<LocalInterface.ActivationToken,
        /// Never>`), and the event's own value is `()`.
        var escalateOwner: (@Sendable (TaskPriority) -> Void)?
    }
    private let state = Mutex<State>(State())

    init(posted: Bool) {
        self.posted = Atomic(posted)
    }

    /// Whether the event has fired. The fast path ``wait()`` takes, and a test seam.
    var isPosted: Bool { posted.load(ordering: .acquiring) }

    /// Install the task a waiter's priority should reach. Apple's `readyToReceive(_:)`
    /// stores the passed `Task` as the event's owner.
    func setOwner(_ escalate: @escaping @Sendable (TaskPriority) -> Void) {
        state.withLock { $0.escalateOwner = escalate }
    }

    /// Fire, once. Every parked waiter is resumed; later waiters do not park at all.
    ///
    /// Idempotent, because `posted` is a `Fuse` -- a one-shot whose trip `post()` discards.
    func post() {
        var keyed: [UnsafeContinuation<Void, Never>] = []
        let parked: [UnsafeContinuation<Void, Never>] = state.withLock { state in
            // Trip the fuse under the lock: a slow-path waiter either appended before this
            // (and is drained here) or re-reads posted == true and never parks.
            guard !posted.load(ordering: .relaxed) else { return [] }
            posted.store(true, ordering: .releasing)
            keyed = Array(state.keyedWaiters.values)
            state.keyedWaiters.removeAll()
            defer { state.waiters = [] }
            return state.waiters
        }
        // Resumed outside the lock: a resumed continuation can run inline on this thread and
        // reach straight back into the session, which takes locks of its own.
        for waiter in parked { waiter.resume() }
        for waiter in keyed { waiter.resume() }
    }

    /// Wait, but give up if **this** task is cancelled.
    ///
    /// ``wait()`` deliberately is not cancellation-aware: an inbound execution parked on the
    /// activation gate is released by `cancellationCompleted()` posting the event, and it has
    /// an explicit `Task.isCancelled` check on the far side. That works because something else
    /// is guaranteed to post.
    ///
    /// A peer handler parked in ``Session/waitForCancellation()`` has no such guarantee. It is
    /// woken either by the session dying or by `TransportReceiver.unwindPeers()`, and unwinding
    /// is `task.cancel()` followed by `await task.value` -- so if the park ignores cancellation,
    /// unwinding a peer that is still connected deadlocks. That is not an exotic case; it is
    /// what shutdown looks like every time.
    ///
    /// One waiter, one ticket. `post()` still wakes everyone, and a cancellation wakes only the
    /// waiter it belongs to.
    func waitUnlessCancelled() async {
        let ticket: UInt64 = state.withLock {
            $0.nextWaiterID += 1
            return $0.nextWaiterID
        }
        await withTaskCancellationHandler {
            await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                let resumeNow: Bool = state.withLock { state in
                    // Drain the note unconditionally, even when `posted` also wins the race:
                    // otherwise a ticket that was cancelled-before-parking *and* then posted
                    // leaves its entry behind, because `post()` never touches this set. Bounded
                    // per one-shot event, but a set that only grows is still a set that only
                    // grows.
                    let wasCancelledEarly = state.cancelledBeforeParking.remove(ticket) != nil
                    if posted.load(ordering: .acquiring) || wasCancelledEarly { return true }
                    state.keyedWaiters[ticket] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation: UnsafeContinuation<Void, Never>? = state.withLock { state in
                if let parked = state.keyedWaiters.removeValue(forKey: ticket) { return parked }
                // Cancelled before the body parked. Leave a note; the body will find it.
                state.cancelledBeforeParking.insert(ticket)
                return nil
            }
            continuation?.resume()
        }
    }

    /// Escalate the owner, then await the latch. One await.
    func wait() async {
        // Read before parking, so an already-posted event costs no suspension -- Apple's
        // `wait()` opens with exactly this lockless test (`ldaprb` + `tbz` on `posted`).
        if posted.load(ordering: .acquiring) { return }
        let escalate: (@Sendable (TaskPriority) -> Void)? = state.withLock { state in
            posted.load(ordering: .acquiring) ? nil : state.escalateOwner
        }
        if posted.load(ordering: .acquiring) { return }
        escalate?(Task.currentPriority)
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let alreadyPosted: Bool = state.withLock { state in
                if posted.load(ordering: .acquiring) { return true }
                state.waiters.append(continuation)
                return false
            }
            if alreadyPosted { continuation.resume() }
        }
    }
}
