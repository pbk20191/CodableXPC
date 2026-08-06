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
    private var cancellationReason: String?

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

    public func setPacketHandler(_ handler: @escaping @Sendable (Packet) -> Void) {
        lock.withLock { self.handler = handler }
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
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension XPCRawTransport {

    /// Holds the transport so an incoming-message handler can reach it before the
    /// transport itself exists.
    final class Box: @unchecked Sendable {
        var transport: XPCRawTransport?
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
            }
        )
        let transport = XPCRawTransport(session: session, isAlreadyActive: true)
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
            }
        )
        let transport = XPCRawTransport(session: session, isAlreadyActive: false)
        box.transport = transport
        return transport
    }
}
