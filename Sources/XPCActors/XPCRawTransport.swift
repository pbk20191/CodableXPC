#if canImport(Darwin)
import Foundation
import Synchronization
import XPC

// ===========================================================================================
// MARK: - A RawTransport on Apple's XPCSession / XPCListener overlay
// ===========================================================================================

/// A ``RawTransportProtocol`` over Apple's `XPCSession`, with peers accepted through
/// `XPCListener.IncomingSessionRequest`.
///
/// **This is the overlay Apple's own `XPCSystem` transport uses**, restored now that the
/// module's floor is macOS 26: `XPCRawTransport.accepting(_:)` is
/// `Transport.XPCRawTransport.accepting`, wrapping the *already-live* `XPCSession` that
/// `IncomingSessionRequest.accept` returns (`isAlreadyActive: true`); the client dials are
/// `XPCSession(machService:)` / `XPCSession(xpcService:)` / `XPCSession(endpoint:)`.
///
/// Sends are one-way -- `XPCSession.send(message:)`, never the reply overload -- and the
/// incoming-message handler always returns `nil`, so XPC's reply channel stays unused and
/// replies travel as ordinary inbound packets. That is what lets the listening side
/// originate calls.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public final class XPCRawTransport: RawTransportProtocol, @unchecked Sendable {

    private let session: XPCSession
    private let isAlreadyActive: Bool

    private struct State {
        var handler: (@Sendable (Packet) -> Void)?
        var cancellationHandler: (@Sendable (String) -> Void)?
        var cancellationReason: String?
        /// The box whose closure keeps this transport reachable from the session's
        /// incoming-message handler. Held so ``cancel(reason:)`` can break the resulting
        /// retain cycle (transport -> session -> closure -> box -> transport).
        var box: Box?
        /// The most recent message the peer sent, retained so the peer gates have something
        /// to interrogate. Message-scoped at capture, peer-scoped in meaning: every message
        /// on one session comes from the same peer.
        var lastReceivedMessage: xpc_object_t?
    }
    private let state = Mutex<State>(State())

    /// - Parameter isAlreadyActive: `true` for a session handed to us by
    ///   `IncomingSessionRequest.accept`, which is live on return. Calling
    ///   `session.activate()` on such a session does *not* throw a catchable Swift error --
    ///   it is a fatal `libxpc` API-misuse trap (SIGTRAP, "Attempting to activate an
    ///   already active listener/session"), confirmed empirically by temporarily removing
    ///   this guard and observing the crash. `isAlreadyActive` is load-bearing, not
    ///   defensive boilerplate.
    public init(session: XPCSession, isAlreadyActive: Bool = false) {
        self.session = session
        self.isAlreadyActive = isAlreadyActive
    }

    // MARK: Peer identity

    /// What the peer can attest, if anything.
    ///
    /// **Message-level, not session-level.** Apple's `Transport.XPCRawTransport.auditToken`
    /// read `XPCSession.auditToken`, but that getter is **gone** from the current overlay
    /// (measured -- see `PeerRequirement.swift`), so the token is taken from the last
    /// message and kept, which lands in the same place: every message on one `XPCSession`
    /// comes from the same peer, so "the last message's sender" and "this session's peer"
    /// are the same process. `AuditTokenAttestation.init?` rejects an invalid token, so a
    /// dictionary that never crossed a connection reports "cannot tell", not "not entitled".
    public var peerAttestation: (any PeerAttestation)? {
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard let message = state.withLock({ $0.lastReceivedMessage }) else { return nil }
        return AuditTokenAttestation(XPCDictionary(message).xpcBridgedAuditToken())
        #else
        return nil
        #endif
    }

    // MARK: RawTransportProtocol

    public func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void) {
        state.withLock { $0.handler = handler }
    }

    public func setCancellationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.cancellationHandler = handler }
    }

    /// Apply a client-side peer requirement to the underlying session, Apple's
    /// `XPCSession.setPeerRequirement(_:)`. A no-op for a requirement that carries no overlay
    /// `XPCPeerRequirement` (a named-only stand-in libxpc cannot express).
    public func setPeerRequirement(_ requirement: PeerRequirement) {
        guard let xpc = requirement.xpcRequirement else { return }
        session.setPeerRequirement(xpc)
    }

    public func activate() throws(RawTransportError) {
        guard !isAlreadyActive else { return }
        do {
            try session.activate()
        } catch {
            throw RawTransportError.rawTransportCancelled(
                message: "could not activate XPCSession: \(error)")
        }
    }

    public func send(packet: Packet) throws(RawTransportError) {
        if let reason = state.withLock({ $0.cancellationReason }) {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
        do {
            try session.send(message: XPCDictionary(packet.rawValue))
        } catch {
            throw RawTransportError.rawTransportCancelled(message: "XPCSession send: \(error)")
        }
    }

    public func cancel(reason: String) {
        let box: Box? = state.withLock { state in
            guard state.cancellationReason == nil else { return nil }
            state.cancellationReason = reason
            state.handler = nil
            let box = state.box
            // Break the retain cycle the message handler closes over: transport -> session
            // -> closure -> box -> transport. Clearing `box.transport` also means a packet
            // delivered after cancellation finds nothing to dispatch to.
            state.box = nil
            state.lastReceivedMessage = nil
            return box
        }
        guard let box else { return }
        session.cancel(reason: reason)
        box.transport = nil
    }

    // MARK: Delivery

    /// Feed an inbound `XPCDictionary` in. Wired to the session's or the listener's
    /// incoming-message handler, which always returns `nil`.
    func handleIncoming(_ message: XPCDictionary) {
        let handler: (@Sendable (Packet) -> Void)? = message.withUnsafeUnderlyingDictionary { raw in
            state.withLock { state in
                // Retained before the packet is parsed: a malformed message still identifies
                // its sender, and the gate that will ask about the sender must not depend on
                // this side having understood what it said.
                state.lastReceivedMessage = raw
                return state.handler
            }
        }
        guard let handler else { return }
        message.withUnsafeUnderlyingDictionary { raw in
            guard let packet = Packet(rawValue: raw) else { return }
            handler(packet)
        }
    }

    /// The overlay told us the session died. Wired to the `cancellationHandler:` the
    /// session was built with.
    ///
    /// Deaths that originate here go through ``cancel(reason:)`` instead, which sets
    /// `cancellationReason` *before* calling `session.cancel`. The overlay then calls this
    /// back for our own cancellation too, and the guard below stops that echo being
    /// reported upward as a peer death.
    func handleSessionCancellation(_ error: XPCRichError) {
        let message = "XPCSession cancelled: \(error)"
        let result: (handler: (@Sendable (String) -> Void), box: Box?)? = state.withLock { state in
            guard state.cancellationReason == nil else { return nil }
            guard let handler = state.cancellationHandler else { return nil }
            state.cancellationReason = message
            state.handler = nil
            state.cancellationHandler = nil
            let box = state.box
            state.box = nil
            return (handler, box)
        }
        guard let result else { return }
        result.box?.transport = nil
        result.handler(message)
    }
}

// ===========================================================================================
// MARK: - Accepting, dialling
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCRawTransport {

    /// Breaks the chicken-and-egg between a session's message handler and the transport that
    /// handler dispatches to. Lock-guarded because `accepting` returns a session that is
    /// already live: a peer's first message can reach the handler before the assignment on
    /// the next line completes.
    final class Box: @unchecked Sendable {
        private let _transport = Mutex<XPCRawTransport?>(nil)
        var transport: XPCRawTransport? {
            get { _transport.withLock { $0 } }
            set { _transport.withLock { $0 = newValue } }
        }
    }

    /// Accept an inbound peer. The returned session is already live, so the transport is
    /// built with `isAlreadyActive: true`. Apple's `Transport.XPCRawTransport.accepting`.
    public static func accepting(
        _ request: XPCListener.IncomingSessionRequest
    ) -> (XPCListener.IncomingSessionRequest.Decision, XPCRawTransport) {
        let box = Box()
        let (decision, session) = request.accept(
            incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                box.transport?.handleIncoming(message)
                return nil
            },
            cancellationHandler: { (error: XPCRichError) in
                box.transport?.handleSessionCancellation(error)
            })
        let transport = XPCRawTransport(session: session, isAlreadyActive: true)
        // Order matters: `accept` returns the session already live, so giving the transport
        // its box before publishing the box is what keeps the retain-cycle clear sound
        // against a peer that dies on the very next instruction.
        transport.state.withLock { $0.box = box }
        box.transport = transport
        return (decision, transport)
    }

    /// Dial a launchd Mach service by name. The session comes back inactive; `activate()`
    /// starts it.
    public static func connectingToMachService(
        _ name: String, targetQueue: DispatchQueue? = nil
    ) throws(RawTransportError) -> XPCRawTransport {
        try dialling { box in
            try XPCSession(
                machService: name, targetQueue: targetQueue, options: .inactive,
                incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                    box.transport?.handleIncoming(message); return nil
                },
                cancellationHandler: { (error: XPCRichError) in
                    box.transport?.handleSessionCancellation(error)
                })
        }
    }

    /// Dial an XPC service bundle inside the calling application, by bundle identifier.
    public static func connectingToXPCService(
        _ name: String, targetQueue: DispatchQueue? = nil
    ) throws(RawTransportError) -> XPCRawTransport {
        try dialling { box in
            try XPCSession(
                xpcService: name, targetQueue: targetQueue, options: .inactive,
                incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                    box.transport?.handleIncoming(message); return nil
                },
                cancellationHandler: { (error: XPCRichError) in
                    box.transport?.handleSessionCancellation(error)
                })
        }
    }

    /// Dial an anonymous listener through the `XPCEndpoint` it vended.
    public static func connecting(
        to endpoint: XPCEndpoint, targetQueue: DispatchQueue? = nil
    ) throws(RawTransportError) -> XPCRawTransport {
        try dialling { box in
            try XPCSession(
                endpoint: endpoint, targetQueue: targetQueue, options: .inactive,
                incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                    box.transport?.handleIncoming(message); return nil
                },
                cancellationHandler: { (error: XPCRichError) in
                    box.transport?.handleSessionCancellation(error)
                })
        }
    }

    /// Build a client transport from an inactive session, wiring the box before anything can
    /// call back (the session is `.inactive`, so nothing does until `activate()`).
    private static func dialling(
        _ makeSession: (Box) throws -> XPCSession
    ) throws(RawTransportError) -> XPCRawTransport {
        let box = Box()
        let session: XPCSession
        do {
            session = try makeSession(box)
        } catch {
            throw RawTransportError.rawTransportCancelled(
                message: "could not create XPCSession: \(error)")
        }
        let transport = XPCRawTransport(session: session, isAlreadyActive: false)
        transport.state.withLock { $0.box = box }
        box.transport = transport
        return transport
    }
}
#endif
