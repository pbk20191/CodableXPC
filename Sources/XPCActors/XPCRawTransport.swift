#if canImport(Darwin)
import Foundation
import Synchronization
import XPC

// ===========================================================================================
// MARK: - A RawTransport on Apple's XPCSession / XPCListener overlay
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension Transport {

    /// A ``RawTransportProtocol`` over Apple's `XPCSession`, with peers accepted through
    /// `XPCListener.IncomingSessionRequest` -- Apple's `Transport.XPCRawTransport`.
    ///
    /// It follows Apple's back-reference model: the raw transport stores its parent
    /// ``Transport`` (set by ``activate(linking:)``) and routes inbound packets into
    /// `parentTransport.handleReceivedPacket` and pipe-death into
    /// `parentTransport.handleCancellation` -- there are no injected closures.
    ///
    /// Sends are one-way -- `XPCSession.send(message:)`, never the reply overload -- and the
    /// incoming-message handler always returns `nil`, so XPC's reply channel stays unused and
    /// replies travel as ordinary inbound packets. That is what lets the listening side
    /// originate calls.
    public final class XPCRawTransport: RawTransportProtocol, @unchecked Sendable {

        /// Apple's peer gate -- a class holding a `Mutex<State>`. It governs one-time
        /// activation and one-time cancellation of an accepted (peer) session.
        public final class PeerGate {
            enum State { case initial, activated, canceled }
            let state = Mutex<State>(.initial)
            public init() {}
        }

        /// Which end this is. `.peer` wraps an *already-live* session handed back by
        /// `IncomingSessionRequest.accept`; `.client` wraps an inactive session that
        /// ``activate(linking:)`` configures and activates.
        public enum Role {
            case peer(gate: PeerGate)
            case client

            /// A fresh gate on every access -- Apple's `static var peer`, which mints a gate for
            /// callers who do not have one.
            public static var peer: Role { .peer(gate: PeerGate()) }
        }

        /// Apple's `parentTransport` -- a strong `var`, cleared on cancellation. Together with
        /// the session's handler closures (which capture `self` weakly) this is what keeps the
        /// `Transport <-> XPCRawTransport` cycle breakable.
        private var parentTransport: Transport?
        private let session: XPCSession
        private let role: Role

        /// `@unchecked Sendable`: only ever touched under ``state``' `Mutex`. Also, `xpc_object_t`
        /// is not `Sendable` in the overlay though libxpc objects are thread-safe; the lock is the
        /// synchronization either way.
        private struct State: @unchecked Sendable {
            /// The most recent message the peer sent, retained so the peer gates have something
            /// to interrogate. Message-scoped at capture, peer-scoped in meaning: every message
            /// on one session comes from the same peer. This is the deliberate deviation the
            /// module keeps -- `XPCSession.auditToken` is gone from the current overlay.
            var lastReceivedMessage: xpc_object_t?
        }
        private let state = Mutex<State>(State())

        public init(session: XPCSession, role: Role = .client) {
            self.session = session
            self.role = role
        }

        // MARK: Peer identity

        /// What the peer can attest, if anything -- message-level, from the last message's
        /// sender. `AuditTokenAttestation.init?` rejects an invalid token, so a dictionary that
        /// never crossed a connection reports "cannot tell", not "not entitled".
        public var peerAttestation: (any PeerAttestation)? {
            #if os(macOS) || targetEnvironment(macCatalyst)
            guard let message = state.withLock({ $0.lastReceivedMessage }) else { return nil }
            return AuditTokenAttestation(XPCDictionary(message).xpcBridgedAuditToken())
            #else
            return nil
            #endif
        }

        /// Apply a client-side peer requirement to the underlying (inactive) session -- Apple's
        /// `XPCSession.setPeerRequirement(_:)`. A no-op for a requirement that carries no overlay
        /// `XPCPeerRequirement` (a named-only stand-in libxpc cannot express). Called before
        /// ``activate(linking:)``, i.e. before any byte moves.
        public func setPeerRequirement(_ requirement: PeerRequirement) {
            guard let xpc = requirement.xpcRequirement else { return }
            session.setPeerRequirement(xpc)
        }

        // MARK: RawTransportProtocol

        /// Apple's `activate(linking:)`: store the back-reference, then configure-and-activate.
        /// For a `.peer` gate the work runs only when the gate is still `.initial`; an accepted
        /// session is already live, so configuration only marks the gate and installs nothing
        /// more (its handlers were wired at `accept` time). For a `.client` the inactive session
        /// is configured and activated here.
        public func activate(linking transport: Transport) throws(SetupError) {
            self.parentTransport = transport
            switch role {
            case .peer(let gate):
                let proceed: Bool = gate.state.withLock { st in
                    guard st == .initial else { return false }
                    st = .activated
                    return true
                }
                guard proceed else { return }
                // The accepted session is already active with handlers wired at `accept`; there
                // is nothing to activate. (Deviation from Apple, whose accepted session is
                // inactive at this point -- ours is live, the documented `isAlreadyActive` case.)
            case .client:
                try configureAndActivateSession(queue: transport.queue)
            }
        }

        /// Install the session's incoming-message and error handlers -- routing into
        /// `parentTransport.handleReceivedPacket` / `.handleCancellation` -- then activate the
        /// session on `queue`.
        private func configureAndActivateSession(queue: DispatchSerialQueue) throws(SetupError) {
            session.setIncomingMessageHandler { [weak self] (message: XPCDictionary) -> XPCDictionary? in
                self?.handleIncoming(message)
                return nil
            }
            session.setCancellationHandler { [weak self] (error: XPCRichError) in
                self?.handleSessionCancellation(error)
            }
            session.setTargetQueue(queue)
            do {
                try session.activate()
            } catch {
                throw SetupError("Failed to activate XPCSession (error: \(error))")
            }
        }

        public func send(packet: Packet) throws(RawTransportError) {
            do {
                try session.send(message: XPCDictionary(packet.rawValue))
            } catch {
                throw RawTransportError.rawTransportCancelled(message: "XPCSession send: \(error)")
            }
        }

        /// Tear the session down and drop the back-reference. For a `.peer` gate this runs once
        /// (guarded by the gate's `.canceled` state).
        ///
        /// **Deviation:** Apple's peer branch calls `session.rejectPeer(reason:)`, which the
        /// current overlay does not export; both branches use `session.cancel(reason:)` here.
        public func cancel() {
            switch role {
            case .peer(let gate):
                let proceed: Bool = gate.state.withLock { st in
                    guard st != .canceled else { return false }
                    st = .canceled
                    return true
                }
                guard proceed else { break }
                session.cancel(reason: "(transport cancelled by client)")
            case .client:
                session.cancel(reason: "(transport cancelled by client)")
            }
            parentTransport = nil
            state.withLock { $0.lastReceivedMessage = nil }
        }

        // MARK: Delivery

        /// Wired to the session's incoming-message handler. Retains the raw message (for the
        /// gates), parses the packet, and hops onto the parent's queue to route it -- so
        /// `Transport.handleReceivedPacket` always runs on `parentTransport.queue`.
        private func handleIncoming(_ message: XPCDictionary) {
            guard let parent = parentTransport else { return }
            let packet: Packet? = message.withUnsafeUnderlyingDictionary { raw in
                // Retained before the packet is parsed: a malformed message still identifies its
                // sender, and the gate that will ask about the sender must not depend on this
                // side having understood what it said.
                state.withLock { $0.lastReceivedMessage = raw }
                return Packet(rawValue: raw)
            }
            guard let packet else { return }
            parent.queue.async { parent.handleReceivedPacket(packet) }
        }

        /// Wired to the session's error handler: route the death into the parent. The parent's
        /// fuse makes our own `cancel()` echo harmless.
        private func handleSessionCancellation(_ error: XPCRichError) {
            parentTransport?.handleCancellation()
        }
    }
}

// ===========================================================================================
// MARK: - Accepting, dialling
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension Transport.XPCRawTransport {

    /// Breaks the chicken-and-egg between a session's message handler and the transport that
    /// handler dispatches to: `accept` returns an already-live session, so a peer's first
    /// message can reach the handler before the transport is assigned. The handlers route
    /// through this box; the transport is published into it immediately after.
    final class Box: @unchecked Sendable {
        private let _transport = Mutex<Transport.XPCRawTransport?>(nil)
        var transport: Transport.XPCRawTransport? {
            get { _transport.withLock { $0 } }
            set { _transport.withLock { $0 = newValue } }
        }
    }

    /// Accept an inbound peer. The returned session is already live, so the transport takes the
    /// `.peer` role; its handlers are wired here, through a ``Box``, and begin routing into the
    /// transport as soon as it is published. Apple's `Transport.XPCRawTransport.accepting`.
    public static func accepting(
        _ request: XPCListener.IncomingSessionRequest
    ) -> (XPCListener.IncomingSessionRequest.Decision, Transport.XPCRawTransport) {
        let box = Box()
        let (decision, session) = request.accept(
            incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                box.transport?.handleIncoming(message)
                return nil
            },
            cancellationHandler: { (error: XPCRichError) in
                box.transport?.handleSessionCancellation(error)
            })
        let transport = Transport.XPCRawTransport(session: session, role: .peer)
        box.transport = transport
        return (decision, transport)
    }

    /// Dial a launchd Mach service by name. The session comes back inactive; the client-role
    /// transport activates and configures it in ``activate(linking:)``.
    public static func connectingToMachService(
        _ name: String, targetQueue: DispatchQueue? = nil
    ) throws(RawTransportError) -> Transport.XPCRawTransport {
        try dialling { try XPCSession(machService: name, targetQueue: targetQueue, options: .inactive) }
    }

    /// Dial an XPC service bundle inside the calling application, by bundle identifier.
    public static func connectingToXPCService(
        _ name: String, targetQueue: DispatchQueue? = nil
    ) throws(RawTransportError) -> Transport.XPCRawTransport {
        try dialling { try XPCSession(xpcService: name, targetQueue: targetQueue, options: .inactive) }
    }

    /// Dial an anonymous listener through the `XPCEndpoint` it vended.
    public static func connecting(
        to endpoint: XPCEndpoint, targetQueue: DispatchQueue? = nil
    ) throws(RawTransportError) -> Transport.XPCRawTransport {
        try dialling { try XPCSession(endpoint: endpoint, targetQueue: targetQueue, options: .inactive) }
    }

    /// Dial using a caller-provided (inactive) session.
    public static func connecting(
        using session: XPCSession, targetQueue: DispatchQueue? = nil
    ) -> Transport.XPCRawTransport {
        targetQueue.flatMap(session.setTargetQueue)
        return Transport.XPCRawTransport(session: session, role: .client)
    }

    /// Build a client transport from an inactive session. Its handlers are installed later, in
    /// ``activate(linking:)`` -- nothing calls back before then because the session is inactive.
    private static func dialling(
        _ makeSession: () throws -> XPCSession
    ) throws(RawTransportError) -> Transport.XPCRawTransport {
        let session: XPCSession
        do {
            session = try makeSession()
        } catch {
            throw RawTransportError.rawTransportCancelled(
                message: "could not create XPCSession: \(error)")
        }
        return Transport.XPCRawTransport(session: session, role: .client)
    }
}
#endif
