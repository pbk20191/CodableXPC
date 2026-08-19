import Foundation
import Synchronization
import XPC

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Transport {

    /// Two transports wired to each other in one process -- Apple's
    /// `Transport.InProcessRawTransport`.
    ///
    /// Header framing is skipped -- the `Packet` value is handed across directly -- but the
    /// payload is a real overlay-encoded body, so serialization bugs still surface on this
    /// path. That is what makes it a legitimate test substrate rather than a mock.
    ///
    /// It follows Apple's back-reference model: each end is handed its parent ``Transport`` via
    /// ``activate(linking:)`` and delivers onto that transport's queue. It has no queue of its
    /// own; ``receive(_:)`` hops onto `parentTransport.queue`.
    public final class InProcessRawTransport: RawTransportProtocol, @unchecked Sendable {

        /// Apple's `parentTransport` -- a strong `var`, cleared in ``handleReceivedCancellation()``,
        /// which is what breaks the cycle with the owning ``Transport``.
        private var parentTransport: Transport?

        /// Apple's `cancellationCompleted` -- a one-shot guard against delivering cancellation
        /// twice. Only touched on the parent's serial queue.
        private var cancellationCompleted = false

        /// Apple's `Locked` -- the mutable end of the pipe under one `Mutex`. We add
        /// `peerAttestation` to it (a deliberate deviation, see below).
        private struct Locked {
            var remoteEnd: InProcessRawTransport?
            /// **Ours, not Apple's** -- Apple's `InProcessRawTransport.auditToken` returns `nil`
            /// unconditionally. ``Session``'s gates interrogate ``peerAttestation``, and the
            /// in-process tests inject an attestation at this seam to exercise them; a real pipe
            /// fills the same seam. `nil` unless told otherwise, which every gate reads as refuse.
            var peerAttestation: (any PeerAttestation)?
        }
        private let locked = Mutex<Locked>(Locked())

        /// What this end can prove about the other end. Settable, unlike Apple's fixed `nil`.
        public var peerAttestation: (any PeerAttestation)? {
            get { locked.withLock { $0.peerAttestation } }
            set { locked.withLock { $0.peerAttestation = newValue } }
        }

        private init() {}

        /// Apple's `makePair(_:) -> (outbound:, inbound:)`: two ends already pointed at each
        /// other. The debug name is unused in Apple's build (the argument is proved dead); it is
        /// accepted here for call-site readability and likewise ignored.
        public static func makePair(_ debugName: String = "pair")
        -> (outbound: InProcessRawTransport, inbound: InProcessRawTransport) {
            let a = InProcessRawTransport()
            let b = InProcessRawTransport()
            a.locked.withLock { $0.remoteEnd = b }
            b.locked.withLock { $0.remoteEnd = a }
            return (outbound: a, inbound: b)
        }

        /// Apple's `activate(linking:)`: the entire body is `self.parentTransport = transport`.
        /// It never throws in practice and does no handshake.
        public func activate(linking transport: Transport) throws(SetupError) {
            self.parentTransport = transport
        }

        /// Deliver to the other end. Throws when the pipe has been cancelled (no remote end).
        public func send(packet: Packet) throws(RawTransportError) {
            let remote = locked.withLock { $0.remoteEnd }
            guard let remote else {
                throw RawTransportError.rawTransportCancelled(
                    message: "InProcessRawTransport is cancelled")
            }
            remote.receive { $0.handleReceivedPacket(packet) }
        }

        /// Unlink and deliver a cancellation to **both** ends, each on its own queue.
        public func cancel() {
            let remote: InProcessRawTransport? = locked.withLock { locked in
                let remote = locked.remoteEnd
                locked.remoteEnd = nil
                return remote
            }
            self.receive { $0.handleReceivedCancellation() }
            remote?.receive { $0.handleReceivedCancellation() }
        }

        /// Hop onto **this** end's transport queue and hand `self` to the closure. That is why
        /// ``cancel()`` calls it on both ends: each end wakes up on its own queue. Delivering
        /// inline would let a handler that replies recurse into the sender's stack.
        private func receive(_ body: @escaping @Sendable (InProcessRawTransport) -> Void) {
            guard let parent = parentTransport else { return }
            parent.queue.async { body(self) }
        }

        /// Runs on this end's transport queue: route the packet into the parent.
        private func handleReceivedPacket(_ packet: Packet) {
            parentTransport?.handleReceivedPacket(packet)
        }

        /// Runs on this end's transport queue: clear the link, fire the parent's cancellation
        /// once, then drop the back-reference (breaking the cycle).
        private func handleReceivedCancellation() {
            locked.withLock { $0.remoteEnd = nil }
            guard !cancellationCompleted else { return }
            cancellationCompleted = true
            // Apple force-unwraps here (traps on nil). It cannot be nil: `receive(_:)` only
            // dispatches this when `parentTransport` was non-nil, this end nils it exactly once
            // (the `cancellationCompleted` guard), and it all runs serially on that queue.
            parentTransport!.handleCancellation()
            parentTransport = nil
        }
    }
}
