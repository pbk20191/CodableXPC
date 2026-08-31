import GRPCCore
import XCTest
import XPC

// Deliberately **not** `@testable`. Every other file in this target imports `GRPCXPCTransport`
// with `@testable`, which makes `internal` symbols visible and would defeat the only thing this
// file exists to prove.
//
// The final whole-branch review found that of the three topologies this transport can speak,
// exactly one was reachable by a consumer: `service(named:)` plus `connecting(toMachService:)` /
// `connecting(toXPCService:)`. The anonymous-endpoint topology -- the ordinary XPC brokering
// pattern, where a service vends a per-client endpoint over a connection that already exists --
// existed as machinery but was `internal`, so no consumer could reach it and no test could tell.
//
// A plain `import` is what makes this a proof rather than a claim: if `anonymous()`, `endpoint`
// or `connecting(to:)` loses its `public`, this file stops compiling.
import GRPCXPCTransport

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class BrokeredEndpointTests: XCTestCase {

    private static let descriptor = MethodDescriptor(
        fullyQualifiedService: "xpc.grpc.Broker", method: "Echo")

    /// The whole brokering path, using nothing but public API: stand up an anonymous listener,
    /// read the endpoint a broker would hand over, dial it, and carry one RPC.
    ///
    /// The endpoint is passed by value the way a real broker would pass it -- over a channel that
    /// already exists -- rather than by reaching into the server transport, which is the part
    /// `connectingClient()` does internally and which a consumer cannot do.
    func testAnEndpointHandedToAPeerCarriesAWholeRPC() throws {
        let server = try XPCServerTransport.anonymous()

        // `endpoint` is `Optional` because the launchd-named case has none. The anonymous case
        // always does, and a consumer has no other way to obtain one.
        let endpoint = try XCTUnwrap(
            server.endpoint,
            "an anonymous listener must expose an endpoint; without it `connecting(to:)` has no "
                + "argument a consumer could construct")

        let client = try XPCClientTransport.connecting(to: endpoint)

        let echoed: [String] = try runBounded("brokered RPC", timeout: 10) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await server.listen { stream, _ in
                        do {
                            for try await part in stream.inbound {
                                guard case .message(let bytes) = part else { continue }
                                let body = String(decoding: Array(bytes), as: UTF8.self)
                                try await stream.outbound.write(
                                    .message(GRPCSwiftData(Array(("echo:" + body).utf8))))
                            }
                            try await stream.outbound.write(.status(Status(code: .ok, message: ""), [:]))
                        } catch {
                            return
                        }
                        await stream.outbound.finish()
                    }
                }
                group.addTask { try await client.connect() }

                defer {
                    client.beginGracefulShutdown()
                    server.beginGracefulShutdown()
                }

                return try await client.withStream(
                    descriptor: Self.descriptor, options: .defaults
                ) { stream, _ in
                    try await stream.outbound.write(.metadata([:]))
                    try await stream.outbound.write(.message(GRPCSwiftData(Array("hello".utf8))))
                    await stream.outbound.finish()

                    var bodies: [String] = []
                    for try await part in stream.inbound {
                        if case .message(let bytes) = part {
                            bodies.append(String(decoding: Array(bytes), as: UTF8.self))
                        }
                    }
                    return bodies
                }
            }
        }

        XCTAssertEqual(
            echoed, ["echo:hello"],
            "the RPC must complete over the brokered endpoint, not merely fail to throw")
    }
}
