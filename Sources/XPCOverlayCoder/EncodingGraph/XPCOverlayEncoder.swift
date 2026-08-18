import Foundation
import XPC

/// Encodes a `Codable` value into the byte stream Apple's XPC overlay expects.
///
///     let encoded = try XPCOverlayEncoder().encode(value)
///     // encoded.body      -> _CodableBody
///     // encoded.outOfLine -> _CodableOutOfLine
///
/// The output is byte-compatible with Apple's decoder. It is produced differently,
/// though: Apple walks its node graph twice so it can allocate one buffer of
/// exactly the right size, and we simply append to a growing array. Nothing about
/// the *format* requires the two-pass shape — it buys a single allocation, which is
/// a cost decision rather than a correctness one.
///
/// What the format does require is that container ids are handed out in
/// breadth-first order, because the decoder opens bodies by an ascending counter
/// rather than by matching ids. Get that wrong and the bytes are well-formed but
/// wire up the wrong children.
public struct XPCOverlayEncoder {

    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {}

    public struct Encoded {
        /// Goes under `_CodableBody`.
        public let body: Data
        /// Goes under `_CodableOutOfLine`, in order.
        public let outOfLine: [Data]
        /// Goes under `_CodableOutOfLine4CodableObject`, in order. Live XPC objects
        /// such as an `XPCEndpoint`, which the body refers to by index.
        public let outOfLineObjects: [xpc_object_t]
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func encode<T: Encodable>(_ value: T) throws -> Encoded {
        // Apple's XPCEndpoint.encode(to:) reaches into userInfo for an array to put
        // itself in. Providing one is all it takes for a live object to travel
        // through a coder written from scratch.
        var info = userInfo
        let objects = OverlayCodableObjects.install(into: &info)

        let root = OverlayEncodingNode()
        try OverlayEncoderImpl(node: root, codingPath: [], userInfo: info)
            .encodeTopLevel(value)

        let serialized = OverlaySerializer.serialize(root)
        return Encoded(body: serialized.body,
                       outOfLine: serialized.outOfLine,
                       outOfLineObjects: OverlayCodableObjects.drain(objects))
    }
}

// MARK: - Node graph

/// One container being built. A node has no kind until the value asks for a
/// container, which is how a nested `Encodable` that only ever uses a
/// single-value container ends up as a single-value container.
final class OverlayEncodingNode {
    var kind: OverlayContainerKind?
    /// Keyed entries in insertion order. `nil` is `superEncoder()`.
    var entries: [(key: String?, item: OverlayEncodingItem)] = []
    /// Unkeyed elements, or the single value.
    var items: [OverlayEncodingItem] = []

    /// Children in the order they were added, which is the order ids are assigned.
    var children: [OverlayEncodingNode] {
        let all = entries.map(\.item) + items
        return all.compactMap { if case .child(let node) = $0 { return node } else { return nil } }
    }
}

enum OverlayEncodingItem {
    case value(OverlayRawValue)
    case child(OverlayEncodingNode)
    case outOfLineData(Data)
}

// MARK: - Serializer

enum OverlaySerializer {

    static func serialize(_ root: OverlayEncodingNode) -> XPCOverlayEncoder.Encoded {
        // Breadth-first, matching how Apple assigns ids: every child of a node gets
        // the next id as the node is scanned, then the next level is scanned.
        var ids: [ObjectIdentifier: UInt32] = [:]
        var order: [OverlayEncodingNode] = []
        var queue: [OverlayEncodingNode] = [root]
        var next: UInt32 = 0
        while !queue.isEmpty {
            let node = queue.removeFirst()
            for child in node.children {
                ids[ObjectIdentifier(child)] = next
                next += 1
                order.append(child)
                queue.append(child)
            }
        }

        var bytes: [UInt8] = []
        var outOfLine: [Data] = []
        emit(root, into: &bytes, ids: ids, outOfLine: &outOfLine)
        for node in order {
            bytes.append(OverlayTag.containerStart.rawValue)
            emit(node, into: &bytes, ids: ids, outOfLine: &outOfLine)
        }
        return .init(body: Data(bytes), outOfLine: outOfLine, outOfLineObjects: [])
    }

    private static func emit(_ node: OverlayEncodingNode,
                             into bytes: inout [UInt8],
                             ids: [ObjectIdentifier: UInt32],
                             outOfLine: inout [Data]) {
        // A node nobody asked a container of still has to declare a kind. Apple
        // seeds every node with keyed metadata at construction, so an empty value
        // serialises as an empty keyed container.
        let kind = node.kind ?? .keyed
        bytes.append(OverlayTag.containerMetadata.rawValue)
        bytes.append(kind.rawValue)

        if kind == .keyed {
            for entry in node.entries {
                if let key = entry.key {
                    bytes.append(OverlayTag.key.rawValue)
                    writeString(key, into: &bytes)
                } else {
                    bytes.append(OverlayTag.keyNil.rawValue)
                }
                emit(entry.item, into: &bytes, ids: ids, outOfLine: &outOfLine)
            }
        } else {
            for item in node.items {
                emit(item, into: &bytes, ids: ids, outOfLine: &outOfLine)
            }
        }
    }

    private static func emit(_ item: OverlayEncodingItem,
                             into bytes: inout [UInt8],
                             ids: [ObjectIdentifier: UInt32],
                             outOfLine: inout [Data]) {
        switch item {
        case .child(let node):
            bytes.append(OverlayTag.containerReference.rawValue)
            write(UInt32(ids[ObjectIdentifier(node)] ?? 0), into: &bytes)
        case .outOfLineData(let data):
            bytes.append(OverlayTag.outOfLineData.rawValue)
            write(UInt32(outOfLine.count), into: &bytes)
            outOfLine.append(data)
        case .value(let value):
            emit(value, into: &bytes)
        }
    }

    private static func emit(_ value: OverlayRawValue, into bytes: inout [UInt8]) {
        switch value {
        case .null: bytes.append(OverlayTag.null.rawValue)
        case .bool(let v):
            bytes.append((v ? OverlayTag.boolTrue : .boolFalse).rawValue)
        case .string(let v):
            bytes.append(OverlayTag.string.rawValue); writeString(v, into: &bytes)
        case .float(let v):
            bytes.append(OverlayTag.float.rawValue); write(v.bitPattern, into: &bytes)
        case .double(let v):
            bytes.append(OverlayTag.double.rawValue); write(v.bitPattern, into: &bytes)
        case .int(let v):
            bytes.append(OverlayTag.int.rawValue); write(UInt64(bitPattern: Int64(v)), into: &bytes)
        case .int8(let v):
            bytes.append(OverlayTag.int8.rawValue); bytes.append(UInt8(bitPattern: v))
        case .int16(let v):
            bytes.append(OverlayTag.int16.rawValue); write(UInt16(bitPattern: v), into: &bytes)
        case .int32(let v):
            bytes.append(OverlayTag.int32.rawValue); write(UInt32(bitPattern: v), into: &bytes)
        case .int64(let v):
            bytes.append(OverlayTag.int64.rawValue); write(UInt64(bitPattern: v), into: &bytes)
        case .uint(let v):
            bytes.append(OverlayTag.uint.rawValue); write(UInt64(v), into: &bytes)
        case .uint8(let v):
            bytes.append(OverlayTag.uint8.rawValue); bytes.append(v)
        case .uint16(let v):
            bytes.append(OverlayTag.uint16.rawValue); write(v, into: &bytes)
        case .uint32(let v):
            bytes.append(OverlayTag.uint32.rawValue); write(v, into: &bytes)
        case .uint64(let v):
            bytes.append(OverlayTag.uint64.rawValue); write(v, into: &bytes)
        case .key, .containerKind, .containerReference, .outOfLineData:
            preconditionFailure("structural values are emitted by their own path")
        }
    }

    /// `UInt64` byte count, the UTF-8 bytes, then a NUL that the count excludes.
    private static func writeString(_ string: String, into bytes: inout [UInt8]) {
        let utf8 = Array(string.utf8)
        write(UInt64(utf8.count), into: &bytes)
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    private static func write<T: FixedWidthInteger & UnsignedInteger>(
        _ value: T, into bytes: inout [UInt8]) {
        for index in 0..<MemoryLayout<T>.size {
            bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index)))
        }
    }
}
