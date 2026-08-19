import XCTest
import GRPCCore
import Synchronization
@testable import GRPCXPCTransport

/// Task 7: proves all four gRPC call shapes work over the XPC mux.
///
/// Unary is already covered by `XPCServerTransportTests.testListenRunsHandlerAndHandlerCanReply`
/// -- these three exercise the streaming shapes: server-streaming (1 request message, many
/// replies), client-streaming (many request messages, 1 reply), and bidi (interleaved).
///
/// Bounded per Task 6's reviewed pattern (see `XPCServerTransportTests`'s doc comment): the
/// client call runs on its own `Task`, accumulates into a local `var` owned by that task's
/// closure, writes the finished value into a `Mutex<T?>` exactly once, then fulfils an
/// expectation. The test body only reads the `Mutex` after `fulfillment(of:timeout:)` returns.
@available(macOS 15.0, *)
final class CallTypeTests: XCTestCase {
    private struct Outcome: Sendable {
        var messages: [[UInt8]] = []
        var finalStatus: Status?
    }

    func testServerStreaming() async throws {
        try await run(clientMessages: [[1]], serverReplies: [[1], [2], [3]])
    }

    func testClientStreaming() async throws {
        try await run(clientMessages: [[1], [2], [3]], serverReplies: [[6]])
    }

    func testBidiStreaming() async throws {
        try await run(clientMessages: [[1], [2]], serverReplies: [[9], [8]])
    }

    private func run(clientMessages: [[UInt8]], serverReplies: [[UInt8]]) async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let listenTask = Task {
            try await server.listen { stream, _ in
                do {
                    for try await part in stream.inbound { _ = part }   // drain requests
                } catch {
                    return
                }
                for reply in serverReplies {
                    try? await stream.outbound.write(.message(reply))
                }
                try? await stream.outbound.write(.status(Status(code: .ok, message: ""), Metadata()))
                await stream.outbound.finish()
            }
        }
        defer { listenTask.cancel(); server.beginGracefulShutdown() }

        let outcomeBox = Mutex<Outcome?>(nil)
        let clientReturned = expectation(description: "client.withStream returned")
        let clientTask = Task {
            var outcome = Outcome()
            try? await client.withStream(
                descriptor: MethodDescriptor(fullyQualifiedService: "p.S", method: "M"),
                options: .defaults
            ) { stream, _ in
                for m in clientMessages {
                    try await stream.outbound.write(.message(m))
                }
                await stream.outbound.finish()
                for try await part in stream.inbound {
                    switch part {
                    case .message(let b):
                        outcome.messages.append(b)
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
        XCTAssertEqual(outcome?.messages, serverReplies)
        XCTAssertEqual(outcome?.finalStatus?.code, .ok, "the terminal status must reach the client")
    }

    /// `testBidiStreaming` above (the brief's literal shape) has the client write everything and
    /// finish *before* it ever reads, and the server read everything to `halfClose` *before* it
    /// writes anything -- the exact "write-all-then-read vs read-all-then-write-all" ordering the
    /// brief calls out as a deadlock risk. It passes, but only because writes never block: there
    /// is no flow control yet (Task 8), so the client's few small writes land on the wire and the
    /// server drains them without either side ever waiting on the other.
    ///
    /// That test alone doesn't prove the mux delivers genuinely *interleaved* per-message
    /// round-trips -- a ping-pong bidi handler (reply to message N before reading message N+1) is
    /// what Task 10's real bidi services are more likely to look like. This test drives exactly
    /// that shape: the server echoes each request message back doubled as soon as it arrives, and
    /// the client reads each reply concurrently with writing the next request, on its own child
    /// task (`async let`) rather than sequentially -- so both sides' inbound and outbound are live
    /// on the same stream at the same time.
    func testBidiStreamingGenuinelyInterleaved() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()
        let server = XPCServerTransport(connection: serverConn)
        let client = XPCClientTransport(connection: clientConn)

        let clientMessages: [[UInt8]] = [[1], [2], [3]]
        let expectedReplies: [[UInt8]] = [[2], [4], [6]]   // server doubles each byte

        let listenTask = Task {
            try await server.listen { stream, _ in
                do {
                    for try await part in stream.inbound {
                        if case .message(let b) = part {
                            let doubled = b.map { $0 * 2 }
                            try? await stream.outbound.write(.message(doubled))   // reply per request, interleaved
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

        let outcomeBox = Mutex<Outcome?>(nil)
        let clientReturned = expectation(description: "interleaved client.withStream returned")
        let clientTask = Task {
            var outcome = Outcome()
            try? await client.withStream(
                descriptor: MethodDescriptor(fullyQualifiedService: "p.S", method: "M"),
                options: .defaults
            ) { stream, _ in
                async let reading: ([[UInt8]], Status?) = {
                    var msgs: [[UInt8]] = []
                    var status: Status?
                    for try await part in stream.inbound {
                        switch part {
                        case .message(let b): msgs.append(b)
                        case .status(let s, _): status = s
                        default: break
                        }
                    }
                    return (msgs, status)
                }()
                for m in clientMessages {
                    try await stream.outbound.write(.message(m))
                }
                await stream.outbound.finish()
                let (msgs, status) = try await reading
                outcome.messages = msgs
                outcome.finalStatus = status
            }
            outcomeBox.withLock { $0 = outcome }
            clientReturned.fulfill()
        }
        await fulfillment(of: [clientReturned], timeout: 5)
        clientTask.cancel()

        let outcome = outcomeBox.withLock { $0 }
        XCTAssertEqual(outcome?.messages, expectedReplies)
        XCTAssertEqual(outcome?.finalStatus?.code, .ok, "the terminal status must reach the client")
    }
}
