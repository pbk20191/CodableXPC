import Foundation

/// The wire format Apple's `XPC` Swift overlay uses to carry a `Codable` value.
///
/// This module reproduces that format. It is not how `CodableXPC` encodes — that
/// builds a native `xpc_object_t` tree — and the two are deliberately different
/// things. This one exists to read and write what Apple's overlay produces.
///
/// ## Shape
///
/// A message is an `xpc_dictionary` with five fixed keys (``OverlayEnvelope``). The
/// interesting one is `_CodableBody`, an `xpc_data` holding a flat little-endian
/// byte stream — *not* an xpc tree. Bulk and handle-bearing values do not go in the
/// stream: they live in side arrays and the stream carries an index.
///
/// ## Why a byte stream at all
///
/// Apple's encoder walks its node graph twice: once to total the exact byte count
/// and assign each container an index in breadth-first order, then once to write.
/// That buys a single `dispatch_data` allocation of exactly the right size, with no
/// growth and no back-patching. The graph is the deferred write.
///
/// ## Provenance
///
/// Every constant here was confirmed three ways: measured off a live
/// `XPCSession.send` capture, read out of Hex-Rays pseudocode in `xpcdump/`, and
/// checked against the `__cstring` table of the shipping dylib. Where the first
/// two disagreed, the measurement won — see the notes on ``OverlayEnvelope/body``.
///
/// The measurements were made on **macOS 27, build 26A5388g**, which is what this
/// machine runs — not on the iOS build the pseudocode came from, whose version
/// the dump does not record. The two are only assumed to agree.
///
/// Not assumed for long: the same envelope, decoded by Apple, was then checked in
/// an **iOS 26.5** and an **iOS 27.0** simulator, through
/// `XPCReceivedMessage.init(dictionary:)`. Scalars, nesting, arrays, absent
/// optionals and an out-of-line `Data` all come back intact on both. So the
/// format holds across three shipping builds and two platforms, which is the
/// claim — `coderVersion` 1 is not a promise about any build that has not been
/// run.
public enum OverlayWireFormat {

    /// The only coder version this module understands.
    ///
    /// Apple's decoder throws unless `_CodableCoderVersion` is exactly this.
    public static let coderVersion: Int64 = 1
}

/// The five top-level keys of an overlay-encoded message.
public enum OverlayEnvelope {

    /// The byte stream. `xpc_data`.
    ///
    /// A static reading of the dump suggested `_CodableOutOfLine` held the stream
    /// and this key was only existence-checked. Measuring a real message settled
    /// it the other way: this is the stream, and `_CodableOutOfLine` is an array.
    public static let body = "_CodableBody"

    /// `xpc_int64`, must equal ``OverlayWireFormat/coderVersion``.
    public static let coderVersion = "_CodableCoderVersion"

    /// `xpc_bool`. Whether the message expects a synchronous reply.
    public static let isSync = "_CodableIsSync"

    /// `xpc_array`. Bulk payloads the stream refers to by index — in practice the
    /// `xpc_data` for each `Data` value, kept out of the stream so it need not be
    /// copied through it.
    public static let outOfLine = "_CodableOutOfLine"

    /// `xpc_array`. Live xpc objects the stream refers to by index, supplied by the
    /// caller through `userInfo` rather than by the serialiser. An `XPCEndpoint`
    /// travels this way.
    ///
    /// Keeping these in a separate array from ``outOfLine`` is what lets the
    /// serialiser stay ignorant of endpoints and connections entirely.
    public static let outOfLineObjects = "_CodableOutOfLine4CodableObject"
}

/// One byte introducing each item in the stream.
///
/// The numbering is Apple's. Note that it is not the same as the encoder's internal
/// enum ordering — `nil` is internal case 18 but wire tag 0, for instance.
public enum OverlayTag: UInt8, Equatable, Sendable, CaseIterable {

    /// No payload. Written by every `encodeNil`.
    ///
    /// Apple's decoder reaches this through a `default:` branch, so an unknown byte
    /// would also decode as nil there. This module rejects unknown bytes instead;
    /// silently reading corruption as `nil` is not a behaviour worth reproducing.
    case null = 0

    case boolTrue = 1
    case boolFalse = 2

    /// `UInt64` byte count, the UTF-8 bytes, then a NUL. The count excludes the NUL.
    case string = 3

    case float = 4
    case double = 5

    case int = 6
    case int8 = 7
    case int16 = 8
    case int32 = 9
    case int64 = 10
    case uint = 11
    case uint8 = 12
    case uint16 = 13
    case uint32 = 14
    case uint64 = 15

    /// A keyed container's key, with no name. This is `superEncoder()`.
    case keyNil = 16

    /// A keyed container's key, followed by a string in the same layout as ``string``.
    case key = 17

    /// `UInt32` index into ``OverlayEnvelope/outOfLine``.
    case outOfLineData = 18

    /// One byte naming the container kind: see ``OverlayContainerKind``.
    /// Always the first item of a container body.
    case containerMetadata = 19

    /// `UInt32` id of a container whose body appears later in the stream.
    ///
    /// Each id may be referenced exactly once. Apple's decoder throws on a repeat,
    /// which is what makes this a linearisation device rather than object sharing —
    /// there is no aliasing and no cycle support anywhere in the format.
    case containerReference = 20

    /// Opens the body of the next referenced container. No payload.
    case containerStart = 21
}

/// The byte following ``OverlayTag/containerMetadata``.
///
/// The raw values are offset by 10 from the container kind, which is Apple's
/// encoding, not an accident of this port.
public enum OverlayContainerKind: UInt8, Equatable, Sendable {
    case keyed = 10
    case unkeyed = 11
    case singleValue = 12
}

/// Failures reading or writing the stream.
public enum OverlayCoderError: Error, Equatable {
    case truncated(needed: Int, available: Int)
    case unknownTag(UInt8)
    case unknownContainerKind(UInt8)
    case stringNotTerminated
    case duplicateContainerReference(UInt32)
    case danglingContainerReference(UInt32)
    case unopenedContainerBody
    case trailingBytes(Int)
    case missingEnvelopeKey(String)
    case unsupportedCoderVersion(Int64)
    case outOfLineIndexOutOfRange(UInt32)
}
