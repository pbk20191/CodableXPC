#if canImport(Darwin)
import XCTest
import Foundation
import XPCCodable

/// A peer that never replies, and what a cancelled caller can do about it.
///
/// The generated two-way client parks in `withCheckedThrowingContinuation`, and the only two
/// things that resume it are the reply block and the connection's error handler. Neither fires
/// for a peer that is alive and simply not answering -- so the call waits, and it waits past its
/// own `Task` being cancelled.
///
/// That is worse than a documented limitation. A structured-concurrency caller cannot reclaim
/// the task, `withTimeout`-style wrappers do not work, and there is no public NSXPC call that
/// bounds the wait -- `remoteObjectProxyWithTimeout:errorHandler:` exists but is private. The
/// fix belongs in the generated client, because that is what owns the continuation.
@XPCService
protocol Stall {
    func neverReplies() async throws -> Int
    func neverRepliesVoid() async throws
    func replies() async throws -> Int
}

/// Holds the reply blocks instead of calling them, which is what a hung peer looks like from the
/// outside: the connection is healthy, the method returned, and nothing ever comes back.
private final class StallImpl: Stall, @unchecked Sendable {
    func neverReplies() async throws -> Int {
        try await withCheckedThrowingContinuation { (_: CheckedContinuation<Int, any Error>) in }
    }
    func neverRepliesVoid() async throws {
        try await withCheckedThrowingContinuation { (_: CheckedContinuation<Void, any Error>) in }
    }
    func replies() async throws -> Int { 42 }
}

private final class StallDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = StallXPC.interface
        connection.exportedObject = StallXPC.exported(StallImpl())
        connection.resume()
        return true
    }
}

final class CancellationTests: XCTestCase {

    private var listener: NSXPCListener!
    private var delegate: StallDelegate!
    private var connection: NSXPCConnection!

    override func setUp() {
        super.setUp()
        listener = NSXPCListener.anonymous()
        delegate = StallDelegate()
        listener.delegate = delegate
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = StallXPC.interface
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        super.tearDown()
    }

    /// Cancelling the calling task ends the call.
    ///
    /// **Polled, not awaited.** `await task.value` on a call that never returns is a hung test
    /// process rather than a failing test, and this package has been wedged that way more than
    /// once. The box is what makes a regression a red test.
    func testCancellingATaskEndsAValueReturningCall() async throws {
        let outcome = Outcome<Int>()
        let remote = StallXPC.remote(connection)
        let task = Task {
            do { outcome.set(.success(try await remote.neverReplies())) }
            catch { outcome.set(.failure(error)) }
        }

        // Let the call reach the peer before cancelling, so this exercises an in-flight call
        // rather than a task that was cancelled before it started.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(outcome.value, "the peer replied; it is supposed to stall")

        task.cancel()
        let arrived = await waitFor { outcome.value != nil }
        XCTAssertTrue(arrived,
                      "a cancelled task never came back from a peer that does not reply")
        XCTAssertThrowsError(try outcome.value?.get()) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    /// The same for a call that returns nothing -- a separate generated body, so a separate test.
    func testCancellingATaskEndsAVoidCall() async throws {
        let outcome = Outcome<Void>()
        let remote = StallXPC.remote(connection)
        let task = Task {
            do { outcome.set(.success(try await remote.neverRepliesVoid())) }
            catch { outcome.set(.failure(error)) }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(outcome.value)

        task.cancel()
        let arrived = await waitFor { outcome.value != nil }
        XCTAssertTrue(arrived,
                      "a cancelled task never came back from a void call")
        XCTAssertThrowsError(try outcome.value?.get()) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    /// With cancellation working, a caller can impose its own timeout using nothing but public
    /// API -- which is why the generated client does not bake one in.
    ///
    /// This is the payoff test. A deadline is a policy, and policies belong to callers; what the
    /// generated code owes them is a call that can be abandoned.
    func testACallerCanImposeATimeoutOnceCancellationWorks() async throws {
        let remote = StallXPC.remote(connection)
        let outcome = Outcome<Int>()

        let work = Task {
            do { outcome.set(.success(try await remote.neverReplies())) }
            catch { outcome.set(.failure(error)) }
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            work.cancel()
        }

        let arrived = await waitFor { outcome.value != nil }
        XCTAssertTrue(arrived, "the timeout did not end the call")
        _ = await deadline.value
        XCTAssertThrowsError(try outcome.value?.get())
    }

    /// Cancellation must not have been bought by breaking the normal path.
    func testAReplyingCallStillReturnsItsValue() async throws {
        let got = try await StallXPC.remote(connection).replies()
        XCTAssertEqual(got, 42)
    }

    /// A task cancelled *before* the call starts fails without reaching the peer.
    ///
    /// The other end of the same guard: `withTaskCancellationHandler` runs its handler
    /// immediately when the task is already cancelled, so the continuation has to be claimable
    /// before it is ever parked.
    func testACallOnAnAlreadyCancelledTaskFailsImmediately() async throws {
        let outcome = Outcome<Int>()
        let remote = StallXPC.remote(connection)
        let task = Task {
            // Cancel before the first suspension point that matters.
            try? await Task.sleep(nanoseconds: 1)
            do { outcome.set(.success(try await remote.neverReplies())) }
            catch { outcome.set(.failure(error)) }
        }
        task.cancel()

        let arrived = await waitFor { outcome.value != nil }
        XCTAssertTrue(arrived,
                      "an already-cancelled task still hung on the call")
        XCTAssertThrowsError(try outcome.value?.get())
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}

private final class Outcome<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Result<Value, any Error>?
    var value: Result<Value, any Error>? { lock.withLock { _value } }
    func set(_ value: Result<Value, any Error>) { lock.withLock { if _value == nil { _value = value } } }
}
#endif
