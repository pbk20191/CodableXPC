import Foundation
import XPC

/// Encodes a `Codable` value into the pre-graph overlay byte stream.
///
///     let encoded = try XPCLegacyOverlayEncoder().encode(value)
///     // encoded.body             -> _CodableBody
///     // encoded.outOfLineObjects -> _CodableOutOfLine
///
/// Checked against Apple's own iOS 18 coder, which an iOS 18.6 simulator runtime
/// still exports as `XPCEncoder`/`XPCDecoder` — the byte-level pair the macOS
/// build folded away. Every shape this module claims to handle round-trips in
/// both directions there, and where the format leaves no ordering freedom the
/// bytes are identical. See `Tools/verify-legacy-against-ios18.sh`.
///
/// - Note: keyed entries are not ordered by the format. Apple emits them in
///   `Dictionary` hash order, which is seeded per process, so two encoders
///   agreeing on content will disagree on byte order for any keyed container.
public struct XPCLegacyOverlayEncoder {

    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// Which build to write for. See ``LegacyOverlayGeneration``.
    public var generation: LegacyOverlayGeneration = .iOS18

    public init() {}
    public init(generation: LegacyOverlayGeneration) { self.generation = generation }

    public struct Encoded {
        /// Goes under `_CodableBody`.
        public let body: Data
        /// The same content as ``body`` before serialisation, for callers
        /// assembling an envelope themselves or asserting on structure.
        public let tree: LegacyOverlayValue
        /// Goes under `_CodableOutOfLine`, in order. Live XPC objects such as an
        /// `XPCEndpoint`, which the body refers to by index.
        public let outOfLineObjects: [xpc_object_t]
    }

    /// Encoding is one call rather than a body call and an objects call, because a
    /// value that put an `XPCEndpoint` in the side array produces a body that is
    /// meaningless without it. Splitting them would let a caller keep the half
    /// that decodes into a dangling index.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func encode<T: Encodable>(_ value: T) throws -> Encoded {
        // Apple's XPCEndpoint.encode(to:) reaches into userInfo for an array to put
        // itself in, and throws CodingUserInfoKeyNotFound when there is none.
        // Providing one is all it takes for a live object to travel through a coder
        // written from scratch.
        var info = userInfo
        // iOS 17 has no side array, and installing one would let a Data or an
        // XPCEndpoint encode in a shape that build cannot read.
        let objects = generation.carriesOutOfLineObjects
            ? LegacyCodableObjects.install(into: &info)
            : nil

        let root = LegacyEncodingNode()
        try LegacyEncoderImpl(node: root, codingPath: [], userInfo: info)
            .encodeTopLevel(value)

        let tree = root.materialise()
        return Encoded(body: LegacyOverlayStreamWriter.serialize(tree),
                       tree: tree,
                       outOfLineObjects: objects.map(LegacyCodableObjects.drain) ?? [])
    }
}

/// Failures raised while encoding, as opposed to by the value being encoded.
public enum LegacyOverlayEncodingError: Error, Equatable {
    /// Apple's encoder traps here. Throwing is strictly better behaviour for the
    /// same programmer error, and it does not change the format.
    case duplicateKey(String)
    /// A single-value container that was never written. Apple traps on this too.
    case emptySingleValueContainer
}

// MARK: - Node graph

/// A container under construction.
///
/// A node has no kind until something asks for a container, which matters because
/// a single-value container is transparent: a node that only ever held a leaf
/// materialises as that leaf, with no container framing around it.
final class LegacyEncodingNode {
    enum Kind { case keyed, unkeyed, single }

    var kind: Kind?
    var leaf: LegacyOverlayValue?
    var entries: [(key: String, node: LegacyEncodingNode)] = []
    var elements: [LegacyEncodingNode] = []

    func materialise() -> LegacyOverlayValue {
        switch kind {
        case .keyed:
            return .keyed(entries.map { .init(key: $0.key, value: $0.node.materialise()) })
        case .unkeyed:
            return .unkeyed(elements.map { $0.materialise() })
        case .single, nil:
            // Transparent. A node nobody wrote to at all becomes null rather than
            // producing a zero-length value region.
            return leaf ?? .null
        }
    }

    /// Reuse the node already stored under `key`, matching Apple's
    /// `SharableStorageContainer.getExisting` — asking twice for the same nested
    /// container returns the same one rather than adding a second entry.
    func existingChild(forKey key: String) -> LegacyEncodingNode? {
        entries.first { $0.key == key }?.node
    }
}

// MARK: - Encoder

final class LegacyEncoderImpl: Encoder {
    let node: LegacyEncodingNode
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    init(node: LegacyEncodingNode, codingPath: [any CodingKey], userInfo: [CodingUserInfoKey: Any]) {
        self.node = node
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    func encodeTopLevel<T: Encodable>(_ value: T) throws {
        // A top-level Data never reaches a container, so the hook has to be here
        // too -- otherwise it writes its own byte run and Apple reads an index.
        if let data = value as? Data, LegacyOutOfLineData.isEnabled(userInfo) {
            node.kind = .single
            node.leaf = .int(try LegacyOutOfLineData.append(data, to: userInfo))
            return
        }
        try value.encode(to: self)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.kind = .keyed
        return KeyedEncodingContainer(LegacyKeyedEncodingContainer(encoder: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        node.kind = .unkeyed
        return LegacyUnkeyedEncodingContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        node.kind = .single
        return LegacySingleValueEncodingContainer(encoder: self)
    }

    func child(forKey key: (any CodingKey)?) -> (LegacyEncodingNode, LegacyEncoderImpl) {
        let child = LegacyEncodingNode()
        return (child, LegacyEncoderImpl(
            node: child,
            codingPath: key.map { codingPath + [$0] } ?? codingPath,
            userInfo: userInfo))
    }
}

/// The key `superEncoder()` stores under, which Apple spells `"super"`.
struct LegacySuperKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }
    init() {}
    init?(stringValue: String) { nil }
    init?(intValue: Int) { nil }
}

struct LegacyIndexKey: CodingKey {
    let index: Int
    init(_ index: Int) { self.index = index }
    var stringValue: String { "Index \(index)" }
    var intValue: Int? { index }
    init?(stringValue: String) { nil }
    init?(intValue: Int) { self.init(intValue) }
}

// MARK: - Keyed

private struct LegacyKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: LegacyEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }

    private func put(_ value: LegacyOverlayValue, _ key: String) throws {
        guard encoder.node.existingChild(forKey: key) == nil else {
            throw LegacyOverlayEncodingError.duplicateKey(key)
        }
        let leafNode = LegacyEncodingNode()
        leafNode.leaf = value
        encoder.node.entries.append((key, leafNode))
    }

    mutating func encodeNil(forKey key: Key) throws { try put(.null, key.stringValue) }

    mutating func encode(_ v: Bool, forKey key: Key) throws { try put(.bool(v), key.stringValue) }
    mutating func encode(_ v: String, forKey key: Key) throws { try put(.string(v), key.stringValue) }
    mutating func encode(_ v: Double, forKey key: Key) throws { try put(.double(v), key.stringValue) }
    mutating func encode(_ v: Float, forKey key: Key) throws { try put(.float(v), key.stringValue) }
    mutating func encode(_ v: Int, forKey key: Key) throws { try put(.int(v), key.stringValue) }
    mutating func encode(_ v: Int8, forKey key: Key) throws { try put(.int8(v), key.stringValue) }
    mutating func encode(_ v: Int16, forKey key: Key) throws { try put(.int16(v), key.stringValue) }
    mutating func encode(_ v: Int32, forKey key: Key) throws { try put(.int32(v), key.stringValue) }
    mutating func encode(_ v: Int64, forKey key: Key) throws { try put(.int64(v), key.stringValue) }
    mutating func encode(_ v: UInt, forKey key: Key) throws { try put(.uint(v), key.stringValue) }
    mutating func encode(_ v: UInt8, forKey key: Key) throws { try put(.uint8(v), key.stringValue) }
    mutating func encode(_ v: UInt16, forKey key: Key) throws { try put(.uint16(v), key.stringValue) }
    mutating func encode(_ v: UInt32, forKey key: Key) throws { try put(.uint32(v), key.stringValue) }
    mutating func encode(_ v: UInt64, forKey key: Key) throws { try put(.uint64(v), key.stringValue) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        if let data = value as? Data, LegacyOutOfLineData.isEnabled(encoder.userInfo) {
            try put(.int(LegacyOutOfLineData.append(data, to: encoder.userInfo)), key.stringValue)
            return
        }
        let (child, childEncoder) = try newChild(forKey: key)
        try value.encode(to: childEncoder)
        _ = child
    }

    private mutating func newChild(forKey key: Key) throws -> (LegacyEncodingNode, LegacyEncoderImpl) {
        guard encoder.node.existingChild(forKey: key.stringValue) == nil else {
            throw LegacyOverlayEncodingError.duplicateKey(key.stringValue)
        }
        let (child, childEncoder) = encoder.child(forKey: key)
        encoder.node.entries.append((key.stringValue, child))
        return (child, childEncoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        // Asking twice for the same key returns the same container, as Apple's
        // getExisting does, rather than adding a second entry under one key.
        if let existing = encoder.node.existingChild(forKey: key.stringValue) {
            return LegacyEncoderImpl(node: existing,
                                     codingPath: encoder.codingPath + [key],
                                     userInfo: encoder.userInfo).container(keyedBy: keyType)
        }
        let child = LegacyEncodingNode()
        encoder.node.entries.append((key.stringValue, child))
        return LegacyEncoderImpl(node: child,
                                 codingPath: encoder.codingPath + [key],
                                 userInfo: encoder.userInfo).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        if let existing = encoder.node.existingChild(forKey: key.stringValue) {
            return LegacyEncoderImpl(node: existing,
                                     codingPath: encoder.codingPath + [key],
                                     userInfo: encoder.userInfo).unkeyedContainer()
        }
        let child = LegacyEncodingNode()
        encoder.node.entries.append((key.stringValue, child))
        return LegacyEncoderImpl(node: child,
                                 codingPath: encoder.codingPath + [key],
                                 userInfo: encoder.userInfo).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let child = LegacyEncodingNode()
        encoder.node.entries.append((LegacySuperKey().stringValue, child))
        return LegacyEncoderImpl(node: child,
                                 codingPath: encoder.codingPath + [LegacySuperKey()],
                                 userInfo: encoder.userInfo)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        let child = LegacyEncodingNode()
        encoder.node.entries.append((key.stringValue, child))
        return LegacyEncoderImpl(node: child,
                                 codingPath: encoder.codingPath + [key],
                                 userInfo: encoder.userInfo)
    }
}

// MARK: - Unkeyed

private struct LegacyUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: LegacyEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int { encoder.node.elements.count }

    private func put(_ value: LegacyOverlayValue) {
        let node = LegacyEncodingNode()
        node.leaf = value
        encoder.node.elements.append(node)
    }

    mutating func encodeNil() throws { put(.null) }

    mutating func encode(_ v: Bool) throws { put(.bool(v)) }
    mutating func encode(_ v: String) throws { put(.string(v)) }
    mutating func encode(_ v: Double) throws { put(.double(v)) }
    mutating func encode(_ v: Float) throws { put(.float(v)) }
    mutating func encode(_ v: Int) throws { put(.int(v)) }
    mutating func encode(_ v: Int8) throws { put(.int8(v)) }
    mutating func encode(_ v: Int16) throws { put(.int16(v)) }
    mutating func encode(_ v: Int32) throws { put(.int32(v)) }
    mutating func encode(_ v: Int64) throws { put(.int64(v)) }
    mutating func encode(_ v: UInt) throws { put(.uint(v)) }
    mutating func encode(_ v: UInt8) throws { put(.uint8(v)) }
    mutating func encode(_ v: UInt16) throws { put(.uint16(v)) }
    mutating func encode(_ v: UInt32) throws { put(.uint32(v)) }
    mutating func encode(_ v: UInt64) throws { put(.uint64(v)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let data = value as? Data, LegacyOutOfLineData.isEnabled(encoder.userInfo) {
            put(.int(try LegacyOutOfLineData.append(data, to: encoder.userInfo)))
            return
        }
        let (child, childEncoder) = encoder.child(forKey: LegacyIndexKey(count))
        encoder.node.elements.append(child)
        try value.encode(to: childEncoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let (child, childEncoder) = encoder.child(forKey: LegacyIndexKey(count))
        encoder.node.elements.append(child)
        return childEncoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let (child, childEncoder) = encoder.child(forKey: LegacyIndexKey(count))
        encoder.node.elements.append(child)
        return childEncoder.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let (child, childEncoder) = encoder.child(forKey: LegacyIndexKey(count))
        encoder.node.elements.append(child)
        return childEncoder
    }
}

// MARK: - Single value

private struct LegacySingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: LegacyEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }

    private func put(_ value: LegacyOverlayValue) { encoder.node.leaf = value }

    mutating func encodeNil() throws { put(.null) }

    mutating func encode(_ v: Bool) throws { put(.bool(v)) }
    mutating func encode(_ v: String) throws { put(.string(v)) }
    mutating func encode(_ v: Double) throws { put(.double(v)) }
    mutating func encode(_ v: Float) throws { put(.float(v)) }
    mutating func encode(_ v: Int) throws { put(.int(v)) }
    mutating func encode(_ v: Int8) throws { put(.int8(v)) }
    mutating func encode(_ v: Int16) throws { put(.int16(v)) }
    mutating func encode(_ v: Int32) throws { put(.int32(v)) }
    mutating func encode(_ v: Int64) throws { put(.int64(v)) }
    mutating func encode(_ v: UInt) throws { put(.uint(v)) }
    mutating func encode(_ v: UInt8) throws { put(.uint8(v)) }
    mutating func encode(_ v: UInt16) throws { put(.uint16(v)) }
    mutating func encode(_ v: UInt32) throws { put(.uint32(v)) }
    mutating func encode(_ v: UInt64) throws { put(.uint64(v)) }

    /// Encoding into the same node, not a child: the container is transparent, so
    /// whatever the value writes becomes this node's own content.
    mutating func encode<T: Encodable>(_ value: T) throws {
        if let data = value as? Data, LegacyOutOfLineData.isEnabled(encoder.userInfo) {
            put(.int(try LegacyOutOfLineData.append(data, to: encoder.userInfo)))
            return
        }
        try value.encode(to: encoder)
    }
}
