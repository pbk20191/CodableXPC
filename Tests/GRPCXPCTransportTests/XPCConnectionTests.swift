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
}
