import Dispatch
import Foundation
import GRPCCore
import Synchronization
import XCTest

@testable import GRPCXPCTransport

// ===========================================================================================
// MARK: - Overview
// ===========================================================================================

// Shared scaffolding for the lifecycle slice. Three kinds of thing live here:
//
// 1. **`OneShotGate`** -- a single-waiter async gate. Lifecycle tests need to hold an RPC open
//    across a shutdown, and the only honest way to do that is to make one side genuinely suspend.
// 2. **`Observed`** -- a `Mutex`-backed box the *server handler* writes into and the test polls.
//    A `streamHandler` is `async -> Void`: it cannot throw and there is nowhere to report to, so
//    everything a handler sees has to be shipped out through a box (or through trailing metadata,
//    which the gRPC-level slice used). Task 8a §6 note 2.
// 3. **`waitUntil`** -- bounded polling. L8 says every test is bounded; `runBounded` bounds the
//    *test*, and this bounds each individual wait inside it so a failure names which condition
//    never came true rather than only "the body timed out".
//
// None of it touches an `XPCSession`, an `XPCPipe`'s handlers or a second accept path -- the four
// hazards the brief names are avoided the same way `XPCPairHarness` avoids them: by not writing
// the code that could trip them. The two files that *do* have to reach lower (`OwnershipTests`
// builds a client-side pipe by hand, `AcceptWindowTests` drives `XPCPipe.accepting`) say so at
// the site and explain why it is safe there.

// ===========================================================================================
// MARK: - Gates
// ===========================================================================================

/// A one-shot, **single-waiter** async gate: `wait()` suspends until someone calls `open()`.
///
/// An `AsyncStream<Void>` rather than a continuation or a semaphore, for the reason Task 8a's bidi
/// ping-pong reached for the same shape: there is no continuation to leak or double-resume, and
/// `finish()` is idempotent, so a test that opens the gate twice (or on a failing path *and* in a
/// `defer`) cannot trap.
///
/// - Important: exactly one `wait()` per gate. `AsyncStream`'s iterator is single-consumer and two
///   concurrent iterations are unsupported; every use here has one waiter by construction.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class OneShotGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        self.stream = made.stream
        self.continuation = made.continuation
    }

    /// Releases the waiter. Idempotent.
    func open() { continuation.finish() }

    /// Suspends until ``open()``. Returns immediately if it has already been called.
    func wait() async { for await _ in stream {} }
}

// ===========================================================================================
// MARK: - Observation
// ===========================================================================================

/// A `Sendable` box a server handler can write into and a test can read. The suite's answer to
/// "a `streamHandler` has nowhere to report to".
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class Observed<Value: Sendable>: Sendable {
    private let cell: Mutex<Value>

    init(_ initial: Value) { self.cell = Mutex(initial) }

    var value: Value { cell.withLock { $0 } }

    func mutate<T>(_ body: (inout Value) -> T) -> T { cell.withLock { body(&$0) } }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Observed where Value == Bool {
    func set() { mutate { $0 = true } }
    var isSet: Bool { value }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Observed {
    func append<Element: Sendable>(_ element: Element) where Value == [Element] {
        mutate { $0.append(element) }
    }
}

/// Thrown by ``waitUntil(_:timeout:file:line:_:)``. The `XCTFail` has already been recorded; this
/// exists so the test stops rather than going on to read state that never arrived.
struct ConditionNeverHeld: Error, CustomStringConvertible {
    let label: String
    var description: String { "the condition '\(label)' never became true" }
}

/// Polls `predicate` until it is true or `timeout` elapses, recording an `XCTFail` naming the
/// condition if it never is.
///
/// Deliberately *not* `runBounded`'s job: `runBounded` bounds the whole body and reports "the body
/// timed out", which for a lifecycle test with four waits in it is the least useful diagnostic
/// available. Each wait gets its own name and its own (shorter) budget, and `runBounded` is still
/// the outer net.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
func waitUntil(
    _ label: String,
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    guard predicate() else {
        XCTFail("timed out waiting for: \(label)", file: file, line: line)
        throw ConditionNeverHeld(label: label)
    }
}

/// The settle window a *negative* assertion needs: "X has **not** happened" is only meaningful
/// after giving X a real chance to happen.
///
/// 250 ms is three orders of magnitude past the ~265 µs a whole listener→dial→accept→RPC→drain
/// cycle costs on this substrate (Task 8a §4, fact 5), so a shutdown that wrongly resumed
/// `connect()` has had thousands of opportunities to do so by the time the assertion runs. It is
/// named rather than inlined so that the two tests which depend on it cannot drift apart.
let negativeAssertionSettleWindow: Duration = .milliseconds(250)

// ===========================================================================================
// MARK: - Methods and payloads
// ===========================================================================================

/// The lifecycle slice's method set. Separate from `CallTypeTests`' so that neither file's edits
/// can silently change the other's wire traffic.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum LifecycleMethods {
    static let service = "xpc.lifecycle.Drain"

    /// A method whose handler is expected to park, so a call on it stays in flight until the test
    /// releases it.
    static let parking = MethodDescriptor(fullyQualifiedService: service, method: "Parking")
    /// A method whose handler echoes once and finishes, for the "a call completes" leg of a test.
    static let echo = MethodDescriptor(fullyQualifiedService: service, method: "Echo")
}

/// Past `Data`'s 14-byte inline threshold, so every message here crosses libxpc on the same side
/// of the borrow/copy boundary as real traffic.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
func lifecyclePayload(_ n: Int) -> GRPCSwiftData {
    GRPCSwiftData(Array("lifecycle-payload-\(String(format: "%04d", n))".utf8))
}

// ===========================================================================================
// MARK: - Reusable raw-seam handlers
// ===========================================================================================

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
typealias RawSeamHandler = @Sendable (
    RPCStream<XPCServerTransport.Inbound, XPCServerTransport.Outbound>, ServerContext
) async -> Void

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum RawSeamHandlers {

    /// Reads the request's first message, reports it into `sawMessage`, then **parks on its own
    /// inbound** and writes nothing at all -- no status, not even metadata.
    ///
    /// Writing nothing is the point: the client's `for try await ... in stream.inbound` therefore
    /// has nothing to consume and stays suspended, which is what makes an RPC "in flight" in the
    /// only sense a drain barrier cares about. The parking is on `stream.inbound`, which the
    /// client never half-closes, so the handler is released only by a teardown -- a peer `cancel`,
    /// peer death, or the connection being failed.
    ///
    /// `endedWith` records how the handler left: `"inbound-ended"` if the sequence finished
    /// cleanly, or the `RPCError`'s code if it threw. That is the server-side observable for
    /// "the peer's `cancel` arrived", and it is why a deadline test can assert what the *peer*
    /// saw rather than only what the caller saw.
    static func parking(
        sawMessage: Observed<Bool>,
        endedWith: Observed<String?>
    ) -> RawSeamHandler {
        { stream, _ in
            do {
                for try await part in stream.inbound {
                    if case .message = part { sawMessage.set() }
                }
                endedWith.mutate { $0 = "inbound-ended" }
            } catch let error as RPCError {
                // Code **and** message: the message is what distinguishes "the peer cancelled
                // because its deadline fired" from every other `.cancelled`, and a deadline test
                // asserting only the code would pass on an unrelated cancellation.
                endedWith.mutate { $0 = "\(error.code)|\(error.message)" }
            } catch {
                endedWith.mutate { $0 = "\(type(of: error))" }
            }
        }
    }

    /// Reads the request to completion, echoes every message body back with a `"echo:"` prefix and
    /// an ok `status`. The "a whole RPC really completed" handler.
    ///
    /// `finished` is set *after* the status has been written, so a test can distinguish "the
    /// handler ran" from "the handler ran to completion".
    static func echoing(finished: Observed<Bool>? = nil) -> RawSeamHandler {
        { stream, _ in
            var bodies: [GRPCSwiftData] = []
            do {
                for try await part in stream.inbound {
                    if case .message(let body) = part { bodies.append(body) }
                }
                for body in bodies {
                    try await stream.outbound.write(
                        .message(GRPCSwiftData(Array("echo:".utf8) + Array(body))))
                }
                try await stream.outbound.write(.status(Status(code: .ok, message: ""), [:]))
                finished?.set()
            } catch {
                // Nowhere to report to (`streamHandler` is non-throwing). The failure is
                // observable as the client's error, which is what every assertion here reads.
                return
            }
            await stream.outbound.finish()
        }
    }

    /// Reads the request to completion, then waits for `release` before replying. The handler that
    /// lets a test hold a *server-side* RPC across a drain and then let it finish cleanly.
    static func releasable(
        started: Observed<Bool>,
        release: OneShotGate,
        finished: Observed<Bool>
    ) -> RawSeamHandler {
        { stream, _ in
            do {
                for try await part in stream.inbound {
                    if case .message = part { started.set() }
                }
                await release.wait()
                try await stream.outbound.write(.message(lifecyclePayload(999)))
                try await stream.outbound.write(.status(Status(code: .ok, message: ""), [:]))
                finished.set()
            } catch {
                return
            }
            await stream.outbound.finish()
        }
    }
}

// ===========================================================================================
// MARK: - A pair whose client-side substrate is reachable
// ===========================================================================================

/// ``XPCTransportPair`` plus the client's ``RPCTransportCore`` and ``XPCPipe``.
///
/// # Why this exists
///
/// `XPCClientTransport.core` and `RPCTransportCore.pipe` are both `private`, so a test whose
/// *subject* is one of them -- "was the XPC session cancelled?", "did the peer's `goAway` reach
/// this core?", "is this core's `deinit` reachable?" -- cannot get at it through
/// ``XPCTransportPair/make()``. This builds the client half with exactly the two calls
/// `XPCServerTransport.connectingClient()` makes and hands both intermediates back.
///
/// # Why it is safe, hazard by hazard
///
/// * **No second accept path.** This is the *dial* side. There is no accept window here, so the
///   "publish before you return the `Decision`" rule -- whose violation is an unclosable process
///   death -- does not apply. The server half is still `XPCServerTransport.anonymous()`, whose
///   `Acceptor` remains the only accept path in the package.
/// * **One serial queue per connection, and not the listener's.** Minted here, used by nothing
///   else. `XPCPipe.connecting` does not `queue.sync`, so the `dispatchPrecondition` in
///   `accepting` is not even in play.
/// * **No handler installation.** `building` constructs the core and nothing else;
///   `RPCTransportCore.init` installs `onReceive`/`onPeerDeath` itself, weakly. A second install
///   trips `XPCPipe`'s `precondition`.
/// * **No nudge blob.** Nothing is sent here at all.
///
/// Holding ``clientPipe`` strongly for a test's duration is safe under `XPCPipe`'s disposal
/// matrix: a dialled session's only safe disposal is activate-then-cancel, and whichever of
/// `core.close()` / `XPCPipe.deinit` gets there first performs exactly one cancel (the flag is
/// taken and cleared under the pipe's own lock).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct InspectableXPCPair: Sendable {
    let server: XPCServerTransport
    let client: XPCClientTransport
    let clientCore: RPCTransportCore
    let clientPipe: XPCPipe

    /// - Parameter label: goes into the connection queue's label, so a `dispatchPrecondition`
    ///   failure or a crash log names the test that built it.
    static func make(label: String) throws -> InspectableXPCPair {
        let server = try XPCServerTransport.anonymous()
        guard let endpoint = server.endpoint else {
            throw RPCError(
                code: .failedPrecondition,
                message: "an anonymous XPCServerTransport must have an endpoint")
        }
        let queue = DispatchSerialQueue(label: "GRPCXPCTransportTests.\(label).client")
        var built: RPCTransportCore?
        let pipe = try XPCPipe.connecting(to: endpoint, queue: queue) { pipe in
            built = RPCTransportCore(pipe: pipe, codec: CompactWireCodec(), role: .client)
        }
        guard let core = built else {
            throw RPCError(
                code: .internalError,
                message: "XPCPipe.connecting did not run its `building` closure")
        }
        return InspectableXPCPair(
            server: server, client: XPCClientTransport(core: core), clientCore: core,
            clientPipe: pipe)
    }

    /// The plain pair, for the parts of a test that do not need the extra reach.
    var transports: XPCTransportPair { XPCTransportPair(server: server, client: client) }
}

// ===========================================================================================
// MARK: - Client-side conveniences
// ===========================================================================================

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension XPCClientTransport {

    /// One complete round trip at the raw seam: metadata, one message, `finish()`, then drain the
    /// response to its `status`. Returns the message bodies as strings.
    ///
    /// Used by the tests whose subject is a *shutdown* rather than a call: they need one real RPC
    /// to have crossed the wire (which is also what wakes the listener's incoming-session closure
    /// -- Task 5 §2.1) and do not want twenty lines of stream plumbing to say so.
    func completeOneEchoRPC(
        descriptor: MethodDescriptor = LifecycleMethods.echo,
        payload: GRPCSwiftData = lifecyclePayload(1),
        options: CallOptions = .defaults
    ) async throws -> [String] {
        try await withStream(descriptor: descriptor, options: options) { stream, _ in
            try await stream.outbound.write(.metadata([:]))
            try await stream.outbound.write(.message(payload))
            await stream.outbound.finish()

            var bodies: [String] = []
            for try await part in stream.inbound {
                if case .message(let body) = part {
                    bodies.append(String(decoding: Array(body), as: UTF8.self))
                }
            }
            return bodies
        }
    }
}
