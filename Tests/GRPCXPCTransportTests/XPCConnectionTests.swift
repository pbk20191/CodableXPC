import Foundation
import XCTest
import GRPCCore
import XPC
@testable import GRPCXPCTransport

@available(macOS 15.0, *)
final class XPCConnectionTests: XCTestCase {
    func testAClientOpenStreamAppearsOnTheServersAcceptedStreams() async throws {
        // Anonymous listener + a client session dialing its endpoint, both in this process.
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()

        let (sid, _) = clientConn.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "M"))
        try clientConn.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))

        var it = serverConn.acceptedStreams.makeAsyncIterator()
        let accepted = await it.next()
        XCTAssertEqual(accepted?.id, sid)
        XCTAssertEqual(accepted?.descriptor.fullyQualifiedMethod, "pkg.S/M")
    }

    /// A malformed wire method string (no "/") must not crash the connection -- the frame is
    /// dropped and nothing appears on `acceptedStreams`.
    func testMalformedOpenStreamMethodIsDroppedNotCrashed() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()

        try clientConn.send(.openStream(99, method: "not-a-valid-method", deadlineNanos: nil))
        // Follow it with a well-formed one on a different id -- if the connection survived the
        // malformed frame, this one still arrives.
        try clientConn.send(.openStream(100, method: "pkg.S/Other", deadlineNanos: nil))

        var it = serverConn.acceptedStreams.makeAsyncIterator()
        let accepted = await it.next()
        XCTAssertEqual(accepted?.id, 100)
        XCTAssertEqual(accepted?.descriptor.fullyQualifiedMethod, "pkg.S/Other")
    }

    /// The main mux path: metadata + message + halfClose reach the server's `RPCStream.inbound`
    /// in order, and the sequence finishes -- with every frame sent *before* this test ever reads
    /// `acceptedStreams`, so there is no `await` anywhere between the sends and the point where
    /// `route()` is proven (by the accept arriving at all) to have processed at least
    /// `.openStream`. This is deliberately structured not to assert code order as execution
    /// order: the only thing this test relies on `await`ing for is well-defined (the accept
    /// itself, and then draining `inbound`), and both are correct regardless of exactly how far
    /// `route()` has gotten through the other three frames by the time each `await` resumes --
    /// because the server-side channel is built in the same `route()` call that processes
    /// `.openStream`, *before* it is handed out on `acceptedStreams` (see `AcceptedStream`'s doc
    /// comment), there is no window in which any of these frames can find nowhere to land.
    func testMetadataAndMessageFramesReachTheAcceptedStreamInOrder() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()

        let (sid, _) = clientConn.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "M"))

        // All four frames, sent back-to-back with no `await` in between and none of them awaited
        // individually -- by the time this test code next suspends, all four are already in
        // flight (at minimum), well ahead of the accept below.
        try clientConn.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))
        try clientConn.send(.metadata(sid, WireMetadata(Metadata())))
        try clientConn.send(.message(sid, seq: 0, bytes: GRPCMessageFraming.frame(GRPCSwiftData([1, 2, 3]))))
        try clientConn.send(.halfClose(sid))

        var it = serverConn.acceptedStreams.makeAsyncIterator()
        let next = await it.next()
        let accepted = try XCTUnwrap(next)
        XCTAssertEqual(accepted.id, sid)

        // Deliberately pins the regression this round exists to prevent: give the connection's
        // serial queue a generous, explicit grace period so `route()` has almost certainly
        // already processed metadata/message/halfClose -- including the terminal, which finishes
        // `inbound`'s underlying continuation -- *before* the drain below ever starts reading it.
        // Not a synchronization guarantee (there is no reply/ack at this layer to block on), but
        // long enough on a same-process real-XPC round trip that this is the case in practice;
        // the drain below is correct either way, since `AsyncThrowingStream` buffers everything
        // yielded (including a `finish()`) whether or not a consumer has attached yet.
        try await Task.sleep(nanoseconds: 50_000_000)

        var parts: [RPCRequestPart<GRPCSwiftData>] = []
        for try await part in accepted.stream.inbound { parts.append(part) }

        XCTAssertEqual(parts.count, 2)
        switch parts.first {
        case .metadata: break
        default: XCTFail("expected metadata first, got \(String(describing: parts.first))")
        }
        switch parts.last {
        case .message(let bytes): XCTAssertEqual(bytes, [1, 2, 3])
        default: XCTFail("expected message second, got \(String(describing: parts.last))")
        }
    }

    /// Ownership pin. `route`'s `.openStream` arm builds the whole server-side `RPCStream` and
    /// yields it on `acceptedStreams`, whose continuation buffers that payload *inside the
    /// connection*. If anything reachable from the payload owned the connection back -- as a
    /// strong `XPCOutboundWriter.connection` did -- then a consumer that lags or never drains
    /// `acceptedStreams` would make the connection retain itself, `deinit` would never run, its
    /// `session.cancel(reason:)` would never fire, and the native `XPCSession` would leak.
    ///
    /// So: open a stream, let the server buffer the accept, never read `acceptedStreams` at all,
    /// drop the only outside references, and require both connections to deinitialize.
    func testConnectionDeinitsWithAnAcceptedStreamBufferedButNeverDrained() async throws {
        weak var weakClient: XPCConnection?
        weak var weakServer: XPCConnection?

        // A single optional holding the pair, niled explicitly below: binding the connections to
        // ordinary `let`s would keep them alive to the end of the function and make the
        // assertions untestable regardless of the fix.
        var pair: (XPCConnection, XPCConnection)? = try await XPCPairHarness().connectPair()
        weakClient = pair?.0
        weakServer = pair?.1
        XCTAssertNotNil(weakClient)
        XCTAssertNotNil(weakServer)

        let (sid, _) = pair!.0.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "M"))
        try pair!.0.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))

        // Give the server's serial queue time to route `.openStream` and yield the `AcceptedStream`
        // into `acceptedContinuation`'s buffer, then barrier on that queue so no routing block is
        // still on the stack (each one holds a transient strong `self`). Nothing here ever
        // iterates `acceptedStreams`, so that payload -- writer included -- is still sitting in
        // the connection's own buffer when the references are dropped below: precisely the
        // leaking configuration. (Delivery of an in-process XPC message is not something this
        // layer can synchronise on without draining the accept, which the scenario forbids; the
        // deterministic form of the same ownership proof, with the accepted stream definitely
        // drained and definitely still alive, is
        // `testWritingToAnAcceptedStreamAfterTheConnectionIsGoneFailsUnavailable` below.)
        try await Task.sleep(nanoseconds: 100_000_000)
        pair!.1.queue.sync { }

        pair = nil

        // Polled rather than asserted instantly: the last release can race a routing block that
        // still holds a transient strong `self`, so "not yet nil at this instant" is a scheduling
        // artifact, while "never nil" is the leak. With the retain cycle present this waits out
        // the full timeout and then fails, as verified by reverting the fix.
        let serverReleased = await waitUntilTrue { weakServer == nil }
        XCTAssertTrue(serverReleased,
                      "the server connection must deinit with an undrained accepted stream buffered "
                      + "-- otherwise deinit's session.cancel(reason:) never runs and the XPCSession leaks")
        let clientReleased = await waitUntilTrue { weakClient == nil }
        XCTAssertTrue(clientReleased, "the client connection must deinit once nobody outside holds it")
    }

    /// The other half of the ownership contract: a write attempted through a stream whose
    /// connection is gone must fail deterministically -- not crash (which `unowned` would) and not
    /// silently succeed (which dropping the frame would). Doubles as the strongest form of the
    /// deinit pin: here the accepted stream is *drained and still held alive*, so the only thing
    /// that can be keeping the connection alive is the writer inside it.
    func testWritingToAnAcceptedStreamAfterTheConnectionIsGoneFailsUnavailable() async throws {
        weak var weakServer: XPCConnection?

        var pair: (XPCConnection, XPCConnection)? = try await XPCPairHarness().connectPair()
        weakServer = pair?.1

        let (sid, _) = pair!.0.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "M"))
        try pair!.0.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))

        var iterator = pair!.1.acceptedStreams.makeAsyncIterator()
        let next = await iterator.next()
        let accepted = try XCTUnwrap(next)
        XCTAssertEqual(accepted.id, sid)
        // Keep only the built `RPCStream` (and hence its outbound writer) past the connections'
        // lifetime; `accepted` itself is a value, so `stream` is the sole survivor.
        let stream = accepted.stream
        // Barrier: `await iterator.next()` can resume while the routing block that yielded the
        // accept is still on the server queue's stack, holding a transient strong `self`.
        pair!.1.queue.sync { }

        pair = nil
        let serverReleased = await waitUntilTrue { weakServer == nil }
        XCTAssertTrue(serverReleased,
                      "a live, drained accepted stream must not keep its connection alive either")

        do {
            try await stream.outbound.write(.metadata(Metadata()))
            XCTFail("a write after the connection is gone must throw, not silently succeed")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }

    /// The read direction of the same contract: a stream that outlives its connection must have
    /// its inbound sequence *failed*, not left awaiting a frame that can never arrive. (Without
    /// `deinit -> failAll`, the drain below would hang forever rather than fail.)
    func testAnAcceptedStreamsInboundFailsWhenItsConnectionGoesAway() async throws {
        var pair: (XPCConnection, XPCConnection)? = try await XPCPairHarness().connectPair()

        let (sid, _) = pair!.0.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "M"))
        try pair!.0.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))

        var iterator = pair!.1.acceptedStreams.makeAsyncIterator()
        let next = await iterator.next()
        let stream = try XCTUnwrap(next).stream

        pair = nil

        // Bounded deliberately: the regression this pins does not *fail* the drain, it **hangs**
        // it -- without `deinit -> failAll` the channel's continuation is never finished, so
        // `for try await` waits forever (verified: the test wedges rather than failing). Racing
        // the drain against a fulfillment timeout turns that into a fast, legible failure instead
        // of a stuck test process.
        let terminated = expectation(description: "the inbound sequence terminated")
        let complaint = FirstComplaint()
        Task {
            do {
                for try await part in stream.inbound {
                    complaint.note("no request part was ever sent, yet got \(part)")
                }
                complaint.note("the inbound sequence finished cleanly instead of failing")
            } catch let error as RPCError {
                if error.code != .unavailable { complaint.note("wrong RPCError code \(error.code)") }
            } catch {
                complaint.note("expected an RPCError, got \(error)")
            }
            terminated.fulfill()
        }
        await fulfillment(of: [terminated], timeout: 5)
        XCTAssertNil(complaint.message, complaint.message ?? "")
    }
}

/// Records the first thing that went wrong inside a detached task, for the test body to assert on
/// once that task reports in.
private final class FirstComplaint: @unchecked Sendable {
    private let lock = NSLock()
    private var _message: String?
    var message: String? { lock.withLock { _message } }
    func note(_ message: String) { lock.withLock { if _message == nil { _message = message } } }
}
