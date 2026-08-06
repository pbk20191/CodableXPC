import Foundation
import XPC

/// Two transports wired to each other in one process.
///
/// Header framing is skipped -- the `Packet` value is handed across directly --
/// but the payload is a real encoded xpc dictionary, so serialization bugs still
/// surface on this path. That is what makes it a legitimate test substrate rather
/// than a mock.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class InProcessRawTransport: RawTransportProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var remoteEnd: InProcessRawTransport?
    private var handler: (@Sendable (Packet) -> Void)?
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
            let peer = remoteEnd
            remoteEnd = nil
            return peer
        }
        // Unlink from the far side so its next send fails rather than vanishing.
        peer?.lock.withLock { peer?.remoteEnd = nil }
    }
}
