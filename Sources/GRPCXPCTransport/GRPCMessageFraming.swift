import Foundation
import GRPCCore

/// gRPC's standard `Length-Prefixed-Message`:
///
///     Compressed-Flag (1 byte) | Message-Length (4 bytes, big-endian) | Message
///
/// This is the exact byte sequence gRPC carries in an HTTP/2 DATA frame, so a payload framed here
/// is byte-identical to one from any other gRPC implementation. XPC already delimits messages, so
/// the prefix is redundant for *correctness* — it is here for interoperability (see spec D4).
///
/// **Everything here works in `Data`, never `[UInt8]`.** The transport's `Bytes` is
/// ``GRPCSwiftData``, which wraps a `Data` that may be a no-copy view onto an `xpc_data` payload.
/// Materialising an `[UInt8]` at either end would copy the whole message and throw that away, so
/// `unframe` slices instead: a `Data` slice is a view onto the same buffer, not a copy.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
enum GRPCMessageFraming {

    static let prefixLength = 5

    /// Prefix `payload` with the standard 5-byte header. This one *does* allocate: the framed form
    /// has to be one contiguous buffer, and the payload is not adjacent to a spare five bytes.
    static func frame(_ payload: GRPCSwiftData) -> GRPCSwiftData {
        var out = Data(capacity: prefixLength + payload.count)
        out.append(0)                                   // compressed-flag: v1 never compresses
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(payload.data)
        return GRPCSwiftData(viewing: out)
    }

    /// Strip the header. The returned payload is a **view onto `data`**, so when `data` is a no-copy
    /// wrapper around an `xpc_data` the message never gets copied on the way in.
    static func unframe(_ framed: GRPCSwiftData) throws -> GRPCSwiftData {
        let data = framed.data
        guard data.count >= prefixLength else {
            throw RPCError(code: .internalError,
                           message: "gRPC message frame is \(data.count) bytes, shorter than its "
                                  + "\(prefixLength)-byte prefix")
        }
        // Index off `startIndex`: a sliced `Data` does not rebase to 0, and assuming it does is the
        // classic way to read the wrong bytes here.
        let base = data.startIndex
        let flag = data[base]
        guard flag == 0 else {
            throw RPCError(code: .unimplemented,
                           message: "compressed gRPC messages are not supported (flag \(flag))")
        }
        let declared = (UInt32(data[base + 1]) << 24) | (UInt32(data[base + 2]) << 16)
                     | (UInt32(data[base + 3]) << 8)  |  UInt32(data[base + 4])
        let payload = data[(base + prefixLength)...]
        guard payload.count == Int(declared) else {
            throw RPCError(code: .internalError,
                           message: "gRPC message frame declares \(declared) bytes but carries "
                                  + "\(payload.count)")
        }
        return GRPCSwiftData(viewing: payload)
    }
}
