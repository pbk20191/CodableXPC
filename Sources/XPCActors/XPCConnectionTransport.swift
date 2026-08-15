#if canImport(Darwin)
import Foundation
import XPC

// ===========================================================================================
// MARK: - A RawTransport on libxpc itself
// ===========================================================================================

/// A ``RawTransportProtocol`` over a bare `xpc_connection_t`.
///
/// **Why not the Swift overlay.** `XPCSession`, `XPCListener` and `XPCEndpoint` are macOS 14,
/// 14 and 15; the C calls they wrap -- `xpc_connection_create`,
/// `xpc_connection_create_mach_service`, `xpc_connection_create_from_endpoint`,
/// `xpc_endpoint_create` -- are all `__OSX_AVAILABLE_STARTING(__MAC_10_7)`. The overlay was
/// the only thing holding this module at macOS 14, and it bought nothing that is not here:
/// `xpc_session_t` is a wrapper over `xpc_connection_t`, and the two peer-requirement
/// primitives (`xpc_connection_set_peer_requirement`,
/// `xpc_peer_requirement_match_received_message`) are macOS 26 either way, so nothing is
/// given up by dropping down a layer.
///
/// The module's floor is now `import Distributed`, which is macOS 13 and in no
/// back-deployment set -- measured, not assumed: `distributed actor` fails to compile at
/// `-target arm64-apple-macos12.0` with *"only available in macOS 13.0"*.
///
/// Sends are one-way, exactly as before. `xpc_connection_send_message` never uses the reply
/// channel, so replies travel as ordinary inbound messages -- which is what lets the
/// listening side originate calls.
@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
public final class XPCConnectionTransport: RawTransportProtocol, @unchecked Sendable {

    private let connection: xpc_connection_t
    private let lock = NSLock()
    private var handler: (@Sendable (Packet) -> Void)?
    private var cancellationHandler: (@Sendable (String) -> Void)?
    private var cancellationReason: String?
    private var isActivated = false

    /// The most recent message the peer sent, retained so the peer gates have something to
    /// interrogate.
    ///
    /// **Message-scoped at capture, peer-scoped in meaning.** Every message on one connection
    /// comes from the same peer, so "the last message's sender" and "this connection's peer"
    /// are the same process -- which is what makes it sound to answer a question asked much
    /// later, after an `await`, from a message that arrived before it. That was the reason the
    /// overlay-backed version read `XPCSession.auditToken` instead of a per-message one; the
    /// connection API has no connection-level accessor in public headers, so the token is
    /// taken from a message and then kept, which lands in the same place.
    private var lastReceivedMessage: xpc_object_t?

    /// The box whose closure keeps this transport reachable from the connection's event
    /// handler. Held so `cancel(reason:)` can break the cycle
    /// (transport -> connection -> handler -> box -> transport).
    private var box: Box?

    /// Wrap a connection. It must **not** have been resumed yet: `activate()` resumes it, and
    /// everything that has to be installed first -- the event handler, the packet handler --
    /// is installed before then.
    ///
    /// There is no `isAlreadyActive` parameter and no trap guarding it. That was an artefact
    /// of the overlay, where `IncomingSessionRequest.accept` handed back a live `XPCSession`
    /// and calling `activate()` on it was a fatal libxpc API-misuse trap. libxpc never hands
    /// out a resumed connection: a peer arriving at a listener's event handler is suspended
    /// until its receiver resumes it, which is precisely the window the handler installation
    /// needs.
    public init(connection: xpc_connection_t) {
        self.connection = connection
    }

    // MARK: Peer identity

    /// What the peer's connection can attest, if anything.
    ///
    /// `nil` below macOS 26, and that is not a regression from the overlay version: the
    /// bridged `audit_token_t.satisfies(requirement:)` and `XPCPeerRequirement` are macOS 26
    /// there too. Below that OS there was never a check, and this says so rather than
    /// inventing one.
    public var peerAttestation: (any PeerAttestation)? {
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard let message = lock.withLock({ lastReceivedMessage }) else { return nil }
        // The token comes from a *message* rather than from the connection, because the
        // connection API has no public audit-token accessor -- `XPCSession.auditToken` had one
        // and that is gone with the overlay. `XPCDictionary.auditToken` is the message-side
        // twin, already bridged in `PeerRequirement.swift`, and its doc there anticipated
        // exactly this caller. `AuditTokenAttestation.init?` rejects an invalid token, so a
        // dictionary that never crossed a connection reports "cannot tell", not "not entitled".
        return AuditTokenAttestation(XPCDictionary(message).xpcBridgedAuditToken())
        #else
        return nil
        #endif
    }

    // MARK: RawTransportProtocol

    public func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func setCancellationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.cancellationHandler = handler }
    }

    /// Install the event handler and resume the connection.
    ///
    /// `xpc_connection_activate` rather than `xpc_connection_resume`: resuming a connection
    /// twice is an API-misuse trap in libxpc, and `activate` is the idempotent-by-contract
    /// spelling introduced for exactly that. The `isActivated` latch is still here, because
    /// activating a *cancelled* connection is a different mistake and this catches it.
    public func activate() throws(RawTransportError) {
        let box = Box()
        let outcome: (cancelled: String?, alreadyActive: Bool) = lock.withLock {
            if let reason = cancellationReason { return (reason, false) }
            if isActivated { return (nil, true) }
            isActivated = true
            self.box = box
            // Published under the *same* lock hold that stores `self.box`, and the ordering is
            // the point: an earlier revision did this after releasing the lock, which left a
            // window for `cancel(reason:)` to run in between -- its `box?.transport = nil`
            // cleared a box this line would then repopulate, reinstating the
            // transport -> connection -> handler -> box -> transport cycle that the clear
            // exists to cut. The same race `XPCRawTransport.accepting` documented; the fix is
            // the same publication order it used.
            box.transport = self
            return (nil, false)
        }
        if let reason = outcome.cancelled {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
        guard !outcome.alreadyActive else { return }
        // These stay outside the lock on purpose. `xpc_connection_set_event_handler` can
        // deliver on another queue the instant `xpc_connection_activate` runs, and that
        // delivery path takes this lock (`handleIncoming`); holding it here would be a
        // lock-order inversion waiting for a queue. A cancel that lands between the lock
        // release and these two calls is benign now: the box is already cleared, so the
        // handler installed below dispatches into nothing.
        xpc_connection_set_event_handler(connection) { event in
            box.transport?.handle(event)
        }
        xpc_connection_activate(connection)
    }

    public func send(packet: Packet) throws(RawTransportError) {
        if let reason = lock.withLock({ cancellationReason }) {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
        // **`xpc_connection_send_message` cannot fail synchronously and reports nothing.** A
        // send to a dead connection is accepted and then dropped, with the death arriving
        // later on the event handler as `XPC_ERROR_CONNECTION_INVALID`. That is not a
        // regression from `XPCSession.send(message:)`, which throws: the overlay's throw comes
        // from the same asynchronous machinery and only ever fires for a connection it already
        // knew was gone -- which is what the `cancellationReason` check above reproduces. The
        // layer that actually notices a lost request is `RequestTable`, woken by the
        // cancellation handler.
        xpc_connection_send_message(connection, packet.rawValue)
    }

    public func cancel(reason: String) {
        let shouldCancel: Bool = lock.withLock {
            guard cancellationReason == nil else { return false }
            cancellationReason = reason
            handler = nil
            return true
        }
        guard shouldCancel else { return }
        xpc_connection_cancel(connection)
        // Break the cycle the event handler closes over: transport -> connection -> handler ->
        // box -> transport. The box is where it has to be cut, and clearing `box.transport`
        // also means an event delivered after cancellation finds nothing to dispatch to -- a
        // second layer beyond the `handler` check.
        lock.withLock {
            box?.transport = nil
            box = nil
            lastReceivedMessage = nil
        }
    }

    // MARK: Events

    /// One event from libxpc: a message, a death, or -- on a listener connection -- a peer.
    ///
    /// The type check is not defensive boilerplate. `xpc_connection_set_event_handler` is a
    /// single untyped channel and the object really can be any of three unrelated things, so
    /// treating everything as a dictionary would feed `Packet(rawValue:)` an error object and
    /// silently drop every connection death.
    private func handle(_ event: xpc_object_t) {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            handleError(event)
        } else if type == XPC_TYPE_DICTIONARY {
            handleIncoming(event)
        }
        // A peer connection (`XPC_TYPE_CONNECTION`) never reaches here: peers are delivered to
        // a *listener* connection's handler, and a listener is never wrapped in this type.
        // `XPCConnectionListener` owns that channel.
    }

    private func handleIncoming(_ message: xpc_object_t) {
        let handler: (@Sendable (Packet) -> Void)? = lock.withLock {
            // Retained before the packet is even parsed: a malformed message still identifies
            // its sender, and the gate that will ask about the sender must not depend on this
            // side having understood what it said.
            lastReceivedMessage = message
            return self.handler
        }
        guard let handler, let packet = Packet(rawValue: message) else { return }
        handler(packet)
    }

    /// The pipe died. Route it the same way the overlay's cancellation handler was routed.
    ///
    /// Deaths that originate here go through `cancel(reason:)`, which sets `cancellationReason`
    /// *before* calling `xpc_connection_cancel`. libxpc then delivers
    /// `XPC_ERROR_CONNECTION_INVALID` back to us for our own cancellation too, and the guard
    /// below is what stops that echo being reported upward as a peer death.
    private func handleError(_ error: xpc_object_t) {
        let text = xpc_dictionary_get_string(error, XPC_ERROR_KEY_DESCRIPTION)
            .map { String(cString: $0) } ?? "unknown XPC error"
        // `XPC_ERROR_TERMINATION_IMMINENT` is a warning, not a death -- it means the process is
        // about to be jetsammed and is delivered *before* anything breaks. Reporting it as a
        // cancellation would fail every outstanding request on a connection that still works.
        if error === XPC_ERROR_TERMINATION_IMMINENT { return }

        let message = "XPC connection cancelled: \(text)"
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            guard cancellationReason == nil else { return nil }
            cancellationReason = message
            self.handler = nil
            defer { cancellationHandler = nil }
            return cancellationHandler
        }
        guard let handler else { return }
        // The connection is gone, so the cycle that kept it reachable has nothing left to
        // serve. Cut it here as well as in `cancel(reason:)` -- otherwise a peer that dies
        // first leaks the transport until someone cancels a dead pipe.
        lock.withLock {
            box?.transport = nil
            box = nil
        }
        handler(message)
    }

    /// Breaks the chicken-and-egg between a connection's event handler and the transport that
    /// handler dispatches to. Lock-guarded because a resumed connection can deliver an event
    /// on another queue while `activate()` is still returning.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _transport: XPCConnectionTransport?
        var transport: XPCConnectionTransport? {
            get { lock.withLock { _transport } }
            set { lock.withLock { _transport = newValue } }
        }
    }
}

// ===========================================================================================
// MARK: - Dialling
// ===========================================================================================

@available(macOS 26, iOS 26, tvOS 26, watchOS 26, *)
extension XPCConnectionTransport {

    /// Dial a launchd Mach service by name.
    ///
    /// `xpc_connection_create_mach_service` with flags `0` -- the `LISTENER` bit is what makes
    /// the same call produce a listener instead, and it is deliberately not exposed here:
    /// ``XPCConnectionListener`` is where listening lives, and a factory that could
    /// accidentally return one would be a factory whose result means two different things.
    public static func connectingToMachService(
        _ name: String, targetQueue: DispatchQueue? = nil
    ) -> XPCConnectionTransport {
        XPCConnectionTransport(
            connection: xpc_connection_create_mach_service(name, targetQueue, 0))
    }

    /// Dial an XPC service bundle inside the calling application, by bundle identifier.
    public static func connectingToXPCService(
        _ name: String, targetQueue: DispatchQueue? = nil
    ) -> XPCConnectionTransport {
        XPCConnectionTransport(connection: xpc_connection_create(name, targetQueue))
    }

    /// Dial an anonymous listener through the endpoint it vended.
    public static func connecting(
        to endpoint: xpc_endpoint_t
    ) -> XPCConnectionTransport {
        XPCConnectionTransport(connection: xpc_connection_create_from_endpoint(endpoint))
    }
}
#endif
