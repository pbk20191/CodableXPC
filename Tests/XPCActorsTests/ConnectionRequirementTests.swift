#if canImport(Darwin)
import XCTest
import Distributed
@testable import XPCActors

/// The connection-level `forPeersSatisfying` gate: a listener requirement carried onto each
/// served session (``XPCActorSystem/Session/connectionRequirement``) and checked per request,
/// refusing a peer that does not satisfy it before any target runs. A designed enforcement of
/// Apple's intent (Apple's is a libxpc listener requirement; this side's attestation is
/// message-level, so the check is per request).
///
/// Both branches are driven deterministically over an ``Transport.InProcessRawTransport`` pair by setting
/// the server end's ``PeerAttestation`` to a stub.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class ConnectionRequirementTests: XCTestCase {

    private var alive: [Any] = []

    /// Serve a greeter behind `requirement`, with the peer presenting `attestation`, and return
    /// the client session over the paired transport.
    private func connect(
        requirement: PeerRequirement?, peerAttestation: (any PeerAttestation)?
    ) async throws -> Session {
        let serverSystem = XPCActorSystem("cr-server")
        let clientSystem = XPCActorSystem("cr-client")
        let receiver = XPCActorSystem.TransportReceiver(
            actorSystem: serverSystem, forPeersSatisfying: requirement
        ) { local in
            local.export(DirectGreeter(actorSystem: serverSystem), asServerActorFor: "greeter")
            return await local.activateThenWaitForCancellation()
        }
        let (near, far) = Transport.InProcessRawTransport.makePair("cr")
        far.peerAttestation = peerAttestation
        let farTransport = Transport(debugName: "server", rawTransport: far)
        try farTransport.activate()
        try receiver.attachTransport(farTransport)

        let clientTransport = Transport(debugName: "client", rawTransport: near)
        let clientSession = clientSystem.makeSession(over: clientTransport)
        try clientTransport.activate()

        alive.append(contentsOf: [serverSystem, clientSystem, receiver, farTransport, clientTransport])
        return clientSession
    }

    func testASatisfyingPeerIsServed() async throws {
        let session = try await connect(
            requirement: PeerRequirement("test.requirement"),
            peerAttestation: StubAttestation(result: true))
        let proxy: DirectGreeter = session.remote.import(clientActorFor: "greeter")
        let greeting = try await proxy.greet(name: "ok")
        XCTAssertEqual(greeting, "hello, ok")
    }

    func testANonSatisfyingPeerIsRefused() async throws {
        let session = try await connect(
            requirement: PeerRequirement("test.requirement"),
            peerAttestation: StubAttestation(result: false))
        let proxy: DirectGreeter = session.remote.import(clientActorFor: "greeter")
        do {
            _ = try await proxy.greet(name: "no")
            XCTFail("a peer failing the connection requirement should be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("peer requirement"), "\(error)")
        }
    }

    func testAnUnattestedPeerFailsASetRequirement() async throws {
        // No attestation at all: "cannot tell" must read as "no", not "allowed".
        let session = try await connect(
            requirement: PeerRequirement("test.requirement"), peerAttestation: nil)
        let proxy: DirectGreeter = session.remote.import(clientActorFor: "greeter")
        do {
            _ = try await proxy.greet(name: "no")
            XCTFail("an unattested peer should fail a set requirement")
        } catch {
            XCTAssertTrue("\(error)".contains("peer requirement"), "\(error)")
        }
    }

    func testNoRequirementServesAnyPeer() async throws {
        let session = try await connect(requirement: nil, peerAttestation: nil)
        let proxy: DirectGreeter = session.remote.import(clientActorFor: "greeter")
        let greeting = try await proxy.greet(name: "any")
        XCTAssertEqual(greeting, "hello, any")
    }
}

/// A stub ``PeerAttestation`` that answers a fixed verdict, so both gate branches are testable
/// without a real audit token.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private struct StubAttestation: PeerAttestation {
    let result: Bool?
    func satisfies(_ requirement: PeerRequirement) -> Bool? { result }
}
#endif
