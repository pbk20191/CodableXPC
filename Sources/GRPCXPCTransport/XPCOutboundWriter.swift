import Foundation
import GRPCCore
import Synchronization

/// Bridges a gRPC outbound `RPCWriter` to `XPCConnection.send`. `write` does not yet suspend for
/// credit (unbounded); Task 9 adds reply-as-credit backpressure.
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
    let connection: XPCConnection

    /// Per-writer message sequence. Only `.message` parts consume one -- mirrors
    /// `StreamChannel`'s seq guard, which advances only on `.message` (metadata/status/halfClose
    /// carry no seq). Bumping this on every `write` (metadata included, as an earlier sketch did)
    /// would desynchronize it from that guard.
    private let seq = Atomic<UInt64>(0)

    init(streamID: StreamID, connection: XPCConnection) {
        self.streamID = streamID
        self.connection = connection
    }

    func write(_ element: Part) async throws {
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
        if Part.self == RPCRequestPart<[UInt8]>.self {
            try? connection.send(.halfClose(streamID))
        }
    }

    func finish(throwing error: any Error) async {
        try? connection.send(.cancel(streamID, reason: "\(error)"))
    }

    private func frame(for element: Part) -> XPCFrame {
        switch element {
        case let req as RPCRequestPart<[UInt8]>:
            switch req {
            case .metadata(let m):
                return .metadata(streamID, WireMetadata(m))
            case .message(let b):
                let s = seq.wrappingAdd(1, ordering: .relaxed).oldValue
                return .message(streamID, seq: s, bytes: Data(b))
            }
        case let resp as RPCResponsePart<[UInt8]>:
            switch resp {
            case .metadata(let m):
                return .metadata(streamID, WireMetadata(m))
            case .message(let b):
                let s = seq.wrappingAdd(1, ordering: .relaxed).oldValue
                return .message(streamID, seq: s, bytes: Data(b))
            case .status(let status, let trailers):
                return .status(streamID, code: status.code.rawValue, message: status.message,
                                trailers: WireMetadata(trailers))
            }
        default:
            fatalError("XPCOutboundWriter: unsupported Part type \(type(of: element))")
        }
    }
}
