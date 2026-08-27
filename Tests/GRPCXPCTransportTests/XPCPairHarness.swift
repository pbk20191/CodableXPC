import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - L8: bounded async bodies
// ===========================================================================================

/// Thrown when a bounded body did not finish inside its wall-clock budget. The `XCTFail` has
/// already been recorded by then; this exists so the calling test stops rather than going on to
/// read a result that was never written.
struct BoundedBodyTimedOut: Error, CustomStringConvertible {
    let label: String
    let seconds: TimeInterval
    var description: String { "\(label) did not finish within \(seconds)s" }
}

/// L8's shape in one object: **write once into a `Mutex<T?>`, then fulfil an expectation.**
///
/// `@unchecked Sendable` for the reason the rest of this package is: the mutex *is* the
/// synchronisation for `cell`, and `XCTestExpectation.fulfill()` is thread-safe. `Result<Value, any
/// Error>` is not `Sendable` (`any Error` is not), which is the only reason this cannot be a
/// checked conformance -- the error is written and read under the lock.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class BoundedOutcome<Value: Sendable>: @unchecked Sendable {

    private let cell = Mutex<Result<Value, any Error>?>(nil)

    /// Fulfilled exactly once, by the first (and only) write.
    let expectation: XCTestExpectation

    init(label: String) {
        self.expectation = XCTestExpectation(description: label)
    }

    /// Records the outcome and releases the waiter. A second call is ignored, so a body that
    /// somehow completes twice cannot over-fulfil the expectation (which traps).
    func finish(_ outcome: Result<Value, any Error>) {
        let isFirst = cell.withLock { stored -> Bool in
            guard stored == nil else { return false }
            stored = outcome
            return true
        }
        if isFirst { expectation.fulfill() }
    }

    var stored: Result<Value, any Error>? { cell.withLock { $0 } }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension XCTestCase {

    /// Runs `body` on its own detached task and blocks this test until it finishes **or the
    /// timeout expires** -- never longer.
    ///
    /// This is the only way an async body should be entered in this suite. The transport under
    /// test has two ways to hang -- a streaming call that never terminates, and a drain that never
    /// completes -- and both of them hung the previous build's suite with no diagnosis at all. A
    /// timeout turns each of those into a named failure instead.
    ///
    /// The task is cancelled on the way out, on both paths: on the timeout path that is what stops
    /// a runaway body from holding two XPC sessions open into the next test.
    ///
    /// - Note: `Task.detached` rather than `Task` deliberately -- nothing here should inherit the
    ///   test's actor context, and a body that hopped to the main actor would deadlock against the
    ///   `XCTWaiter` blocking on this thread.
    func runBounded<Value: Sendable>(
        _ label: String = "bounded body",
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @Sendable @escaping () async throws -> Value
    ) throws -> Value {
        let outcome = BoundedOutcome<Value>(label: label)
        let task = Task.detached {
            do {
                outcome.finish(.success(try await body()))
            } catch {
                outcome.finish(.failure(error))
            }
        }
        defer { task.cancel() }

        guard XCTWaiter.wait(for: [outcome.expectation], timeout: timeout) == .completed else {
            XCTFail("\(label): timed out after \(timeout)s", file: file, line: line)
            throw BoundedBodyTimedOut(label: label, seconds: timeout)
        }
        guard let stored = outcome.stored else {
            XCTFail(
                "\(label): the expectation was fulfilled without an outcome", file: file, line: line)
            throw BoundedBodyTimedOut(label: label, seconds: timeout)
        }
        return try stored.get()
    }
}

// ===========================================================================================
// MARK: - The pair
// ===========================================================================================

/// Two `GRPCXPCTransport` transports joined by **two real XPC sessions in this process** -- an
/// anonymous `XPCListener` on the server side, its endpoint dialled on the client side.
///
/// Both halves come straight out of the production factories: `XPCServerTransport.anonymous()`
/// owns the listener and the accept path, and `connectingClient()` is the only place an
/// `XPCEndpoint` is dialled. **This type deliberately contains no accept code of its own** -- a
/// second accept path would have to re-derive the publish-before-you-return-the-`Decision` rule
/// that makes a mistake here a process death rather than a test failure (Task 5 §2.4), and the
/// transport already gets it right.
///
/// Two further hazards, both settled by *not* doing anything:
/// * no `pipe.onReceive` / `pipe.onPeerDeath` is installed here -- `RPCTransportCore.init` installs
///   both, weakly, and a second install replaces the core's and trips `XPCPipe`'s `precondition`;
/// * **no nudge blob.** The legacy harness sent an inert `.credit(0, n: 0)` to wake the listener's
///   incoming-session handler. Measured in Task 5 §2.1: the blob that wakes the handler *is*
///   delivered to the accepted pipe, so a nudge would arrive at the mux as a spurious op.
///
/// Hold on to the value: dropping `server` releases the listener and, with it, every accepted
/// session.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct XPCTransportPair: Sendable {
    let server: XPCServerTransport
    let client: XPCClientTransport

    /// The listener is active and the client's session is activated when this returns. Nothing is
    /// *connected* in any observable sense yet: the listener's incoming-session closure does not
    /// run at dial time, it runs when the first blob arrives (Task 5 §2.1) -- which is the first
    /// write of the first RPC.
    static func make() throws -> XPCTransportPair {
        let server = try XPCServerTransport.anonymous()
        return XPCTransportPair(server: server, client: try server.connectingClient())
    }
}

/// Everything a test body needs: the two transports, and the `GRPCClient`/`GRPCServer` running
/// over them.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct RunningXPCPair: Sendable {
    let transports: XPCTransportPair
    let client: GRPCClient<XPCClientTransport>
    let server: GRPCServer<XPCServerTransport>
}

/// The end-to-end harness. Two entry points, one per layer:
///
/// * ``withPair(router:_:)`` -- a real `GRPCClient`/`GRPCServer` pair. This is what a call-type or
///   an interceptor test wants.
/// * ``withTransports(streamHandler:_:)`` -- the raw `ClientTransport`/`ServerTransport` seam, with
///   `listen(streamHandler:)` and `connect()` running but no gRPC runtime above them. This is what
///   a lifecycle or flow-control test wants, because it can call `withStream` directly and see the
///   transport's own refusals rather than whatever the runtime rewrites them into.
///
/// Both bring the pair up, run the body, and shut both halves down before returning. Neither
/// imposes a timeout: wrap the call in ``XCTestCase/runBounded(_:timeout:file:line:_:)``, which is
/// where L8 lives.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum XPCPairHarness {

    /// Brings up a `GRPCServer` over an anonymous `XPCServerTransport` and a `GRPCClient` over a
    /// transport dialled at its endpoint, runs `body`, then shuts both down gracefully and waits
    /// for both to stop.
    ///
    /// Shutdown order is client first, then server: closing the client's session is what makes the
    /// server see peer death and retire the connection, so the server's own drain then has nothing
    /// left to wait for. Both are graceful -- nothing here cancels a task, so this path exercises
    /// the drain rather than the forceful teardown.
    ///
    /// - Important: `body` must issue at least one RPC. `GRPCClient.beginGracefulShutdown()` on a
    ///   client that has not started yet moves it straight to `.stopped` **without** telling the
    ///   transport, and the `runConnections()` that follows then throws `clientIsStopped`. That is
    ///   grpc-swift's documented "`withGRPCClient` with an empty body" hazard, not this transport's;
    ///   a body that makes a call cannot reach it.
    static func withPair<Result: Sendable>(
        router: RPCRouter<XPCServerTransport>,
        _ body: @Sendable (RunningXPCPair) async throws -> Result
    ) async throws -> Result {
        let transports = try XPCTransportPair.make()
        let pair = RunningXPCPair(
            transports: transports,
            client: GRPCClient(transport: transports.client),
            server: GRPCServer(transport: transports.server, router: router))

        return try await withThrowingTaskGroup(of: Void.self, returning: Result.self) { group in
            group.addTask { try await pair.server.serve() }
            group.addTask { try await pair.client.runConnections() }

            // Kept rather than propagated, so the shutdown below happens on the failing path too:
            // a body that threw must still take both halves down, or a listener and two sessions
            // leak into every test that follows.
            let outcome: Swift.Result<Result, any Error>
            do {
                outcome = .success(try await body(pair))
            } catch {
                outcome = .failure(error)
            }

            pair.client.beginGracefulShutdown()
            pair.server.beginGracefulShutdown()

            // **The body's error wins.** A broken body usually makes the teardown fail too, and
            // the teardown's error is the derived one -- reporting it would name the symptom and
            // hide the cause.
            var teardownError: (any Error)?
            do {
                try await group.waitForAll()
            } catch {
                teardownError = error
            }
            let value = try outcome.get()
            if let teardownError { throw teardownError }
            return value
        }
    }

    /// The raw transport seam: `listen(streamHandler:)` and `connect()` running, no gRPC runtime.
    ///
    /// `body` gets the two transports, so it can call `client.withStream(descriptor:options:_:)`
    /// itself.
    static func withTransports<Result: Sendable>(
        streamHandler: @escaping @Sendable (
            RPCStream<XPCServerTransport.Inbound, XPCServerTransport.Outbound>, ServerContext
        ) async -> Void,
        _ body: @Sendable (XPCTransportPair) async throws -> Result
    ) async throws -> Result {
        let pair = try XPCTransportPair.make()

        return try await withThrowingTaskGroup(of: Void.self, returning: Result.self) { group in
            group.addTask { try await pair.server.listen(streamHandler: streamHandler) }
            group.addTask { try await pair.client.connect() }

            let outcome: Swift.Result<Result, any Error>
            do {
                outcome = .success(try await body(pair))
            } catch {
                outcome = .failure(error)
            }

            pair.client.beginGracefulShutdown()
            pair.server.beginGracefulShutdown()

            var teardownError: (any Error)?
            do {
                try await group.waitForAll()
            } catch {
                teardownError = error
            }
            let value = try outcome.get()
            if let teardownError { throw teardownError }
            return value
        }
    }
}

// ===========================================================================================
// MARK: - Messages
// ===========================================================================================

/// The suite's message type is `String`, carried as UTF-8. No protobuf, no `Codable`: the payload
/// only has to be something whose bytes can be asserted, and a string keeps every assertion
/// readable in a failure message.
///
/// `serialize` is generic over `Bytes` because that is how the transport's `Bytes` type reaches a
/// serializer at all -- `RPCRouter`/`ClientRPCExecutor` call it with `Transport.Bytes`, i.e. with
/// `GRPCSwiftData`. A serializer hardcoded to `[UInt8]` would not compile against this transport.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct UTF8Serializer: MessageSerializer {
    typealias Message = String

    func serialize<Bytes: GRPCContiguousBytes>(_ message: String) throws -> Bytes {
        Bytes(Array(message.utf8))
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct UTF8Deserializer: MessageDeserializer {
    typealias Message = String

    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> String {
        serializedMessageBytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }
}
