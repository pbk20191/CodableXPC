import Foundation
import GRPCCore

/// The compact wire encoding (§O3): the only `WireCodec` conformer. One XPC message carries one
/// blob; a blob carries one or more encoded ops, concatenated back-to-back. Every op is a 10-byte
/// header followed by its body:
///
/// ```
/// +--------+--------+--------------------+---------------------+
/// | kind   | flags  | streamID (4 BE)    | body length (4 BE)  |  10-byte header
/// +--------+--------+--------------------+---------------------+
/// | body …                                                     |
/// +------------------------------------------------------------+
/// ```
///
/// `flags` is reserved: this codec always writes 0 and ignores whatever it reads. An unknown
/// `kind` is **skipped** -- `bodyLength` is exactly what lets a reader advance past an op it does
/// not understand without decoding its body -- which is what lets the encoding grow without
/// breaking an older peer.
///
/// **No LPM framing.** Unlike HTTP/2's DATA frames, an op already delimits one whole message, so
/// a `message` op's body is the raw message bytes with no length-prefixed-message envelope. See
/// `RPCOp`'s doc comment for the full rationale; do not add one here "for standardness".
///
/// **Every length is peer-controlled input.** Each is checked against the bytes actually
/// remaining *before* it is used to slice, and every offset is derived from the buffer's own
/// `startIndex` -- `GRPCSwiftData` indices do not rebase to zero, and in production this codec's
/// input is always a slice of a received XPC payload, never a fresh buffer starting at 0.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct CompactWireCodec: WireCodec {

    init() {}

    // =======================================================================================
    // MARK: - Wire constants
    // =======================================================================================

    /// kind(1) + flags(1) + streamID(4) + bodyLength(4).
    private static let headerLength = 10

    /// §O3: "a single op body above 16 MiB is rejected as a protocol error (a bound on
    /// peer-controlled allocation, not a protocol feature)". Enforced on both encode (so this
    /// codec never produces a blob its own decoder -- or a wire-compatible peer's -- would then
    /// reject) and decode (where the length comes from the peer and must be checked before it is
    /// ever used to size an allocation or a slice).
    static let maxBodyLength = 16 * 1024 * 1024

    private static let grpcStatusFieldName = "grpc-status"
    private static let grpcMessageFieldName = "grpc-message"

    private enum Kind: UInt8 {
        case openStream = 1
        case metadata = 2
        case message = 3
        case halfClose = 4
        case status = 5
        case cancel = 6
        case credit = 7
        case goAway = 8
    }

    // =======================================================================================
    // MARK: - WireCodec
    // =======================================================================================

    func encode(_ ops: [RPCOp]) throws -> GRPCSwiftData {
        var out = Data()
        for op in ops {
            try Self.encodeOne(op, into: &out)
        }
        return GRPCSwiftData(viewing: out)
    }

    func decode(_ blob: GRPCSwiftData) throws -> [RPCOp] {
        let data = blob.data
        let end = data.endIndex
        var cursor = data.startIndex
        var ops: [RPCOp] = []

        while cursor < end {
            guard end - cursor >= Self.headerLength else {
                throw RPCError(
                    code: .internalError,
                    message: "op header truncated: \(end - cursor) byte(s) remain, need \(Self.headerLength)")
            }

            let kindRaw = data[cursor]
            // data[cursor + 1] is flags: reserved, ignored on receive.
            let streamID = Self.readUInt32BE(data, at: cursor + 2)
            let bodyLength = Int(Self.readUInt32BE(data, at: cursor + 6))

            guard bodyLength <= Self.maxBodyLength else {
                throw RPCError(
                    code: .internalError,
                    message: "op (kind \(kindRaw), stream \(streamID)) declares a \(bodyLength)-byte "
                        + "body, exceeding the \(Self.maxBodyLength)-byte (16 MiB) maximum")
            }

            let bodyStart = cursor + Self.headerLength
            guard end - bodyStart >= bodyLength else {
                throw RPCError(
                    code: .internalError,
                    message: "op (kind \(kindRaw), stream \(streamID)) declares a \(bodyLength)-byte "
                        + "body but only \(end - bodyStart) byte(s) remain")
            }
            let bodyEnd = bodyStart + bodyLength
            cursor = bodyEnd

            guard let kind = Kind(rawValue: kindRaw) else {
                // Unknown kind: skip and discard, per §O3 -- this is what lets the encoding grow
                // without breaking a peer that doesn't understand this kind yet.
                continue
            }

            let body = GRPCSwiftData(viewing: data[bodyStart..<bodyEnd])
            ops.append(try Self.decodeOne(kind: kind, streamID: streamID, body: body))
        }

        return ops
    }

    // =======================================================================================
    // MARK: - Per-op encode
    // =======================================================================================

    private static func encodeOne(_ op: RPCOp, into out: inout Data) throws {
        switch op {
        case .openStream(let streamID, let method, let timeout):
            // §O3: "openStream: field list ... containing :path and, if set, grpc-timeout --
            // built by GRPCWireHeaders.request(...)". The op carries no user metadata of its own
            // (that arrives as a separate `metadata` op per §O2's grammar), so `metadata` here is
            // deliberately empty.
            let fields = GRPCWireHeaders.request(path: "/" + method, timeout: timeout, metadata: Metadata())
            let body = try encodeFieldList(fields)
            try appendHeader(kind: .openStream, streamID: streamID, bodyLength: body.count, to: &out)
            out.append(body)

        case .metadata(let streamID, let fields):
            let body = try encodeFieldList(fields)
            try appendHeader(kind: .metadata, streamID: streamID, bodyLength: body.count, to: &out)
            out.append(body)

        case .message(let streamID, let payload):
            // No LPM prefix: the op's body length header is the only framing a `message` op
            // needs, since the op itself already delimits one whole message.
            try appendHeader(kind: .message, streamID: streamID, bodyLength: payload.count, to: &out)
            out.append(payload.data)

        case .halfClose(let streamID):
            try appendHeader(kind: .halfClose, streamID: streamID, bodyLength: 0, to: &out)

        case .status(let streamID, let code, let message, let trailers):
            // §O3: "status: ... the list includes grpc-status and, when non-empty, grpc-message,
            // per GRPCWireHeaders.trailers(...)". The op already carries `code`/`message` split
            // out from `trailers`, so this reassembles the same field-list shape
            // `GRPCWireHeaders.trailers(status:metadata:)` produces without round-tripping
            // through `Status`/`Metadata` -- `percentEncode` is `GRPCWireHeaders`'s own, reused
            // rather than reimplemented.
            var fields: [HTTPField] = [(grpcStatusFieldName, String(code))]
            if !message.isEmpty {
                fields.append((grpcMessageFieldName, GRPCWireHeaders.percentEncode(message)))
            }
            fields.append(contentsOf: trailers)
            let body = try encodeFieldList(fields)
            try appendHeader(kind: .status, streamID: streamID, bodyLength: body.count, to: &out)
            out.append(body)

        case .cancel(let streamID, let reason):
            let body = Data(reason.utf8)
            try appendHeader(kind: .cancel, streamID: streamID, bodyLength: body.count, to: &out)
            out.append(body)

        case .credit(let streamID, let bytes):
            var body = Data()
            appendUInt32BE(bytes, to: &body)
            try appendHeader(kind: .credit, streamID: streamID, bodyLength: body.count, to: &out)
            out.append(body)

        case .goAway(let lastStreamID):
            // Connection-level: the header's streamID field is meaningless here, so it is
            // written as 0 (and ignored on decode); the real payload is the body.
            var body = Data()
            appendUInt32BE(lastStreamID, to: &body)
            try appendHeader(kind: .goAway, streamID: 0, bodyLength: body.count, to: &out)
            out.append(body)
        }
    }

    /// Writes the 10-byte op header. `flags` is always 0 (reserved; MUST be 0 on send, §O3).
    ///
    /// - Throws: `RPCError(code: .internalError)` if `bodyLength` exceeds the 16 MiB cap -- this
    ///   codec refuses to produce a blob its own `decode(_:)` would then reject.
    private static func appendHeader(kind: Kind, streamID: RPCStreamID, bodyLength: Int, to out: inout Data) throws {
        guard bodyLength <= maxBodyLength else {
            throw RPCError(
                code: .internalError,
                message: "\(kind) op (stream \(streamID)) body is \(bodyLength) byte(s), exceeding "
                    + "the \(maxBodyLength)-byte (16 MiB) maximum")
        }
        out.append(kind.rawValue)
        out.append(0)  // flags: reserved, MUST be 0 on send
        appendUInt32BE(streamID, to: &out)
        appendUInt32BE(UInt32(bodyLength), to: &out)
    }

    // =======================================================================================
    // MARK: - Per-op decode
    // =======================================================================================

    /// - Precondition: `body`'s declared length has already been validated against the bytes
    ///   remaining in the enclosing blob by `decode(_:)`'s caller; this only validates each
    ///   kind's own internal shape.
    private static func decodeOne(kind: Kind, streamID: RPCStreamID, body: GRPCSwiftData) throws -> RPCOp {
        switch kind {
        case .openStream:
            let fields = try decodeFieldList(body)
            let parsed = try GRPCWireHeaders.parseRequest(fields)
            // §O2: user metadata travels in its own `metadata` op, never inside `openStream`'s
            // field list -- and `RPCOp.openStream` has no field that could carry it onward even
            // if it did. A conforming peer never puts anything here, so anything `parseRequest`
            // recovered as metadata is either a bug or an attack smuggling up to 16 MiB of extra
            // field-list bytes into every call; both must be loud; a silent `continue` here would
            // destroy the only evidence that it happened.
            guard parsed.metadata.isEmpty else {
                let strayNames = parsed.metadata.map(\.key).joined(separator: ", ")
                throw RPCError(
                    code: .internalError,
                    message: "openStream op (stream \(streamID)) carries stray metadata field(s) "
                        + "outside the reserved set: \(strayNames); user metadata must arrive as "
                        + "a separate metadata op")
            }
            let method = parsed.path.hasPrefix("/") ? String(parsed.path.dropFirst()) : parsed.path
            return .openStream(streamID, method: method, timeout: parsed.timeout)

        case .metadata:
            let fields = try decodeFieldList(body)
            return .metadata(streamID, fields: fields)

        case .message:
            // Zero-copy: `body` already views the blob's own storage -- see `decode(_:)`.
            return .message(streamID, payload: body)

        case .halfClose:
            guard body.isEmpty else {
                throw RPCError(
                    code: .internalError,
                    message: "halfClose op (stream \(streamID)) declares a \(body.count)-byte body; must be empty")
            }
            return .halfClose(streamID)

        case .status:
            let fields = try decodeFieldList(body)
            var code: Int?
            var message = ""
            var trailers: [HTTPField] = []
            trailers.reserveCapacity(fields.count)
            var sawStatus = false
            var sawMessage = false
            for field in fields {
                let lowered = field.name.lowercased()
                if !sawStatus, lowered == grpcStatusFieldName {
                    guard let parsedCode = Int(field.value) else {
                        throw RPCError(
                            code: .internalError,
                            message: "status op (stream \(streamID)) has a malformed 'grpc-status' "
                                + "value: '\(field.value)'")
                    }
                    code = parsedCode
                    sawStatus = true
                    continue
                }
                if !sawMessage, lowered == grpcMessageFieldName {
                    message = GRPCWireHeaders.percentDecode(field.value)
                    sawMessage = true
                    continue
                }
                trailers.append(field)
            }
            guard let code else {
                throw RPCError(
                    code: .internalError,
                    message: "status op (stream \(streamID)) is missing a 'grpc-status' field")
            }
            return .status(streamID, code: code, message: message, trailers: trailers)

        case .cancel:
            guard let reason = String(bytes: body.data, encoding: .utf8) else {
                throw RPCError(
                    code: .internalError,
                    message: "cancel op (stream \(streamID)) reason is not valid UTF-8")
            }
            return .cancel(streamID, reason: reason)

        case .credit:
            guard body.count == 4 else {
                throw RPCError(
                    code: .internalError,
                    message: "credit op (stream \(streamID)) declares a \(body.count)-byte body; must be exactly 4")
            }
            let bytes = readUInt32BE(body.data, at: body.startIndex)
            return .credit(streamID, bytes: bytes)

        case .goAway:
            guard body.count == 4 else {
                throw RPCError(
                    code: .internalError,
                    message: "goAway op declares a \(body.count)-byte body; must be exactly 4")
            }
            let lastStreamID = readUInt32BE(body.data, at: body.startIndex)
            return .goAway(lastStreamID: lastStreamID)
        }
    }

    // =======================================================================================
    // MARK: - Field list (openStream / metadata / status bodies)
    // =======================================================================================

    /// §O3: "a 2-byte BE count, then per field a 2-byte BE name length, name UTF-8, 4-byte BE
    /// value length, value UTF-8." Names are already lowercased and reserved-name-filtered by
    /// `GRPCWireHeaders`, and `-bin` values are already base64 there -- this codec never
    /// interprets a field's value, only its length.
    private static func encodeFieldList(_ fields: [HTTPField]) throws -> Data {
        guard let count = UInt16(exactly: fields.count) else {
            throw RPCError(
                code: .internalError,
                message: "field list has \(fields.count) field(s), exceeding the 65535 maximum")
        }

        var out = Data()
        appendUInt16BE(count, to: &out)
        for field in fields {
            let nameBytes = Array(field.name.utf8)
            guard let nameLength = UInt16(exactly: nameBytes.count) else {
                throw RPCError(
                    code: .internalError,
                    message: "field name '\(field.name)' is \(nameBytes.count) byte(s), exceeding "
                        + "the 65535 maximum")
            }
            appendUInt16BE(nameLength, to: &out)
            out.append(contentsOf: nameBytes)

            let valueBytes = Array(field.value.utf8)
            guard let valueLength = UInt32(exactly: valueBytes.count) else {
                throw RPCError(
                    code: .internalError,
                    message: "field '\(field.name)' value is \(valueBytes.count) byte(s), exceeding "
                        + "the 4294967295 maximum")
            }
            appendUInt32BE(valueLength, to: &out)
            out.append(contentsOf: valueBytes)
        }
        return out
    }

    /// The inverse of `encodeFieldList`. `body` need not start at index 0 -- it is always a slice
    /// of the enclosing blob's own storage (see `decode(_:)`) -- so every offset here is derived
    /// from `body.startIndex`/`body.endIndex`, never a literal `0`.
    ///
    /// - Throws: `RPCError(code: .internalError)` for a truncated count/length/value, a declared
    ///   length exceeding the bytes remaining *in this field list*, a non-UTF-8 name or value, or
    ///   trailing bytes left over after the declared field count has been fully read.
    private static func decodeFieldList(_ body: GRPCSwiftData) throws -> [HTTPField] {
        let data = body.data
        let end = data.endIndex
        var cursor = data.startIndex

        guard end - cursor >= 2 else {
            throw RPCError(code: .internalError, message: "field list truncated: expected a 2-byte field count")
        }
        let count = Int(readUInt16BE(data, at: cursor))
        cursor += 2

        var fields: [HTTPField] = []
        fields.reserveCapacity(count)

        for _ in 0..<count {
            guard end - cursor >= 2 else {
                throw RPCError(code: .internalError, message: "field list truncated: expected a 2-byte name length")
            }
            let nameLength = Int(readUInt16BE(data, at: cursor))
            cursor += 2
            guard end - cursor >= nameLength else {
                throw RPCError(
                    code: .internalError,
                    message: "field list declares a \(nameLength)-byte name but only \(end - cursor) byte(s) remain")
            }
            let nameEnd = cursor + nameLength
            guard let name = String(bytes: data[cursor..<nameEnd], encoding: .utf8) else {
                throw RPCError(code: .internalError, message: "field list contains a non-UTF-8 field name")
            }
            cursor = nameEnd

            guard end - cursor >= 4 else {
                throw RPCError(code: .internalError, message: "field list truncated: expected a 4-byte value length")
            }
            let valueLength = Int(readUInt32BE(data, at: cursor))
            cursor += 4
            guard end - cursor >= valueLength else {
                throw RPCError(
                    code: .internalError,
                    message: "field list declares a \(valueLength)-byte value but only \(end - cursor) byte(s) remain")
            }
            let valueEnd = cursor + valueLength
            guard let value = String(bytes: data[cursor..<valueEnd], encoding: .utf8) else {
                throw RPCError(
                    code: .internalError, message: "field list contains a non-UTF-8 value for field '\(name)'")
            }
            cursor = valueEnd

            fields.append((name: name, value: value))
        }

        guard cursor == end else {
            throw RPCError(
                code: .internalError,
                message: "field list declares \(count) field(s) but \(end - cursor) trailing byte(s) remain")
        }

        return fields
    }

    // =======================================================================================
    // MARK: - Big-endian integer primitives
    // =======================================================================================

    private static func appendUInt16BE(_ value: UInt16, to out: inout Data) {
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32BE(_ value: UInt32, to out: inout Data) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    /// - Precondition: the caller has already checked `data.endIndex - index >= 2`.
    private static func readUInt16BE(_ data: Data, at index: Data.Index) -> UInt16 {
        (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }

    /// - Precondition: the caller has already checked `data.endIndex - index >= 4`.
    private static func readUInt32BE(_ data: Data, at index: Data.Index) -> UInt32 {
        (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }
}
