import Foundation
import GRPCCore

/// Translates between gRPC's domain concepts -- a method path, a call deadline, ``Metadata``, a
/// ``Status`` -- and the wire-level header field lists (``HTTPField``) that a ``WireCodec``
/// conformer (``CompactWireCodec``, the only one so far) encodes and decodes.
///
/// Every rule here is taken verbatim from the gRPC-over-HTTP/2 wire spec
/// (`https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md`), not inferred:
///
/// ```
/// Request-Headers  → Call-Definition *Custom-Metadata
/// Call-Definition   → Method Scheme Path [Authority] TE [Timeout] Content-Type
///                      [Message-Type] [Message-Encoding] [Message-Accept-Encoding] [User-Agent]
/// Response-Headers → HTTP-Status [Message-Encoding] [Message-Accept-Encoding]
///                      Content-Type *Custom-Metadata
/// Trailers         → Status [Status-Message] [Status-Details] *Custom-Metadata
/// TimeoutValue     → {positive integer as ASCII string of at most 8 digits}
/// TimeoutUnit      → Hour "H" / Minute "M" / Second "S" / Millisecond "m"
///                      / Microsecond "u" / Nanosecond "n"
/// Status           → "grpc-status" 1*DIGIT
/// Status-Message   → "grpc-message" Percent-Encoded
/// Percent-Byte-Unencoded → %x20-%x24 / %x26-%x7E                 ; space..VCHAR, except '%'
/// Percent-Byte-Encoded   → "%" 2HEXDIGIT
/// Header-Name      → 1*( %x30-39 / %x61-7A / "_" / "-" / "." )    ; 0-9 a-z _ - .
/// Binary-Header    → {Header-Name "-bin"} {base64 encoded value}  ; MUST accept padded and
///                                                                  ; unpadded, SHOULD emit unpadded
/// ```
///
/// This module does not implement `Authority`, `Message-Type`, `Message-Encoding`,
/// `Message-Accept-Encoding`, `User-Agent`, or `Status-Details` -- none of them are exercised by
/// this transport (no compression, no authority multiplexing, no rich error details), so they are
/// simply absent from the field lists this type builds, per Task 3's brief (W4): request field
/// order is `:method,:scheme,:path,te,content-type[,grpc-timeout],user-metadata…`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum GRPCWireHeaders {

    // =======================================================================================
    // MARK: - Well-known field names and values
    // =======================================================================================

    private static let methodPseudoHeader = ":method"
    private static let schemePseudoHeader = ":scheme"
    private static let pathPseudoHeader = ":path"
    private static let statusPseudoHeader = ":status"
    private static let teHeader = "te"
    private static let contentTypeHeader = "content-type"
    private static let timeoutHeader = "grpc-timeout"
    private static let grpcStatusHeader = "grpc-status"
    private static let grpcMessageHeader = "grpc-message"
    private static let grpcReservedPrefix = "grpc-"
    private static let binaryKeySuffix = "-bin"

    private static let methodValue = "POST"
    private static let schemeValue = "https"
    private static let contentTypeValue = "application/grpc"
    private static let teValue = "trailers"
    private static let httpStatusOKValue = "200"

    // =======================================================================================
    // MARK: - Field-list construction
    // =======================================================================================

    /// Builds the header field list for a request's `HEADERS` frame.
    ///
    /// `path` is the already-slash-prefixed `:path` value (e.g.
    /// `"/" + descriptor.fullyQualifiedMethod`); this type does not own `MethodDescriptor`
    /// construction on the send side, only on `parseRequest`'s validation side.
    static func request(path: String, timeout: Duration?, metadata: Metadata) -> [HTTPField] {
        var fields: [HTTPField] = [
            (methodPseudoHeader, methodValue),
            (schemePseudoHeader, schemeValue),
            (pathPseudoHeader, path),
            (teHeader, teValue),
            (contentTypeHeader, contentTypeValue),
        ]
        if let timeout {
            fields.append((timeoutHeader, encodeTimeout(timeout)))
        }
        fields.append(contentsOf: userMetadataFields(metadata))
        return fields
    }

    /// Builds the header field list for a response's initial (non-trailing) `HEADERS` frame.
    static func initialResponse(metadata: Metadata) -> [HTTPField] {
        var fields: [HTTPField] = [
            (statusPseudoHeader, httpStatusOKValue),
            (contentTypeHeader, contentTypeValue),
        ]
        fields.append(contentsOf: userMetadataFields(metadata))
        return fields
    }

    /// Builds the header field list for a response's trailing `HEADERS` frame (`END_STREAM` set).
    ///
    /// `grpc-message` is omitted when `status.message` is empty -- there is nothing to say, and
    /// omitting it (rather than emitting `grpc-message: `) keeps the trailers block minimal.
    static func trailers(status: Status, metadata: Metadata) -> [HTTPField] {
        var fields: [HTTPField] = [
            (grpcStatusHeader, String(status.code.rawValue)),
        ]
        if !status.message.isEmpty {
            fields.append((grpcMessageHeader, percentEncode(status.message)))
        }
        fields.append(contentsOf: userMetadataFields(metadata))
        return fields
    }

    // =======================================================================================
    // MARK: - Parsing
    // =======================================================================================

    struct ParsedRequest {
        var path: String
        var timeout: Duration?
        var metadata: Metadata
    }

    enum ParsedResponse {
        case initial(Metadata)
        case trailers(Status, Metadata)
    }

    /// Parses a request's header field list.
    ///
    /// Validates `:path` by splitting it on the *last* `/` and constructing a
    /// `MethodDescriptor(fullyQualifiedService:method:)` from the two halves --
    /// `MethodDescriptor` has no `fullyQualifiedMethod` initializer, and its own
    /// `fullyQualifiedMethod` accessor never includes the leading slash the `:path`
    /// pseudo-header carries, so that split-then-reconstruct is the only way to confirm the path
    /// names a real method shape before handing it onward. The returned `path` is the original
    /// `:path` value (leading slash included), matching what `request(path:)` was given.
    static func parseRequest(_ fields: [HTTPField]) throws -> ParsedRequest {
        guard let path = firstValue(fields, forLoweredName: pathPseudoHeader) else {
            throw RPCError(code: .invalidArgument, message: "request is missing the ':path' pseudo-header")
        }
        try validateMethodPath(path)

        var timeout: Duration?
        if let rawTimeout = firstValue(fields, forLoweredName: timeoutHeader) {
            timeout = try parseTimeout(rawTimeout)
        }

        let metadata = try parseUserMetadata(fields)
        return ParsedRequest(path: path, timeout: timeout, metadata: metadata)
    }

    /// Parses a response's header field list. `endStream` -- read off the enclosing `HEADERS`
    /// frame by the caller -- decides whether this is trailing metadata (which must carry
    /// `grpc-status`) or initial metadata (which must not).
    static func parseResponse(_ fields: [HTTPField], endStream: Bool) throws -> ParsedResponse {
        let statusValue = firstValue(fields, forLoweredName: grpcStatusHeader)

        if endStream {
            guard let statusValue else {
                throw RPCError(code: .invalidArgument, message: "trailers are missing 'grpc-status'")
            }
            let status = try parseStatus(statusValue: statusValue, fields: fields)
            let metadata = try parseUserMetadata(fields)
            return .trailers(status, metadata)
        } else {
            guard statusValue == nil else {
                throw RPCError(
                    code: .invalidArgument,
                    message: "initial metadata unexpectedly contains 'grpc-status'; "
                        + "the frame that carried it should have set END_STREAM")
            }
            let metadata = try parseUserMetadata(fields)
            return .initial(metadata)
        }
    }

    /// Splits `path` (leading slash optionally present) on the last `/` into service and method,
    /// then constructs a `MethodDescriptor` to confirm both halves are non-empty. The descriptor
    /// itself is discarded -- callers downstream (Task 6) reconstruct their own from `path` --
    /// this exists purely to reject a malformed `:path` here rather than downstream.
    private static func validateMethodPath(_ path: String) throws {
        let withoutLeadingSlash = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let lastSlash = withoutLeadingSlash.lastIndex(of: "/") else {
            throw RPCError(code: .unimplemented, message: "malformed ':path' value: '\(path)'")
        }
        let service = String(withoutLeadingSlash[withoutLeadingSlash.startIndex..<lastSlash])
        let method = String(withoutLeadingSlash[withoutLeadingSlash.index(after: lastSlash)...])
        guard !service.isEmpty, !method.isEmpty else {
            throw RPCError(code: .unimplemented, message: "malformed ':path' value: '\(path)'")
        }
        _ = MethodDescriptor(fullyQualifiedService: service, method: method)
    }

    private static func parseStatus(statusValue: String, fields: [HTTPField]) throws -> Status {
        guard let rawCode = Int(statusValue), let code = Status.Code(rawValue: rawCode) else {
            throw RPCError(code: .invalidArgument, message: "malformed 'grpc-status' value: '\(statusValue)'")
        }
        let message = firstValue(fields, forLoweredName: grpcMessageHeader).map(percentDecode) ?? ""
        return Status(code: code, message: message)
    }

    /// First field value whose lowercased name matches `loweredName`. Header names are
    /// case-insensitive on the wire (HTTP/2 requires lowercase, but a decoded field is only as
    /// trustworthy as the peer that sent it), so every lookup in this type goes through here.
    private static func firstValue(_ fields: [HTTPField], forLoweredName loweredName: String) -> String? {
        fields.first { $0.name.lowercased() == loweredName }?.value
    }

    // =======================================================================================
    // MARK: - User metadata: reserved-name stripping, `-bin` handling
    // =======================================================================================

    /// A name gRPC or HTTP/2 itself owns: pseudo-headers, anything `grpc-`-prefixed, `te`, and
    /// `content-type`. Excluded from user metadata on both emit and parse, so a caller can never
    /// inject `:path` or forge `grpc-status` by hiding it in ordinary metadata.
    private static func isReservedName(_ loweredName: String) -> Bool {
        loweredName.hasPrefix(":")
            || loweredName.hasPrefix(grpcReservedPrefix)
            || loweredName == teHeader
            || loweredName == contentTypeHeader
    }

    /// Converts `metadata` into wire fields: reserved names stripped, keys lowercased (Header-Name
    /// is lowercase-only on the wire), `-bin` keys' binary values base64-encoded (unpadded).
    ///
    /// A `.binary` value under a key that does *not* end `-bin` is a caller-contract violation --
    /// `Metadata.addBinary` already asserts this on the way in, so reaching this function with one
    /// (e.g. via a Release-mode build where the assert was compiled out) means the caller bypassed
    /// that contract, not that the peer sent something we're rejecting. This traps rather than
    /// silently emitting binary bytes as if they were printable ASCII, which would corrupt the
    /// header block for every field after it -- the same "caller bug traps" convention this
    /// module's `WireCodec` conformers use for their own encode-side preconditions.
    private static func userMetadataFields(_ metadata: Metadata) -> [HTTPField] {
        var fields: [HTTPField] = []
        fields.reserveCapacity(metadata.count)
        for (key, value) in metadata {
            let loweredKey = key.lowercased()
            guard !isReservedName(loweredKey) else { continue }

            let wireValue: String
            switch value {
            case .string(let string):
                wireValue = string
            case .binary(let bytes):
                precondition(
                    loweredKey.hasSuffix(binaryKeySuffix),
                    "GRPCWireHeaders.request/initialResponse/trailers: a binary metadata value's "
                        + "key must end in '-bin', got '\(key)'")
                wireValue = base64Unpadded(bytes)
            }
            fields.append((loweredKey, wireValue))
        }
        return fields
    }

    /// Recovers `Metadata` from wire fields: reserved names excluded, `-bin` keys base64-decoded
    /// and fed to `addBinary`, everything else fed to `addString`.
    ///
    /// A malformed `-bin` value is thrown as `RPCError` here, *before* it ever reaches
    /// `Metadata.addBinary` -- that method asserts its key ends `-bin` (which parseBase64's caller
    /// already guarantees by construction) but has no way to reject bad *bytes*, so the base64
    /// decode failure has to be caught on this side of the boundary or it doesn't get caught at
    /// all.
    private static func parseUserMetadata(_ fields: [HTTPField]) throws -> Metadata {
        var metadata = Metadata()
        for field in fields {
            let loweredKey = field.name.lowercased()
            guard !isReservedName(loweredKey) else { continue }

            if loweredKey.hasSuffix(binaryKeySuffix) {
                let bytes = try parseBase64(field.value)
                metadata.addBinary(bytes, forKey: loweredKey)
            } else {
                metadata.addString(field.value, forKey: loweredKey)
            }
        }
        return metadata
    }

    // =======================================================================================
    // MARK: - grpc-timeout: encode/decode
    // =======================================================================================

    /// The largest amount representable in the 8-digit `TimeoutValue` grammar.
    private static let maxTimeoutDigits: Int64 = 99_999_999

    /// Encodes `d` as a `grpc-timeout` value: the finest unit (nanoseconds first, hours last)
    /// whose amount, **rounded up**, still fits in 8 digits.
    ///
    /// Rounding up (never truncating) is deliberate, and is the opposite of this file's first
    /// draft -- truncating was tried and rejected on review. The two directions are not
    /// symmetric in their failure mode: a truncated wire value is `<=` the real deadline, so a
    /// server enforcing it can abandon work and return `DEADLINE_EXCEEDED` for a call the
    /// client's own (longer, real) deadline would still have accepted -- a client-visible
    /// functional failure caused purely by this encoding step. A value rounded up is `>=` the
    /// real deadline; the worst case is bounded extra server-side work after the client's own
    /// precise local timer has already fired and moved on -- wasted resources, not a wrong
    /// answer, and specifically not wrong *because the client enforces its real deadline itself*
    /// regardless of what it advertised on the wire. grpc-swift-2's own `Timeout.swift` reaches
    /// the same conclusion (`quotientRoundedUp`). Do not "fix" this back to truncation -- it
    /// looks like a precision improvement but reintroduces the client-visible failure mode above.
    ///
    /// A non-positive `Duration` (already-expired or malformed deadline) encodes as `"0n"` --
    /// there is no shorter unit to round up into, and zero is itself already an upper bound on a
    /// non-positive duration's wire representation. An amount so large it doesn't fit even in
    /// hours saturates at `"99999999H"` (~11,415 years) rather than overflowing; that clamp still
    /// rounds toward being the *larger* number a coarser unit could have expressed, so it stays on
    /// the safe (over-, not under-, estimating) side of the client's real deadline.
    static func encodeTimeout(_ d: Duration) -> String {
        guard d > .zero else { return "0n" }

        let (seconds, attoseconds) = d.components

        if let nanoseconds = roundedUpAmount(
            seconds: seconds, attoseconds: attoseconds,
            secondsMultiplier: 1_000_000_000, attosecondDivisor: 1_000_000_000)
        {
            return "\(nanoseconds)n"
        }
        if let microseconds = roundedUpAmount(
            seconds: seconds, attoseconds: attoseconds,
            secondsMultiplier: 1_000_000, attosecondDivisor: 1_000_000_000_000)
        {
            return "\(microseconds)u"
        }
        if let milliseconds = roundedUpAmount(
            seconds: seconds, attoseconds: attoseconds,
            secondsMultiplier: 1_000, attosecondDivisor: 1_000_000_000_000_000)
        {
            return "\(milliseconds)m"
        }
        let roundedSeconds = ceilingUnits(seconds: seconds, attoseconds: attoseconds, secondsPerUnit: 1)
        if roundedSeconds <= maxTimeoutDigits {
            return "\(roundedSeconds)S"
        }
        let minutes = ceilingUnits(seconds: seconds, attoseconds: attoseconds, secondsPerUnit: 60)
        if minutes <= maxTimeoutDigits {
            return "\(minutes)M"
        }
        let hours = min(ceilingUnits(seconds: seconds, attoseconds: attoseconds, secondsPerUnit: 3600), maxTimeoutDigits)
        return "\(hours)H"
    }

    /// Ceiling of `seconds * secondsMultiplier + attoseconds / attosecondDivisor` -- the real
    /// elapsed duration expressed in a sub-second unit (nanoseconds through seconds) -- computed
    /// without risking `Int64` overflow for absurdly large durations. Returns `nil` (rather than a
    /// too-large or overflowed value) whenever the result wouldn't fit in 8 digits, so callers can
    /// just fall through to the next coarser unit.
    ///
    /// Ceiling, not floor: `secondsPart` is exact (both operands are integers), so the only
    /// fractional contribution is `attoseconds / attosecondDivisor`; rounding that division up by
    /// one whenever there's a nonzero remainder is what makes the whole sum an upper bound on the
    /// real duration instead of a lower one.
    private static func roundedUpAmount(
        seconds: Int64, attoseconds: Int64, secondsMultiplier: Int64, attosecondDivisor: Int64
    ) -> Int64? {
        let (secondsPart, multiplyOverflowed) = seconds.multipliedReportingOverflow(by: secondsMultiplier)
        guard !multiplyOverflowed else { return nil }
        let fractionalPart = ceilingDivide(attoseconds, by: attosecondDivisor)
        let (total, addOverflowed) = secondsPart.addingReportingOverflow(fractionalPart)
        guard !addOverflowed, total <= maxTimeoutDigits else { return nil }
        return total
    }

    /// Ceiling of the real elapsed duration (`seconds` plus a sub-second `attoseconds` remainder)
    /// expressed in whole units of `secondsPerUnit` seconds each -- used for whole seconds
    /// (`secondsPerUnit: 1`), minutes (`60`), and hours (`3600`). Unlike `roundedUpAmount`, the
    /// remainder here can come from *either* `seconds` not being an exact multiple of
    /// `secondsPerUnit` *or* a nonzero `attoseconds`; either one means the true duration exceeds
    /// the truncated quotient, so either one rounds the result up by one unit.
    private static func ceilingUnits(seconds: Int64, attoseconds: Int64, secondsPerUnit: Int64) -> Int64 {
        let (quotient, remainder) = seconds.quotientAndRemainder(dividingBy: secondsPerUnit)
        return (remainder != 0 || attoseconds != 0) ? quotient + 1 : quotient
    }

    /// Ceiling integer division: the quotient, rounded toward positive infinity when there is a
    /// nonzero remainder. Both operands are always non-negative in this file's usage.
    private static func ceilingDivide(_ dividend: Int64, by divisor: Int64) -> Int64 {
        let (quotient, remainder) = dividend.quotientAndRemainder(dividingBy: divisor)
        return remainder == 0 ? quotient : quotient + 1
    }

    /// Parses a `grpc-timeout` value: 1-8 ASCII digits followed by exactly one of the six unit
    /// characters (`H`/`M`/`S`/`m`/`u`/`n`). Anything else -- empty, too many digits, a non-digit,
    /// an unrecognized unit -- is a malformed value from the peer, not a caller bug, so it throws
    /// rather than trapping.
    static func parseTimeout(_ s: String) throws -> Duration {
        func malformed() -> RPCError {
            RPCError(code: .invalidArgument, message: "malformed 'grpc-timeout' value: '\(s)'")
        }

        guard let unitCharacter = s.last else { throw malformed() }
        let digits = s.dropLast()
        guard (1...8).contains(digits.count),
            digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            throw malformed()
        }
        guard let amount = Int64(digits), amount <= maxTimeoutDigits else { throw malformed() }

        switch unitCharacter {
        case "H": return .seconds(amount * 3600)
        case "M": return .seconds(amount * 60)
        case "S": return .seconds(amount)
        case "m": return .milliseconds(amount)
        case "u": return .microseconds(amount)
        case "n": return .nanoseconds(amount)
        default: throw malformed()
        }
    }

    // =======================================================================================
    // MARK: - Percent-encoding (`grpc-message`)
    // =======================================================================================

    /// Encodes conservatively per `Percent-Byte-Unencoded → %x20-%x24 / %x26-%x7E`: any byte
    /// outside printable ASCII, *and* `%` (0x25) itself even though it's inside that range, is
    /// escaped as `%XX`. `grpc-message` is diagnostic text, not wire-critical, so this errs toward
    /// escaping more than strictly necessary rather than risk emitting a byte a peer's header
    /// parser chokes on.
    static func percentEncode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for byte in s.utf8 {
            if (0x20...0x24).contains(byte) || (0x26...0x7E).contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += percentEncodedByte(byte)
            }
        }
        return out
    }

    /// Decodes leniently: a well-formed `%XX` escape decodes to its byte; anything else
    /// (a trailing `%`, `%` followed by fewer than two hex digits, `%` followed by non-hex
    /// characters) passes through untouched rather than throwing. `grpc-message` carries a status's
    /// human-readable explanation -- it must never be the reason a real status fails to parse, so
    /// this asymmetry (strict encode, lenient decode) is intentional, not an oversight.
    ///
    /// The decoded bytes are reassembled as UTF-8 via `String(decoding:as:)`, which substitutes
    /// U+FFFD for any invalid sequence rather than failing -- consistent with "never error" here.
    static func percentDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)

        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
                let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2])
            {
                out.append((hi << 4) | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static let uppercaseHexDigits: [Character] = Array("0123456789ABCDEF")

    private static func percentEncodedByte(_ byte: UInt8) -> String {
        let high = uppercaseHexDigits[Int(byte >> 4)]
        let low = uppercaseHexDigits[Int(byte & 0x0F)]
        return "%\(high)\(low)"
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    // =======================================================================================
    // MARK: - Base64 (`-bin` metadata values)
    // =======================================================================================

    /// Encodes `bytes` as standard (not URL-safe) base64 with trailing `=` padding stripped, per
    /// `Binary-Header`'s "SHOULD emit un-padded values".
    static func base64Unpadded(_ bytes: [UInt8]) -> String {
        var encoded = Data(bytes).base64EncodedString()
        while encoded.hasSuffix("=") {
            encoded.removeLast()
        }
        return encoded
    }

    /// Decodes standard base64, accepting both padded and unpadded input per `Binary-Header`'s
    /// "MUST accept padded and un-padded values". Pads out to a multiple of 4 before handing it to
    /// `Data(base64Encoded:)`, which requires padding; a string whose length isn't already a
    /// multiple of 4 after padding to the next one (i.e. was already malformed) fails decoding
    /// there and throws.
    static func parseBase64(_ s: String) throws -> [UInt8] {
        let remainder = s.count % 4
        let padded = remainder == 0 ? s : s + String(repeating: "=", count: 4 - remainder)
        guard let data = Data(base64Encoded: padded) else {
            throw RPCError(code: .invalidArgument, message: "malformed base64 value: '\(s)'")
        }
        return Array(data)
    }
}
