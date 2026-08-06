import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class RequestTableTests: XCTestCase {

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
