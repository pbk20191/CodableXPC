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
@available(macOS 26, *)
final class RequestTableTerminalTests: XCTestCase {

    /// Every call here is one that *hung* before the fix, so a regression must fail
    /// rather than wedge the suite. Two seconds is far beyond any legitimate path:
    /// nothing in these tests touches a real transport.
    ///
    /// **Abandons rather than races.** An earlier version put the body and a sleeper in
    /// a `withTaskGroup` and cancelled the group on the first result — which is unsound,
    /// because `withTaskGroup` awaits every child on the way out, so a genuinely parked
    /// `CheckedContinuation` hangs the helper too. It happened to work here only because
    /// `waitForReply` installs a cancellation handler that `cancelAll()` could fire; a
    /// mutation that empties that handler brought the hang straight back, which is
    /// exactly the failure this helper exists to prevent. Now the body runs in an
    /// unstructured `Task` whose result is polled, and a body that never finishes is
    /// left running rather than awaited.
    private func withTimeout<T: Sendable>(
        _ seconds: Double = 2,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        let box = ResultBox<T>()
        let task = Task { box.value = await body() }
        defer { task.cancel() }

        let finished = await waitUntil(timeout: seconds) { box.value != nil }
        if !finished {
            XCTFail("timed out after \(seconds)s -- the caller was never resumed",
                    file: file, line: line)
        }
        return box.value
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
        let (a, _) = Transport.InProcessRawTransport.makePair()
        let transport = Transport(debugName: "terminal", rawTransport: a)
        try transport.activate()
        transport.cancel()

        let payload = try Packet.Payload(encoding: 1 as Int, userInfo: [:])
        let outcome = await withTimeout { await transport.sendRequest(seq: 7, payload) }
        guard case .failed = outcome else {
            return XCTFail("expected a failure outcome")
        }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private final class Box: @unchecked Sendable {
    var value = false
}

/// Carries the body's result out of the unstructured task. Safe because `waitUntil`
/// establishes the ordering: nothing reads `value` except after observing it non-nil.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
