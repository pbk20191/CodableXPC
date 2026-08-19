import Foundation
import GRPCCore

/// gRPC's standard `Length-Prefixed-Message`:
///
///     Compressed-Flag (1 byte) | Message-Length (4 bytes, big-endian) | Message
///
/// This is the exact byte sequence gRPC carries in an HTTP/2 DATA frame, so a payload framed here
/// is byte-identical to one from any other gRPC implementation. XPC already delimits messages, so
/// the prefix is redundant for *correctness* — it is here for interoperability (see spec D4).
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum GRPCMessageFraming {

    static let prefixLength = 5

    static func frame(_ payload: [UInt8]) -> Data {
        var out = Data(capacity: prefixLength + payload.count)
        out.append(0)                                   // compressed-flag: v1 never compresses
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(contentsOf: payload)
        return out
    }

    static func unframe(_ data: Data) throws -> [UInt8] {
        guard data.count >= prefixLength else {
            throw RPCError(code: .internalError,
                           message: "gRPC message frame is \(data.count) bytes, shorter than its "
                                  + "\(prefixLength)-byte prefix")
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 0 else {
            throw RPCError(code: .unimplemented,
                           message: "compressed gRPC messages are not supported (flag \(bytes[0]))")
        }
        let declared = (UInt32(bytes[1]) << 24) | (UInt32(bytes[2]) << 16)
                     | (UInt32(bytes[3]) << 8)  |  UInt32(bytes[4])
        let payload = bytes.dropFirst(prefixLength)
        guard payload.count == Int(declared) else {
            throw RPCError(code: .internalError,
                           message: "gRPC message frame declares \(declared) bytes but carries "
                                  + "\(payload.count)")
        }
        return Array(payload)
    }
}
