import Foundation
import XPC

/// Two transports wired to each other in one process.
///
/// Header framing is skipped -- the `Packet` value is handed across directly --
/// but the payload is a real overlay-encoded body, so serialization bugs still
/// surface on this path. That is what makes it a legitimate test substrate rather
/// than a mock.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class InProcessRawTransport: RawTransportProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var remoteEnd: InProcessRawTransport?
    private var handler: (@Sendable (Packet) -> Void)?
    private var cancellationHandler: (@Sendable (String) -> Void)?
    private var activated = false
    private var cancellationReason: String?

    private init(debugName: String) {
        self.queue = DispatchQueue(label: "XPCActors.InProcess.\(debugName)")
    }

    public static func makePair(
        debugName: String = "pair"
    ) -> (InProcessRawTransport, InProcessRawTransport) {
        let a = InProcessRawTransport(debugName: "\(debugName).a")
        let b = InProcessRawTransport(debugName: "\(debugName).b")
        a.lock.withLock { a.remoteEnd = b }
        b.lock.withLock { b.remoteEnd = a }
        return (a, b)
    }

    public func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func setCancellationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.cancellationHandler = handler }
    }

    public func activate() throws(RawTransportError) {
        // Explicit lock/unlock rather than `withLock`: that method is `rethrows`,
        // which cannot carry a typed `throws(RawTransportError)` out of the closure.
        lock.lock()
        let reason = cancellationReason
        if reason == nil { activated = true }
        lock.unlock()
        if let reason {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
    }

    public func send(packet: Packet) throws(RawTransportError) {
        lock.lock()
        let reason = cancellationReason
        let isActivated = activated
        let target = remoteEnd
        lock.unlock()

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
        let handler: (@Sendable (Packet) -> Void)? = lock.withLock {
            cancellationReason == nil && activated ? self.handler : nil
        }
        handler?(packet)
    }

    public func cancel(reason: String) {
        let peer: InProcessRawTransport? = lock.withLock {
            guard cancellationReason == nil else { return nil }
            cancellationReason = reason
            handler = nil
            // Our own cancellation never calls our own cancellation handler: that
            // channel reports deaths that did *not* originate on this side.
            cancellationHandler = nil
            let peer = remoteEnd
            remoteEnd = nil
            return peer
        }
        guard let peer else { return }

        // Unlink from the far side so its next send fails rather than vanishing, and
        // pick up its cancellation handler in the same critical section. Our own lock
        // is already released here: the two ends are locked strictly one at a time, so
        // a simultaneous cancel from both directions cannot deadlock.
        let peerHandler: (@Sendable (String) -> Void)? = peer.lock.withLock {
            peer.remoteEnd = nil
            guard peer.cancellationReason == nil else { return nil }
            defer { peer.cancellationHandler = nil }
            return peer.cancellationHandler
        }
        guard let peerHandler else { return }

        // Dispatch with no lock held, and on the peer's own queue -- the same queue its
        // packets arrive on, so a handler cannot observe a cancellation interleaved with
        // a delivery it is already running.
        let message = "peer cancelled: \(reason)"
        peer.queue.async { peerHandler(message) }
    }
}
