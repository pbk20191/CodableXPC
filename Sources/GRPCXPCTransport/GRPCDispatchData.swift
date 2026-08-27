//
//  GRPCDispatchData.swift
//  CodableXPC
//
//  Created by 박병관 on 8/25/26.
//

import Foundation
import GRPCCore
import Dispatch
import XPCDispatchDataBridge
import XPC

/// The transport's `Bytes` type: gRPC's `GRPCContiguousBytes` over a `Data` that can be a **no-copy
/// view onto an `xpc_data` payload**.
///
/// `[UInt8]` would have been simpler, but it forces a copy of every message in both directions —
/// once to build the array from the received `xpc_data`, and once to rebuild a buffer on the way
/// out. `Data` can instead *reference* the bytes libxpc already holds, which is the whole reason
/// this type exists. See ``init(from:)`` for the inbound half and ``createXPCRepresentation()``
/// for the outbound half.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct GRPCSwiftData: GRPCContiguousBytes, Sendable, Equatable {

    public var data: Data

    /// `GRPCContiguousBytes`' sequence initializer. This one **does** copy — it has to, since an
    /// arbitrary `Sequence` has no buffer to borrow. gRPC calls it when it builds a message from
    /// something other than our own wire path.
    public init<Bytes>(_ sequence: Bytes) where Bytes: Sequence, Bytes.Element == UInt8 {
        self.data = Data(sequence)
    }

    public init(repeating byte: UInt8, count: Int) {
        self.data = .init(repeating: byte, count: count)
    }

    /// Adopt `data` as-is, **without copying**. A `Data` slice is a view onto its parent's buffer,
    /// so this is what keeps a payload sliced out of a received frame (see
    /// `GRPCMessageFraming.unframe`) referencing the original `xpc_data` rather than duplicating it.
    init(viewing data: Data) {
        self.data = data
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try data.withUnsafeBytes(body)
    }

    public mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        return try data.withUnsafeMutableBytes(body)
    }

    public var count: Int { data.count }

    /// The outbound half: hand the bytes to libxpc through the repo's `DispatchDataBridge`, which
    /// takes the cheaper of the two available copies (and none at all when the `Data` is already
    /// dispatch-backed).
    internal func createXPCRepresentation() -> xpc_object_t {
        return DispatchDataBridge.xpcData(for: data)
    }

    /// The inbound half: wrap an `xpc_data`'s bytes **in place**.
    ///
    /// `DispatchData(bytesNoCopy:)` borrows libxpc's buffer, and the custom deallocator holds the
    /// `xpc_object_t` alive for exactly as long as that borrow lasts — without it the pointer would
    /// dangle the moment the message handler returned. The `DispatchData -> NSData -> Data` bridge
    /// is what lets `Data` adopt that borrowed buffer instead of copying out of it.
    /// **Measured caveat: this borrows only for payloads of 15 bytes or more.** `Data` keeps small
    /// values in inline storage, so anything up to 14 bytes is copied into the struct itself no
    /// matter what it is handed. That is the right trade — the copy is at most 14 bytes — but it
    /// means "no copy" is a property of real messages, not of every message, and a test that
    /// asserts it with a tiny payload will fail for that reason alone.
    ///
    /// `xpc_data_get_bytes_ptr` returns `NULL` for a payload libxpc cannot present contiguously.
    /// There is nothing to borrow in that case, so this falls back to a copy rather than
    /// constructing a buffer over a null pointer.
    internal init(from xpc: xpc_object_t) {
        precondition(xpc_get_type(xpc) == XPC_TYPE_DATA, "must be an xpc_data_t")
        let count = xpc_data_get_length(xpc)
        guard count > 0, let head = xpc_data_get_bytes_ptr(xpc) else {
            var copied = Data(count: count)
            if count > 0 {
                copied.withUnsafeMutableBytes { _ = xpc_data_get_bytes(xpc, $0.baseAddress!, 0, count) }
            }
            self.data = copied
            return
        }

        self.data = Data(bytesNoCopy: .init(mutating: head), count: count, deallocator: .custom({ _, _ in
            withExtendedLifetime(xpc, {})
        }))
    }
}

// ===========================================================================================
// MARK: - Byte-container conveniences
// ===========================================================================================

/// It *is* a byte container, so it behaves like one: `first`, `Array(_:)`, iteration and equality
/// against a literal all work without materialising an intermediate array at the call site.
///
/// Indices are `Data`'s, **not rebased to zero** — a value produced by
/// `GRPCMessageFraming.unframe` is a slice of the received frame, so its `startIndex` is 5, not 0.
/// Subscripting from a hardcoded `0` would trap; that is `Data`'s own contract and copying it here
/// is deliberate, since hiding it would mean copying the payload to rebase it.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension GRPCSwiftData: RandomAccessCollection {
    public typealias Element = UInt8
    public typealias Index = Data.Index

    public var startIndex: Index { data.startIndex }
    public var endIndex: Index { data.endIndex }
    public subscript(position: Index) -> UInt8 { data[position] }
}

/// So a test or a caller can write `[0x01, 0x02]` where a payload is expected.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension GRPCSwiftData: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: UInt8...) {
        self.data = Data(elements)
    }
}
