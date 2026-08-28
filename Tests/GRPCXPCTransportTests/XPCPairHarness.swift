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
    ///
    /// - Important: **A `deinit`-reachability test must call this directly, not through
    ///   ``XPCPairHarness/withPair(router:expectingRoughTeardown:_:)`` or
    ///   ``XPCPairHarness/withTransports(streamHandler:expectingRoughTeardown:_:)``.** Both entry
    ///   points hold the pair alive for the whole of the body, so a weak reference taken inside one
    ///   can never nil. Measured: `make()` inside a `do { }` scope leaves both weak references nil
    ///   on exit from that scope.
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
    /// The bring-up/run/shut-down sequence itself, and the rule about whose error the caller sees,
    /// are ``run(_:serving:driving:shuttingDown:expectingRoughTeardown:_:)``'s -- including the
    /// client-first shutdown order and why it is that way round.
    ///
    /// - Important: **`body` must issue at least one RPC.** `GRPCClient.beginGracefulShutdown()` on
    ///   a client that has not started yet moves it straight to `.stopped` **without** telling the
    ///   transport, and the `runConnections()` that follows then throws `clientIsStopped`.
    ///   `GRPCServer.serve()` loses the identical race and throws `serverIsStopped`. **Which of the
    ///   two you get is race-dependent**, and it depends on load, not on the body: measured, the
    ///   same empty body gives `clientIsStopped` 10 out of 10 times run in isolation and
    ///   `serverIsStopped` when run alongside four other tests in the same process. So do not match
    ///   on the code -- there is no reliable one. This is grpc-swift's documented "`withGRPCClient`
    ///   with an empty body" hazard on both halves, not this transport's; a body that makes a call
    ///   cannot reach either. **``withTransports(streamHandler:expectingRoughTeardown:_:)`` has no
    ///   equivalent and is confirmed safe with an empty body** -- use it for anything that shuts
    ///   down with nothing in flight.
    /// - Parameter expectingRoughTeardown: pass `true` when the body has *deliberately* left the
    ///   pair in a state whose shutdown is not expected to be clean -- a killed peer, a forced
    ///   cancellation, a session already closed. The teardown's error is then discarded instead of
    ///   thrown. See the note on the default below for why this exists.
    static func withPair<Result: Sendable>(
        router: RPCRouter<XPCServerTransport>,
        expectingRoughTeardown: Bool = false,
        _ body: @Sendable (RunningXPCPair) async throws -> Result
    ) async throws -> Result {
        let transports = try XPCTransportPair.make()
        let pair = RunningXPCPair(
            transports: transports,
            client: GRPCClient(transport: transports.client),
            server: GRPCServer(transport: transports.server, router: router))

        return try await run(
            pair,
            serving: { try await pair.server.serve() },
            driving: { try await pair.client.runConnections() },
            shuttingDown: {
                pair.client.beginGracefulShutdown()
                pair.server.beginGracefulShutdown()
            },
            expectingRoughTeardown: expectingRoughTeardown,
            body)
    }

    /// The raw transport seam: `listen(streamHandler:)` and `connect()` running, no gRPC runtime.
    ///
    /// `body` gets the two transports, so it can call `client.withStream(descriptor:options:_:)`
    /// itself.
    /// - Parameter expectingRoughTeardown: as on
    ///   ``withPair(router:expectingRoughTeardown:_:)``.
    static func withTransports<Result: Sendable>(
        streamHandler: @escaping @Sendable (
            RPCStream<XPCServerTransport.Inbound, XPCServerTransport.Outbound>, ServerContext
        ) async -> Void,
        expectingRoughTeardown: Bool = false,
        _ body: @Sendable (XPCTransportPair) async throws -> Result
    ) async throws -> Result {
        let pair = try XPCTransportPair.make()

        return try await run(
            pair,
            serving: { try await pair.server.listen(streamHandler: streamHandler) },
            driving: { try await pair.client.connect() },
            shuttingDown: {
                pair.client.beginGracefulShutdown()
                pair.server.beginGracefulShutdown()
            },
            expectingRoughTeardown: expectingRoughTeardown,
            body)
    }

    /// **The teardown policy, written once.** Both entry points above differ only in what they
    /// run in the group, what they hand the body and what they shut down; the rule about *whose
    /// error wins* is one rule and belongs in one place, not restated per entry point where the
    /// two copies can drift.
    ///
    /// What it does, in order:
    ///
    /// 1. runs `serving` and `driving` as the group's two long-lived tasks;
    /// 2. runs `body`, **keeping** its outcome rather than propagating it, so that step 3 happens
    ///    on the failing path too -- a body that threw must still take both halves down, or a
    ///    listener and two sessions leak into every test that follows;
    /// 3. calls `shuttingDown`, which every caller implements as **client first, then server**:
    ///    closing the client's session is what makes the server see peer death and retire the
    ///    connection, so the server's own drain then has nothing left to wait for. Both are
    ///    graceful -- nothing here cancels a task, so this path exercises the drain rather than
    ///    the forceful teardown;
    /// 4. waits for both tasks, and decides which error the caller sees.
    ///
    /// **The body's error wins.** A broken body usually makes the teardown fail too, and the
    /// teardown's error is the derived one -- reporting it would name the symptom and hide the
    /// cause.
    ///
    /// When the body *succeeded*, a teardown error is thrown by default: silently swallowing "the
    /// drain never finished" would hide a real transport defect behind a green test, which is the
    /// worse of the two failure modes for a suite whose whole job is to find them. But it does
    /// mean a test whose asserted property held can still fail with an error pointing at
    /// `waitForAll()` rather than at anything it asserted -- so a test that has deliberately made
    /// the teardown rough passes `expectingRoughTeardown: true` and gets its value regardless.
    ///
    /// No timeout here either: wrap the call in
    /// ``XCTestCase/runBounded(_:timeout:file:line:_:)``, which is where L8 lives.
    private static func run<Subject: Sendable, Result: Sendable>(
        _ subject: Subject,
        serving: @escaping @Sendable () async throws -> Void,
        driving: @escaping @Sendable () async throws -> Void,
        shuttingDown: @Sendable () -> Void,
        expectingRoughTeardown: Bool,
        _ body: @Sendable (Subject) async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Void.self, returning: Result.self) { group in
            group.addTask { try await serving() }
            group.addTask { try await driving() }

            let outcome: Swift.Result<Result, any Error>
            do {
                outcome = .success(try await body(subject))
            } catch {
                outcome = .failure(error)
            }

            shuttingDown()

            var teardownError: (any Error)?
            do {
                try await group.waitForAll()
            } catch {
                teardownError = error
            }
            let value = try outcome.get()
            if let teardownError, !expectingRoughTeardown { throw teardownError }
            return value
        }
    }
}

// ===========================================================================================
// MARK: - The harness's own contract
// ===========================================================================================

/// Two tests, both about ``XPCPairHarness`` rather than about the transport. They live here, beside
/// the code they pin, because slices 2 and 3 build on this contract and a silent regression in it
/// would surface as twenty unexplained failures in *their* files.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class XPCPairHarnessContractTests: XCTestCase {

    /// `expectingRoughTeardown` exists so a lifecycle test whose asserted property *held* is not
    /// failed by a teardown it deliberately made messy. This pins both halves of that switch.
    ///
    /// The subject is the one deterministically rough teardown available: `withPair` with a body
    /// that issues no RPC, which loses grpc-swift's start/shutdown race (see
    /// ``XPCPairHarness/withPair(router:expectingRoughTeardown:_:)``). **Which** error that produces
    /// is race-dependent -- `clientIsStopped` or `serverIsStopped` -- so this asserts only that one
    /// is thrown by default and none is thrown when the caller opted out. That is exactly the
    /// contract; matching on the code would be pinning grpc-swift's race instead.
    func testRoughTeardownIsThrownByDefaultAndSuppressedOnRequest() throws {
        let thrownByDefault = try runBounded("rough teardown, default") { () -> Bool in
            do {
                _ = try await XPCPairHarness.withPair(router: RPCRouter()) { _ in 41 }
                return false
            } catch {
                return true
            }
        }
        XCTAssertTrue(
            thrownByDefault,
            "a teardown error must not be swallowed by default: hiding 'the drain never finished' "
                + "behind a green test is the worse of the two failure modes")

        let suppressed = try runBounded("rough teardown, opted out") {
            try await XPCPairHarness.withPair(
                router: RPCRouter(), expectingRoughTeardown: true
            ) { _ in 42 }
        }
        XCTAssertEqual(
            suppressed, 42,
            "expectingRoughTeardown must return the body's value rather than the teardown's error")
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
