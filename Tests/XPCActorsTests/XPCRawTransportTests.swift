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
                      let body = try? Packet.Payload(encoding: Ping(value: ping.value + 1), userInfo: [:])
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
        let request = try Packet.Payload(encoding: Ping(value: 41), userInfo: [:])
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

    /// Keeps the raw transport as well, so the attestation can be read off the accepted
    /// side of a live connection.
    final class RawBox: @unchecked Sendable {
        var raw: XPCRawTransport?
        var transport: Transport?
    }

    /// **The peer check, over a real connection, with nothing stubbed.**
    ///
    /// This is the test behind the claim that Apple's overlay gives us what the gates need.
    /// `XPCRawTransport.peerAttestation` reads `XPCSession.auditToken` and
    /// `audit_token_t.isValid` through symbols that `libswiftXPC` exports and the public
    /// `.swiftinterface` does not declare; here they run against a connection libxpc
    /// actually established, and the token comes back **valid** -- which is the one thing a
    /// synthesised `XPCDictionary` cannot show (`PeerGateTests` pins that an unconnected
    /// dictionary's token is invalid, i.e. that "valid" here means something).
    ///
    /// The peer is this same process, so what it is asked is the pair of questions whose
    /// answers do not depend on how the test binary happens to be signed: a requirement the
    /// checker cannot express (`nil`), and an entitlement nothing has (`false`).
    func testPeerAttestationOverRealXPCIsTheLiveConnectionsAuditToken() async throws {
        guard #available(macOS 26, macCatalyst 26, *) else {
            throw XCTSkip("XPCPeerRequirement and the audit-token accessors are macOS 26+")
        }
        let serverReady = expectation(description: "server transport built")
        let box = RawBox()

        let listener = XPCListener(targetQueue: nil, options: .inactive) { request in
            let (decision, raw) = XPCRawTransport.accepting(request)
            let transport = Transport(debugName: "server", role: .responder, rawTransport: raw)
            transport.inboundRequestHandler = { _, payload, reply in
                guard let ping = try? payload.decode(as: Ping.self),
                      let body = try? Packet.Payload(encoding: Ping(value: ping.value + 1),
                                                     userInfo: [:])
                else { return }
                reply(body)
            }
            box.raw = raw
            box.transport = transport
            Task { try? await transport.activate() }
            serverReady.fulfill()
            return decision
        }
        try listener.activate()

        let clientRaw = try XPCRawTransport.connecting(to: listener.endpoint)
        let client = Transport(debugName: "client", role: .initiator, rawTransport: clientRaw)
        try await client.activate()

        // The session is not established until the first message, so one round trip first.
        let request = try Packet.Payload(encoding: Ping(value: 1), userInfo: [:])
        async let pending = client.sendRequest(seq: client.allocateSeq(), request)
        await fulfillment(of: [serverReady], timeout: 5)
        guard case .reply = await pending else { return XCTFail("expected a reply") }

        for (side, attestation) in [("server", box.raw?.peerAttestation),
                                    ("client", clientRaw.peerAttestation)] {
            let real = try XCTUnwrap(attestation,
                                     "\(side): a live XPC connection must attest to its peer")
            XCTAssertTrue(real is AuditTokenAttestation, "\(side): \(type(of: real))")
            XCTAssertNil(real.satisfies(PeerRequirement("nothing can express this")),
                         "\(side): an inexpressible requirement must not read as satisfied")
            XCTAssertEqual(
                real.satisfies(PeerRequirement(.hasEntitlement("com.example.not-granted"),
                                               describedAs: "ungranted")),
                false,
                "\(side): an entitlement nothing holds must not read as satisfied")
        }

        client.cancel(reason: "test over")
        box.transport?.cancel(reason: "test over")
        listener.cancel()
    }
}
