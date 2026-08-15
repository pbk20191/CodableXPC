import Foundation
import Synchronization

// ===========================================================================================
// MARK: - The process-wide service registry
// ===========================================================================================

/// Apple's `ServiceRegistry.shared`: the table that makes the same-process optimization
/// possible.
///
/// A service listening in this process registers here (`ServiceRegistry.register(service:
/// receiver:actorSystem:targetQueue:)`, from ``XPCActorSystem/listen(as:targetQueue:peerHandler:)``);
/// a client in the *same* process dialling that service consults it first
/// (`lookUpAndConnect(to:from:options:)`, from ``XPCActorSystem/Service/connect(from:with:)``)
/// and, when it finds the receiver, is wired to it directly rather than going out to launchd
/// and back. `preserveSelfIPC` is the escape hatch that forces the XPC path even so.
///
/// **Phase (a): the registry and its lifecycle only.** `lookUpAndConnect` resolves the
/// escape hatch and the not-registered case; the in-process hit still returns `nil` (falls
/// through to XPC) until the `.local` session and its direct-invocation path land in phases
/// (b) and (c). Registering here matches Apple's `listen` regardless, and is what those
/// phases build on.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class ServiceRegistry: Sendable {

    static let shared = ServiceRegistry()
    private init() {}

    /// A registered service and the receiver that serves it, in this process.
    struct Registration {
        /// Held strongly, with an explicit lifecycle: ``XPCActorSystem/ServiceListener`` owns
        /// the receiver and calls ``unregister(_:)`` when it stops, so a dead service leaves
        /// no entry a same-process client could be routed into.
        let receiver: XPCActorSystem.TransportReceiver
        let actorSystem: XPCActorSystem
        let targetQueue: DispatchQueue?
    }

    private let table = Mutex<[XPCActorSystem.Service: Registration]>([:])

    /// Enter a listening service into the process-wide table. Apple's
    /// `ServiceRegistry.register(service:receiver:actorSystem:targetQueue:)`.
    func register(
        _ service: XPCActorSystem.Service,
        receiver: XPCActorSystem.TransportReceiver,
        actorSystem: XPCActorSystem,
        targetQueue: DispatchQueue?
    ) {
        table.withLock {
            $0[service] = Registration(
                receiver: receiver, actorSystem: actorSystem, targetQueue: targetQueue)
        }
    }

    /// Remove a service, once its listener stops.
    func unregister(_ service: XPCActorSystem.Service) {
        table.withLock { $0[service] = nil }
    }

    /// The registration for a service serving in this process, or `nil`. Test seam and the
    /// lookup half of ``lookUpAndConnect(to:from:options:)``.
    func registration(for service: XPCActorSystem.Service) -> Registration? {
        table.withLock { $0[service] }
    }

    /// Apple's `ServiceRegistry.shared.lookUpAndConnect(to:from:options:)`, the first thing
    /// `Service.connect(from:with:)` consults.
    ///
    /// Returns a `.local` session when the service is served in this process and
    /// `preserveSelfIPC` is not set; `nil` otherwise, so the caller falls through to XPC.
    /// Apple logs the two branches it takes -- `"Using same-process optimization for
    /// service %s"` and `"preserveSelfIPC set, forcing XPC for service %s"`.
    ///
    /// **Phase (a) stops short of the in-process hit:** the escape hatch and the
    /// not-registered case are resolved here; the hit returns `nil` until the `.local`
    /// session lands in (b)/(c).
    func lookUpAndConnect(
        to service: XPCActorSystem.Service,
        from actorSystem: XPCActorSystem,
        options: XPCActorSystem.InitializationOptions
    ) -> Session? {
        if options.contains(.preserveSelfIPC) { return nil }
        guard let registration = registration(for: service) else { return nil }
        // In-process hit: build the pair. The server end is a transport-less `.local`
        // session that starts shut; its receiver's handler exports the service's actors and
        // opens its gate. The client end is a `.local` session holding the server as its
        // peer, so its calls run directly against the server's table, never encoding a byte.
        let serverSession = registration.actorSystem.makeLocalSession(
            peer: nil, localInterfaceActivated: false)
        registration.receiver.acceptLocal(serverSession)
        return actorSystem.makeLocalSession(
            peer: serverSession,
            localInterfaceActivated: !options.contains(.bidirectional))
    }
}
