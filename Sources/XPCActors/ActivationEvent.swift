// Sources/XPCActors/ActivationEvent.swift
import Foundation

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
/// what the future is being used as. `Fuse` — Apple's `{ value: Atomic<Bool> }` one-shot —
/// is the `posted` flag under the same lock.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class ActivationEvent: @unchecked Sendable {

    private let lock = NSLock()
    private var posted: Bool
    private var waiters: [UnsafeContinuation<Void, Never>] = []

    /// Apple's `OwnedAwaitableEvent.owningTask`. Escalated by ``wait()``, never awaited.
    ///
    /// A closure rather than a `Task`, because the concrete `Task<Success, Never>` that owns
    /// a real activation carries a `Success` this type has no business naming — Apple's is
    /// generic over exactly that (`Task<LocalInterface.ActivationToken, Never>`), and the
    /// event's own value is `()`.
    private var escalateOwner: (@Sendable (TaskPriority) -> Void)?

    init(posted: Bool) {
        self.posted = posted
    }

    /// Whether the event has fired. The fast path ``wait()`` takes, and a test seam.
    var isPosted: Bool { lock.withLock { posted } }

    /// Install the task a waiter's priority should reach. Apple's `readyToReceive(_:)`
    /// stores the passed `Task` as the event's owner.
    func setOwner(_ escalate: @escaping @Sendable (TaskPriority) -> Void) {
        lock.withLock { escalateOwner = escalate }
    }

    /// Fire, once. Every parked waiter is resumed; later waiters do not park at all.
    ///
    /// Idempotent, because Apple's `posted` is a `Fuse` — a `caslb` one-shot whose result
    /// `post()` discards.
    func post() {
        let parked: [UnsafeContinuation<Void, Never>] = lock.withLock {
            guard !posted else { return [] }
            posted = true
            defer { waiters = [] }
            return waiters
        }
        // Resumed outside the lock: a resumed continuation can run inline on this thread and
        // reach straight back into the session, which takes locks of its own.
        for waiter in parked { waiter.resume() }
    }

    /// Escalate the owner, then await the latch. One await.
    func wait() async {
        // Read before parking, so an already-posted event costs no suspension -- Apple's
        // `wait()` opens with exactly this test (`ldaprb` + `tbz` on `posted`).
        let escalate: (@Sendable (TaskPriority) -> Void)? = lock.withLock {
            posted ? nil : escalateOwner
        }
        if lock.withLock({ posted }) { return }
        escalate?(Task.currentPriority)
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            let alreadyPosted: Bool = lock.withLock {
                if posted { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyPosted { continuation.resume() }
        }
    }
}
