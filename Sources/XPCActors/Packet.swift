import Foundation
import XPC

/// The four envelope keys. Exhaustive: a packet dictionary carries nothing else.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum EnvelopeKey {
    public static let version = "version"
    public static let kind = "kind"
    public static let seq = "seq"
    public static let body = "body"
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public enum PacketKind: UInt64, Sendable, Hashable {
    case request = 0
    case reply = 1
    case notification = 2
    case hello = 3
    case helloAck = 4
}

/// The envelope. Construction is failable because the presence rules are a
/// contract, not a convention: a notification carrying a `seq` would be
/// indistinguishable from a request, and a `hello` carrying a real version would
/// mean the sender had already negotiated one.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct PacketHeader: Hashable, Sendable {
    public let version: ProtocolVersion
    public let kind: PacketKind
    public let seq: UInt64?

    public init?(version: ProtocolVersion, kind: PacketKind, seq: UInt64?) {
        switch kind {
        case .request, .reply:
            guard seq != nil, version != .unnegotiated else { return nil }
        case .notification:
            guard seq == nil, version != .unnegotiated else { return nil }
        case .hello, .helloAck:
            guard seq == nil, version == .unnegotiated else { return nil }
        }
        self.version = version
        self.kind = kind
        self.seq = seq
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct Packet: @unchecked Sendable {
    public let header: PacketHeader
    public let payload: Payload

    public init(header: PacketHeader, payload: Payload) {
        self.header = header
        self.payload = payload
    }

    /// Parse and validate. Returns `nil` for anything that does not satisfy the
    /// envelope contract; the caller drops such packets.
    public init?(rawValue: xpc_object_t) {
        guard xpc_get_type(rawValue) == XPC_TYPE_DICTIONARY,
              let rawVersion = Packet.uint64(rawValue, EnvelopeKey.version),
              let rawKind = Packet.uint64(rawValue, EnvelopeKey.kind),
              let kind = PacketKind(rawValue: rawKind),
              let header = PacketHeader(
                  version: ProtocolVersion(rawValue: rawVersion),
                  kind: kind,
                  seq: Packet.uint64(rawValue, EnvelopeKey.seq)
              ),
              let body = xpc_dictionary_get_value(rawValue, EnvelopeKey.body),
              xpc_get_type(body) == XPC_TYPE_DICTIONARY
        else { return nil }
        self.header = header
        self.payload = Payload(unchecked: body)
    }

    public var rawValue: xpc_object_t {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dictionary, EnvelopeKey.version, header.version.rawValue)
        xpc_dictionary_set_uint64(dictionary, EnvelopeKey.kind, header.kind.rawValue)
        if let seq = header.seq {
            xpc_dictionary_set_uint64(dictionary, EnvelopeKey.seq, seq)
        }
        xpc_dictionary_set_value(dictionary, EnvelopeKey.body, payload.object)
        return dictionary
    }

    /// Read a uint64, distinguishing "absent" from "zero".
    ///
    /// `xpc_dictionary_get_uint64` returns 0 for a missing key and for a key of the
    /// wrong type, so it cannot be used here: a packet with no `kind` would parse
    /// as a request.
    static func uint64(_ dictionary: xpc_object_t, _ key: String) -> UInt64? {
        guard let value = xpc_dictionary_get_value(dictionary, key),
              xpc_get_type(value) == XPC_TYPE_UINT64
        else { return nil }
        return xpc_uint64_get_value(value)
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
extension Packet {
    public struct Payload: @unchecked Sendable {
        let object: xpc_object_t
        init(unchecked object: xpc_object_t) { self.object = object }
    }
}
