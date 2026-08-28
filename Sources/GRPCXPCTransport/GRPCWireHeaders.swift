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

    // =======================================================================================
    // MARK: - Field-list construction
    // =======================================================================================

    /// Builds the header field list for a request's `HEADERS` frame.
    ///
    /// `path` is the already-slash-prefixed `:path` value (e.g.
    /// `"/" + descriptor.fullyQualifiedMethod`); this type never constructs a `MethodDescriptor`
    /// in either direction -- it moves the path as a string and validates its shape on the way
    /// back in (``validateMethodPath(_:)``).
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



    // =======================================================================================
    // MARK: - Parsing
    // =======================================================================================

    struct ParsedRequest {
        var path: String
        var timeout: Duration?
        var metadata: Metadata
    }


    /// Parses a request's header field list **in a single traversal**.
    ///
    /// Validates `:path` by splitting it on the *last* `/` and requiring both halves to be
    /// non-empty (see ``validateMethodPath(_:)``). The returned `path` is the original `:path`
    /// value (leading slash included), matching what `request(path:)` was given.
    ///
    /// **One pass, and that is a security property, not a micro-optimisation.** This function --
    /// via `CompactWireCodec.decode` -- runs on an `openStream` body *before* `RPCTransportCore`
    /// has decided whether the peer is even allowed to open another stream, so every byte of work
    /// it does is work an unauthenticated peer can command at will. `count` is a peer-chosen
    /// `UInt16`, so a single ~393 KB `openStream` body can declare 65,535 fields; the previous
    /// shape walked the list three times (`:path`, then `grpc-timeout`, then user metadata) and
    /// allocated a lowercased `String` for every name on every walk, which turned that one message
    /// into ~200,000 `String` allocations. Adding a fourth lookup, or reintroducing a
    /// `fields.first { $0.name.lowercased() == … }` helper, puts that amplification straight back.
    ///
    /// `fields` is any `Collection`, not just `[HTTPField]`, so a test can hand in a collection
    /// that counts element accesses and assert the single-pass property directly rather than
    /// asserting on wall-clock time -- see `WireProtocolTests`.
    ///
    /// Rejection precedence is deliberately unchanged from the three-pass version: a missing
    /// `:path` beats a malformed one, which beats a malformed `grpc-timeout`, which beats a
    /// malformed `-bin` metadata value. Because the single pass now reaches a bad `-bin` value
    /// *before* the path and timeout have been examined, that error is held in
    /// `deferredMetadataError` and rethrown last instead of escaping where it was raised.
    static func parseRequest<Fields: Collection>(_ fields: Fields) throws(RPCError) -> ParsedRequest
    where Fields.Element == HTTPField {
        var path: String?
        var rawTimeout: String?
        var metadata = Metadata()
        var deferredMetadataError: RPCError?

        for field in fields {
            switch classify(field.name) {
            case .path:
                // `firstValue` took the first match; so does this.
                if path == nil { path = field.value }
            case .timeout:
                if rawTimeout == nil { rawTimeout = field.value }
            case .reserved:
                continue
            case .userMetadata(let key):
                // Once a `-bin` value has failed, the rest of the metadata is going to be thrown
                // away with it -- but the walk must continue, since `:path` may still be ahead.
                guard deferredMetadataError == nil else { continue }
                if key.hasSuffix(binaryKeySuffix) {
                    do {
                        metadata.addBinary(try parseBase64(field.value), forKey: key)
                    } catch {
                        deferredMetadataError = error
                    }
                } else {
                    metadata.addString(field.value, forKey: key)
                }
            }
        }

        guard let path else {
            throw RPCError(code: .invalidArgument, message: "request is missing the ':path' pseudo-header")
        }
        try validateMethodPath(path)

        var timeout: Duration?
        if let rawTimeout {
            timeout = try parseTimeout(rawTimeout)
        }

        if let deferredMetadataError { throw deferredMetadataError }
        return ParsedRequest(path: path, timeout: timeout, metadata: metadata)
    }


    /// Splits `path` (leading slash optionally present) on the last `/` into service and method
    /// and requires both halves to be non-empty -- the whole of what "a real method shape" means
    /// here. Callers downstream reconstruct their own `MethodDescriptor` from `path`; this exists
    /// purely to reject a malformed `:path` at the boundary rather than downstream.
    ///
    /// It deliberately does *not* build a `MethodDescriptor` of its own.
    /// `MethodDescriptor(fullyQualifiedService:method:)` is a non-failable memberwise initialiser
    /// that stores both strings and validates nothing, so a discarded `_ = MethodDescriptor(…)`
    /// here checked exactly nothing while reading like a validation step. The two `guard`s above
    /// are the validation.
    private static func validateMethodPath(_ path: String) throws(RPCError) {
        let withoutLeadingSlash = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let lastSlash = withoutLeadingSlash.lastIndex(of: "/") else {
            throw RPCError(code: .unimplemented, message: "malformed ':path' value: '\(path)'")
        }
        let service = withoutLeadingSlash[withoutLeadingSlash.startIndex..<lastSlash]
        let method = withoutLeadingSlash[withoutLeadingSlash.index(after: lastSlash)...]
        guard !service.isEmpty, !method.isEmpty else {
            throw RPCError(code: .unimplemented, message: "malformed ':path' value: '\(path)'")
        }
    }

    // =======================================================================================
    // MARK: - Field-name classification (allocation-free for ASCII names)
    // =======================================================================================

    /// What one inbound field name is, decided once per field.
    private enum FieldRole {
        /// The `:path` pseudo-header.
        case path
        /// The `grpc-timeout` header.
        case timeout
        /// Some other name gRPC or HTTP/2 owns; never becomes user metadata.
        case reserved
        /// Ordinary user metadata, under its lowercased key.
        case userMetadata(key: String)
    }

    /// Classifies one field name without allocating, for the ASCII names the wire format actually
    /// permits (`Header-Name → 1*( %x30-39 / %x61-7A / "_" / "-" / "." )`, plus the `:`-prefixed
    /// pseudo-headers, plus whatever ASCII case a non-conforming peer chose).
    ///
    /// **Non-ASCII names still go through `lowercased()`, and that is not laziness.** A handful of
    /// non-ASCII scalars case-fold *into* ASCII -- U+212A KELVIN SIGN lowercases to `"k"` -- so an
    /// ASCII-only fold would silently change which names match and which key a value is stored
    /// under. Everything below the `guard` is therefore an exact fast path for all-ASCII names,
    /// not a redefinition of the matching rule: the `else` branch is byte-for-byte the old
    /// behaviour, and both branches classify in the same order.
    ///
    /// The ASCII path allocates a `String` only for a user-metadata name that actually contains an
    /// uppercase byte; a name already lowercase (every name a conforming peer sends, and every
    /// name this file's own encoder emits) is passed through by reference.
    private static func classify(_ name: String) -> FieldRole {
        guard name.utf8.allSatisfy({ $0 < 0x80 }) else {
            return classifyLowered(name.lowercased())
        }
        // `:path` and `grpc-timeout` are themselves reserved names, so they must be recognised
        // before the reserved-name filter swallows them.
        if asciiCaseInsensitiveEquals(name, pathPseudoHeader) { return .path }
        if asciiCaseInsensitiveEquals(name, timeoutHeader) { return .timeout }
        if name.utf8.first == UInt8(ascii: ":") { return .reserved }
        if asciiCaseInsensitiveHasPrefix(name, grpcReservedPrefix) { return .reserved }
        if asciiCaseInsensitiveEquals(name, teHeader) { return .reserved }
        if asciiCaseInsensitiveEquals(name, contentTypeHeader) { return .reserved }
        let hasUppercase = name.utf8.contains { (0x41...0x5A).contains($0) }
        return .userMetadata(key: hasUppercase ? name.lowercased() : name)
    }

    /// The same decision as ``classify(_:)``, spelled against an already-lowercased name -- the
    /// slow path for the non-ASCII names `classify` refuses to fold itself.
    private static func classifyLowered(_ loweredName: String) -> FieldRole {
        if loweredName == pathPseudoHeader { return .path }
        if loweredName == timeoutHeader { return .timeout }
        if isReservedName(loweredName) { return .reserved }
        return .userMetadata(key: loweredName)
    }

    /// `byte`, lowercased if it is an ASCII uppercase letter.
    private static func asciiLowered(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte &+ 0x20 : byte
    }

    /// `name == loweredASCII`, ignoring ASCII case, with no intermediate `String`.
    ///
    /// - Precondition: `name` contains no byte `>= 0x80` (``classify(_:)`` has already checked),
    ///   and `loweredASCII` is one of this type's lowercase ASCII name constants.
    private static func asciiCaseInsensitiveEquals(_ name: String, _ loweredASCII: String) -> Bool {
        guard name.utf8.count == loweredASCII.utf8.count else { return false }
        return zip(name.utf8, loweredASCII.utf8).allSatisfy { asciiLowered($0) == $1 }
    }

    /// `name.hasPrefix(loweredASCII)`, ignoring ASCII case, with no intermediate `String`.
    ///
    /// - Precondition: as ``asciiCaseInsensitiveEquals(_:_:)``.
    private static func asciiCaseInsensitiveHasPrefix(_ name: String, _ loweredASCII: String) -> Bool {
        var nameBytes = name.utf8.makeIterator()
        for target in loweredASCII.utf8 {
            guard let byte = nameBytes.next(), asciiLowered(byte) == target else { return false }
        }
        return true
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
    static func userMetadataFields(_ metadata: Metadata) -> [HTTPField] {
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
                    "GRPCWireHeaders.request/userMetadataFields: a binary metadata value's "
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
    /// Shares ``classify(_:)`` with `parseRequest` rather than lowercasing each name itself: this
    /// runs on every inbound `metadata` op and every `status` op's trailers, all of which are
    /// peer-sized field lists too, so the same allocation-free ASCII path applies. `.path` and
    /// `.timeout` are both reserved names, so they are dropped here exactly as `isReservedName`
    /// dropped them before.
    static func parseUserMetadata(_ fields: [HTTPField]) throws(RPCError) -> Metadata {
        var metadata = Metadata()
        for field in fields {
            guard case .userMetadata(let loweredKey) = classify(field.name) else { continue }

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
    /// hours saturates at `"99999999H"` (~11,415 years) rather than overflowing -- and unlike every
    /// other case here, **that clamp under-estimates**: it takes `min(roundedUpAmount, 99999999)`,
    /// so a deadline past ~11,415 years is advertised shorter than it is. Measured, not reasoned:
    /// 100,000,000 h goes out as `99999999H` and comes back 3,600 s short. Harmless in practice --
    /// the deadline is unreachable and the client's own timer stays authoritative either way -- but
    /// an earlier version of this sentence claimed the clamp stayed on the over-estimating side,
    /// which is the one thing it does not do.
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
    static func parseTimeout(_ s: String) throws(RPCError) -> Duration {
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
    static func parseBase64(_ s: String) throws(RPCError) -> [UInt8] {
        let remainder = s.count % 4
        let padded = remainder == 0 ? s : s + String(repeating: "=", count: 4 - remainder)
        guard let data = Data(base64Encoded: padded) else {
            throw RPCError(code: .invalidArgument, message: "malformed base64 value: '\(s)'")
        }
        return Array(data)
    }
}
