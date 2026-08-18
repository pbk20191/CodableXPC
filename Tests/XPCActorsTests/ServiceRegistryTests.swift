import XCTest
@testable import XPCActors

/// Phase (a) of the same-process optimization: the process-wide registry and its lifecycle.
/// The `.local` session and its direct-invocation path arrive in (b)/(c); here the registry
/// holds registrations, resolves the `preserveSelfIPC` escape hatch, and reports the
/// not-registered case.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class ServiceRegistryTests: XCTestCase {

    private func makeReceiver(_ system: XPCActorSystem) -> XPCActorSystem.TransportReceiver {
        XPCActorSystem.TransportReceiver(actorSystem: system) { local in
            await local.activateThenWaitForCancellation()
        }
    }

    func testRegisterMakesAServiceFindable() {
        let system = XPCActorSystem("server")
        let service = XPCActorSystem.Service.machService("com.example.registry.findable")
        defer { ServiceRegistry.shared.unregister(service) }

        XCTAssertNil(ServiceRegistry.shared.registration(for: service),
                     "the service was findable before it was registered")
        ServiceRegistry.shared.register(service, receiver: makeReceiver(system),
                                        actorSystem: system, targetQueue: nil)
        let registration = ServiceRegistry.shared.registration(for: service)
        XCTAssertNotNil(registration, "a registered service was not findable")
        XCTAssertTrue(registration?.actorSystem === system, "the wrong system was recorded")
    }

    func testUnregisterRemovesTheEntry() {
        let system = XPCActorSystem("server")
        let service = XPCActorSystem.Service.machService("com.example.registry.removable")
        ServiceRegistry.shared.register(service, receiver: makeReceiver(system),
                                        actorSystem: system, targetQueue: nil)
        ServiceRegistry.shared.unregister(service)
        XCTAssertNil(ServiceRegistry.shared.registration(for: service),
                     "the entry survived unregister")
    }

    /// The escape hatch wins over an in-process hit: even a registered service returns `nil`
    /// (forcing XPC) when `preserveSelfIPC` is set.
    func testPreserveSelfIPCForcesTheXPCPath() {
        let system = XPCActorSystem("server")
        let service = XPCActorSystem.Service.machService("com.example.registry.forced")
        defer { ServiceRegistry.shared.unregister(service) }
        ServiceRegistry.shared.register(service, receiver: makeReceiver(system),
                                        actorSystem: system, targetQueue: nil)

        XCTAssertNil(ServiceRegistry.shared.lookUpAndConnect(
            to: service, from: XPCActorSystem("client"), options: [.preserveSelfIPC]),
            "preserveSelfIPC did not force the XPC path")
    }

    /// A service nobody serves in this process is not a same-process hit.
    func testAnUnregisteredServiceDoesNotConnectLocally() {
        let service = XPCActorSystem.Service.machService("com.example.registry.absent")
        XCTAssertNil(ServiceRegistry.shared.lookUpAndConnect(
            to: service, from: XPCActorSystem("client"), options: []),
            "an unregistered service was treated as a same-process hit")
    }
}
