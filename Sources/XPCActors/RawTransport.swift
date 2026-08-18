import Foundation

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension Transport {

    /// The byte pipe, with everything above it abstracted away.
    ///
    /// This seam is why the whole stack is testable without XPC, a second process, or an
    /// installed service, and it is where a different transport would slot in.
    ///
    /// Apple's `Transport.RawTransportProtocol` -- **exactly four requirements**, and not
    /// class-constrained (`Transport.rawTransport` is a boxed opaque existential, not two
    /// words). The raw transport is handed its parent ``Transport`` via ``activate(linking:)``
    /// and routes inbound packets and pipe-death back into it through the parent's
    /// ``Transport/handleReceivedPacket(_:)`` and ``Transport/handleCancellation()`` -- a
    /// back-reference, not injected closures.
    public protocol RawTransportProtocol: Sendable {

        /// Bring the pipe up, linking it to the ``Transport`` that owns it. The raw transport
        /// stores the back-reference and routes inbound traffic and pipe-death into it.
        func activate(linking transport: Transport) throws(SetupError)

        /// The only place a packet leaves this side.
        func send(packet: Packet) throws(RawTransportError)

        /// Tear the pipe down and release what it holds. Idempotent.
        func cancel()

        /// What this transport can prove about the process on the other end, or `nil` when it
        /// can prove nothing.
        ///
        /// Apple's `RawTransportProtocol.auditToken : audit_token_t?`, one level of indirection
        /// further out -- a deliberate, documented deviation: the *token* is the only identity
        /// an XPC pipe has, but it is not the only identity a transport could have, and every
        /// consumer only ever asks it one question. Handing over the question-answerer rather
        /// than the token keeps ``Session``'s gates written against "can the peer prove this"
        /// instead of against Mach.
        ///
        /// Defaulted to `nil` so a transport that cannot attest says so by saying nothing.
        /// `nil` is **not** "yes": see ``PeerAttestation``.
        var peerAttestation: (any PeerAttestation)? { get }
    }
}

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension Transport.RawTransportProtocol {
    public var peerAttestation: (any PeerAttestation)? { nil }
}
