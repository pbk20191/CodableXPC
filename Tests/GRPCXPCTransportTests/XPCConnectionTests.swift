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
        try clientConn.send(.message(sid, seq: 0, bytes: Data([1, 2, 3])))
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

        var parts: [RPCRequestPart<[UInt8]>] = []
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
}
