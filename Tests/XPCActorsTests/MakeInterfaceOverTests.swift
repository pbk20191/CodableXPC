import XCTest
import Distributed
@testable import XPCActors

/// The `over:` connection factories: build (or reuse) a session and hand back its remote
/// interface, without dialling a ``XPCActorSystem/Service``. Apple's
/// `makeRemoteInterface(over: Session)` and `makeRemoteInterface(over: Transport)`.
///
/// `import` resolves a proxy rather than making a call, so these exercise the factory shape
/// (session built, transport activated, interface returned) without needing a live peer.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class MakeInterfaceOverTests: XCTestCase {

    func testMakeRemoteInterfaceOverSessionReturnsAUsableRemote() async throws {
        let system = XPCActorSystem("over-session")
        let (near, _) = InProcessRawTransport.makePair(debugName: "over-session")
        let transport = Transport(debugName: "client", role: .initiator, rawTransport: near)
        let session = system.makeSession(over: transport)

        let remote = try await system.makeRemoteInterface(over: session)
        let proxy: DirectGreeter = remote.import(clientActorFor: "greeter")
        XCTAssertNotNil(proxy, "over: Session did not hand back a usable remote interface")
    }

    func testMakeRemoteInterfaceOverTransportActivatesAndReturnsARemote() async throws {
        let system = XPCActorSystem("over-transport")
        let (near, _) = InProcessRawTransport.makePair(debugName: "over-transport")
        let transport = Transport(debugName: "client", role: .initiator, rawTransport: near)

        // Builds the session and activates the transport; must not throw with no peer present.
        let remote = try await system.makeRemoteInterface(over: transport)
        let proxy: DirectGreeter = remote.import(clientActorFor: "greeter")
        XCTAssertNotNil(proxy, "over: Transport did not hand back a usable remote interface")
    }
}
