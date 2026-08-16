import XCTest
import Distributed
@testable import XPCActors

/// ``BackpressureManager`` -- the actor that bounds in-flight requests for a
/// ``XPCActorSystem/BackpressurePolicy``. Its logic is a designed reconstruction (Apple's
/// bodies do not resolve), so these unit tests are what validate it: the limit holds, a
/// release unblocks a waiter, a freed slot wakes the highest-priority waiter first, and a
/// cancelled waiter is resumed rather than leaked.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class BackpressureTests: XCTestCase {

    func testTheDisabledPolicyGrantsWithoutAToken() async {
        let manager = BackpressureManager<Int>(N: 5, enabled: false)
        let token = await manager.acquireSlot(for: 1)
        XCTAssertNil(token, "a disabled manager owes no token and imposes no limit")
    }

    func testTheLimitHoldsAndAReleaseUnblocks() async throws {
        let manager = BackpressureManager<Int>(N: 1, enabled: true)
        let first = await manager.acquireSlot(for: 1)
        XCTAssertNotNil(first, "the first slot is under the limit and granted at once")

        let unblocked = Flag()
        let waiter = Task { _ = await manager.acquireSlot(for: 2); unblocked.set() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(unblocked.isSet, "a second acquire must block at the limit")

        await manager.releaseSlot(token: first!)
        let woke = await waitUntil { unblocked.isSet }
        XCTAssertTrue(woke, "releasing the slot must unblock the waiter")
        waiter.cancel()
    }

    func testAFreedSlotWakesTheHighestPriorityWaiterFirst() async throws {
        let manager = BackpressureManager<Int>(N: 1, enabled: true)
        let held = await manager.acquireSlot(for: 0, priority: .medium)
        XCTAssertNotNil(held)

        let lowWoke = Flag()
        let highWoke = Flag()
        let low = Task { _ = await manager.acquireSlot(for: 1, priority: .background); lowWoke.set() }
        try await Task.sleep(for: .milliseconds(40))
        let high = Task { _ = await manager.acquireSlot(for: 2, priority: .high); highWoke.set() }
        try await Task.sleep(for: .milliseconds(40))

        await manager.releaseSlot(token: held!)
        let highOK = await waitUntil { highWoke.isSet }
        XCTAssertTrue(highOK, "the high-priority waiter should wake on the freed slot")
        XCTAssertFalse(lowWoke.isSet, "the low-priority waiter should still be blocked")
        low.cancel()
        high.cancel()
    }

    func testACancelledWaiterIsResumedNotLeaked() async throws {
        let manager = BackpressureManager<Int>(N: 1, enabled: true)
        let held = await manager.acquireSlot(for: 1)
        XCTAssertNotNil(held)

        let done = Flag()
        let waiter = Task { _ = await manager.acquireSlot(for: 2); done.set() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(done.isSet, "the waiter should be parked at the limit")

        waiter.cancel()
        let resumed = await waitUntil { done.isSet }
        XCTAssertTrue(resumed, "a cancelled waiter must be resumed (nil), never left dangling")
    }

    /// Integration: a policy set on a real (in-process transport) connection bounds the send
    /// path without breaking it -- several concurrent calls through a limit of 2 all complete,
    /// the third waiting for a slot to free rather than deadlocking or being dropped.
    func testABoundedConnectionStillCarriesConcurrentCalls() async throws {
        let serverSystem = XPCActorSystem("bp-server")
        let service = XPCActorSystem.InProcessService("test.backpressure.integration")
        let listening = Task {
            try await serverSystem.listen(on: service) { local in
                local.export(DirectGreeter(actorSystem: serverSystem), asServerActorFor: "greeter")
                return await local.activateThenWaitForCancellation()
            }
        }
        defer { listening.cancel() }
        guard await waitUntil({
            InProcessListenerRegistry.shared.receiver(for: service.name) != nil
        }) else {
            return XCTFail("the in-process listener never registered")
        }

        let client = XPCActorSystem("bp-client")
        let remote = try await client.makeRemoteInterface(to: service)
        remote.setBackpressurePolicy(.custom(maxConcurrentRequests: 2))
        let proxy: DirectGreeter = remote.import(clientActorFor: "greeter")

        async let a = proxy.greet(name: "1")
        async let b = proxy.greet(name: "2")
        async let c = proxy.greet(name: "3")
        let results = try await [a, b, c]
        XCTAssertEqual(Set(results), ["hello, 1", "hello, 2", "hello, 3"])
    }

    func testPolicyFactories() {
        XCTAssertFalse(XPCActorSystem.BackpressurePolicy.disabled.enabled)
        XCTAssertTrue(XPCActorSystem.BackpressurePolicy.default.enabled)
        let custom = XPCActorSystem.BackpressurePolicy.custom(maxConcurrentRequests: 7)
        XCTAssertTrue(custom.enabled)
        XCTAssertEqual(custom.maxConcurrentRequests, 7)
        XCTAssertNotEqual(XPCActorSystem.BackpressurePolicy.disabled,
                          XPCActorSystem.BackpressurePolicy.default)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
