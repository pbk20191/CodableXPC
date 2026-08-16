#if canImport(Darwin)
import Foundation
import XPC
import Synchronization

// ===========================================================================================
// MARK: - EphemeralService server side: makeEphemeralService, Receiver, ListeningToken
// ===========================================================================================
//
// The *server* half of Apple's ephemeral-service taxonomy. `makeEphemeralService` stands up an
// anonymous `XPCListener`, wraps its endpoint in an ``XPCActorSystem/EphemeralService``, and
// hands a ``XPCActorSystem/EphemeralService/Receiver`` to the caller's activation closure;
// the closure returns a `Task` that calls `receiver.listen(executingForEachPeer:)` to serve.
//
// **Behaviour-verified reconstruction, not transcription.** The surfaces are resolved from the
// dump (`Receiver.init(service:actorSystem:listener:)`,
// `Receiver.listen(forPeersSatisfying:executingForEachPeer:) async -> ListeningToken`,
// `makeEphemeralService(_:assumeActivatedIn:) -> EphemeralService`,
// `makeEphemeralServiceWithListeningTask(...) -> EphemeralServiceWithListeningTask`), but the
// internal serving mechanism -- how the anonymous listener, created *before* `listen` installs
// the peer handler, bridges to it -- lives in async-fragmented bodies the dump does not resolve.
// This closes that gap with a buffering bridge (sessions accepted before `listen` is called are
// held and drained once it is) and a park-until-cancelled serve, proven end to end over real
// XPC (`RealXPCEndToEndTests.testACallCrossesAServedEphemeralService`).

/// Bridges the anonymous listener's accepted sessions to the ``TransportReceiver`` that
/// `Receiver.listen` installs later. Closes the race where a client dials the endpoint before
/// the peer handler exists: such sessions are buffered and drained on `install`.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
private final class EphemeralServing: @unchecked Sendable {

    let park = CancellationPark()

    private let lock = NSLock()
    private var receiver: XPCActorSystem.TransportReceiver?
    private var pending: [(XPCRawTransport, String)] = []

    /// Called from the listener's (synchronous) accept handler.
    func accept(_ raw: XPCRawTransport, debugName: String) {
        lock.lock()
        if let receiver {
            lock.unlock()
            receiver.accept(raw, debugName: debugName)
            return
        }
        pending.append((raw, debugName))
        lock.unlock()
    }

    /// Called once, by `Receiver.listen`, when the peer handler is known.
    func install(_ receiver: XPCActorSystem.TransportReceiver) {
        lock.lock()
        self.receiver = receiver
        let drained = pending
        pending = []
        lock.unlock()
        for (raw, debugName) in drained { receiver.accept(raw, debugName: debugName) }
    }
}

/// Suspends until the calling task is cancelled, then resumes once. What keeps
/// `Receiver.listen` alive (and so the receiver, listener, and every served peer) for as long
/// as the serving task runs -- Apple's `listen` is `async` and returns only when it stops.
/// Shared with ``XPCActorSystem/InProcessService``'s `listen`, which parks the same way.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
final class CancellationPark: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelled = false

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem.EphemeralService {

    /// Apple's `EphemeralService.ListeningToken` -- the receipt `Receiver.listen` returns when
    /// it stops serving. [sym] `Codable`/`Hashable`, keyed. One field, `id: ID64`, like
    /// ``XPCActorSystem/Session/LocalInterface/ActivationToken``; why it is `Codable` is
    /// unresolved there too and repeated rather than re-derived.
    public struct ListeningToken: Hashable, Codable, Sendable {

        public let id: ID64

        private enum CodingKeys: String, CodingKey { case id }

        public init(id: ID64) { self.id = id }
    }

    /// Apple's `EphemeralService.Receiver` -- the server side of an ephemeral service. Handed to
    /// `makeEphemeralService`'s `assumeActivatedIn` closure, which returns the `Task` that calls
    /// ``listen(forPeersSatisfying:executingForEachPeer:)`` to serve peers.
    ///
    /// [sym] fields `service`, `actorSystem`, `id: ID64`, `listener: XPC.XPCListener`.
    public final class Receiver: Sendable {

        public let service: XPCActorSystem.EphemeralService
        public let actorSystem: XPCActorSystem
        public let id: ID64
        public let listener: XPCListener

        private let serving: EphemeralServing

        private static let counter = Atomic<UInt64>(0)
        static func nextID() -> ID64 {
            ID64(rawValue: counter.wrappingAdd(1, ordering: .relaxed).newValue)
        }

        fileprivate init(
            service: XPCActorSystem.EphemeralService, actorSystem: XPCActorSystem,
            id: ID64, listener: XPCListener, serving: EphemeralServing
        ) {
            self.service = service
            self.actorSystem = actorSystem
            self.id = id
            self.listener = listener
            self.serving = serving
        }

        /// Serve peers on the anonymous listener. Each peer is handed a fresh
        /// ``XPCActorSystem/Session/LocalInterface`` to `executingForEachPeer`, which exports
        /// and activates. Installs the peer handler (draining any session that dialled the
        /// endpoint first), then parks until the serving task is cancelled -- at which point it
        /// cancels the listener and returns the ``ListeningToken`` receipt.
        ///
        /// **`forPeersSatisfying` is accepted to match Apple's signature; accept-side
        /// enforcement is not wired here.** Apple applies an `XPCPeerRequirement` to refuse
        /// peers at the listener; the accepted sessions here are already live, so per-peer
        /// requirement checking would belong on ``XPCActorSystem/Session`` (which has
        /// `peerSatisfiesRequirement`) rather than at accept -- a known simplification.
        @discardableResult
        public func listen(
            forPeersSatisfying requirement: PeerRequirement? = nil,
            executingForEachPeer peerHandler:
                @escaping @Sendable (consuming Session.LocalInterface) async
                -> (result: (), token: Session.LocalInterface.ActivationToken)
        ) async -> ListeningToken {
            let transportReceiver = XPCActorSystem.TransportReceiver(
                actorSystem: actorSystem, peerHandler: peerHandler)
            serving.install(transportReceiver)
            await serving.park.wait()
            listener.cancel()
            return ListeningToken(id: id)
        }
    }
}

// ===========================================================================================
// MARK: - EphemeralServiceWithListeningTask + the factories
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCActorSystem {

    /// Apple's `EphemeralServiceWithListeningTask` -- the service paired with the `Task` that
    /// serves it, so a caller can await or cancel the serving. [sym] fields `service`,
    /// `listeningTask`.
    public struct EphemeralServiceWithListeningTask: Sendable {
        public let service: EphemeralService
        public let listeningTask: Task<EphemeralService.ListeningToken, Never>
    }

    /// Apple's `makeEphemeralService(_:assumeActivatedIn:)`: stand up an anonymous listener,
    /// wrap its endpoint in an ``EphemeralService``, and spawn the serving task through the
    /// caller's `assumeActivatedIn` closure. Returns the service (hand it to a peer, which dials
    /// it back). The serving task runs unstructured, so it keeps serving after this returns.
    @discardableResult
    public func makeEphemeralService(
        _ name: String,
        assumeActivatedIn body:
            (EphemeralService.Receiver) -> Task<EphemeralService.ListeningToken, Never>
    ) -> EphemeralService {
        makeEphemeralServiceWithListeningTask(name, assumeActivatedIn: body).service
    }

    /// As ``makeEphemeralService(_:assumeActivatedIn:)``, but also hands back the serving
    /// `Task`, so the caller can await its ``EphemeralService/ListeningToken`` or cancel it to
    /// stop serving. Apple's `makeEphemeralServiceWithListeningTask(_:assumeActivatedIn:)`.
    public func makeEphemeralServiceWithListeningTask(
        _ name: String,
        assumeActivatedIn body:
            (EphemeralService.Receiver) -> Task<EphemeralService.ListeningToken, Never>
    ) -> EphemeralServiceWithListeningTask {
        let serving = EphemeralServing()
        let listener = XPCListener { request in
            let (decision, raw) = XPCRawTransport.accepting(request)
            serving.accept(raw, debugName: name)
            return decision
        }
        let service = EphemeralService(endpoint: listener.endpoint)
        let receiver = EphemeralService.Receiver(
            service: service, actorSystem: self, id: EphemeralService.Receiver.nextID(),
            listener: listener, serving: serving)
        let listeningTask = body(receiver)
        return EphemeralServiceWithListeningTask(service: service, listeningTask: listeningTask)
    }
}
#endif
