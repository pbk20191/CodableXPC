#if canImport(Darwin)
import Foundation
import Synchronization

// ===========================================================================================
// MARK: - InProcessService
// ===========================================================================================
//
// Apple's `XPCSystem.InProcessService`: a service reached over an in-process transport by name,
// never leaving the process -- no launchd, no XPC crossing. Distinct from ``ServiceRegistry``'s
// same-process optimization (which shortcuts a *launchd* ``XPCActorSystem/Service`` onto the
// `.local` direct-invocation path): an `InProcessService` is its own address space of names,
// served over a real ``InProcessRawTransport`` pair.
//
// **Designed reconstruction, not transcription.** Unlike every other piece in this module,
// `InProcessService.connect(using:)`'s mechanism does NOT resolve from the binary: its live
// disassembly misresolves (shared-cache data/code confusion -- the BL targets land in unrelated
// dylibs), and there is no on-disk image to extract statically. Only the *surface* is resolved
// -- `init(String)`, `connect(using:) -> Transport`, `listen(on:executingForEachPeer:)`,
// `makeRemoteInterface(to:)`, `makeBidirectionalInterface(to:)`. The registry-and-pairing below
// is therefore a behaviour-verified reconstruction of that surface (proven in-process by
// `InProcessServiceTests`), and is marked as such rather than passed off as read from Apple.

/// Process-wide table of in-process listeners by name. A service listening in this process via
/// ``XPCActorSystem/listen(on:executingForEachPeer:)`` registers here; a same-process client
/// dialling that name (``XPCActorSystem/InProcessService/connect(using:)``) is paired to it over
/// an ``InProcessRawTransport``.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class InProcessListenerRegistry: Sendable {

    static let shared = InProcessListenerRegistry()
    private init() {}

    private let table = Mutex<[String: XPCActorSystem.TransportReceiver]>([:])

    func register(_ name: String, receiver: XPCActorSystem.TransportReceiver) {
        table.withLock { $0[name] = receiver }
    }

    func unregister(_ name: String) { table.withLock { $0[name] = nil } }

    func receiver(for name: String) -> XPCActorSystem.TransportReceiver? {
        table.withLock { $0[name] }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem {

    /// Apple's `XPCSystem.InProcessService` -- a named, in-process-only service. [sym] a class:
    /// `init(String)`, `connect(using:) -> Transport`.
    public final class InProcessService {

        public let name: String

        public init(_ name: String) { self.name = name }

        /// Pair an ``InProcessRawTransport`` to the listener registered under ``name`` and return
        /// this (client) side's ``Transport``. [sym] `(connect)(using:) -> Transport`; the
        /// pairing is a designed reconstruction (see the file note).
        func connect(using system: XPCActorSystem) async throws(SetupError) -> Transport {
            guard let receiver = InProcessListenerRegistry.shared.receiver(for: name) else {
                throw SetupError("no in-process service is listening as \(name)")
            }
            let (near, far) = Transport.InProcessRawTransport.makePair(name)
            // Hand the far end to the listener: activate it, then attach, which runs the peer
            // handler (export + activate) under the shut-interface gate exactly as the XPC
            // accept path does.
            let farTransport = Transport(debugName: name, rawTransport: far)
            do {
                try farTransport.activate()
            } catch {
                throw SetupError(
                    "could not activate the in-process server end for \(name): \(error)")
            }
            do {
                try receiver.attachTransport(farTransport)
            } catch {
                throw SetupError("the in-process listener for \(name) refused the peer: \(error)")
            }
            return Transport(debugName: name, rawTransport: near)
        }
    }

    /// Dial an ``InProcessService``. Apple's `makeRemoteInterface(to: InProcessService)`.
    public func makeRemoteInterface(to service: InProcessService) async throws(SetupError)
    -> Session.RemoteInterface {
        let transport = try await service.connect(using: self)
        return try await makeRemoteInterface(over: transport)
    }

    /// Dial an ``InProcessService`` bidirectionally. Apple's
    /// `makeBidirectionalInterface(to: InProcessService, assumeLocalInterfaceActivatedIn:)`.
    public func makeBidirectionalInterface(
        to service: InProcessService,
        assumeLocalInterfaceActivatedIn body:
            (Session.LocalInterface.UncheckedHandoff)
            -> Task<Session.LocalInterface.ActivationToken, Never>
    ) async throws(SetupError) -> Session.RemoteInterface {
        let transport = try await service.connect(using: self)
        return try await makeBidirectionalInterface(
            over: transport, assumeLocalInterfaceActivatedIn: body)
    }

    /// Serve an ``InProcessService`` in this process: register the peer handler under the
    /// service's name and park until the serving task is cancelled, unregistering on exit.
    /// Apple's `listen(on: InProcessService, executingForEachPeer:)` (which returns `()` and so
    /// carries no handle -- cancel the task running it to stop).
    public func listen(
        on service: InProcessService,
        executingForEachPeer peerHandler:
            @escaping @Sendable (consuming Session.LocalInterface) async
            -> (result: (), token: Session.LocalInterface.ActivationToken)
    ) async throws {
        let receiver = TransportReceiver(actorSystem: self, peerHandler: peerHandler)
        InProcessListenerRegistry.shared.register(service.name, receiver: receiver)
        defer { InProcessListenerRegistry.shared.unregister(service.name) }
        await CancellationPark().wait()
    }
}
#endif
