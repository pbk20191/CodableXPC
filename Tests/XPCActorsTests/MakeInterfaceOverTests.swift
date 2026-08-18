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

    /// `makeBidirectionalInterface` runs the activation task through the ``UncheckedHandoff``:
    /// the task `complete()`s the handoff, exports on the local interface, and activates. The
    /// call returns only once the interface has activated, and the task exports *before* it
    /// activates -- so by the time the remote interface is handed back, the export has run.
    func testMakeBidirectionalInterfaceRunsTheHandoffAndActivates() async throws {
        let system = XPCActorSystem("bidi")
        let (near, _) = InProcessRawTransport.makePair(debugName: "bidi")
        let transport = Transport(debugName: "client", role: .initiator, rawTransport: near)

        let exported = Flag()
        let remote = try await system.makeBidirectionalInterface(over: transport) { handoff in
            Task {
                let local = handoff.complete()
                local.export(DirectCallback(actorSystem: system), asServerActorFor: "callback")
                exported.set()
                return await local.activateThenWithRemoteInterface { _ in }.token
            }
        }

        XCTAssertTrue(exported.isSet, "the activation task did not run the handoff export")
        let proxy: DirectCallback = remote.import(clientActorFor: "callback")
        XCTAssertNotNil(proxy, "bidirectional interface did not hand back a usable remote")
    }
}

/// A minimal thread-safe one-shot flag for observing that an activation task ran.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
