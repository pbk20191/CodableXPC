import Foundation
import GRPCCore
import Synchronization

/// One RPC's inbound side. Frames arrive (possibly interleaved with other streams' frames at the
/// connection); this delivers this stream's parts in order and enforces the gRPC part grammar:
///
/// - Requests (server inbound): `metadata* -> message* -> halfClose` -- `halfClose` finishes the
///   sequence without a status. A `status` frame on a request stream is a protocol violation.
/// - Responses (client inbound): `metadata* -> message* -> status` -- `status` is the single
///   terminator and finishes the sequence. A second terminal, or any frame after the terminal, is
///   a violation.
/// - `message` frames must carry consecutive `seq` values starting at 0, *per direction*; a gap
///   is a violation. Only `.message` frames consume a `seq` -- metadata/status/halfClose do not.
///
/// `openStream`/`cancel`/`credit`/`goAway` are connection-level frames; `accept` ignores them
/// (the connection handles them -- see Task 4).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class StreamChannel<Part: Sendable>: Sendable {
    /// `leading` accepts metadata; the first message frame moves the channel to `messages`,
    /// after which metadata is no longer legal. Either terminator moves to `terminated`.
    private enum Phase: Sendable { case leading, messages, terminated }
    private struct State: Sendable {
        var phase: Phase = .leading
        var nextSeq: UInt64 = 0
    }

    /// A frame's payload, translated to the direction-neutral shape the factory's `toPart`
    /// closure turns into this channel's concrete `Part`.
    enum Inbound: Sendable {
        case metadata(Metadata)
        case message([UInt8])
        case status(Status, Metadata)
    }

    let streamID: StreamID
    private let isServer: Bool
    private let state = Mutex(State())
    private let continuation: AsyncThrowingStream<Part, any Error>.Continuation
    private let toPart: @Sendable (Inbound) -> Part

    private init(
        streamID: StreamID,
        isServer: Bool,
        continuation: AsyncThrowingStream<Part, any Error>.Continuation,
        toPart: @escaping @Sendable (Inbound) -> Part
    ) {
        self.streamID = streamID
        self.isServer = isServer
        self.continuation = continuation
        self.toPart = toPart
    }

    /// Routes a frame into this stream's inbound sequence, enforcing the grammar above.
    /// Connection-level frames are ignored; everything else either yields a `Part` or throws.
    ///
    /// - Important: Callers must invoke `accept` serially per stream. Ordering validation (the
    ///   `seq`/phase checks) happens under `state`'s lock, but the yield to `continuation` happens
    ///   after the lock is released, so two concurrent `accept` calls for the *same* stream can
    ///   each validate correctly against the state as it was under their own lock acquisition, yet
    ///   still deliver their parts to the sequence in the wrong relative order if one thread is
    ///   descheduled between releasing the lock and calling `continuation.yield`. Serial calls
    ///   (e.g. one connection-level dispatch loop per stream) are required to avoid this.
    func accept(_ frame: XPCFrame) throws {
        switch frame {
        case .metadata(_, let wireMetadata):
            try state.withLock { state in
                guard state.phase == .leading else { throw violation() }
            }
            continuation.yield(toPart(.metadata(wireMetadata.asMetadata())))

        case .message(_, let seq, let bytes):
            let payload = try GRPCMessageFraming.unframe(bytes)
            try state.withLock { state in
                guard state.phase != .terminated else { throw violation() }
                guard seq == state.nextSeq else { throw violation() }
                state.nextSeq += 1
                state.phase = .messages
            }
            continuation.yield(toPart(.message(payload)))

        case .halfClose:
            // Ends the *request* direction only; a response stream never sees halfClose.
            guard isServer else { throw violation() }
            try state.withLock { state in
                guard state.phase != .terminated else { throw violation() }
                state.phase = .terminated
            }
            continuation.finish()

        case .status(_, let code, let message, let trailers):
            // Ends the *response* direction only; a request stream never sees status.
            guard !isServer else { throw violation() }
            try state.withLock { state in
                guard state.phase != .terminated else { throw violation() }
                state.phase = .terminated
            }
            let status = Status(code: Status.Code(rawValue: code) ?? .unknown, message: message)
            continuation.yield(toPart(.status(status, trailers.asMetadata())))
            continuation.finish()

        case .openStream, .cancel, .credit, .goAway:
            break   // connection-level frames; the connection (Task 4) handles these, not the channel
        }
    }

    /// Fails the inbound sequence out-of-band -- used on cancellation or peer death, where there
    /// is no frame to route through `accept`.
    func failInbound(_ error: any Error) {
        state.withLock { $0.phase = .terminated }
        continuation.finish(throwing: error)
    }

    private func violation() -> any Error {
        RPCError(code: .internalError, message: "stream \(streamID): out-of-order or post-terminal frame")
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension StreamChannel {
    /// A server's inbound view of an RPC: the request parts the peer sends.
    static func serverInbound(streamID: StreamID)
        -> (StreamChannel<RPCRequestPart<[UInt8]>>, RPCAsyncSequence<RPCRequestPart<[UInt8]>, any Error>)
        where Part == RPCRequestPart<[UInt8]>
    {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RPCRequestPart<[UInt8]>.self)
        let channel = StreamChannel<RPCRequestPart<[UInt8]>>(
            streamID: streamID, isServer: true, continuation: continuation
        ) { event in
            switch event {
            case .metadata(let metadata): .metadata(metadata)
            case .message(let bytes): .message(bytes)
            case .status: fatalError("request streams carry no status part")
            }
        }
        return (channel, RPCAsyncSequence(wrapping: stream))
    }

    /// A client's inbound view of an RPC: the response parts the peer sends.
    static func clientInbound(streamID: StreamID)
        -> (StreamChannel<RPCResponsePart<[UInt8]>>, RPCAsyncSequence<RPCResponsePart<[UInt8]>, any Error>)
        where Part == RPCResponsePart<[UInt8]>
    {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RPCResponsePart<[UInt8]>.self)
        let channel = StreamChannel<RPCResponsePart<[UInt8]>>(
            streamID: streamID, isServer: false, continuation: continuation
        ) { event in
            switch event {
            case .metadata(let metadata): .metadata(metadata)
            case .message(let bytes): .message(bytes)
            case .status(let status, let trailers): .status(status, trailers)
            }
        }
        return (channel, RPCAsyncSequence(wrapping: stream))
    }
}
