import Foundation

/// The byte pipe, with everything above it abstracted away.
///
/// This seam is why the whole stack is testable without XPC, a second process, or
/// an installed service, and it is where an `xpc_connection_t`-backed transport
/// would slot in later to lower the deployment floor to macOS 13.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public protocol RawTransportProtocol: AnyObject, Sendable {
    /// Install the inbound handler. Must be called before `activate()`; packets
    /// that arrive with no handler installed are dropped.
    func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void)

    /// Called when the pipe dies for a reason that did not originate on this side --
    /// the peer crashed, exited, or cancelled. Install before `activate()`.
    ///
    /// This exists because the protocol has no timeout: without it, a request whose
    /// peer died is indistinguishable from one whose peer is merely slow, and waits
    /// forever.
    func setCancellationHandler(_ handler: @escaping @Sendable (String) -> Void)

    func activate() throws(RawTransportError)

    func send(packet: Packet) throws(RawTransportError)

    /// Tear the pipe down and release what it holds.
    ///
    /// **This call is mandatory, not merely tidy.** Every conformer holds a reference
    /// cycle that only `cancel` breaks, because a live pipe must stay reachable from
    /// the callback that feeds it:
    ///
    /// - `InProcessRawTransport` — each end strongly holds `remoteEnd`, so the pair
    ///   keeps itself alive; `cancel` unlinks it.
    /// - `XPCRawTransport` — transport → session → incoming-message closure → box →
    ///   transport; `cancel` clears the box.
    ///
    /// A transport that is dropped without being cancelled leaks itself and its
    /// session. `cancel` is idempotent and keeps the first reason, which is the one
    /// that explains why the pipe died.
    func cancel(reason: String)

    /// What this transport can prove about the process on the other end, or `nil` when it
    /// can prove nothing.
    ///
    /// Apple's `RawTransportProtocol.auditToken : audit_token_t?`, one level of indirection
    /// further out: the *token* is the only identity an XPC pipe has, but it is not the only
    /// identity a transport could have, and every consumer of it only ever asks it one
    /// question. Handing over the question-answerer rather than the token keeps
    /// ``Session``'s two gates written against "can the peer prove this" instead of against
    /// Mach.
    ///
    /// Defaulted to `nil` so that a transport which cannot attest says so by saying nothing.
    /// `nil` is **not** "yes": see ``PeerAttestation``.
    var peerAttestation: (any PeerAttestation)? { get }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension RawTransportProtocol {
    public var peerAttestation: (any PeerAttestation)? { nil }
}
