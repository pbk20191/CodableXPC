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

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
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
/// The logic below is a designed reconstruction of that surface (the bodies do not resolve); it
/// is a plain `actor` where Apple's is `ActorBackedByDispatchSerialQueue` (same serial
/// guarantee), and uses arrays where Apple uses `Deque` (see the file note).
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
actor BackpressureManager<A: Hashable & Sendable> {

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

    /// Apple's `N` -- the maximum number of in-flight requests.
    let N: UInt8
    private let isEnabled: Bool

    /// Apple's `inflightCountByPrio` / `pendingRequestsByPrio`, one entry per ``PriorityBucket``.
    private var inflightByBucket: [Int]
    private var pendingByBucket: [[PendingRequest]]

    private var nextWaiterID: UInt64 = 0

    /// Apple's `init(queue:N:)` -- the serial queue is subsumed by actor isolation here.
    init(N: UInt8, enabled: Bool) {
        self.N = N
        self.isEnabled = enabled
        let bucketCount = PriorityBucket.allCases.count
        self.inflightByBucket = Array(repeating: 0, count: bucketCount)
        self.pendingByBucket = Array(repeating: [], count: bucketCount)
    }

    private func totalInflight() -> Int { inflightByBucket.reduce(0, +) }

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
