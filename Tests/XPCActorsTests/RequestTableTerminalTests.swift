import XCTest
@testable import XPCActors

/// Once the transport is gone, a waiter registered afterwards must still get an
/// outcome.
///
/// Found by reconstructing Apple's `RequestManager.Request.State`, which is
/// `initial -> (active(handler) | cancelled(B?)) -> completed`. The `cancelled`
/// case *stores* an outcome that arrived before any reply handler was installed,
/// and installing one then delivers it immediately. Our table had no equivalent:
/// `failAll` resumed the waiters that happened to be registered and left no trace,
/// so a caller that entered afterwards registered into a table nothing would ever
/// complete — and this protocol has no timeout, so that is a permanent hang.
///
/// It was masked rather than absent. `Transport.cancel` cancels the raw transport
/// *before* failing the table, so the later `send()` throws and `waitForReply`'s
/// catch path resumes the caller. The bug was real, and its only guard was an
/// ordering in a different type with nothing pinning it. Both are pinned here.
@available(macOS 14, *)
final class RequestTableTerminalTests: XCTestCase {

    /// Every call here is one that *hung* before the fix, so a regression must fail
    /// rather than wedge the suite. Two seconds is far beyond any legitimate path:
    /// nothing in these tests touches a real transport.
    private func withTimeout<T: Sendable>(
        _ seconds: Double = 2,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil {
                XCTFail("timed out after \(seconds)s -- the caller was never resumed",
                        file: file, line: line)
            }
            return first
        }
    }

    func testAWaiterRegisteredAfterFailAllStillGetsAnOutcome() async {
        let table = RequestTable()
        await table.failAll(with: .transportCancelled(message: "dead"))

        // `send` deliberately succeeds: this must not depend on the transport
        // reporting the failure a second time.
        let outcome = await withTimeout { await table.waitForReply(seq: 1, sending: { }) }

        guard case .failed(.transportCancelled(let message)) = outcome else {
            return XCTFail("expected the terminal failure, got \(outcome)")
        }
        XCTAssertEqual(message, "dead", "the original reason must survive, not a new one")
    }

    /// The failure is terminal, not one-shot: every later caller gets it.
    func testTheTerminalFailureIsRememberedForEveryLaterWaiter() async {
        let table = RequestTable()
        await table.failAll(with: .transportCancelled(message: "dead"))

        for seq in UInt64(1)...3 {
            let outcome = await withTimeout { await table.waitForReply(seq: seq, sending: { }) }
            guard case .failed = outcome else {
                return XCTFail("seq \(seq) did not get an outcome")
            }
        }
        let count = await table.pendingCount
        XCTAssertEqual(count, 0, "a terminal table must not accumulate waiters")
    }

    /// And `send` is not run once the table is terminal — there is nothing to send
    /// on, and running it would be a side effect the caller cannot observe the
    /// result of.
    func testSendIsNotRunOnATerminalTable() async {
        let table = RequestTable()
        await table.failAll(with: .transportCancelled(message: "dead"))

        let ran = Box()
        _ = await withTimeout { await table.waitForReply(seq: 1, sending: { ran.value = true }) }
        XCTAssertFalse(ran.value)
    }

    /// The masking path, pinned so the ordering it depends on cannot drift silently:
    /// through `Transport`, a send after cancellation reports the transport failure
    /// even without the terminal state.
    func testSendRequestAfterCancelReturnsRatherThanHanging() async throws {
        let (a, _) = InProcessRawTransport.makePair()
        let transport = Transport(debugName: "terminal", role: .initiator, rawTransport: a)
        try await transport.activate()
        transport.cancel(reason: "probe")

        let payload = try Packet.Payload(encoding: 1 as Int, userInfo: [:])
        let outcome = await withTimeout { await transport.sendRequest(seq: 7, payload) }
        guard case .failed = outcome else {
            return XCTFail("expected a failure outcome")
        }
    }
}

private final class Box: @unchecked Sendable {
    var value = false
}
