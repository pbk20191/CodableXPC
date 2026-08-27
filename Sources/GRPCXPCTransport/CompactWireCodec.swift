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

    /// §O2 (as amended): a body-level rejection never takes the rest of the blob with it. Each
    /// op's 10-byte header -- including its stream id -- is parsed before its body ever is, so a
    /// body this codec rejects still yields an item naming that stream, and decoding resumes at
    /// the next op using the same `bodyLength`-derived `cursor` advance this method already uses
    /// to step over a `kind` it doesn't recognise. See `WireDecodeItem`'s doc for why this is
    /// skip-and-continue rather than stop-at-first-failure or a separate failures array, and for
    /// why `openStream` gets its own `.streamOpenFailure` case instead of sharing `.streamFailure`.
    ///
    /// **What crosses this seam is not `kind`, it is blast radius.** Three outcomes, one per
    /// rejection: `throw` means connection (the header-level guards below, and `goAway`'s
    /// carve-out); `.streamOpenFailure` means answer (`openStream` only -- see
    /// `WireDecodeItem.streamOpenFailure`'s doc); `.streamFailure` means fail-or-drop (every other
    /// kind, decided by whether the id has a table entry, at the core, not here). That vocabulary
    /// is deliberately encoding-independent -- `WireDecodeItem` says nothing about `kind` at all --
    /// so the core still owns *how* each radius actually executes (which op to send, whether a
    /// table entry exists) while this switch owns only *which radius applies*. Moving that
    /// decision to the core instead would mean exporting `Kind`, a type this codec should be free
    /// to redefine, or keeping a second enum in the core in sync with this one by hand -- the
    /// classic two-places-that-must-agree-forever shape this codebase avoids elsewhere (see
    /// `FlowControl.charge(for:)`'s "one definition" argument for the same principle applied to a
    /// different pair of call sites).
    ///
    /// **`goAway` is the one kind whose body failure still `throw`s**, and deliberately so:
    /// `goAway` is already a connection-scoped signal (§O1: "no new streams above `lastStreamID`"),
    /// not a per-stream one, and this codec writes its header's `streamID` as 0 on encode --
    /// meaningless, not a real stream id (see `encodeOne`) -- so there is no stream to attribute a
    /// failure to. Manufacturing `.streamFailure(0, …)` anyway would force the core to special-case
    /// id 0 as "fail the connection," and `0` is never a legal client-allocated stream id (§O1:
    /// odd, non-zero) -- so that special case would be indistinguishable at the core from a
    /// hostile peer forging streamID 0 onto some *other* kind's malformed body, which must NOT be
    /// connection-fatal (that forgery is exactly the amplification this task closes). Throwing
    /// here keeps that special case out of the core entirely. The cost -- losing whatever this
    /// call already decoded from the same blob -- is bounded and one-time: `failConnection` (this
    /// error's eventual destination) fails every live stream in the same synchronous call
    /// regardless of whether they got one more op processed first, so nothing decoded from this
    /// blob would have survived past that call either way. A hostile peer gains no leverage over
    /// any *other* blob or connection by corrupting a `goAway`'s body, only over the one
    /// connection it was already entitled to end.
    func decode(_ blob: GRPCSwiftData) throws -> [WireDecodeItem] {
        let data = blob.data
        let end = data.endIndex
        var cursor = data.startIndex
        var items: [WireDecodeItem] = []

        while cursor < end {
            guard end - cursor >= Self.headerLength else {
                throw RPCError(
                    code: .internalError,
                    message: "op header truncated: \(end - cursor) byte(s) remain, need \(Self.headerLength)")
            }

            let kindRaw = data[cursor]
            // data[cursor + 1] is flags: reserved, ignored on receive.
            let streamID = Self.readBE(data, at: cursor + 2, as: UInt32.self)
            let bodyLength = Int(Self.readBE(data, at: cursor + 6, as: UInt32.self))

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
            do {
                items.append(.op(try Self.decodeOne(kind: kind, streamID: streamID, body: body)))
            } catch let error as RPCError {
                // This switch is the policy seam: it assigns one of the three blast radii a body
                // rejection can have. Spelled out case by case, deliberately not `default:` --
                // §O3 anticipates the encoding growing new kinds, and a `default:` here would let
                // a ninth `Kind` silently inherit "fail that stream" with no compiler prompt at
                // exactly the place this decision has to be made. `message` never actually throws
                // (its body is taken verbatim), but it is listed anyway so this stays exhaustive
                // by construction rather than by the switch happening not to notice.
                switch kind {
                case .goAway:
                    // See this method's doc: goAway has no stream to fail, so its body rejection
                    // stays connection-fatal instead of becoming an item.
                    throw error
                case .openStream:
                    // §O2's carve-out: `openStream` is the one kind whose semantics create state,
                    // so a rejection must be answered on the wire, not silently dropped like every
                    // other kind's -- see `WireDecodeItem.streamOpenFailure`'s doc.
                    items.append(.streamOpenFailure(streamID, error))
                case .metadata, .message, .halfClose, .status, .cancel, .credit:
                    items.append(.streamFailure(streamID, error))
                }
            } catch {
                // Every throw site in `decodeOne` (and everything it calls: `decodeFieldList`,
                // `GRPCWireHeaders.parseRequest`) constructs `RPCError`, so this is unreachable in
                // practice. If it is ever reached, it is a codec bug, not peer input, and deserves
                // the loud connection-fatal treatment a header failure gets rather than being
                // silently folded into a `.streamFailure` that would misrepresent it as an
                // ordinary per-stream rejection.
                throw error
            }
        }

        return items
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
            appendBE(bytes, to: &body)
            try appendHeader(kind: .credit, streamID: streamID, bodyLength: body.count, to: &out)
            out.append(body)

        case .goAway(let lastStreamID):
            // Connection-level: the header's streamID field is meaningless here, so it is
            // written as 0 (and ignored on decode); the real payload is the body.
            var body = Data()
            appendBE(lastStreamID, to: &body)
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
        appendBE(streamID, to: &out)
        appendBE(UInt32(bodyLength), to: &out)
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
            let bytes = readBE(body.data, at: body.startIndex, as: UInt32.self)
            return .credit(streamID, bytes: bytes)

        case .goAway:
            guard body.count == 4 else {
                throw RPCError(
                    code: .internalError,
                    message: "goAway op declares a \(body.count)-byte body; must be exactly 4")
            }
            let lastStreamID = readBE(body.data, at: body.startIndex, as: UInt32.self)
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
        appendBE(count, to: &out)
        for field in fields {
            let nameBytes = Array(field.name.utf8)
            guard let nameLength = UInt16(exactly: nameBytes.count) else {
                throw RPCError(
                    code: .internalError,
                    message: "field name '\(field.name)' is \(nameBytes.count) byte(s), exceeding "
                        + "the 65535 maximum")
            }
            appendBE(nameLength, to: &out)
            out.append(contentsOf: nameBytes)

            let valueBytes = Array(field.value.utf8)
            guard let valueLength = UInt32(exactly: valueBytes.count) else {
                throw RPCError(
                    code: .internalError,
                    message: "field '\(field.name)' value is \(valueBytes.count) byte(s), exceeding "
                        + "the 4294967295 maximum")
            }
            appendBE(valueLength, to: &out)
            out.append(contentsOf: valueBytes)
        }
        return out
    }

    /// The inverse of `encodeFieldList`. `body` need not start at index 0 -- it is always a slice
    /// of the enclosing blob's own storage (see `decode(_:)`) -- so every offset here is derived
    /// from `body.startIndex`/`body.endIndex`, never a literal `0`.
    ///
    /// - Throws: `RPCError(code: .internalError)` for a truncated count/length/value, a declared
    ///   field count this field list cannot possibly hold, a declared length exceeding the bytes
    ///   remaining *in this field list*, a non-UTF-8 name or value, or trailing bytes left over
    ///   after the declared field count has been fully read.
    private static func decodeFieldList(_ body: GRPCSwiftData) throws -> [HTTPField] {
        /// The smallest an encoded field can be: a 2-byte name length, a 0-byte name, a 4-byte
        /// value length, a 0-byte value.
        let minimumEncodedFieldLength = 6

        let data = body.data
        let end = data.endIndex
        var cursor = data.startIndex

        guard end - cursor >= 2 else {
            throw RPCError(code: .internalError, message: "field list truncated: expected a 2-byte field count")
        }
        let count = Int(readBE(data, at: cursor, as: UInt16.self))
        cursor += 2

        // §O2's skip-and-continue turned a single-shot allocation lever into a per-op one: before
        // this guard, a 12-byte `metadata` op (10-byte header, 2-byte body `count = 0xFFFF`) made
        // `reserveCapacity` reserve ~2 MiB and then throw on field 1 -- once, when a bad blob was
        // connection-fatal, but now once *per such op in the blob*, since decoding resumes after
        // each rejection. A ~1 MiB blob packs ~87 000 of these 12-byte ops, so the same allocate/
        // free churn that used to cost one blob now repeats per op: cheap and legitimate to reject
        // here, not a heuristic -- `count` fields need at least `6 * count` bytes (the smallest
        // possible field is 6 bytes; see `minimumEncodedFieldLength`), so a declared `count` this
        // field list cannot possibly hold is already malformed, and rejecting it before
        // `reserveCapacity` ever runs is exact, not approximate: a genuine 65 535-field list needs
        // ≥ 393 210 bytes, comfortably inside the 16 MiB body cap.
        guard end - cursor >= count * minimumEncodedFieldLength else {
            throw RPCError(
                code: .internalError,
                message: "field list declares \(count) field(s), which would need at least "
                    + "\(count * minimumEncodedFieldLength) byte(s), but only \(end - cursor) byte(s) remain")
        }

        var fields: [HTTPField] = []
        fields.reserveCapacity(count)

        for _ in 0..<count {
            guard end - cursor >= 2 else {
                throw RPCError(code: .internalError, message: "field list truncated: expected a 2-byte name length")
            }
            let nameLength = Int(readBE(data, at: cursor, as: UInt16.self))
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
            let valueLength = Int(readBE(data, at: cursor, as: UInt32.self))
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

    /// Appends `value` in network byte order. `bigEndian` does the swap, so the only thing left
    /// is to copy the storage out -- no per-byte shift-and-mask ladder to get wrong.
    private static func appendBE<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
    }

    /// Reads a big-endian `T` starting at `index`.
    ///
    /// Deliberately *not* the mirror of `appendBE`: loading the bytes into a `T` and calling
    /// `T(bigEndian:)` would need the source to be contiguous and correctly aligned, and here
    /// it is neither guaranteed -- `data` is a slice of a received XPC payload whose
    /// `startIndex` is arbitrary. Accumulating byte by byte is alignment-agnostic and reads
    /// the same on either endianness.
    ///
    /// - Precondition: the caller has already checked
    ///   `data.endIndex - index >= MemoryLayout<T>.size`.
    private static func readBE<T: FixedWidthInteger>(
        _ data: Data, at index: Data.Index, as: T.Type
    ) -> T {
        data[index ..< index + MemoryLayout<T>.size].reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
