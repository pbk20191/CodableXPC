import Foundation
import GRPCCore

/// A wire-level header field name/value pair. Shared by name across the module (Task 3 builds
/// these from gRPC metadata; Task 6 consumes the decoded form) -- `(String, String)` and
/// `(name: String, value: String)` are structurally the same tuple type, but the labels are what
/// let call sites write `field.name` / `field.value` instead of `.0` / `.1`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
typealias HTTPField = (name: String, value: String)

/// Encodes and decodes the **literal-only subset** of HPACK (RFC 7541): every field is a
/// "Literal Header Field without Indexing -- New Name" (§6.2.2), with a plain (non-Huffman)
/// string for both name and value. No dynamic table, no static-table lookups, no Huffman coding
/// -- deliberately. The point of the subset is that it is nonetheless **100% valid HPACK**: any
/// conformant HTTP/2 peer decodes it correctly, because RFC 7541 defines this exact
/// representation. A full HPACK decoder (dynamic table, indexing, Huffman) is explicit later
/// work, not something to grow here by accretion.
///
/// On decode, anything outside that subset is a distinct, named rejection rather than a guess:
/// an indexed field, incremental indexing, or a dynamic-table-size update all imply table state
/// this codec does not have, and a Huffman-coded string implies a decoder this codec is not. A
/// peer sending any of those is either a real HPACK implementation this transport does not yet
/// support, or an attacker probing for a parser that mis-decodes instead of refusing.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum HPACKLiteralCodec {

    /// RFC 7541 §6.2.2's first byte: `0000` prefix pattern, 4 bits of index (always 0 here --
    /// "new name" -- since this codec never references a static-table name).
    private static let literalWithoutIndexingFirstByteBits: UInt8 = 0x00
    private static let fieldTypePrefixBits = 4
    private static let stringLengthPrefixBits = 7

    // =======================================================================================
    // MARK: - Encode
    // =======================================================================================

    /// Encodes `fields` as a sequence of literal-without-indexing representations, in order.
    ///
    /// - Precondition: pseudo-header fields (name starting with `:`) must all precede regular
    ///   fields, per HTTP/2's own requirement (RFC 9113 §8.3) that pseudo-headers appear first in
    ///   a header block. This is a caller bug, not peer input, so it traps rather than throwing.
    static func encode(_ fields: [HTTPField]) -> GRPCSwiftData {
        var out = Data()
        var sawRegularField = false
        for field in fields {
            let isPseudoHeader = field.name.hasPrefix(":")
            precondition(
                !(isPseudoHeader && sawRegularField),
                "HPACKLiteralCodec.encode: pseudo-header field '\(field.name)' follows a regular "
              + "field; all pseudo-headers must precede regular fields (RFC 9113 §8.3)")
            if !isPseudoHeader { sawRegularField = true }

            writeInt(0, prefixBits: fieldTypePrefixBits, firstByteBits: literalWithoutIndexingFirstByteBits,
                     into: &out)
            writeLiteralString(field.name.lowercased(), into: &out)
            writeLiteralString(field.value, into: &out)
        }
        return GRPCSwiftData(viewing: out)
    }

    /// Appends a non-Huffman string literal: a 7-bit-prefixed length (H bit unset) followed by
    /// its raw UTF-8 bytes (RFC 7541 §5.2).
    private static func writeLiteralString(_ string: String, into out: inout Data) {
        let utf8 = Array(string.utf8)
        writeInt(utf8.count, prefixBits: stringLengthPrefixBits, firstByteBits: 0x00, into: &out)
        out.append(contentsOf: utf8)
    }

    /// RFC 7541 §5.1's prefix-integer encoding. `firstByteBits` carries whatever fixed high bits
    /// belong in the same byte as the prefix (a representation's type bits, or 0 for a bare
    /// string length) -- the two are OR'd together, so callers never need to pre-shift `value`.
    ///
    /// When `value` fits under the prefix's all-ones maximum, it is written directly in the
    /// prefix bits. Otherwise the prefix bits are set to all ones and `value` minus that maximum
    /// follows as a base-128 (LEB128) continuation: 7 value bits plus a high continuation bit per
    /// byte, least-significant group first.
    static func writeInt(_ value: Int, prefixBits: Int, firstByteBits: UInt8, into out: inout Data) {
        precondition((1...8).contains(prefixBits), "prefixBits must be in 1...8, got \(prefixBits)")
        precondition(value >= 0, "HPACK integers are non-negative, got \(value)")

        let prefixMaximum = (1 << prefixBits) - 1
        guard value >= prefixMaximum else {
            out.append(firstByteBits | UInt8(value))
            return
        }

        out.append(firstByteBits | UInt8(prefixMaximum))
        var remainder = value - prefixMaximum
        while remainder >= 128 {
            out.append(UInt8(remainder % 128) | 0x80)
            remainder /= 128
        }
        out.append(UInt8(remainder))
    }

    // =======================================================================================
    // MARK: - Decode
    // =======================================================================================

    /// Decodes a header block containing only literal-without-indexing (or never-indexed)
    /// representations with new names. `block` need not start at index 0 -- see
    /// `HTTP2FrameTests.testDecodeFromANonZeroOffsetBuffer` for why that matters in production,
    /// where this is always a slice of a received HEADERS frame's payload.
    ///
    /// - Throws: `RPCError(code: .unimplemented)` naming the rejected construct, for any of:
    ///   an indexed field, incremental indexing, a dynamic-table-size update, an indexed-name
    ///   literal, or a Huffman-coded string. `RPCError(code: .internalError)` for a header block
    ///   that is truncated, declares a string longer than the bytes remaining, contains a
    ///   pathological (non-terminating or overflowing) integer, or a string that is not valid
    ///   UTF-8.
    static func decode(_ block: GRPCSwiftData) throws -> [HTTPField] {
        var fields: [HTTPField] = []
        var offset = block.startIndex

        while offset < block.endIndex {
            let first = block[offset]

            if first & 0x80 != 0 {
                throw RPCError(
                    code: .unimplemented,
                    message: "HPACK indexed header field representation (0x\(hex(first))) is not "
                           + "supported; only the literal-without-indexing subset is supported")
            }
            if first & 0xC0 == 0x40 {
                throw RPCError(
                    code: .unimplemented,
                    message: "HPACK literal header field with incremental indexing (0x\(hex(first))) "
                           + "is not supported; only the literal-without-indexing subset is supported")
            }
            if first & 0xE0 == 0x20 {
                throw RPCError(
                    code: .unimplemented,
                    message: "HPACK dynamic table size update (0x\(hex(first))) is not supported; "
                           + "only the literal-without-indexing subset is supported")
            }
            // Remaining possibilities both have a 4-bit type prefix: `0000` (without indexing,
            // RFC 7541 §6.2.2) or `0001` (never indexed, §6.2.3). This codec has no dynamic
            // table either way, so both decode identically.

            let index = try readInt(prefixBits: fieldTypePrefixBits, block: block, offset: &offset)
            guard index == 0 else {
                throw RPCError(
                    code: .unimplemented,
                    message: "HPACK literal header field with an indexed name (index \(index)) is "
                           + "not supported; only new-name (index 0) literals are supported")
            }

            let name = try readLiteralString(block: block, offset: &offset)
            let value = try readLiteralString(block: block, offset: &offset)
            fields.append((name: name, value: value))
        }

        return fields
    }

    /// Reads one non-Huffman string literal (RFC 7541 §5.2): an H bit, a 7-bit-prefixed length,
    /// then that many raw bytes, decoded as UTF-8.
    private static func readLiteralString(block: GRPCSwiftData, offset: inout Int) throws -> String {
        guard offset < block.endIndex else {
            throw RPCError(code: .internalError,
                           message: "HPACK header block truncated: expected a string literal")
        }
        guard block[offset] & 0x80 == 0 else {
            throw RPCError(
                code: .unimplemented,
                message: "HPACK Huffman-coded string literal (H bit set) is not supported; only "
                       + "plain (non-Huffman) string literals are supported")
        }

        let length = try readInt(prefixBits: stringLengthPrefixBits, block: block, offset: &offset)
        let remaining = block.endIndex - offset
        guard length <= remaining else {
            throw RPCError(
                code: .internalError,
                message: "HPACK string literal declares \(length) byte(s) but only \(remaining) "
                       + "remain in the header block")
        }

        let end = offset + length
        let bytes = block.data[offset..<end]
        offset = end

        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw RPCError(code: .internalError,
                           message: "HPACK string literal is not valid UTF-8")
        }
        return string
    }

    /// RFC 7541 §5.1's prefix-integer decoding, the inverse of `writeInt`. Reads the byte at
    /// `offset` within `block` (masking off whatever fixed high bits the caller already
    /// inspected), advances `offset` past every byte consumed, and -- if the prefix bits read as
    /// all ones -- continues through the base-128 (LEB128) continuation bytes.
    ///
    /// `offset` is never assumed to start at 0: `block` is a `GRPCSwiftData`, whose indices do
    /// not rebase to zero on a slice.
    ///
    /// - Throws: `RPCError(code: .internalError)` if the block ends before a required byte (the
    ///   prefix byte itself, or a continuation byte implied by a still-set continuation bit), or
    ///   if the value would overflow `Int` or requires an implausible number of continuation
    ///   bytes -- both of which a peer fully controls and neither of which a conforming HPACK
    ///   integer needs (values fit gRPC's needs many times over well under this limit).
    static func readInt(prefixBits: Int, block: GRPCSwiftData, offset: inout Int) throws -> Int {
        precondition((1...8).contains(prefixBits), "prefixBits must be in 1...8, got \(prefixBits)")
        guard offset < block.endIndex else {
            throw RPCError(code: .internalError,
                           message: "HPACK header block truncated: expected a prefix-integer byte")
        }

        let prefixMaximum = (1 << prefixBits) - 1
        let prefixValue = Int(block[offset]) & prefixMaximum
        offset += 1

        guard prefixValue == prefixMaximum else {
            return prefixValue
        }

        // Extended (LEB128) form. Cap the number of continuation bytes well short of what could
        // overflow `Int` (64-bit, so 10 groups of 7 bits already exceeds it) -- a peer that keeps
        // the continuation bit set past that is malicious or corrupt, not merely encoding a large
        // number.
        let maxContinuationBytes = 9
        var value = prefixValue
        var shift = 0
        for _ in 0..<maxContinuationBytes {
            guard offset < block.endIndex else {
                throw RPCError(code: .internalError,
                               message: "HPACK prefix-integer truncated: missing continuation byte")
            }
            let byte = block[offset]
            offset += 1

            let addend = Int(byte & 0x7F) << shift
            guard shift < Int.bitWidth, addend >= 0, value <= Int.max - addend else {
                throw RPCError(code: .internalError,
                               message: "HPACK prefix-integer overflowed while decoding")
            }
            value += addend

            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw RPCError(
            code: .internalError,
            message: "HPACK prefix-integer exceeded \(maxContinuationBytes) continuation bytes "
                   + "without terminating; the peer is malicious or the block is corrupt")
    }

    private static func hex(_ byte: UInt8) -> String { String(byte, radix: 16) }
}
