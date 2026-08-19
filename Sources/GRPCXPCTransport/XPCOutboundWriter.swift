import Foundation
import GRPCCore
import Synchronization

/// A weak, `Sendable` box around the connection a writer sends through.
///
/// A writer must **never** own its `XPCConnection`, because the connection can transitively own
/// the writer: `XPCConnection.route`'s `.openStream` arm builds the whole server-side `RPCStream`
/// (outbound writer included) and yields it on `acceptedStreams`, whose continuation buffers that
/// payload *inside the connection*. A strong `connection` here would close the loop
/// `XPCConnection -> acceptedContinuation buffer -> AcceptedStream -> RPCStream.outbound ->
/// XPCOutboundWriter -> XPCConnection`, so any accepted-but-not-yet-drained stream would make the
/// connection retain itself: `deinit` never runs, its `session.cancel(reason:)` never fires, and
/// the native `XPCSession` leaks for the process's lifetime. Weak here is what keeps that
/// `deinit` reachable (pinned by
/// `XPCConnectionTests.testConnectionDeinitsWithAnAcceptedStreamBufferedButNeverDrained`).
///
/// A `Mutex`-wrapped struct rather than a bare `weak var` stored property because
/// `ClosableRPCWriterProtocol: RPCWriterProtocol: Sendable`, and a `Sendable` class may not have
/// mutable stored properties -- which a `weak var` necessarily is.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private struct WeakConnection: Sendable {
    weak var connection: XPCConnection?
}

/// Bridges a gRPC outbound `RPCWriter` to `XPCConnection.send`. `write` does not yet suspend for
/// credit (unbounded); Task 9 adds reply-as-credit backpressure.
///
/// Holds its connection **weakly** -- see ``WeakConnection`` for why that is load-bearing rather
/// than a micro-optimisation. Once the connection is gone, `write` fails deterministically with
/// `RPCError(code: .unavailable)`; it never crashes and never reports a send that did not happen.
///
/// A `final class`, not a struct: the per-writer `seq` counter needs `Synchronization.Atomic`,
/// which is `~Copyable` and so cannot live in a struct that `RPCWriter.Closable(wrapping:)` boxes
/// into an `any ClosableRPCWriterProtocol<Element>` existential -- existentials require the
/// wrapped type be `Copyable`. A class is a reference type (its own identity is already
/// `Copyable` via the reference), so `Atomic` can live in it directly.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class XPCOutboundWriter<Part: Sendable>: ClosableRPCWriterProtocol {
    typealias Element = Part

    let streamID: StreamID
    private let weakConnection: Mutex<WeakConnection>

    /// Per-writer message sequence. Only `.message` parts consume one -- mirrors
    /// `StreamChannel`'s seq guard, which advances only on `.message` (metadata/status/halfClose
    /// carry no seq). Bumping this on every `write` (metadata included, as an earlier sketch did)
    /// would desynchronize it from that guard.
    private let seq = Atomic<UInt64>(0)

    init(streamID: StreamID, connection: XPCConnection) {
        self.streamID = streamID
        self.weakConnection = Mutex(WeakConnection(connection: connection))
    }

    /// The connection, or `nil` if it has been deinitialized. Deliberately returns the strong
    /// reference *out* of the lock so no `send` (which reaches into libxpc) ever runs under it.
    private var connection: XPCConnection? {
        weakConnection.withLock { $0.connection }
    }

    /// Thrown by `write` once the connection is gone: an outbound part that provably never
    /// reached the wire must surface as an error, not as a silent success.
    private func connectionGone() -> RPCError {
        RPCError(code: .unavailable,
                 message: "stream \(streamID): the XPC connection is no longer available")
    }

    func write(_ element: Part) async throws {
        guard let connection else { throw connectionGone() }
        try connection.send(frame(for: element))
    }

    func write(contentsOf elements: some Sequence<Part>) async throws {
        for element in elements { try await write(element) }
    }

    func finish() async {
        // Only the *request* direction's grammar has a `halfClose` terminator (see
        // StreamChannel.accept: `.halfClose` guards `isServer`, i.e. is legal only on a
        // server-inbound/request channel). The *response* direction's terminal is the `.status`
        // part already sent through `write(_:)`; sending `halfClose` there would violate the
        // grammar on the peer's inbound channel.
        //
        // `finish` cannot throw (the protocol's signature is non-throwing), so a gone connection
        // is a no-op here rather than an error: there is no peer left to inform of a half-close,
        // and no caller to report it to. `write` above is where a lost connection is surfaced.
        if Part.self == RPCRequestPart<[UInt8]>.self {
            try? connection?.send(.halfClose(streamID))
        }
    }

    func finish(throwing error: any Error) async {
        try? connection?.send(.cancel(streamID, reason: "\(error)"))
    }

    private func frame(for element: Part) -> XPCFrame {
        switch element {
        case let req as RPCRequestPart<[UInt8]>:
            switch req {
            case .metadata(let m):
                return .metadata(streamID, WireMetadata(m))
            case .message(let b):
                let s = seq.wrappingAdd(1, ordering: .relaxed).oldValue
                return .message(streamID, seq: s, bytes: GRPCMessageFraming.frame(b))
            }
        case let resp as RPCResponsePart<[UInt8]>:
            switch resp {
            case .metadata(let m):
                return .metadata(streamID, WireMetadata(m))
            case .message(let b):
                let s = seq.wrappingAdd(1, ordering: .relaxed).oldValue
                return .message(streamID, seq: s, bytes: GRPCMessageFraming.frame(b))
            case .status(let status, let trailers):
                return .status(streamID, code: status.code.rawValue, message: status.message,
                                trailers: WireMetadata(trailers))
            }
        default:
            fatalError("XPCOutboundWriter: unsupported Part type \(type(of: element))")
        }
    }
}
