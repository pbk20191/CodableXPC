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
        XCTAssertEqual(accepted?.0, sid)
        XCTAssertEqual(accepted?.1.fullyQualifiedMethod, "pkg.S/M")
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
        XCTAssertEqual(accepted?.0, 100)
        XCTAssertEqual(accepted?.1.fullyQualifiedMethod, "pkg.S/Other")
    }

    /// The main mux path: metadata + message frames sent right after `openStream` must reach the
    /// server's registered `StreamChannel` inbound sequence, in order -- and must do so even when
    /// (as here) they are sent *before* `registerServerStream` is ever called, which is exactly
    /// the gap a real client's immediate metadata/first-message write falls into. This is the
    /// path that (pre-fix) silently dropped every frame in that gap.
    func testMetadataAndMessageFramesReachTheRegisteredServerStream() async throws {
        let harness = XPCPairHarness()
        let (clientConn, serverConn) = try await harness.connectPair()

        let (sid, _) = clientConn.openClientStream(
            descriptor: MethodDescriptor(fullyQualifiedService: "pkg.S", method: "M"))
        try clientConn.send(.openStream(sid, method: "pkg.S/M", deadlineNanos: nil))

        var it = serverConn.acceptedStreams.makeAsyncIterator()
        let next = await it.next()
        let accepted = try XCTUnwrap(next)
        XCTAssertEqual(accepted.0, sid)

        // Sent before `registerServerStream` below -- simulating a real client writing metadata
        // and its first message immediately after `openStream`, ahead of whatever task ends up
        // consuming `acceptedStreams` and calling `registerServerStream`.
        try clientConn.send(.metadata(sid, WireMetadata(Metadata())))
        try clientConn.send(.message(sid, seq: 0, bytes: Data([1, 2, 3])))
        try clientConn.send(.halfClose(sid))

        let stream = serverConn.registerServerStream(sid, descriptor: accepted.1)

        var parts: [RPCRequestPart<[UInt8]>] = []
        for try await part in stream.inbound { parts.append(part) }

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
