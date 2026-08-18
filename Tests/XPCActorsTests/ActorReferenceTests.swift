import XCTest
import Distributed
@testable import XPCActors

/// ``XPCActorSystem/ActorReference`` -- a typed, `Codable` reference to a distributed actor. It
/// crosses as its ``ActorID`` (single value, no keys) and resolves back to a proxy on the far
/// side, so an actor can be handed to a peer inside an ordinary message rather than only as a
/// `remoteCall` argument.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class ActorReferenceTests: XCTestCase {

    /// A reference to a server-side actor, encoded through the server session and decoded through
    /// the client session, resolves to a *remote* proxy whose id matches what crossed.
    func testAnActorReferenceRoundTripsToARemoteProxy() throws {
        let serverSystem = XPCActorSystem("ref-server")
        let clientSystem = XPCActorSystem("ref-client")
        let (near, far) = Transport.InProcessRawTransport.makePair("ref")
        let clientSession = clientSystem.makeSession(
            over: Transport(debugName: "client", rawTransport: near))
        let serverSession = serverSystem.makeSession(
            over: Transport(debugName: "server", rawTransport: far))

        let greeter = DirectGreeter(actorSystem: serverSystem)
        let reference = XPCActorSystem.ActorReference(greeter, as: DirectGreeter.self)

        let payload = try Packet.Payload(
            encoding: reference, userInfo: [.xpcActorSession: serverSession])
        let decoded = try payload.decode(
            as: XPCActorSystem.ActorReference<DirectGreeter>.self,
            userInfo: [.xpcActorSession: clientSession])

        // It crossed as an id and became a remote reference on the client side.
        guard case .remote = decoded.id.raw else {
            return XCTFail("expected a remote id after the crossing, got \(decoded.id.raw)")
        }
        let proxy = decoded.resolve()
        XCTAssertEqual(proxy.id, decoded.id, "the resolved proxy's id must match the decoded id")
        withExtendedLifetime(greeter) {}
    }

    /// On the sending side, `resolve()` hands back the very actor the reference was made from.
    func testResolveReturnsTheReferencedActorOnTheSendingSide() throws {
        let system = XPCActorSystem("ref-local")
        let greeter = DirectGreeter(actorSystem: system)
        let reference = XPCActorSystem.ActorReference(greeter, as: DirectGreeter.self)
        XCTAssertEqual(reference.resolve().id, greeter.id)
        XCTAssertEqual(reference.id, greeter.id)
    }
}
