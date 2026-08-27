import Foundation
import GRPCCore

/// One HTTP/2 frame, per RFC 9113 §4.1:
///
///     Length (24) | Type (8) | Flags (8) | R (1) + Stream Identifier (31) | Frame Payload (0...)
///
/// This is genuine byte-level HTTP/2, not a custom protocol -- a `HTTP2Frame` encodes to the exact
/// nine-byte header any HTTP/2 implementation would recognize, followed by its payload verbatim.
/// `HTTP2FrameCodec` is the only thing that produces or consumes those bytes.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct HTTP2Frame: Equatable, Sendable {

    /// The frame header's flags octet. Only the two bits this transport's frame kinds actually use
    /// are named; RFC 9113 defines others per frame type (e.g. PADDED, PRIORITY, ACK) that this
    /// codec's `Kind` does not model. Those bits are neither an error nor silently dropped -- they
    /// round-trip through `rawValue` like any `OptionSet` bit this type doesn't name, exactly as
    /// RFC 9113 §4.1 requires ("flags that have no defined semantics for a particular frame type
    /// MUST be ignored, and MUST be left unset when sending").
    struct Flags: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        static let endStream  = Flags(rawValue: 0x1)
        static let endHeaders = Flags(rawValue: 0x4)
    }

    /// The frame types this transport speaks. RFC 9113 defines more (SETTINGS, PING, PRIORITY,
    /// PUSH_PROMISE, CONTINUATION, ...); any type byte that doesn't match a case here is, by
    /// construction, "unknown" to `HTTP2FrameCodec.decodeAll`, which discards it per RFC 9113
    /// §4.1's "implementations MUST ignore and discard any frame that has a type that is unknown."
    enum Kind: UInt8, Sendable {
        case data = 0x0
        case headers = 0x1
        case rstStream = 0x3
        case goAway = 0x7
        case windowUpdate = 0x8
    }

    var kind: Kind
    var flags: Flags
    /// 31-bit stream identifier; the reserved top bit is always 0 in a value this type holds.
    /// `HTTP2FrameCodec.decodeAll` masks it off whatever a peer sent, and `encode` masks it again
    /// before writing, so neither side depends on the other having already done so.
    var streamID: UInt32
    var payload: GRPCSwiftData
}

/// An HTTP/2 error code (RFC 9113 §7). This is a raw-value struct with static constants, not an
/// enum, because RFC 9113 §7 requires an unrecognized error code to be treated as though it were
/// INTERNAL_ERROR rather than rejected -- an enum could not represent a value outside its known
/// cases at all, let alone let a caller compare it against `.internalError` as a fallback.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct HTTP2ErrorCode: RawRepresentable, Equatable, Sendable {
    let rawValue: UInt32
    static let noError          = HTTP2ErrorCode(rawValue: 0x0)
    static let protocolError    = HTTP2ErrorCode(rawValue: 0x1)
    static let internalError    = HTTP2ErrorCode(rawValue: 0x2)
    static let flowControlError = HTTP2ErrorCode(rawValue: 0x3)
    static let cancel           = HTTP2ErrorCode(rawValue: 0x8)
    static let compressionError = HTTP2ErrorCode(rawValue: 0x9)
}

/// Encodes and decodes the binary HTTP/2 frame wire format (RFC 9113 §4.1). This is the bottom
/// layer of the new transport: everything above it deals in `HTTP2Frame` values, never in raw
/// bytes.
///
/// **Everything here works in `Data`, never `[UInt8]`** -- see ``GRPCMessageFraming`` for why:
/// materializing an array copies a payload that may otherwise be a no-copy view onto an
/// `xpc_data` buffer. `decodeAll`'s payload slices are views onto `blob`'s own storage, not copies.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum HTTP2FrameCodec {

    /// The frame header's Length field is 24 bits, but this transport additionally enforces the
    /// same default `SETTINGS_MAX_FRAME_SIZE` (2^14) every HTTP/2 implementation starts at
    /// (RFC 9113 §6.5.2) -- a peer would need an explicit SETTINGS exchange to raise it, which
    /// this transport does not offer, so the default is the permanent ceiling.
    static let maxFramePayload = 16_384

    private static let headerLength = 9

    /// Concatenate the wire bytes for `frames`, in order. Each frame's stream id has its reserved
    /// top bit masked to 0 regardless of what the caller put there.
    static func encode(_ frames: [HTTP2Frame]) -> GRPCSwiftData {
        var out = Data()
        for frame in frames {
            let length = frame.payload.count
            out.append(UInt8((length >> 16) & 0xFF))
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
            out.append(frame.kind.rawValue)
            out.append(frame.flags.rawValue)
            let streamID = frame.streamID & 0x7FFF_FFFF
            out.append(UInt8((streamID >> 24) & 0xFF))
            out.append(UInt8((streamID >> 16) & 0xFF))
            out.append(UInt8((streamID >> 8) & 0xFF))
            out.append(UInt8(streamID & 0xFF))
            out.append(frame.payload.data)
        }
        return GRPCSwiftData(viewing: out)
    }

    /// Parses a blob of zero or more COMPLETE frames.
    ///
    /// Frames of a type `HTTP2Frame.Kind` doesn't name are skipped and discarded, per RFC 9113
    /// §4.1 -- this is not an error path, it is what a conforming receiver is required to do with
    /// e.g. a PING or SETTINGS frame from a real HTTP/2 peer.
    ///
    /// Throws when: the blob ends mid-header or mid-payload (a truncated trailing frame); a known
    /// frame's declared length is invalid for its kind (RST_STREAM and WINDOW_UPDATE are always
    /// exactly 4 bytes); or the declared length exceeds `maxFramePayload`.
    static func decodeAll(_ blob: GRPCSwiftData) throws -> [HTTP2Frame] {
        let data = blob.data
        let end = data.endIndex
        var cursor = data.startIndex
        var frames: [HTTP2Frame] = []

        while cursor < end {
            guard end - cursor >= headerLength else {
                throw RPCError(
                    code: .internalError,
                    message: "HTTP/2 frame header truncated: \(end - cursor) byte(s) remain, "
                           + "need \(headerLength)")
            }

            let length = (Int(data[cursor]) << 16) | (Int(data[cursor + 1]) << 8) | Int(data[cursor + 2])
            let typeRaw = data[cursor + 3]
            let flagsRaw = data[cursor + 4]
            let streamID = ((UInt32(data[cursor + 5]) << 24) | (UInt32(data[cursor + 6]) << 16)
                          | (UInt32(data[cursor + 7]) << 8)  |  UInt32(data[cursor + 8])) & 0x7FFF_FFFF

            // Checked before the type is even looked up, and for unknown types too: a length
            // this large can't be trusted regardless of frame type (FRAME_SIZE_ERROR in RFC 9113
            // §4.2 is a type-independent connection error), so there is nothing to gain by
            // deferring this to a known-type frame only.
            guard length <= maxFramePayload else {
                throw RPCError(
                    code: .internalError,
                    message: "HTTP/2 frame declares a \(length)-byte payload, exceeding the "
                           + "\(maxFramePayload)-byte maximum")
            }

            let payloadStart = cursor + headerLength
            guard end - payloadStart >= length else {
                throw RPCError(
                    code: .internalError,
                    message: "HTTP/2 frame declares a \(length)-byte payload but only "
                           + "\(end - payloadStart) byte(s) remain")
            }
            let payloadEnd = payloadStart + length
            cursor = payloadEnd

            guard let kind = HTTP2Frame.Kind(rawValue: typeRaw) else {
                // Unknown frame type: ignore and discard (RFC 9113 §4.1), not an error.
                continue
            }

            if kind == .rstStream || kind == .windowUpdate {
                guard length == 4 else {
                    throw RPCError(
                        code: .internalError,
                        message: "HTTP/2 \(kind) frame must carry a 4-byte payload, got \(length)")
                }
            }

            let payload = GRPCSwiftData(viewing: data[payloadStart..<payloadEnd])
            frames.append(HTTP2Frame(kind: kind, flags: HTTP2Frame.Flags(rawValue: flagsRaw),
                                      streamID: streamID, payload: payload))
        }

        return frames
    }
}
