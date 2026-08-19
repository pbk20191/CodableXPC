import Foundation
import GRPCCore
import CodableXPC
import XPC

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public typealias StreamID = UInt64

/// A `GRPCCore.Metadata` in a Codable shape. Each entry is a key plus its raw bytes; binary vs.
/// string is decided by gRPC's own discriminator -- the `-bin` key suffix -- not by a private
/// tag, so the wire shape matches the convention every other gRPC implementation uses. Keys are
/// normalized to lowercase (gRPC metadata keys are case-insensitive and conventionally lowercase).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct WireMetadata: Codable, Sendable {
    struct Entry: Codable, Sendable { var key: String; var bytes: Data }
    var entries: [Entry]

    init(_ metadata: Metadata) {
        entries = metadata.map { element in
            let key = element.key.lowercased()
            switch element.value {
            case .string(let s): return Entry(key: key, bytes: Data(s.utf8))
            case .binary(let b): return Entry(key: key, bytes: Data(b))
            }
        }
    }

    func asMetadata() -> Metadata {
        var md = Metadata()
        for e in entries {
            if e.key.hasSuffix("-bin") { md.addBinary([UInt8](e.bytes), forKey: e.key) }
            else { md.addString(String(decoding: e.bytes, as: UTF8.self), forKey: e.key) }
        }
        return md
    }
}

/// One packet on the wire. Exactly one of these per `XPCSession` message.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum XPCFrame: Codable, Sendable {
    case openStream(StreamID, method: String, deadlineNanos: Int64?)
    case metadata(StreamID, WireMetadata)
    case message(StreamID, seq: UInt64, bytes: Data)
    case halfClose(StreamID)
    case status(StreamID, code: Int, message: String, trailers: WireMetadata)
    case cancel(StreamID, reason: String)
    case credit(StreamID, n: UInt32)
    case goAway
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension WireMetadata.Entry: Equatable {}
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension WireMetadata: Equatable {}
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension XPCFrame: Equatable {}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension XPCFrame {
    /// Encode via CodableXPC. `Data` fields map to `xpc_data` (zero-copy for the message payload,
    /// per CodableXPC's ZeroCopyData path).
    func encodeToXPC() throws -> xpc_object_t {
        try XPCEncoder().encode(self)
    }
    static func decode(from object: xpc_object_t) throws -> XPCFrame {
        try XPCDecoder().decode(XPCFrame.self, from: object)
    }
}
