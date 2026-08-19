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

        async let serverSaw: [UInt8]? = {
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
}
