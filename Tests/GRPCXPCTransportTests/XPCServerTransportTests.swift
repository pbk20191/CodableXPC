import XCTest
import GRPCCore
import Synchronization
@testable import GRPCXPCTransport

/// Adapted from the task-6 brief's sketch: the brief predates `AcceptedStream`'s one-phase
/// accept (there is no `registerServerStream` two-call shape any more -- `listen` reads the
/// already-built `RPCStream` straight off `acceptedStreams`, see `AcceptedStream`'s doc comment
/// in `XPCConnection.swift`), and pins `ServerContext`'s cancellation handle to
/// `withServerContextRPCCancellationHandle(_:)` rather than a public `RPCCancellationHandle.init()`
/// call (see `XPCServerTransport.listen`'s doc comment for why that alternative doesn't wire up).
@available(macOS 15.0, *)
final class XPCServerTransportTests: XCTestCase {
    /// The echoed message plus everything the terminal `.status` frame is meant to prove: that
    /// it arrives at all, with the right code, and after the echoed message rather than before
    /// or instead of it. Built entirely inside the client-side task below and handed out through
    /// one `Mutex.withLock` write -- not through captured `var`s mutated from outside that task
    /// -- so nothing here needs cross-task synchronization beyond that single write/read pair.
    private struct EchoOutcome: Sendable {
        var echoed: [UInt8]?
        var finalStatus: Status?
        var messageArrivedBeforeStatus = false
    }

    /// Bounded per the review's IMPORTANT 2: originally this awaited `client.withStream(...)`
    /// directly on the test's own task, so a handler that returns without writing a status or
    /// finishing outbound would wedge the *test process* indefinitely (reproduced live: 12s+,
    /// no output) rather than failing fast. Racing the client call against
    /// `fulfillment(of:timeout:)` -- the same primitive the four lifecycle tests below already
    /// use -- bounds it the same way: run the call on its own `Task`, have that task fulfill an
    /// expectation when (or if) it returns, and `await fulfillment(timeout:)` rather than
    /// `await` the task directly. This is the pattern Task 7's streaming tests should copy.
    func testListenRunsHandlerAndHandlerCanReply() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let listenTask = Task {
            // `streamHandler` is non-throwing (`ServerTransport.listen`'s signature), so
            // `stream.inbound`'s `try await` iteration -- it can throw -- is caught locally
            // rather than propagated, unlike the brief's sketch which let it propagate.
            try await server.listen { stream, _ in
                do {
                    for try await part in stream.inbound {
                        if case .message(let b) = part {
                            try? await stream.outbound.write(.message(b))   // echo
                        }
                    }
                } catch {
                    return
                }
                try? await stream.outbound.write(.status(Status(code: .ok, message: ""), Metadata()))
                await stream.outbound.finish()
            }
        }
        defer { listenTask.cancel(); server.beginGracefulShutdown() }

        let outcomeBox = Mutex<EchoOutcome?>(nil)
        let clientReturned = expectation(description: "client.withStream returned")
        let clientTask = Task {
            var outcome = EchoOutcome()
            try? await client.withStream(
                descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "Echo"),
                options: .defaults
            ) { stream, _ in
                try await stream.outbound.write(.message([7]))
                await stream.outbound.finish()
                for try await part in stream.inbound {
                    switch part {
                    case .message(let b):
                        outcome.echoed = b
                        // Whether the message got here before any `.status` was seen -- proves
                        // ordering (message, then terminal status), not just that both arrived.
                        outcome.messageArrivedBeforeStatus = outcome.finalStatus == nil
                    case .status(let status, _):
                        outcome.finalStatus = status
                    default:
                        break
                    }
                }
            }
            outcomeBox.withLock { $0 = outcome }
            clientReturned.fulfill()
        }
        await fulfillment(of: [clientReturned], timeout: 5)
        clientTask.cancel()

        let outcome = outcomeBox.withLock { $0 }
        XCTAssertEqual(outcome?.echoed, [7])
        XCTAssertEqual(outcome?.finalStatus?.code, .ok, "the terminal status must reach the client, and must be .ok")
        XCTAssertEqual(outcome?.messageArrivedBeforeStatus, true, "the echoed message must arrive before the terminal status")
    }

    // MARK: - listen()/beginGracefulShutdown() lifecycle
    //
    // Mirrors `XPCClientTransportTests`' four `connect()`/`beginGracefulShutdown()` lifecycle
    // tests -- Task 5's review found real, reproducible bugs in exactly this shape, so `listen()`
    // is held to the same four orderings here: a second concurrent call must be refused (not
    // race the first for `acceptedStreams`' elements), a call after shutdown must return
    // immediately, a duplicate shutdown must not double-fail anything, and cancelling `listen()`'s
    // own task must unblock it rather than hang forever on `acceptedStreams`.
    //
    // As in `XPCClientTransportTests`, each test gives the racing call a short, generous grace
    // period (`Task.sleep`) to reach its running state before the next step.

    func testASecondConcurrentListenThrowsRatherThanRacingTheFirst() async throws {
        let harness = XPCPairHarness()
        // Keep `clientConn` alive for the whole test: dropping it lets it `deinit`, which
        // cancels its XPC session -- and because this is a real, paired XPC session (not an
        // in-process double), that cancellation reaches `serverConn`'s cancellation handler,
        // which calls `failAll` and finishes `serverConn.acceptedStreams` out from under the
        // very `listen()` call this test means to catch still running.
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)

        let firstReturned = expectation(description: "the first listen() returned")
        let first = Task {
            try? await server.listen { _, _ in }
            firstReturned.fulfill()
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // let the first listen() start accepting

        do {
            try await server.listen { _, _ in }
            XCTFail("a second concurrent listen() must not silently race the first")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .failedPrecondition)
        }

        server.beginGracefulShutdown()
        await fulfillment(of: [firstReturned], timeout: 5)
        first.cancel()
        _ = clientConn
    }

    func testListenCalledAfterShutdownReturnsImmediatelyRatherThanParkingForever() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)

        // Shutdown arrives before any `listen()` call at all -- `.idle -> .shutDown` directly.
        server.beginGracefulShutdown()

        let returned = expectation(description: "listen() returned without parking")
        Task {
            try? await server.listen { _, _ in }
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)
        _ = clientConn
    }

    func testASecondBeginGracefulShutdownIsSafe() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)

        let returned = expectation(description: "listen() returned")
        let task = Task {
            try? await server.listen { _, _ in }
            returned.fulfill()
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // let listen() start accepting

        // `connection.failAll(...)` (and the `AsyncStream.Continuation.finish()` inside it) is
        // itself safe to call twice, but this pins that a second `beginGracefulShutdown()` also
        // doesn't trap or double-fail anything at the `XPCServerTransport` level.
        server.beginGracefulShutdown()
        server.beginGracefulShutdown()

        await fulfillment(of: [returned], timeout: 5)
        task.cancel()
        _ = clientConn
    }

    func testCancellingListensOwnTaskUnblocksItRatherThanHanging() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)

        let returned = expectation(description: "listen() returned after its task was cancelled")
        let task = Task {
            // Cancellation must make `listen()` return normally, not hang and not throw -- see
            // `listen()`'s doc comment for why `GRPCServer.serve()` makes a thrown error on
            // cancellation actively worse (it gets reported as a transport failure).
            try await server.listen { _, _ in }
            returned.fulfill()
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // let listen() start accepting
        task.cancel()
        await fulfillment(of: [returned], timeout: 5)
        _ = clientConn
    }
}
