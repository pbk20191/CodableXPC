import Foundation
import XPC

/// Which build of Apple's XPC overlay a message belongs to.
///
/// Three of them ship, and they are not revisions of one format — the byte
/// stream was replaced outright between ``iOS18`` and ``iOS26``.
///
/// | | ``iOS17`` | ``iOS18`` | ``iOS26`` |
/// |---|---|---|---|
/// | stream | one pass, length-prefixed | same | encoding graph, by reference |
/// | tags | `1`…`20` | same | different values throughout |
/// | envelope | `_CodableBody`, `_CodableIsSync` | plus `_CodableOutOfLine` | five keys |
/// | version key | none | none | required, `1` |
/// | `Data` | in the stream | side array | out-of-line blob |
/// | live objects | none | `XPCCodableObject` | `XPCCodableObject` |
///
/// ## How each was established
///
/// ``iOS17`` from a decompiled 17.6.1 `libswiftXPC`: every
/// `CodingContainer.wireType` ordinal read directly, and an `encodeMessage` that
/// writes two keys and returns. No `XPCCodableObject` anywhere in it.
///
/// ``iOS18`` measured live in an 18.6 simulator. That build still exports the
/// byte-level `XPCEncoder`/`XPCDecoder`, so both directions were run against
/// Apple's own coder with no connection involved.
///
/// ``iOS26`` measured live on macOS 27 and in iOS 26.5 and 27.0 simulators. Those
/// builds dropped `XPCEncoder`/`XPCDecoder` and export
/// `XPCReceivedMessage.init(dictionary:)` instead, which is the opposite half of
/// the same trick — see ``AppleCoderBridge``.
///
/// ## Which layer is public moved with the rewrite
///
/// The older pair expose the coder and hide the message: `XPCEncoder`/`XPCDecoder`
/// are exported and take `userInfo`, while `send`, `reply` and `decode(as:)` have
/// no `userInfo` form at all. The newer builds do the reverse — the byte-level
/// classes are gone and all three message entry points gained one, which is also
/// when `encodeMessage` grew its `userInfo:` parameter.
///
/// `XPCReceivedMessage` differs with them. On ``iOS17`` and ``iOS18`` it carries
/// an `XPCReceivedMessageMetadata`, a nested type the newer one does not have,
/// and there is no `init(dictionary:)` to make one from a bare dictionary.
/// ## Where the code is
///
/// `ByteStream/` is ``iOS17`` and ``iOS18``; `EncodingGraph/` is ``iOS26``;
/// `Shared/` is this file and ``AppleCoderBridge``. The two implementations
/// import nothing from each other — the split is the honest shape of a module
/// holding two formats that share only a lineage.
///
/// ## Errors
///
/// Failures here throw this module's own types. An `XPCRichError` can be made
/// too, despite libxpc having no creator for one — see
/// ``XPC/XPCRichError/make(_:canRetry:)``, which does not need libxpc because
/// the Swift type turns out not to wrap an `xpc_rich_error_t`.
public enum XPCOverlayGeneration: Sendable, Equatable, CaseIterable {
    /// macOS 14 / iOS 17.
    case iOS17
    /// macOS 15 / iOS 18.
    case iOS18
    /// macOS 26+ / iOS 26+. The encoding-graph rewrite.
    case iOS26

    /// Whether this generation's stream is the pre-graph one.
    public var usesLegacyStream: Bool { self != .iOS26 }

    /// The value of `_CodableCoderVersion`, or `nil` where the key does not exist.
    public var coderVersion: Int64? { self == .iOS26 ? OverlayWireFormat.coderVersion : nil }

    var legacy: LegacyOverlayGeneration? {
        switch self {
        case .iOS17: return .iOS17
        case .iOS18: return .iOS18
        case .iOS26: return nil
        }
    }
}

/// Encodes a value into a complete message for a chosen generation.
///
/// The two stream implementations stay separate — they share nothing but a
/// lineage — and this picks between them.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct XPCOverlayMessageEncoder {

    public var generation: XPCOverlayGeneration
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init(generation: XPCOverlayGeneration) {
        self.generation = generation
    }

    public func message<T: Encodable>(_ value: T, isSync: Bool = false) throws -> xpc_object_t {
        if let legacy = generation.legacy {
            var encoder = XPCLegacyOverlayEncoder(generation: legacy)
            encoder.userInfo = userInfo
            return LegacyOverlayEnvelope.message(try encoder.encode(value),
                                                 isSync: isSync, generation: legacy)
        }
        var encoder = XPCOverlayEncoder()
        encoder.userInfo = userInfo
        return OverlayEnvelope.message(try encoder.encode(value), isSync: isSync)
    }
}

/// Decodes a message, choosing the reader from the message itself where it can.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
public struct XPCOverlayMessageDecoder {

    /// Which reader to use, or `nil` to decide per message. See
    /// ``detectGeneration(of:)`` for what that decision can and cannot see.
    public var generation: XPCOverlayGeneration?
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// - Parameter generation: omit to detect. Detection distinguishes ``iOS26``
    ///   from the older pair and nothing finer, so a peer known to be iOS 17
    ///   should be named.
    public init(generation: XPCOverlayGeneration? = nil) {
        self.generation = generation
    }

    /// The only thing a message says about its own generation.
    ///
    /// `_CodableCoderVersion` is present exactly on ``XPCOverlayGeneration/iOS26``,
    /// so its absence narrows the field to two and stops. Nothing separates
    /// ``XPCOverlayGeneration/iOS17`` from ``XPCOverlayGeneration/iOS18`` on the
    /// wire — the streams are identical and the third envelope key is only
    /// present when a `Data` or a live object was there to need it.
    ///
    /// - Returns: ``XPCOverlayGeneration/iOS26``, or ``XPCOverlayGeneration/iOS18``
    ///   as the older default.
    public static func detectGeneration(of message: xpc_object_t) -> XPCOverlayGeneration {
        xpc_dictionary_get_value(message, OverlayEnvelope.coderVersion) != nil ? .iOS26 : .iOS18
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self,
                                     from message: xpc_object_t) throws -> T {
        let chosen = generation ?? Self.detectGeneration(of: message)
        if let legacy = chosen.legacy {
            var decoder = XPCLegacyOverlayDecoder(generation: legacy)
            decoder.userInfo = userInfo
            return try decoder.decode(type, from: message)
        }
        var decoder = XPCOverlayDecoder()
        decoder.userInfo = userInfo
        return try decoder.decode(type, from: message)
    }
}
