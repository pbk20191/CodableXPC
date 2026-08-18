import Foundation

// ===========================================================================================
// MARK: - Backpressure
// ===========================================================================================
//
// Apple's outbound backpressure: cap the number of in-flight requests on a transport so a fast
// caller cannot outrun a slow peer. `BackpressurePolicy` is the knob; `BackpressureManager` is
// the mechanism, set on a transport via `setBackpressurePolicy`.
//
// **Designed reconstruction of the mechanism.** Only the *surface* resolves from the binary:
// `BackpressurePolicy { enabled: Bool, maxConcurrentRequests: UInt8 }` with `.disabled` /
// `.default` / `.custom(maxConcurrentRequests:)`; `BackpressureManager<A>` (an actor) with
// `init(queue:N:)`, `acquireSlot(for:) -> SendToken?`, `releaseSlot(token:)`, and per-priority
// state (`inflightCountByPrio`, `pendingRequestsByPrio: [Deque<PendingRequest>]`, `PriorityBucket`,
// `SendToken`). The slot-acquisition/queuing *logic* is async-fragmented and does not resolve,
// so it is reconstructed here to that surface and unit-tested. Two deliberate deviations, both
// because the alternatives are unresolvable or heavyweight: `.default`'s exact limit is a
// documented placeholder (the getter disassembles to garbage), and the pending queue is a plain
// array rather than Apple's `CollectionsInternal.Deque` (functionally equivalent for a bounded
// waiter queue, and this package takes no swift-collections dependency).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension XPCActorSystem {

    /// Apple's `XPCSystem.BackpressurePolicy`. [refl] two fields, `enabled: Bool` and
    /// `maxConcurrentRequests: UInt8`.
    public struct BackpressurePolicy: Hashable, Sendable {

        public let enabled: Bool
        public let maxConcurrentRequests: UInt8

        /// No limiting: the transport sends as fast as it likes. `(enabled: false)`.
        public static let disabled = BackpressurePolicy(enabled: false, maxConcurrentRequests: 0)

        /// **`.default`'s exact limit is unresolved** -- the getter disassembles to garbage in
        /// the live image, and there is no on-disk binary to extract. This is a documented
        /// placeholder so `.default` is a real, distinct, enabled policy; a caller that needs a
        /// specific bound should use ``custom(maxConcurrentRequests:)``.
        public static let `default` = BackpressurePolicy(
            enabled: true, maxConcurrentRequests: defaultMaxConcurrentRequests)

        /// Enable limiting to `maxConcurrentRequests` in-flight. Apple's
        /// `static custom(maxConcurrentRequests: UInt8)`.
        public static func custom(maxConcurrentRequests: UInt8) -> BackpressurePolicy {
            BackpressurePolicy(enabled: true, maxConcurrentRequests: maxConcurrentRequests)
        }

        /// [inf] placeholder -- see ``default``.
        static let defaultMaxConcurrentRequests: UInt8 = 100
    }
}

/// Apple's `XPCDistributed.BackpressureManager<A>` -- the actor that enforces a
/// ``XPCActorSystem/BackpressurePolicy`` by handing out a bounded number of send slots, keyed by
/// request id `A` and ordered by priority so a flood of low-priority work cannot starve a
/// high-priority request.
///
/// [sym] `init(queue:N:)`, `acquireSlot(for:) async -> SendToken?`, `releaseSlot(token:)`, with
/// `inflightCountByPrio`, `pendingRequestsByPrio`, `PriorityBucket`, `SendToken`, `PendingRequest`.
/// The slot-acquisition/queuing logic below is a designed reconstruction of that surface (the
/// bodies do not resolve); it uses arrays where Apple uses `Deque` (see the file note).
///
/// It conforms to ``ActorBackedByDispatchSerialQueue`` as Apple's does, so its executor *is* a
/// `DispatchSerialQueue` -- which gives it Apple's synchronous entry (`syncToActor`) on top of
/// the async actor API. The existing `async` `acquireSlot`/`releaseSlot` keep working over that
/// executor; Apple additionally reaches in *synchronously* (a `syncToActor ... -> Bool` slot
/// grant), a path the async surface here does not yet expose.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
actor BackpressureManager<A: Hashable & Sendable>: ActorBackedByDispatchSerialQueue {

    /// The ``ActorBackedByDispatchSerialQueue/queue`` requirement -- the serial queue that is this
    /// actor's executor. Apple threads in the **transport's** single serial queue via
    /// `init(queue:N:)`, shared with the `RequestManager`; see ``Transport``.
    nonisolated let queue: DispatchSerialQueue

    /// Apple's `PriorityBucket: RawRepresentable<UInt8>` -- requests are bucketed into four
    /// priority bands so a freed slot wakes the highest-priority waiter first. `high` is `0` so
    /// iteration order is wake-order.
    enum PriorityBucket: UInt8, CaseIterable, Hashable {
        case high = 0, medium = 1, low = 2, background = 3

        init(_ priority: TaskPriority) {
            if priority >= .high { self = .high }
            else if priority >= .medium { self = .medium }
            else if priority >= .low { self = .low }
            else { self = .background }
        }
    }

    /// Apple's `SendToken` -- the receipt a granted slot hands back, presented to
    /// ``releaseSlot(token:)`` when the request completes. Carries what release needs.
    struct SendToken: Sendable {
        let id: A
        let bucket: PriorityBucket
    }

    /// Apple's `PendingRequest` -- a waiter parked because the transport is at capacity.
    private struct PendingRequest {
        let waiterID: UInt64
        let id: A
        let continuation: CheckedContinuation<SendToken?, Never>
    }

    /// Apple's `N` -- the maximum number of in-flight requests. `var` because the policy can be
    /// reconfigured on the live actor via ``apply(_:)`` (Apple's synchronous `setBackpressurePolicy`
    /// path).
    var N: UInt8
    private var isEnabled: Bool

    /// Apple's `inflightCountByPrio` / `pendingRequestsByPrio`, one entry per ``PriorityBucket``.
    private var inflightByBucket: [Int]
    private var pendingByBucket: [[PendingRequest]]

    private var nextWaiterID: UInt64 = 0

    /// Apple's `init(queue:N:)`. `queue` is the transport's shared serial queue and becomes this
    /// actor's executor; it defaults to a fresh queue only for standalone construction (tests),
    /// where Apple would still be handed the transport's.
    init(queue: DispatchSerialQueue = DispatchSerialQueue(label: "XPCTransport-BackpressureManager"),
         N: UInt8, enabled: Bool) {
        self.queue = queue
        self.N = N
        self.isEnabled = enabled
        let bucketCount = PriorityBucket.allCases.count
        self.inflightByBucket = Array(repeating: 0, count: bucketCount)
        self.pendingByBucket = Array(repeating: [], count: bucketCount)
    }

    private func totalInflight() -> Int { inflightByBucket.reduce(0, +) }

    /// Reconfigure the live limiter to `policy`, returning whether limiting is now active.
    ///
    /// This is the isolated body Apple's `Transport.setBackpressurePolicy` reaches **synchronously**
    /// through ``ActorBackedByDispatchSerialQueue/syncToActor(_:file:line:)`` -- the whole reason
    /// the manager is a `DispatchSerialQueue`-backed actor rather than a plain one: a non-`async`
    /// `setBackpressurePolicy` cannot `await`, so it hops onto the queue and mutates in place.
    ///
    /// [sym] Apple runs *two* `syncToActor` closures here (one `-> Bool`, one `-> ()`); the exact
    /// division does not resolve. [inf] Reconstructed as a single apply: on disable it resumes every
    /// parked waiter with `nil` (they proceed unthrottled, matching ``acquireSlot(for:priority:)``'s
    /// disabled path) and zeroes the in-flight counts, so nothing stays blocked under a bound that
    /// no longer applies.
    ///
    /// Takes `N`/`enabled` rather than the `XPCActorSystem.BackpressurePolicy` struct so this stays
    /// at the manager's macOS-14 floor (the policy type is nested in the macOS-15 `XPCActorSystem`).
    func apply(N: UInt8, enabled: Bool) -> Bool {
        self.N = N
        self.isEnabled = enabled
        if !isEnabled {
            for bucket in 0..<pendingByBucket.count {
                while !pendingByBucket[bucket].isEmpty {
                    pendingByBucket[bucket].removeFirst().continuation.resume(returning: nil)
                }
            }
            inflightByBucket = Array(repeating: 0, count: PriorityBucket.allCases.count)
        }
        return isEnabled
    }

    /// Acquire a send slot for `id` at `priority`. `nil` when backpressure is disabled (the
    /// caller proceeds and owes no release). Otherwise a ``SendToken`` -- immediately if a slot
    /// is free, or after suspending until one is released, highest priority first. A cancelled
    /// waiter is removed and resumed with `nil`.
    func acquireSlot(for id: A, priority: TaskPriority = .medium) async -> SendToken? {
        guard isEnabled else { return nil }
        let bucket = PriorityBucket(priority)
        if totalInflight() < Int(N) {
            inflightByBucket[Int(bucket.rawValue)] += 1
            return SendToken(id: id, bucket: bucket)
        }
        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SendToken?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                pendingByBucket[Int(bucket.rawValue)].append(
                    PendingRequest(waiterID: waiterID, id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Release a slot obtained from ``acquireSlot(for:priority:)`` and wake the highest-priority
    /// waiter, if any.
    func releaseSlot(token: SendToken) {
        inflightByBucket[Int(token.bucket.rawValue)] -= 1
        for bucket in 0..<pendingByBucket.count where !pendingByBucket[bucket].isEmpty {
            let next = pendingByBucket[bucket].removeFirst()
            inflightByBucket[bucket] += 1
            next.continuation.resume(
                returning: SendToken(id: next.id, bucket: PriorityBucket(rawValue: UInt8(bucket))!))
            return
        }
    }

    private func cancelWaiter(_ waiterID: UInt64) {
        for bucket in 0..<pendingByBucket.count {
            if let index = pendingByBucket[bucket].firstIndex(where: { $0.waiterID == waiterID }) {
                let waiter = pendingByBucket[bucket].remove(at: index)
                waiter.continuation.resume(returning: nil)
                return
            }
        }
    }
}
