import Foundation

/// The wire format Apple's XPC Swift overlay used before the encoding-graph
/// rewrite — the macOS 15 / iOS 18 generation.
///
/// It is a different format from ``XPCOverlayCoder``'s, not an older revision of
/// it. Every tag value differs, the framing differs, and the envelope differs.
/// There is no subset that round-trips between them.
///
/// ## How the two relate
///
/// | | this module (iOS 17–18) | `XPCOverlayCoder` (iOS 26+ / macOS 26+) |
/// |---|---|---|
/// | shape | one pass, length-prefixed | two-pass graph, reference-based |
/// | container | `[tag][u64 count][u64 bodyLength][body]` | metadata tag, bodies deferred |
/// | keyed value | individually length-prefixed | not prefixed |
/// | `null` | `1` | `0` |
/// | `String` | `15` | `3` |
/// | integers | `2`–`11` | `6`–`15` |
/// | single-value container | transparent, never emitted | materialised |
/// | `Data` | out-of-line object, index in stream | out-of-line data, index in stream |
/// | envelope | three keys, **no version** | five keys, version required |
///
/// ## The version asymmetry, which is the point of having both
///
/// A newer reader rejects one of these cleanly: `_CodableCoderVersion` is absent
/// and its check treats that the same as a wrong version. Observed, in its own
/// words — "Received message from a process running old XPC coder".
///
/// A reader of this generation has no version to check, so it will *attempt* a
/// newer message. The tag spaces overlap almost completely, so it does not fail at the
/// first byte — it fails somewhere inside, as a type mismatch or a trap. Adding a
/// version field protects only the readers that ship after it.
/// Which build of the pre-graph overlay a message belongs to.
///
/// The byte stream is the same in both — every tag ordinal matches, checked
/// against a decompiled iOS 17.6.1 build and against a live iOS 18.6 runtime.
/// What differs is what sits beside it.
///
/// | | ``iOS17`` | ``iOS18`` |
/// |---|---|---|
/// | envelope | `_CodableBody`, `_CodableIsSync` | plus `_CodableOutOfLine` |
/// | `Data` | an unkeyed run of `UInt8` | an `xpc_data` in the side array |
/// | live objects (`XPCEndpoint`) | no mechanism at all | `XPCCodableObject` |
///
/// iOS 17 has no `XPCCodableObject`, no `XPCCodableObjectRepresentableCache` and
/// no `_XPCCodable` key — 220 references to that machinery in the iOS 18 binary,
/// none in the iOS 17 one. Its `encodeMessage` writes two keys and stops.
///
/// Nothing in a message says which it is, so this cannot be detected: a caller
/// who knows the peer picks. ``iOS18`` is the default because it is the one
/// checked against a running system.
public enum LegacyOverlayGeneration: Sendable, Equatable {
    /// macOS 14 / iOS 17.
    case iOS17
    /// macOS 15 / iOS 18.
    case iOS18

    var carriesOutOfLineObjects: Bool { self == .iOS18 }
}

public enum LegacyOverlayWireFormat {

    /// The byte written for a value is its `wireType` plus one. Apple's encoder
    /// does the `+ 1` at the single point where a tag is emitted, so the enum
    /// ordinals and the wire bytes are off by one throughout their source.
    static let tagBias: UInt8 = 1
}

/// The three keys of a legacy message. There is no coder-version key, which is
/// exactly how a reader tells this generation from the next one.
public enum LegacyOverlayEnvelope {
    /// `xpc_data`, the byte stream.
    public static let body = "_CodableBody"
    /// `xpc_bool`. Absent means `false`.
    public static let isSync = "_CodableIsSync"
    /// `xpc_array` of live XPC objects, referenced from the stream by index.
    ///
    /// The index is written by an ordinary single-value container, so it lands on
    /// the wire as a plain integer. That is why ``LegacyOverlayTag`` has no case
    /// for an object reference — the format does not need one, and a reader
    /// cannot tell an object index from any other `Int` without knowing the type.
    ///
    /// Populate it via ``CodingUserInfoKey/xpcLegacyCodableObjects``; Apple's
    /// `XPCCodableObject` throws `CodingUserInfoKeyNotFound` when the key is
    /// absent, so a coder that never installs the array cannot carry an endpoint.
    ///
    /// Note the name is reused with a different meaning in the newer format, where
    /// it holds `Data` blobs and the object array moved to
    /// `_CodableOutOfLine4CodableObject`. A reader that keyed off the name alone
    /// and not the version would misread one generation as the other.
    public static let outOfLineObjects = "_CodableOutOfLine"
    /// `xpc_string`, written by the framework rather than the coder: present when a
    /// handler that owed a reply did not produce one.
    public static let error = "_CodableError"
}

/// One byte introducing each item. These are the emitted values, already biased.
public enum LegacyOverlayTag: UInt8, Equatable, Sendable, CaseIterable {
    case null = 1
    case int = 2
    case int8 = 3
    case int16 = 4
    case int32 = 5
    case int64 = 6
    case uint = 7
    case uint8 = 8
    case uint16 = 9
    case uint32 = 10
    case uint64 = 11
    case bool = 12
    case float = 13
    case double = 14
    /// `[u64 length][utf8][NUL]`, where the length **includes** the NUL.
    case string = 15
    /// `[u64 elementCount][u64 bodyLength][elements…]`, no per-element prefix.
    case unkeyedContainer = 16
    /// `[u64 entryCount][u64 bodyLength]` then per entry a `string` key and a
    /// `[u64 valueLength][value]`.
    case keyedContainer = 17
    /// Declared by the encoder but never emitted: a single-value container is
    /// transparent and writes only its contained value.
    case singleValueContainer = 18
    /// A `nil` `Optional` that reached the generic path, rather than `encodeNil`.
    /// Emitted as `19 01`.
    case optionalNone = 19
    /// Declared but never emitted, like ``singleValueContainer``.
    case encoder = 20
}

/// Failures reading or writing the legacy stream.
public enum LegacyOverlayCoderError: Error, Equatable {
    case truncated(needed: Int, available: Int)
    case unknownTag(UInt8)
    case unexpectedTag(expected: LegacyOverlayTag, found: UInt8)
    case stringNotTerminated
    case declaredLengthOverruns(declared: Int, available: Int)
    case trailingBytes(Int)
    case missingEnvelopeKey(String)
    /// The message carries `_CodableCoderVersion`, so it is the newer format and
    /// belongs to `XPCOverlayCoder`.
    case notALegacyMessage
    case outOfLineIndexOutOfRange(Int)
}
