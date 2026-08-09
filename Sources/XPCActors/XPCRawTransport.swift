import Foundation
import XPC

/// A `RawTransport` over Apple's `XPCSession`.
///
/// Sends are one-way: `XPCSession.send(message:)`, never `send(message:replyHandler:)`.
/// The incoming-message handler always returns `nil`, so XPC's reply channel stays
/// unused and replies travel as ordinary inbound packets. That is what allows the
/// listener side to originate calls.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public final class XPCRawTransport: RawTransportProtocol, @unchecked Sendable {

    private let session: XPCSession
    private let isAlreadyActive: Bool
    private let lock = NSLock()
    private var handler: (@Sendable (Packet) -> Void)?
    private var cancellationHandler: (@Sendable (String) -> Void)?
    private var cancellationReason: String?
    /// The box whose closure keeps this transport reachable from the session's
    /// incoming-message handler. Held so `cancel(reason:)` can break the resulting
    /// retain cycle (transport -> session -> closure -> box -> transport); see
    /// `cancel(reason:)`.
    private var box: Box?

    /// - Parameter isAlreadyActive: `true` for a session handed to us by
    ///   `IncomingSessionRequest.accept`, which is live on return. Calling
    ///   `session.activate()` on such a session does *not* throw a catchable Swift
    ///   error -- it is a fatal `libxpc` API-misuse trap (SIGTRAP, "Attempting to
    ///   activate an already active listener/session"), confirmed empirically by
    ///   temporarily removing this guard and observing the crash. `isAlreadyActive`
    ///   is therefore load-bearing, not defensive boilerplate.
    public init(session: XPCSession, isAlreadyActive: Bool = false) {
        self.session = session
        self.isAlreadyActive = isAlreadyActive
    }

    /// The peer's Mach audit token, wrapped so ``Session``'s gates can ask it questions.
    ///
    /// This is Apple's `Transport.XPCRawTransport.auditToken` (`0x2ad4e122c` forwards to it)
    /// step for step: read `XPCSession.auditToken`, apply `audit_token_t.isValid`, and
    /// return `nil` when it fails. Both of those are exported by `libswiftXPC` and declared
    /// in the SDK's `.tbd`, and neither is in the public `.swiftinterface`; the bridge is in
    /// `PeerRequirement.swift`, which explains why it is a link-time binding rather than a
    /// `dlsym`.
    ///
    /// Connection-level, not message-level. `XPCDictionary.auditToken` would give the
    /// sender of one message, which sounds stricter and is not: every message on one
    /// `XPCSession` comes from the same peer, and a per-message read would have to happen
    /// inside the delivery handler, where the per-actor gate — which runs after an `await`
    /// on activation — cannot reach it.
    ///
    /// **The `#available` below is load-bearing, not a formality.** It is the only thing
    /// keeping `XPCSession.auditToken` — a symbol that links *weakly* in this package's
    /// artifacts, so a missing one binds to zero — off an OS that does not export it. The
    /// bridge section in `PeerRequirement.swift` has the measurements.
    public var peerAttestation: (any PeerAttestation)? {
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard #available(macOS 26, macCatalyst 26, *) else { return nil }
        return AuditTokenAttestation(session.xpcBridgedAuditToken())
        #else
        return nil
        #endif
    }

    public func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void) {
        lock.withLock { self.handler = handler }
    }

    public func setCancellationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { self.cancellationHandler = handler }
    }

    public func activate() throws(RawTransportError) {
        guard !isAlreadyActive else { return }
        do {
            try session.activate()
        } catch {
            throw RawTransportError.rawTransportCancelled(
                message: "could not activate XPCSession: \(error)"
            )
        }
    }

    public func send(packet: Packet) throws(RawTransportError) {
        if let reason = lock.withLock({ cancellationReason }) {
            throw RawTransportError.rawTransportCancelled(message: reason)
        }
        do {
            try session.send(message: XPCDictionary(packet.rawValue))
        } catch {
            throw RawTransportError.rawTransportCancelled(message: "XPCSession send: \(error)")
        }
    }

    public func cancel(reason: String) {
        let shouldCancel: Bool = lock.withLock {
            guard cancellationReason == nil else { return false }
            cancellationReason = reason
            handler = nil
            return true
        }
        guard shouldCancel else { return }
        session.cancel(reason: reason)
        // Break the retain cycle the message handler closes over. The transport holds
        // the session, the session holds the closure, and the closure holds the box --
        // so the box is where the loop has to be cut. This is the same cancel-before-
        // release shape InProcessRawTransport uses when it unlinks remoteEnd. Clearing
        // box.transport also means a packet delivered after cancellation finds nothing
        // to dispatch to, a second layer beyond the `handler` check above.
        box?.transport = nil
        box = nil
    }

    /// Feed an inbound `XPCDictionary` in. Wire this to the session's or the
    /// listener's incoming-message handler, which must return `nil`.
    ///
    /// `XPCDictionary` has no property exposing its underlying `xpc_object_t`
    /// (the brief's guess of `.xpcObject` does not exist in the overlay); the
    /// symmetric accessor to `init(_ value: xpc_object_t)` is the closure-based
    /// `withUnsafeUnderlyingDictionary`.
    public func handleIncoming(_ message: XPCDictionary) {
        let handler = lock.withLock { self.handler }
        guard let handler else { return }
        message.withUnsafeUnderlyingDictionary { raw in
            guard let packet = Packet(rawValue: raw) else { return }
            handler(packet)
        }
    }

    /// The overlay told us the session died. Wire this to the `cancellationHandler:`
    /// the session was built with.
    ///
    /// Deaths that originate here go through `cancel(reason:)` instead, which sets
    /// `cancellationReason` *before* calling `session.cancel`. The overlay then calls
    /// this method back for our own cancellation too, and the guard below is what
    /// stops that echo from being reported to the layer above as a peer death.
    func handleSessionCancellation(_ error: XPCRichError) {
        let message = "XPCSession cancelled: \(error)"
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            guard cancellationReason == nil else { return nil }
            cancellationReason = message
            self.handler = nil
            defer { cancellationHandler = nil }
            return cancellationHandler
        }
        guard let handler else { return }
        // The session is already gone, so the retain cycle that kept it reachable has
        // nothing left to serve. Cut it here as well as in `cancel(reason:)`, otherwise
        // a peer that dies first leaks the transport until someone cancels a dead pipe.
        box?.transport = nil
        box = nil
        handler(message)
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension XPCRawTransport {

    /// Breaks the chicken-and-egg between a session's message handler and the
    /// transport that handler dispatches to. Lock-guarded because `accepting`
    /// returns a session that is already live: a peer's first message can reach
    /// the handler before the assignment on the next line completes.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _transport: XPCRawTransport?
        var transport: XPCRawTransport? {
            get { lock.withLock { _transport } }
            set { lock.withLock { _transport = newValue } }
        }
    }

    /// Accept an inbound peer. The returned session is already live, so the
    /// transport is built with `isAlreadyActive: true`.
    public static func accepting(
        _ request: XPCListener.IncomingSessionRequest
    ) -> (XPCListener.IncomingSessionRequest.Decision, XPCRawTransport) {
        let box = Box()
        let (decision, session) = request.accept(
            incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                box.transport?.handleIncoming(message)
                return nil
            },
            // The overlay's death channel. Routed through the same box as the message
            // handler, for the same reason: the transport does not exist yet here.
            cancellationHandler: { (error: XPCRichError) in
                box.transport?.handleSessionCancellation(error)
            }
        )
        let transport = XPCRawTransport(session: session, isAlreadyActive: true)
        // Order matters, and this session is the reason. `accept` returns it already
        // live, so `box.transport = transport` is the moment the transport becomes
        // reachable from both handler closures -- a peer can die on the very next
        // instruction. `handleSessionCancellation` reads and clears `self.box`
        // unsynchronized, so if that publish came first it would race this assignment:
        // the handler would see a nil box, skip the clear, and this line would then
        // reinstate the transport -> session -> closure -> box -> transport cycle the
        // clear exists to cut. Give the transport its box *before* anything can call
        // into it.
        transport.box = box
        box.transport = transport
        return (decision, transport)
    }
}

// `XPCEndpoint`, the `XPCSession(endpoint:...)` initializer, and `XPCListener.endpoint`
// all require macOS 15 / macCatalyst 18 in the real overlay and are marked
// `unavailable` on iOS/tvOS/watchOS -- stricter than this file's macOS-14 floor
// (confirmed against the .swiftinterface; see task-8-report.md). `connecting(to:)`
// is split into its own extension carrying that narrower availability rather than
// widening the whole type, since every other member here only needs macOS 14.
@available(macOS 15, macCatalyst 18, *)
@available(iOS, unavailable)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension XPCRawTransport {

    /// Dial `endpoint`. The session comes back inactive; `activate()` starts it.
    public static func connecting(
        to endpoint: XPCEndpoint,
        targetQueue: DispatchQueue? = nil
    ) throws -> XPCRawTransport {
        let box = Box()
        let session = try XPCSession(
            endpoint: endpoint,
            targetQueue: targetQueue,
            options: .inactive,
            incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                box.transport?.handleIncoming(message)
                return nil   // never use XPC's reply channel
            },
            cancellationHandler: { (error: XPCRichError) in
                box.transport?.handleSessionCancellation(error)
            }
        )
        let transport = XPCRawTransport(session: session, isAlreadyActive: false)
        // Not exposed here -- this session is created `.inactive`, so nothing can call
        // back before `activate()`. Ordered the same way as `accepting` regardless, so
        // the safe shape is the one this file consistently shows.
        transport.box = box
        box.transport = transport
        return transport
    }
}
