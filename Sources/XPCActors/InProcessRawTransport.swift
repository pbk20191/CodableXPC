import Foundation
import Synchronization
import XPC

/// Two transports wired to each other in one process.
///
/// Header framing is skipped -- the `Packet` value is handed across directly --
/// but the payload is a real overlay-encoded body, so serialization bugs still
/// surface on this path. That is what makes it a legitimate test substrate rather
/// than a mock.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public final class InProcessRawTransport: RawTransportProtocol, @unchecked Sendable {

    private let queue: DispatchQueue

    /// All mutable ends of the pipe under one `Synchronization.Mutex` -- `send`, `cancel` and
    /// `deliver` each read several of these together, so they cannot be split into separate
    /// primitives.
    private struct State {
        var remoteEnd: InProcessRawTransport?
        var handler: (@Sendable (Packet) -> Void)?
        var cancellationHandler: (@Sendable (String) -> Void)?
        var activated = false
        var cancellationReason: String?
        var peerAttestation: (any PeerAttestation)?
    }
    private let state = Mutex<State>(State())

    /// What this end can prove about the other end.
    ///
    /// **`nil` by default, and that is the honest answer.** Apple's `.local` session answers
    /// `LocalSessionState.currentProcessAuditToken()` — "the peer is this process" — because
    /// a `.local` session *is* an in-process pair. This type is not that: it is a stand-in
    /// for a real pipe, and what is on the far end of it is whatever a test put there. So it
    /// attests nothing unless it is told what to attest, and every gate in ``Session`` reads
    /// that `nil` as refuse.
    public var peerAttestation: (any PeerAttestation)? {
        get { state.withLock { $0.peerAttestation } }
        set { state.withLock { $0.peerAttestation = newValue } }
    }

    private init(debugName: String, qos: DispatchQoS) {
        self.queue = DispatchQueue(label: "XPCActors.InProcess.\(debugName)", qos: qos)
    }

    /// - Parameter qos: the delivery queue's quality of service.
    ///   `.unspecified` -- the default -- lets Dispatch propagate the *sender's* QoS to the
    ///   delivery block, which is normally what a test wants and is occasionally exactly
    ///   what it must not have: an inbound execution's priority floor is read on the
    ///   delivering context, so a caller at `.background` would otherwise deliver at
    ///   `.background` and the floor would have nothing to lift. Naming a QoS pins the
    ///   receiving side independently of the sending one.
    public static func makePair(
        debugName: String = "pair",
        qos: DispatchQoS = .unspecified
    ) -> (InProcessRawTransport, InProcessRawTransport) {
        let a = InProcessRawTransport(debugName: "\(debugName).a", qos: qos)
        let b = InProcessRawTransport(debugName: "\(debugName).b", qos: qos)
        a.state.withLock { $0.remoteEnd = b }
        b.state.withLock { $0.remoteEnd = a }
        return (a, b)
    }

    public func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void) {
        state.withLock { $0.handler = handler }
    }

    public func setCancellationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.cancellationHandler = handler }
    }

    public func activate() throws(RawTransportError) {
        // The throw is outside the lock so the typed `throws(RawTransportError)` need not
        // cross `Mutex.withLock`'s `rethrows` boundary.
        let reason = state.withLock { state -> String? in
            if state.cancellationReason == nil { state.activated = true }
            return state.cancellationReason
        }
        if let reason {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
    }

    public func send(packet: Packet) throws(RawTransportError) {
        let (reason, isActivated, target) = state.withLock {
            ($0.cancellationReason, $0.activated, $0.remoteEnd)
        }

        if let reason {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
        guard isActivated else {
            throw RawTransportError.rawTransportCancelled(message: "not activated")
        }
        guard let target else {
            throw RawTransportError.rawTransportCancelled(message: "peer is gone")
        }
        // Hop to the peer's queue. Delivering inline would let a handler that
        // replies recurse into the sender's stack.
        target.queue.async { target.deliver(packet) }
    }

    private func deliver(_ packet: Packet) {
        let handler: (@Sendable (Packet) -> Void)? = state.withLock {
            $0.cancellationReason == nil && $0.activated ? $0.handler : nil
        }
        handler?(packet)
    }

    public func cancel(reason: String) {
        let peer: InProcessRawTransport? = state.withLock { state in
            guard state.cancellationReason == nil else { return nil }
            state.cancellationReason = reason
            state.handler = nil
            // Our own cancellation never calls our own cancellation handler: that
            // channel reports deaths that did *not* originate on this side.
            state.cancellationHandler = nil
            let peer = state.remoteEnd
            state.remoteEnd = nil
            return peer
        }
        guard let peer else { return }

        // Unlink from the far side so its next send fails rather than vanishing, and
        // pick up its cancellation handler in the same critical section. Our own lock
        // is already released here: the two ends are locked strictly one at a time, so
        // a simultaneous cancel from both directions cannot deadlock.
        let peerHandler: (@Sendable (String) -> Void)? = peer.state.withLock { peerState in
            peerState.remoteEnd = nil
            guard peerState.cancellationReason == nil else { return nil }
            defer { peerState.cancellationHandler = nil }
            return peerState.cancellationHandler
        }
        guard let peerHandler else { return }

        // Dispatch with no lock held, and on the peer's own queue -- the same queue its
        // packets arrive on, so a handler cannot observe a cancellation interleaved with
        // a delivery it is already running.
        let message = "peer cancelled: \(reason)"
        peer.queue.async { peerHandler(message) }
    }
}
