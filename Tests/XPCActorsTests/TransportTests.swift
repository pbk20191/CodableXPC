import XCTest
import XPC
@testable import XPCActors

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
final class TransportTests: XCTestCase {

    struct Ping: Codable, Equatable { let value: Int }

    /// A negotiated pair, ready for traffic.
    private func makePair() async throws -> (Transport, Transport) {
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "transport")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        let server = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        try await server.activate()
        try await client.activate()
        return (client, server)
    }

    func testNegotiationAgreesOnCurrentVersion() async throws {
        let (client, server) = try await makePair()
        XCTAssertEqual(client.negotiatedVersion, .current)
        XCTAssertEqual(server.negotiatedVersion, .current)
    }

    func testRequestGetsItsReply() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { payload, reply in
            let ping = try! payload.decode(as: Ping.self)
            reply(try! Packet.Payload(encoding: Ping(value: ping.value + 1)))
        }
        let outcome = await client.sendRequest(try Packet.Payload(encoding: Ping(value: 1)))
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 2))
    }

    func testEitherSideCanOriginateARequest() async throws {
        // This is the whole reason the XPC reply channel is unused.
        let (client, server) = try await makePair()
        client.inboundRequestHandler = { payload, reply in
            reply(try! Packet.Payload(encoding: Ping(value: 99)))
        }
        let outcome = await server.sendRequest(try Packet.Payload(encoding: Ping(value: 0)))
        guard case .reply(let payload) = outcome else { return XCTFail("expected a reply") }
        XCTAssertEqual(try payload.decode(as: Ping.self), Ping(value: 99))
    }

    func testConcurrentRequestsAreCorrelatedIndependently() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { payload, reply in
            let ping = try! payload.decode(as: Ping.self)
            reply(try! Packet.Payload(encoding: Ping(value: ping.value * 10)))
        }
        let results = await withTaskGroup(of: Int?.self) { group in
            for i in 1...20 {
                group.addTask {
                    let outcome = await client.sendRequest(
                        try! Packet.Payload(encoding: Ping(value: i))
                    )
                    guard case .reply(let p) = outcome else { return nil }
                    return try? p.decode(as: Ping.self).value
                }
            }
            return await group.reduce(into: [Int?]()) { $0.append($1) }
        }
        XCTAssertEqual(results.compactMap { $0 }.sorted(), (1...20).map { $0 * 10 })
    }

    func testNotificationArrivesWithNoReply() async throws {
        let (client, server) = try await makePair()
        let arrived = expectation(description: "notification arrives")
        server.inboundNotificationHandler = { payload in
            XCTAssertEqual(try? payload.decode(as: Ping.self), Ping(value: 5))
            arrived.fulfill()
        }
        try client.sendNotification(try Packet.Payload(encoding: Ping(value: 5)))
        await fulfillment(of: [arrived], timeout: 2)
    }

    func testCancellingTheTransportFailsOutstandingRequests() async throws {
        let (client, server) = try await makePair()
        server.inboundRequestHandler = { _, _ in }   // never replies
        let task = Task { await client.sendRequest(try! Packet.Payload(encoding: Ping(value: 1))) }
        try await Task.sleep(nanoseconds: 50_000_000)
        client.cancel(reason: "shutting down")
        guard case .failed(.transportCancelled) = await task.value else {
            return XCTFail("expected a transport failure")
        }
    }

    func testTrafficBeforeNegotiationIsRejected() async throws {
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "unnegotiated")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        _ = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        // No activate() -- no version has been agreed.
        XCTAssertThrowsError(try client.sendNotification(try Packet.Payload(encoding: Ping(value: 1))))
    }

    func testPacketWithWrongVersionIsDropped() async throws {
        let (client, server) = try await makePair()
        server.inboundNotificationHandler = { _ in XCTFail("must not deliver") }
        // Forge a packet claiming a version nobody negotiated.
        let header = try XCTUnwrap(
            PacketHeader(version: ProtocolVersion(rawValue: 77), kind: .notification, seq: nil)
        )
        let forged = Packet(header: header, payload: try Packet.Payload(encoding: Ping(value: 1)))
        server.handleReceived(packet: forged)
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testNegotiationFailureSurfacesAsAnErrorRatherThanHanging() async throws {
        // A responder with nothing in common must say so. If it only cancels itself,
        // activate() has no timeout to fall back on and suspends forever.
        let (rawA, rawB) = InProcessRawTransport.makePair(debugName: "mismatch")
        let client = Transport(debugName: "client", role: .initiator, rawTransport: rawA)
        let server = Transport(debugName: "server", role: .responder, rawTransport: rawB)
        try await server.activate()

        // Drive the responder with a hello it cannot satisfy, bypassing the client's
        // own well-formed hello.
        let header = try XCTUnwrap(PacketHeader(version: .unnegotiated, kind: .hello, seq: nil))
        let impossible = Packet(
            header: header,
            payload: try Packet.Payload(encoding: HelloBody(min: 5, max: 2))
        )
        server.handleReceived(packet: impossible)

        do {
            try await client.activate()
            XCTFail("activate() should have thrown, not agreed a version")
        } catch {
            XCTAssertNil(client.negotiatedVersion)
        }
    }
}
