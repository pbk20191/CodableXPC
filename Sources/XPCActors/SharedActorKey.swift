import Foundation

/// An actor reference on the wire is exactly this and nothing else.
///
/// Matches Apple's shipping `XPCDistributed` (`SharedActorKey.encode(to:)`,
/// disassembled from the macOS 27 binary at `0x2ad4f8458`), not the synthesized enum
/// coding an older, dump-only build used. The type has no `CodingKeys` of any kind in
/// the shipping build, so a keyed container is not an option: each case writes exactly
/// two values -- a `WireCode`, then its payload -- into one unkeyed container.
///
/// See `docs/superpowers/specs/2026-08-08-xpcdistributed-interop-wire-format.md`,
/// "SharedActorKey -- an unkeyed pair, not synthesized coding".
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public enum SharedActorKey: Hashable, Sendable {
    /// The default actor for a type. Pre-agreed: a peer can import it with no round
    /// trip. Payload is a `SwiftType`, never a bare mangled name.
    case exported(SwiftType)
    /// An actor exported under a name. Also pre-agreed. Payload is a plain `String` --
    /// the builtin overload, no witness-table call, per the disassembly.
    case exportedRawValue(String)
    /// An actor that crossed the wire as a value during a call. Payload is an `ID64`,
    /// coded through its own conformance -- which is single-value, so this lands as a
    /// bare `UInt64`. Going through the witness table decides which `encode` runs; it
    /// does not add a level of nesting.
    case dynamic(ID64)
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
extension SharedActorKey: Codable {

    /// `RawRepresentable` over `UInt8`, `0, 1, 2` in declaration order -- confirmed by
    /// `WireCode.rawValue.getter : Swift.UInt8` and `WireCode.init(rawValue:)` in the
    /// extracted binary.
    private enum WireCode: UInt8 {
        case exported = 0
        case exportedRawValue = 1
        case dynamic = 2
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .exported(let type):
            try container.encode(WireCode.exported.rawValue)
            try container.encode(type)
        case .exportedRawValue(let raw):
            try container.encode(WireCode.exportedRawValue.rawValue)
            try container.encode(raw)
        case .dynamic(let id):
            try container.encode(WireCode.dynamic.rawValue)
            try container.encode(id)
        }
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let raw = try container.decode(UInt8.self)
        guard let code = WireCode(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown SharedActorKey wire code \(raw)")
        }
        // The discriminator decides which decode runs next. There is no payload key to
        // consult instead -- the container is unkeyed -- so a payload of the wrong
        // shape for this code fails the decode of that element, not a fallback guess.
        //
        // Two reads, no count check: a peer sending a longer array has its trailing
        // elements ignored rather than rejected. That is deliberate -- Apple's decoder
        // is two reads as well, and rejecting here would refuse traffic Apple accepts.
        // Note it is asymmetric with encode, which always writes exactly two.
        switch code {
        case .exported:
            self = .exported(try container.decode(SwiftType.self))
        case .exportedRawValue:
            self = .exportedRawValue(try container.decode(String.self))
        case .dynamic:
            self = .dynamic(try container.decode(ID64.self))
        }
    }
}
