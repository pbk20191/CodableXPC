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

    private struct Registry: Sendable {
        var clientChannels: [StreamID: StreamChannel<RPCResponsePart<[UInt8]>>] = [:]
        var serverChannels: [StreamID: StreamChannel<RPCRequestPart<[UInt8]>>] = [:]
    }
    private let registry = Mutex(Registry())

    private let acceptedContinuation: AsyncStream<(StreamID, MethodDescriptor)>.Continuation
    let acceptedStreams: AsyncStream<(StreamID, MethodDescriptor)>

    /// Wraps `session`.
    ///
    /// - For `.client`: `session` must be inactive (freshly dialled). This installs the
    ///   incoming-message handler and target queue but does **not** activate it -- call
    ///   ``activate()`` before use.
    /// - For `.server`: `session` is an already-live session handed back by
    ///   `XPCListener.IncomingSessionRequest.accept`. This still (re-)installs the handler and
    ///   target queue -- which is safe to call on a live session -- but the session must never be
    ///   passed to ``activate()``.
    init(session: XPCSession, role: Role, queue: DispatchSerialQueue) {
        self.session = session
        self.role = role
        self.queue = queue
        (acceptedStreams, acceptedContinuation) = AsyncStream.makeStream()
        session.setIncomingMessageHandler { [weak self] (message: XPCDictionary) -> XPCDictionary? in
            self?.handleInbound(message)
            return nil
        }
        session.setTargetQueue(queue)
    }

    /// Activates the underlying session. The *client* side calls this after construction -- the
    /// harness today, `XPCClientTransport.connect()` in Task 5. An accepted (server) session
    /// handed back from `IncomingSessionRequest.accept` is already live and must **not** be
    /// activated again.
    func activate() throws {
        try session.activate()
    }

    /// libxpc traps (`_xpc_api_misuse`, `EXC_BREAKPOINT`) if an `XPCSession` is released without
    /// ever being cancelled, whether or not it was ever activated -- so every `XPCConnection`
    /// must cancel its session on the way out. Full graceful-shutdown sequencing (draining,
    /// `.goAway`) is Task 9/10's job; this is just the RAII teardown of the native resource.
    deinit {
        session.cancel(reason: "XPCConnection deinitialized")
    }

    /// Serializes `frame` and sends it one-way over the session. (Credit-bearing sends with a
    /// reply arrive in Task 9.)
    func send(_ frame: XPCFrame) throws {
        let object = try frame.encodeToXPC()
        try session.send(message: XPCDictionary(object))
    }

    private func handleInbound(_ message: XPCDictionary) {
        guard let frame = try? message.withUnsafeUnderlyingDictionary({ try XPCFrame.decode(from: $0) })
        else { return }
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
                if let c = reg.clientChannels[id] { try? c.accept(frame) }
                else if let s = reg.serverChannels[id] { try? s.accept(frame) }
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
    /// `.openStream` frame delivered on ``acceptedStreams``).
    func registerServerStream(_ id: StreamID, descriptor: MethodDescriptor)
    -> RPCStream<RPCAsyncSequence<RPCRequestPart<[UInt8]>, any Error>,
                 RPCWriter<RPCResponsePart<[UInt8]>>.Closable> {
        let (channel, inbound) = StreamChannel<RPCRequestPart<[UInt8]>>.serverInbound(streamID: id)
        registry.withLock { $0.serverChannels[id] = channel }
        let outbound = RPCWriter.Closable(wrapping: XPCOutboundWriter<RPCResponsePart<[UInt8]>>(
            streamID: id, connection: self))
        return RPCStream(descriptor: descriptor, inbound: inbound, outbound: outbound)
    }

    private func failStream(_ id: StreamID, _ error: any Error) {
        registry.withLock { reg in
            reg.clientChannels[id]?.failInbound(error); reg.clientChannels[id] = nil
            reg.serverChannels[id]?.failInbound(error); reg.serverChannels[id] = nil
        }
    }

    /// On peer death / shutdown: fails every live stream's inbound sequence and finishes
    /// ``acceptedStreams``.
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
