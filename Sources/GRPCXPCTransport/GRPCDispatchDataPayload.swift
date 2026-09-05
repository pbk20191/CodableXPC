//
//  GRPCDispatchDataPayload.swift
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
///
/// # The name
///
/// This was `GRPCSwiftData` until this branch, and the rename is the whole of what changed -- no
/// member, no behaviour and no wire byte moved with it. `GRPCSwiftData` reads as "gRPC + SwiftData",
/// i.e. as something to do with Apple's persistence framework, which an adopter importing both
/// `SwiftData` and this module would have to disambiguate at every mention of a bytes type that has
/// nothing to do with persistence. It is a public type, so before this branch merges was the last
/// moment the rename was free rather than API churn.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct GRPCDispatchDataPayload: GRPCContiguousBytes, Sendable, Equatable {

    /// The bytes. **Read-only from outside**, and that is load-bearing rather than tidiness: this
    /// value carries ``borrowsXPCStorage`` alongside it, and a setter would let a caller drop in a
    /// borrowed `Data` under a `false` flag — which is exactly the state
    /// ``withUnsafeMutableBytes(_:)`` exists to prevent.
    public private(set) var data: Data

    /// `true` when ``data`` is (or may be) a no-copy view onto memory **libxpc owns** — a
    /// `Data(bytesNoCopy:)` built by ``init(from:)``, or a slice of one adopted by
    /// ``init(viewing:)``.
    ///
    /// It exists because `Data`'s own copy-on-write cannot tell: `Data(bytesNoCopy:deallocator:)`
    /// believes it owns its buffer, so a mutation through the *sole* reference to it writes
    /// straight into libxpc's storage (measured — `GRPCDispatchDataPayloadTests`). Every other `Data` in
    /// this type is genuinely owned, so the flag, not the `Data`, is what says which.
    private var borrowsXPCStorage: Bool

    /// `GRPCContiguousBytes`' sequence initializer. This one **does** copy — it has to, since an
    /// arbitrary `Sequence` has no buffer to borrow. gRPC calls it when it builds a message from
    /// something other than our own wire path.
    public init<Bytes>(_ sequence: Bytes) where Bytes: Sequence, Bytes.Element == UInt8 {
        self.data = Data(sequence)
        self.borrowsXPCStorage = false
    }

    public init(repeating byte: UInt8, count: Int) {
        self.data = .init(repeating: byte, count: count)
        self.borrowsXPCStorage = false
    }

    /// Adopt `data` as-is, **without copying**. A `Data` slice is a view onto its parent's buffer,
    /// so this is what keeps a message body sliced out of a received blob (see
    /// `CompactWireCodec.decode`) referencing the original `xpc_data` rather than duplicating it.
    ///
    /// `borrowsXPCStorage` defaults to `true` because that is the safe answer for a caller that
    /// did not think about it: the one caller that matters (`CompactWireCodec.decode`) really is
    /// handing over a slice of a received `xpc_data` blob, and the cost of the default being
    /// pessimistic for a caller adopting an owned `Data` is one copy on a mutation that may never
    /// happen. Getting it wrong the other way is a write into libxpc's buffer.
    init(viewing data: Data, borrowsXPCStorage: Bool = true) {
        self.data = data
        self.borrowsXPCStorage = borrowsXPCStorage
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try data.withUnsafeBytes(body)
    }

    /// `GRPCContiguousBytes` requires this, and an application handler is free to call it on a
    /// message body it received — so it must never hand out a writable pointer into the
    /// `xpc_object_t` the body was decoded from. Doing so is either an `EXC_BAD_ACCESS` (a
    /// read-only out-of-line mapping) or silent corruption of every other view of the same blob.
    ///
    /// **Copy-on-first-mutation, paid only by a mutation.** The read path is untouched: a borrowed
    /// value that is only ever read still references libxpc's buffer, at any size.
    ///
    /// # Why the extra reference is the copy
    ///
    /// `data = <a fresh copy>` would work too, but a fresh `Data` starts at index `0` — and this
    /// type documents that its indices are `Data`'s and do **not** rebase (a decoded body starts
    /// at the op header's length, not at `0`). Holding a second reference to the storage instead
    /// makes `Data` do the copy itself, through the one guarantee `bytesNoCopy` does *not* break:
    /// a value type whose storage is not uniquely referenced copies before it mutates. `Data`'s
    /// own copy keeps the slice's index base, so a mutated body still starts where it started.
    ///
    /// `pinned` must outlive the mutable access, not merely be assigned before it — hence
    /// `withExtendedLifetime` rather than trusting the lexical scope. Measured at `-O` and
    /// `-Onone`; `testMutatingAReceivedBodyDoesNotWriteLibxpcsBuffer` is what keeps it measured.
    public mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        guard borrowsXPCStorage else { return try data.withUnsafeMutableBytes(body) }
        let pinned = data
        defer {
            withExtendedLifetime(pinned) {}
            // The storage `data` now points at is `Data`'s own; there is nothing left to borrow.
            borrowsXPCStorage = false
        }
        return try data.withUnsafeMutableBytes(body)
    }

    /// Hand-written because the synthesized `==` would compare ``borrowsXPCStorage`` too, and
    /// where a value's bytes live is not part of its value: the same payload read out of an
    /// `xpc_data` and built from an array literal must compare equal.
    public static func == (lhs: GRPCDispatchDataPayload, rhs: GRPCDispatchDataPayload) -> Bool {
        lhs.data == rhs.data
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
            self.borrowsXPCStorage = false
            return
        }

        self.data = Data(bytesNoCopy: .init(mutating: head), count: count, deallocator: .custom({ _, _ in
            withExtendedLifetime(xpc, {})
        }))
        // The whole point of the branch above: this `Data` is a window onto libxpc's memory, and
        // `withUnsafeMutableBytes` must copy before it writes. (For a payload of 14 bytes or fewer
        // `Data` has already copied into inline storage, so the flag is pessimistic there — one
        // 14-byte copy on a mutation, rather than a size test that would have to stay in step with
        // Foundation's threshold.)
        self.borrowsXPCStorage = true
    }
}

// ===========================================================================================
// MARK: - Byte-container conveniences
// ===========================================================================================

/// It *is* a byte container, so it behaves like one: `first`, `Array(_:)`, iteration and equality
/// against a literal all work without materialising an intermediate array at the call site.
///
/// Indices are `Data`'s, **not rebased to zero** — a message body decoded by
/// `CompactWireCodec.decode` is a slice of the received blob, so its `startIndex` is 10 (the op
/// header's length), not 0.
/// Subscripting from a hardcoded `0` would trap; that is `Data`'s own contract and copying it here
/// is deliberate, since hiding it would mean copying the payload to rebase it.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension GRPCDispatchDataPayload: RandomAccessCollection {
    public typealias Element = UInt8
    public typealias Index = Data.Index

    public var startIndex: Index { data.startIndex }
    public var endIndex: Index { data.endIndex }
    public subscript(position: Index) -> UInt8 { data[position] }
}

/// So a test or a caller can write `[0x01, 0x02]` where a payload is expected.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension GRPCDispatchDataPayload: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: UInt8...) {
        self.data = Data(elements)
        self.borrowsXPCStorage = false
    }
}
