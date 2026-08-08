import XCTest
import XPC
@testable import XPCActors

/// Tier 3: real XPC, one process.
///
/// An anonymous `XPCListener` publishes an endpoint that we dial from this same
/// process. That exercises the real overlay and real message passing without
/// needing an installed service or a second process.
///
/// This class is `@available(macOS 15, ...)`, not the plan's blanket macOS 14 floor:
/// the anonymous `XPCListener` init, `XPCListener.endpoint`, and `XPCEndpoint` itself
/// all require macOS 15 / macCatalyst 18 in the real overlay and are `unavailable` on
/// iOS/tvOS/watchOS. See task-8-report.md for the confirmed signatures.
@available(macOS 15, macCatalyst 18, *)
@available(iOS, unavailable)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
final class XPCRawTransportTests: XCTestCase {

    struct Ping: Codable, Equatable { let value: Int }

    /// Keeps the server side alive; it is built inside the listener callback.
    final class ServerBox: @unchecked Sendable {
        var transport: Transport?
    }

    func testRequestReplyOverRealXPC() async throws {
        let serverReady = expectation(description: "server transport built")
        let box = ServerBox()

        // `.none` here (matching the brief) actually means "start active on init":
        // calling `.activate()` afterward makes libxpc trap with "Attempting to
        // activate an already active listener" (SIGTRAP / api-misuse, confirmed by
        // stepping through `xpc_listener_activate` in lldb -- see task-8-report.md).
        // `.inactive` is required to defer activation to the explicit call below.
        let listener = XPCListener(targetQueue: nil, options: .inactive) { request in
            let (decision, raw) = XPCRawTransport.accepting(request)
            let transport = Transport(debugName: "server", role: .responder, rawTransport: raw)
            transport.inboundRequestHandler = { _, payload, reply in
                guard let ping = try? payload.decode(as: Ping.self),
                      let body = try? Packet.Payload(encoding: Ping(value: ping.value + 1))
                else { return }
                reply(body)
            }
            box.transport = transport
            // activate() only brings the pipe up; it exchanges nothing and blocks on
            // nothing. The accepted session is already live, so this is a no-op beyond
            // installing the handler.
            Task { try? await transport.activate() }
            serverReady.fulfill()
            return decision
        }
        try listener.activate()

        let clientRaw = try XPCRawTransport.connecting(to: listener.endpoint)
        let client = Transport(debugName: "client", role: .initiator, rawTransport: clientRaw)
        try await client.activate()

        // Send *before* waiting for the server, not after. With the handshake gone,
        // `activate()` puts nothing on the wire, and an XPC session is not established
        // until its first message -- so the listener does not learn of this peer until
        // the request below is sent. Waiting for `serverReady` first would deadlock,
        // and it did: that is what deleting the `hello` changed here.
        let request = try Packet.Payload(encoding: Ping(value: 41))
        async let pending = client.sendRequest(seq: client.allocateSeq(), request)

        await fulfillment(of: [serverReady], timeout: 5)

        let outcome = await pending
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 42))

        client.cancel(reason: "test over")
        // Also cancel the server-side transport, reached through the box the listener
        // callback populated. This exercises the box-clearing added to
        // XPCRawTransport.cancel(reason:) to break the transport -> session ->
        // closure -> box -> transport retain cycle, on both ends of the pipe.
        box.transport?.cancel(reason: "test over")
        listener.cancel()
    }
}
