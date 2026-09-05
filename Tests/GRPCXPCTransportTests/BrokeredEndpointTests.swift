import Foundation
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
                                    .message(GRPCDispatchDataPayload(Array(("echo:" + body).utf8))))
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
                    try await stream.outbound.write(.message(GRPCDispatchDataPayload(Array("hello".utf8))))
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

    /// **The server factories' error surface**, and the counterpart to
    /// ``XPCClientTransport/connecting(toMachService:)``'s.
    ///
    /// "Could not stand up the listener/session for this launchd name" is one failure class, and
    /// until this round a consumer had to catch it two ways: `RPCError` from the client factory,
    /// and the XPC overlay's own error from ``XPCServerTransport/service(named:)``, which let
    /// `XPCListener.init` / `activate()` escape raw. This case pins the fix at the only place it
    /// is observable -- the public API, without `@testable`.
    ///
    /// It asserts three things, and the first two are compile-time:
    ///
    /// 1. **the factory is `throws(RPCError)`.** `error` below is bound by an untyped `catch`, so
    ///    `error.code` only resolves because the thrown type is statically `RPCError`. Widen the
    ///    signature back to bare `throws` and this file stops compiling -- which is the same kind
    ///    of proof the plain `import` at the top of this file gives for `public`;
    /// 2. **the wrapping happens in the package, not in this test** -- there is no `as?` here;
    /// 3. **the overlay's error survives as `cause:`**, rather than being flattened into the
    ///    message. That is the project's standing rule about typed throws (a narrower error type
    ///    is not worth a lost `cause:`), and it is the assertion with teeth: a wrapper written as
    ///    `message: "... \(error)"` passes "it threw an RPCError with code .unavailable" and fails
    ///    here.
    ///
    /// The name is a well-formed bundle identifier that no launchd job claims, freshly minted per
    /// run so a previous run cannot have left one behind.
    ///
    /// # Which of the factory's two wraps this reaches -- measured, not assumed
    ///
    /// `XPCListener.init(service:)` **succeeds** for an unclaimed name; `activate()` is what fails
    /// (`"Unable to activate listener: Connection init failed at listener activation with error
    /// 1 - Operation not permitted"`). That is the same late-failure shape
    /// ``XPCClientTransport/connecting(toMachService:)`` documents on the dialling side. So this
    /// case exercises the **activate** wrap only: deleting `cause:` from the `init` wrap leaves it
    /// green, which was verified rather than reasoned about. The `init` wrap exists because that
    /// initialiser is declared `throws` and an unwrapped throw there would reopen exactly the
    /// asymmetry this case pins -- not because a way to reach it is known.
    func testServiceNamedReportsAnRPCErrorAndKeepsTheOverlaysErrorAsCause() {
        let name = "com.example.grpcxpc.no-such-service.\(UUID().uuidString)"
        do {
            _ = try XPCServerTransport.service(named: name)
            XCTFail(
                "a launchd name no job claims must not produce a listener; if the platform "
                    + "started allowing this, the wrapping below is untested rather than wrong")
        } catch {
            XCTAssertEqual(
                error.code, .unavailable,
                "a listener that cannot be stood up is a statement about the name, not about "
                    + "this transport's own lifecycle -- .failedPrecondition is reserved for the "
                    + "latter. Got: \(error)")
            XCTAssertNotNil(
                error.cause,
                "the XPC overlay's error must survive as `cause:`; interpolating it into the "
                    + "message loses the underlying domain and code for every caller. Got: "
                    + "\(error)")
            XCTAssertTrue(
                error.message.contains(name),
                "the message must name the service that could not be listened on. Got: \(error)")
        }
    }
}
