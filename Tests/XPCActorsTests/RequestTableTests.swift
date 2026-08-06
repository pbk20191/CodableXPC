import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class RequestTableTests: XCTestCase {

    /// Lets a detached task publish its result without the test awaiting it.
    final class OutcomeBox: @unchecked Sendable {
        var outcome: RequestTable.Outcome?
    }

    private func payload(_ marker: UInt64) -> Packet.Payload {
        let body = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(body, "marker", marker)
        return Packet.Payload(unchecked: body)
    }

    func testReplyResumesTheWaiter() async throws {
        let table = RequestTable()
        async let outcome = table.waitForReply(seq: 1, sending: {})
        // Poll until the waiter is registered, then complete it.
        while await table.pendingCount == 0 { await Task.yield() }
        await table.complete(seq: 1, with: .reply(payload(7)))
        guard case .reply(let got) = await outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(Packet.uint64(got.object, "marker"), 7)
    }

    func testCompletingAnUnknownSeqIsIgnored() async {
        let table = RequestTable()
        // A late or duplicated reply must not crash or corrupt state.
        await table.complete(seq: 999, with: .reply(payload(1)))
        let count = await table.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testSecondReplyForTheSameSeqIsIgnored() async throws {
        let table = RequestTable()
        async let outcome = table.waitForReply(seq: 4, sending: {})
        while await table.pendingCount == 0 { await Task.yield() }
        await table.complete(seq: 4, with: .reply(payload(1)))
        _ = await outcome
        // Resuming a continuation twice would trap. This must be a no-op.
        await table.complete(seq: 4, with: .reply(payload(2)))
        let count = await table.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testDuplicateSeqFailsTheNewCallerAndLeavesTheExistingWaiter() async throws {
        // Callers supply the seq, so a duplicate is reachable. Overwriting waiters[seq]
        // would strand the displaced continuation: nothing would ever resume it, and
        // with no timeout in this protocol its caller would hang forever.
        let table = RequestTable()
        // A `Task`, not an `async let`: an async-let child is implicitly cancelled and
        // *awaited* at scope exit, so an early XCTFail return would hang here on a
        // regression -- the displaced waiter is exactly the one nothing can resume.
        let first = Task { await table.waitForReply(seq: 3, sending: {}) }
        while await table.pendingCount == 0 { await Task.yield() }

        // Run the duplicate in its own task and watch for it to *finish*, rather than
        // awaiting it. A regressed implementation parks the duplicate instead of
        // failing it, and a direct await would hang the suite instead of reddening it.
        let box = OutcomeBox()
        let duplicateTask = Task { box.outcome = await table.waitForReply(seq: 3, sending: {}) }
        guard await waitUntil({ box.outcome != nil }) else {
            duplicateTask.cancel()
            return XCTFail("the duplicate parked instead of failing -- waiters[3] was overwritten")
        }
        guard case .failed(.transportCancelled(let message)) = box.outcome else {
            return XCTFail("expected the second caller to fail, got \(String(describing: box.outcome))")
        }
        XCTAssertTrue(message.contains("duplicate request seq 3"), message)

        let count = await table.pendingCount
        XCTAssertEqual(count, 1, "the existing waiter must still be registered")
        await table.complete(seq: 3, with: .reply(payload(5)))
        guard await waitUntil({ await table.pendingCount == 0 }) else {
            return XCTFail("the original waiter was stranded -- nothing can resume it")
        }
        guard case .reply(let got) = await first.value else {
            return XCTFail("the original waiter must still be resolvable")
        }
        XCTAssertEqual(Packet.uint64(got.object, "marker"), 5)
    }

    func testSendFailureCompletesImmediately() async {
        let table = RequestTable()
        // Workaround for a typed-throws inference limitation on this toolchain: a
        // closure literal passed directly as a `throws(RawTransportError)` argument
        // fails to infer the typed throw ("invalid conversion of thrown error type
        // 'any Error' to 'RawTransportError'"). Binding it to an explicitly-typed
        // local first sidesteps the inference and is otherwise identical.
        let send: () throws(RawTransportError) -> Void = {
            throw RawTransportError.rawTransportCancelled(message: "pipe closed")
        }
        let outcome = await table.waitForReply(seq: 2, sending: send)
        guard case .failed(.transportCancelled(let message)) = outcome else {
            return XCTFail("expected a transport failure")
        }
        XCTAssertTrue(message.contains("pipe closed"))
        let count = await table.pendingCount
        XCTAssertEqual(count, 0, "a failed send must not leave a waiter behind")
    }

    func testFailAllDrainsEveryWaiter() async throws {
        let table = RequestTable()
        async let first = table.waitForReply(seq: 10, sending: {})
        async let second = table.waitForReply(seq: 11, sending: {})
        while await table.pendingCount < 2 { await Task.yield() }
        await table.failAll(with: .transportCancelled(message: "peer died"))
        let firstOutcome = await first
        let secondOutcome = await second
        for outcome in [firstOutcome, secondOutcome] {
            guard case .failed(.transportCancelled) = outcome else {
                return XCTFail("expected a transport failure")
            }
        }
        let count = await table.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testTaskCancellationUnblocksTheWaiter() async throws {
        let table = RequestTable()
        let task = Task { await table.waitForReply(seq: 20, sending: {}) }
        while await table.pendingCount == 0 { await Task.yield() }
        task.cancel()
        // There is no timeout in this protocol by design; Task cancellation is the
        // only way out of an unanswered request.
        let outcome = await task.value
        guard case .failed(.taskCancelled) = outcome else {
            return XCTFail("expected taskCancelled, got \(outcome)")
        }
    }
}
