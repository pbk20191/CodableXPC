import Foundation
import GRPCCore
import Synchronization
import XPC
import CodableXPC

/// Wraps one `XPCSession`, multiplexing many RPCs over it by `StreamID` and demultiplexing
/// inbound frames to the right stream. Adopts `ActorBackedByDispatchSerialQueue` semantics
/// informally: `queue` is set as the session's target queue, so every inbound message -- and
/// therefore every `route(_:)` call -- runs serially on it. That is what lets
/// `StreamChannel.accept`'s "callers must invoke `accept` serially per stream" precondition hold
/// without a second lock inside `StreamChannel` (see StreamChannel.swift).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class XPCConnection: Sendable {
    enum Role: Sendable { case client, server }

    let role: Role
    private let session: XPCSession
    let queue: DispatchSerialQueue
    private let nextStreamID = Atomic<UInt64>(1)

    /// Tracks whether `session.activate()` has *succeeded*. Seeded `true` for `.server` (an
    /// accepted session is already live); for `.client` it flips to `true` only inside
    /// ``activate()``, after `session.activate()` returns without throwing. Gates `deinit`'s
    /// cancel -- see the comment there for why.
    private let isActivated: Atomic<Bool>

    private struct Registry: Sendable {
        var clientChannels: [StreamID: StreamChannel<RPCResponsePart<[UInt8]>>] = [:]
        var serverChannels: [StreamID: StreamChannel<RPCRequestPart<[UInt8]>>] = [:]
        /// A server-side `StreamChannel`'s inbound sequence, registered eagerly the moment an
        /// `.openStream` frame is routed and claimed later by `registerServerStream`. Without
        /// this, frames arriving between accept and `registerServerStream` (metadata, the first
        /// message -- exactly what a real client sends immediately) would find no channel yet
        /// and be silently dropped; see the type's doc comment.
        var pendingServerInbound: [StreamID: RPCAsyncSequence<RPCRequestPart<[UInt8]>, any Error>] = [:]
    }
    private let registry = Mutex(Registry())

    private let acceptedContinuation: AsyncStream<(StreamID, MethodDescriptor)>.Continuation
    let acceptedStreams: AsyncStream<(StreamID, MethodDescriptor)>

    /// Wraps `session`.
    ///
    /// - For `.client`: `session` must be inactive (freshly dialled). This installs the
    ///   incoming-message handler, cancellation handler, and target queue but does **not**
    ///   activate it -- call ``activate()`` before use, or prefer ``connecting(to:queue:)``,
    ///   which does both atomically. Prefer this initializer directly only when dialling by a
    ///   means other than an `XPCEndpoint` (e.g. a mach or XPC service name).
    /// - For `.server`: `session` is an already-live session handed back by
    ///   `XPCListener.IncomingSessionRequest.accept`. This still (re-)installs the handlers and
    ///   target queue -- which is safe to call on a live session -- but the session must never be
    ///   passed to ``activate()``.
    init(session: XPCSession, role: Role, queue: DispatchSerialQueue) {
        self.session = session
        self.role = role
        self.queue = queue
        self.isActivated = Atomic<Bool>(role == .server)
        (acceptedStreams, acceptedContinuation) = AsyncStream.makeStream()
        session.setIncomingMessageHandler { [weak self] (message: XPCDictionary) -> XPCDictionary? in
            self?.handleInbound(message)
            return nil
        }
        // Peer death (session cancellation, e.g. the other process exiting) fails every live
        // stream locally rather than leaving them hung forever. Deadlines, `.goAway`, and
        // graceful-shutdown *sequencing* stay Task 9/10's job -- this only makes the hook exist.
        session.setCancellationHandler { [weak self] error in
            self?.failAll(RPCError(code: .unavailable, message: "XPC peer session cancelled: \(error)"))
        }
        session.setTargetQueue(queue)
    }

    /// Dials `endpoint` and returns an *activated* client connection in one step. Constructing
    /// and activating separately leaves a window where a caller could drop the `XPCConnection`
    /// before ever calling ``activate()`` (or after it throws) -- harmless with the
    /// ``isActivated`` gate below, but this factory removes the window entirely for the common
    /// endpoint-dialling case.
    static func connecting(to endpoint: XPCEndpoint, queue: DispatchSerialQueue) throws -> XPCConnection {
        let session = try XPCSession(endpoint: endpoint, options: .inactive)
        let connection = XPCConnection(session: session, role: .client, queue: queue)
        try connection.activate()
        return connection
    }

    /// Activates the underlying session. The *client* side calls this after construction -- the
    /// harness today (or, more simply, ``connecting(to:queue:)``); `XPCClientTransport.connect()`
    /// in Task 5. An accepted (server) session handed back from `IncomingSessionRequest.accept`
    /// is already live and must **not** be activated again.
    func activate() throws {
        try session.activate()
        isActivated.store(true, ordering: .relaxed)
    }

    /// libxpc traps (`_xpc_api_misuse`, `EXC_BREAKPOINT`) on `xpc_session_cancel` if the session
    /// was never successfully activated -- so an inactive client session whose `activate()` threw
    /// (Task 5's `connect()`-failure path) must **not** be cancelled here, only released. An
    /// activated-but-never-cancelled session traps on release the same way, so every session that
    /// *did* activate (every `.server` session, and every `.client` session past a successful
    /// `activate()`) still must be cancelled. `isActivated` is exactly that distinction. Full
    /// graceful-shutdown sequencing (draining, `.goAway`) is Task 9/10's job; this is just the
    /// RAII teardown of the native resource.
    deinit {
        if isActivated.load(ordering: .relaxed) {
            session.cancel(reason: "XPCConnection deinitialized")
        }
        acceptedContinuation.finish()
    }

    /// Serializes `frame` and sends it one-way over the session. (Credit-bearing sends with a
    /// reply arrive in Task 9.)
    func send(_ frame: XPCFrame) throws {
        let object = try frame.encodeToXPC()
        try session.send(message: XPCDictionary(object))
    }

    private func handleInbound(_ message: XPCDictionary) {
        guard let frame = try? message.withUnsafeUnderlyingDictionary({ try XPCFrame.decode(from: $0) })
        else {
            // Undecodable message: not a well-formed `XPCFrame` at all, so there is no `StreamID`
            // to fail against -- drop it. (A peer sending garbage is itself a protocol violation
            // better addressed by Task 9's peer-death/misbehavior handling than by this layer.)
            return
        }
        route(frame)
    }

    /// Always dispatched on `queue` -- see the type's doc comment.
    private func route(_ frame: XPCFrame) {
        switch frame {
        case .openStream(let id, let method, _):
            guard let descriptor = Self.methodDescriptor(from: method) else {
                // Malformed "package.Service/Method": no stream is registered for `id` yet
                // (this frame is what would create one), so there is nothing to fail -- drop it.
                return
            }
            // Register the server-side channel *now*, not when `registerServerStream` is later
            // called for this `id` -- a real client writes metadata/the first message right
            // after `openStream`, and those frames can arrive before whatever task is consuming
            // `acceptedStreams` gets around to calling `registerServerStream`. Registering eagerly
            // here (on the same serial `queue` that routes every subsequent frame for `id`)
            // closes that window structurally.
            let (channel, inbound) = StreamChannel<RPCRequestPart<[UInt8]>>.serverInbound(streamID: id)
            registry.withLock { reg in
                reg.serverChannels[id] = channel
                reg.pendingServerInbound[id] = inbound
            }
            acceptedContinuation.yield((id, descriptor))
        case .cancel(let id, let reason):
            failStream(id, RPCError(code: .cancelled, message: reason))
        case .goAway:
            break   // Task 10
        case .credit:
            break   // Task 9
        default:
            let id = frame.streamID
            registry.withLock { reg in
                if let c = reg.clientChannels[id] {
                    do {
                        try c.accept(frame)
                        // `.status` is the response direction's sole terminator (see
                        // StreamChannel.swift) -- drop the entry so a long-lived connection
                        // doesn't grow one registry entry per completed RPC forever.
                        if case .status = frame { reg.clientChannels[id] = nil }
                    } catch {
                        // A grammar violation (out-of-order seq, frame after terminal, ...):
                        // the channel is already desynced, so fail it locally and stop routing
                        // to it rather than leaving a live-but-broken stream in the registry.
                        reg.clientChannels[id] = nil
                        c.failInbound(error)
                    }
                } else if let s = reg.serverChannels[id] {
                    do {
                        try s.accept(frame)
                        // `.halfClose` is the request direction's sole terminator.
                        if case .halfClose = frame { reg.serverChannels[id] = nil }
                    } catch {
                        reg.serverChannels[id] = nil
                        s.failInbound(error)
                    }
                }
                // Else: a frame for a `StreamID` with no registered channel in either table --
                // e.g. it arrived after that stream's entry was already removed above (a
                // straggler after a terminal), or the peer referenced an id this side never
                // opened/accepted. Dropped; there is no local stream left to fail.
            }
        }
    }

    /// Splits the wire's "pkg.Service/Method" on the *last* "/" into service + method.
    /// `MethodDescriptor` has no `fullyQualifiedMethod:` initializer, only
    /// `fullyQualifiedService:method:` -- confirmed against the resolved grpc-swift-2 2.4.2
    /// source. Returns `nil` for a string with no "/" or an empty service/method half.
    private static func methodDescriptor(from wireMethod: String) -> MethodDescriptor? {
        guard let slash = wireMethod.lastIndex(of: "/") else { return nil }
        let service = String(wireMethod[..<slash])
        let method = String(wireMethod[wireMethod.index(after: slash)...])
        guard !service.isEmpty, !method.isEmpty else { return nil }
        return MethodDescriptor(fullyQualifiedService: service, method: method)
    }

    /// Allocates a `StreamID`, registers its inbound `StreamChannel`, and returns the full
    /// client-side `RPCStream` (inbound responses + outbound requests writer).
    func openClientStream(descriptor: MethodDescriptor)
    -> (StreamID, RPCStream<RPCAsyncSequence<RPCResponsePart<[UInt8]>, any Error>,
                            RPCWriter<RPCRequestPart<[UInt8]>>.Closable>) {
        let id = nextStreamID.wrappingAdd(1, ordering: .relaxed).oldValue
        let (channel, inbound) = StreamChannel<RPCResponsePart<[UInt8]>>.clientInbound(streamID: id)
        registry.withLock { $0.clientChannels[id] = channel }
        let outbound = RPCWriter.Closable(wrapping: XPCOutboundWriter<RPCRequestPart<[UInt8]>>(
            streamID: id, connection: self))
        return (id, RPCStream(descriptor: descriptor, inbound: inbound, outbound: outbound))
    }

    /// Server builds its side of an already-accepted stream (its `StreamID` came from an
    /// `.openStream` frame delivered on ``acceptedStreams``). Hands back the same channel/inbound
    /// pair `route`'s `.openStream` arm already registered -- see Critical-1 -- rather than
    /// creating a fresh one, so frames that arrived in the meantime are not lost.
    func registerServerStream(_ id: StreamID, descriptor: MethodDescriptor)
    -> RPCStream<RPCAsyncSequence<RPCRequestPart<[UInt8]>, any Error>,
                 RPCWriter<RPCResponsePart<[UInt8]>>.Closable> {
        let inbound: RPCAsyncSequence<RPCRequestPart<[UInt8]>, any Error> = registry.withLock { reg in
            if let pending = reg.pendingServerInbound.removeValue(forKey: id) {
                return pending
            }
            // No `.openStream` frame registered `id` first -- this id didn't come from
            // `acceptedStreams` (a caller error). Register fresh so the call still returns a
            // usable (if immediately empty) stream rather than crashing.
            let (channel, inbound) = StreamChannel<RPCRequestPart<[UInt8]>>.serverInbound(streamID: id)
            reg.serverChannels[id] = channel
            return inbound
        }
        let outbound = RPCWriter.Closable(wrapping: XPCOutboundWriter<RPCResponsePart<[UInt8]>>(
            streamID: id, connection: self))
        return RPCStream(descriptor: descriptor, inbound: inbound, outbound: outbound)
    }

    private func failStream(_ id: StreamID, _ error: any Error) {
        registry.withLock { reg in
            reg.clientChannels[id]?.failInbound(error); reg.clientChannels[id] = nil
            reg.serverChannels[id]?.failInbound(error); reg.serverChannels[id] = nil
            reg.pendingServerInbound[id] = nil
        }
    }

    /// On peer death / shutdown: fails every live stream's inbound sequence and finishes
    /// ``acceptedStreams``. Wired to the session's cancellation handler in `init` (peer death);
    /// `deinit` separately finishes the accepted-streams continuation (see there) since by then
    /// there may be no error to report and no streams left to fail.
    func failAll(_ error: any Error) {
        registry.withLock { reg in
            reg.clientChannels.values.forEach { $0.failInbound(error) }
            reg.serverChannels.values.forEach { $0.failInbound(error) }
            reg = Registry()
        }
        acceptedContinuation.finish()
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension XPCFrame {
    var streamID: StreamID {
        switch self {
        case .openStream(let id, _, _), .metadata(let id, _), .message(let id, _, _),
             .halfClose(let id), .status(let id, _, _, _), .cancel(let id, _), .credit(let id, _):
            return id
        case .goAway: return 0
        }
    }
}
