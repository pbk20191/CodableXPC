import XCTest
import GRPCCore
@testable import GRPCXPCTransport

/// Adapted from the task-5 brief's sketch: the brief predates `AcceptedStream`'s one-phase
/// accept (there is no `registerServerStream`/pending-table two-call shape any more -- see
/// `AcceptedStream`'s doc comment in `XPCConnection.swift`), so the server half here reads the
/// already-built `RPCStream` straight off `acceptedStreams` instead of registering it separately.
@available(macOS 15.0, *)
final class XPCClientTransportTests: XCTestCase {
    func testWithStreamOpensAndWritesARequestMessage() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let client = XPCClientTransport(connection: clientConn)

        async let serverSaw: GRPCSwiftData? = {
            var it = serverConn.acceptedStreams.makeAsyncIterator()
            guard let accepted = await it.next() else { return nil }
            for try await part in accepted.stream.inbound {
                if case .message(let b) = part { return b }
            }
            return nil
        }()

        try await client.withStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "M"),
            options: .defaults
        ) { stream, _ in
            try await stream.outbound.write(.message([42]))
            await stream.outbound.finish()
        }
        let bytes = try await serverSaw
        XCTAssertEqual(bytes, [42])
    }

    // MARK: - connect()/beginGracefulShutdown() lifecycle
    //
    // A first pass stored the parked continuation in a single `Mutex<CheckedContinuation?>`
    // slot. That let a second, concurrent `connect()` silently overwrite the first's
    // continuation -- reproducible live as a "SWIFT TASK CONTINUATION MISUSE" runtime message,
    // with the first caller stranded parked forever. The four tests below pin the explicit
    // `ConnectState` (`.idle` / `.connected` / `.shutDown`) that replaced it, plus cancellation
    // of `connect()`'s own task, which the single-slot shape never handled at all.
    //
    // Every test gives the racing call a short, generous grace period (`Task.sleep`) to reach
    // its parked state before the next step -- the same non-guaranteed-but-practically-reliable
    // pattern already used by `XPCConnectionTests` for same-process real-XPC timing (see e.g.
    // `testMetadataAndMessageFramesReachTheAcceptedStreamInOrder`'s comment).

    func testASecondConcurrentConnectThrowsRatherThanClobberingTheFirst() async throws {
        let harness = XPCPairHarness()
        let (clientConn, _) = try await harness.connectPair()
        let client = XPCClientTransport(connection: clientConn)

        let firstReturned = expectation(description: "the first connect() returned")
        let first = Task {
            try? await client.connect()
            firstReturned.fulfill()
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // let the first connect() park

        do {
            try await client.connect()
            XCTFail("a second concurrent connect() must not silently clobber the first")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .failedPrecondition)
        }

        // Release the first so the test doesn't leak a parked task.
        client.beginGracefulShutdown()
        await fulfillment(of: [firstReturned], timeout: 5)
        first.cancel()
    }

    func testConnectCalledAfterShutdownReturnsImmediatelyRatherThanParkingForever() async throws {
        let harness = XPCPairHarness()
        let (clientConn, _) = try await harness.connectPair()
        let client = XPCClientTransport(connection: clientConn)

        // Shutdown arrives before any `connect()` call at all -- `.idle -> .shutDown` directly.
        client.beginGracefulShutdown()

        let returned = expectation(description: "connect() returned without parking")
        Task {
            try? await client.connect()
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)
    }

    func testASecondBeginGracefulShutdownResumesConnectAtMostOnce() async throws {
        let harness = XPCPairHarness()
        let (clientConn, _) = try await harness.connectPair()
        let client = XPCClientTransport(connection: clientConn)

        let returned = expectation(description: "connect() returned")
        let task = Task {
            try? await client.connect()
            returned.fulfill()
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // let connect() park

        // A double-resume of the same `CheckedContinuation` traps; if this doesn't, the fix holds.
        client.beginGracefulShutdown()
        client.beginGracefulShutdown()

        await fulfillment(of: [returned], timeout: 5)
        task.cancel()
    }

    func testCancellingConnectsOwnTaskUnblocksItRatherThanHanging() async throws {
        let harness = XPCPairHarness()
        let (clientConn, _) = try await harness.connectPair()
        let client = XPCClientTransport(connection: clientConn)

        let returned = expectation(description: "connect() returned after its task was cancelled")
        let task = Task {
            // Cancellation must make `connect()` return normally, not hang and not throw --
            // see `connect()`'s doc comment for why `GRPCClient.runConnections()` makes a thrown
            // error on cancellation actively worse (it gets reported as a transport failure).
            try await client.connect()
            returned.fulfill()
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // let connect() park
        task.cancel()
        await fulfillment(of: [returned], timeout: 5)
    }
}
