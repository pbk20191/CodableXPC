import Foundation

/// Decodes a `Codable` value from the byte stream Apple's XPC overlay produces.
///
///     let value = try XPCOverlayDecoder().decode(
///         Reading.self, from: body, outOfLine: blobs)
///
/// `body` is the `_CodableBody` payload and `outOfLine` is `_CodableOutOfLine`, in
/// order. Both come off the message dictionary; this type takes `Data` rather than
/// `xpc_object_t` so the format work stays testable without a live connection.
///
/// ## Strictness
///
/// Types must match exactly, which is what Apple's own decoder does on this path:
/// an `Int64` on the wire will not satisfy an `Int` field, and an integer will not
/// satisfy a `Double`. That looks harsh until you notice the format has a distinct
/// tag per width, so a mismatch means the two sides disagree about the type rather
/// than about its range.
public struct XPCOverlayDecoder {

    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {}

    public func decode<T: Decodable>(
        _ type: T.Type = T.self,
        from body: Data,
        outOfLine: [Data] = []
    ) throws -> T {
        let (root, containers) = try OverlayStreamReader.parse(body)
        let node = try OverlayValue.resolve(root, in: containers)
        let decoder = OverlayDecoderImpl(
            value: .container(node), codingPath: [], userInfo: userInfo, outOfLine: outOfLine)
        return try decoder.decodeTopLevel(type)
    }
}

// MARK: - Decoder

final class OverlayDecoderImpl: Decoder {
    let value: OverlayValue
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let outOfLine: [Data]

    init(value: OverlayValue,
         codingPath: [any CodingKey],
         userInfo: [CodingUserInfoKey: Any],
         outOfLine: [Data]) {
        self.value = value
        self.codingPath = codingPath
        self.userInfo = userInfo
        self.outOfLine = outOfLine
    }

    /// Apple checks for the `Data` shape before ever calling `init(from:)`, and so
    /// must we: `Data.init(from:)` expects a run of `UInt8` elements and would fail
    /// on the single out-of-line reference the encoder actually wrote.
    func decodeTopLevel<T: Decodable>(_ type: T.Type) throws -> T {
        if let data = try foundationData() as? T { return data }
        return try T(from: self)
    }

    private func foundationData() throws -> Data? {
        guard case .container(let node) = value, let index = node.foundationDataIndex else {
            return nil
        }
        guard Int(index) < outOfLine.count else {
            throw OverlayCoderError.outOfLineIndexOutOfRange(index)
        }
        return outOfLine[Int(index)]
    }

    private func node() throws -> OverlayNode {
        guard case .container(let node) = value else {
            throw DecodingError.typeMismatch(OverlayNode.self, .init(
                codingPath: codingPath, debugDescription: "expected a container"))
        }
        return node
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type)
    throws -> KeyedDecodingContainer<Key> {
        let node = try unwrapSingleValueWrapper(try node())
        guard node.kind == .keyed else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "expected a keyed container, found \(node.kind)"))
        }
        return KeyedDecodingContainer(OverlayKeyedContainer(node: node, decoder: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let node = try unwrapSingleValueWrapper(try node())
        guard node.kind == .unkeyed else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "expected an unkeyed container, found \(node.kind)"))
        }
        return OverlayUnkeyedContainer(node: node, decoder: self)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        OverlaySingleValueContainer(value: value, decoder: self)
    }

    /// Every nested `Encodable` is wrapped in a single-value container by the
    /// encoder, so a request for a keyed or unkeyed container has to see through
    /// one level of that. Apple's containers do the same unwrap in their `init`.
    private func unwrapSingleValueWrapper(_ node: OverlayNode) throws -> OverlayNode {
        guard node.kind == .singleValue, node.elements.count == 1,
              case .container(let inner) = node.elements[0] else { return node }
        return inner
    }

    func child(_ value: OverlayValue, forKey key: (any CodingKey)?) -> OverlayDecoderImpl {
        OverlayDecoderImpl(value: value,
                           codingPath: key.map { codingPath + [$0] } ?? codingPath,
                           userInfo: userInfo,
                           outOfLine: outOfLine)
    }

    // MARK: primitive extraction

    func unwrap<T>(_ value: OverlayValue, as type: T.Type, at path: [any CodingKey]) throws -> T {
        if let extracted = Self.extract(value) as? T { return extracted }
        throw DecodingError.typeMismatch(type, .init(
            codingPath: path,
            debugDescription: "expected \(type), found \(Self.describe(value))"))
    }

    /// Exact widths only, deliberately. See the note on ``XPCOverlayDecoder``.
    private static func extract(_ value: OverlayValue) -> Any? {
        switch value {
        case .bool(let v): return v
        case .string(let v): return v
        case .float(let v): return v
        case .double(let v): return v
        case .int(let v): return v
        case .int8(let v): return v
        case .int16(let v): return v
        case .int32(let v): return v
        case .int64(let v): return v
        case .uint(let v): return v
        case .uint8(let v): return v
        case .uint16(let v): return v
        case .uint32(let v): return v
        case .uint64(let v): return v
        case .null, .outOfLineData, .container: return nil
        }
    }

    static func describe(_ value: OverlayValue) -> String {
        switch value {
        case .null: return "null"
        case .container(let node): return "a \(node.kind) container"
        case .outOfLineData: return "out-of-line data"
        default: return String(describing: extract(value).map { type(of: $0) } ?? Any.self)
        }
    }

    static func isNull(_ value: OverlayValue) -> Bool {
        if case .null = value { return true }
        // A nested nil arrives wrapped in its own single-value container.
        if case .container(let node) = value, node.kind == .singleValue,
           node.elements.count == 1, case .null = node.elements[0] { return true }
        return false
    }
}

// MARK: - Keyed

private struct OverlayKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let node: OverlayNode
    let decoder: OverlayDecoderImpl

    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { node.entries.compactMap { $0.key.flatMap(Key.init(stringValue:)) } }

    func contains(_ key: Key) -> Bool { node.byKey[key.stringValue] != nil }

    private func value(for key: Key) throws -> OverlayValue {
        guard let value = node.byKey[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath, debugDescription: "no value for \(key.stringValue)"))
        }
        return value
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        // An absent key throws rather than reporting nil, matching Apple and the
        // Codable contract: `decodeNil` answers "is the present value null".
        OverlayDecoderImpl.isNull(try value(for: key))
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try decoder.child(try value(for: key), forKey: key).decodeTopLevel(type)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try primitive(type, key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try primitive(type, key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try primitive(type, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try primitive(type, key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try primitive(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try primitive(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try primitive(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try primitive(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try primitive(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try primitive(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try primitive(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try primitive(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try primitive(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try primitive(type, key) }

    private func primitive<T>(_ type: T.Type, _ key: Key) throws -> T {
        try decoder.unwrap(try value(for: key), as: type, at: codingPath + [key])
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key)
    throws -> KeyedDecodingContainer<NestedKey> {
        try decoder.child(try value(for: key), forKey: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try decoder.child(try value(for: key), forKey: key).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        guard let value = node.superValue else {
            throw DecodingError.keyNotFound(OverlaySuperKey(), .init(
                codingPath: codingPath, debugDescription: "no super value"))
        }
        return decoder.child(value, forKey: OverlaySuperKey())
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        decoder.child(try value(for: key), forKey: key)
    }
}

private struct OverlaySuperKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }
    init() {}
    init?(stringValue: String) { nil }
    init?(intValue: Int) { nil }
}

// MARK: - Unkeyed

private struct OverlayUnkeyedContainer: UnkeyedDecodingContainer {
    let node: OverlayNode
    let decoder: OverlayDecoderImpl
    var currentIndex = 0

    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { node.elements.count }
    var isAtEnd: Bool { currentIndex >= node.elements.count }

    private mutating func next() throws -> OverlayValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(OverlayValue.self, .init(
                codingPath: codingPath, debugDescription: "unkeyed container is at end"))
        }
        defer { currentIndex += 1 }
        return node.elements[currentIndex]
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(OverlayValue.self, .init(
                codingPath: codingPath, debugDescription: "unkeyed container is at end"))
        }
        // Only consume on a real nil, which is what Codable requires.
        guard OverlayDecoderImpl.isNull(node.elements[currentIndex]) else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let key = OverlayIndexKey(currentIndex)
        return try decoder.child(try next(), forKey: key).decodeTopLevel(type)
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try primitive(type) }
    mutating func decode(_ type: String.Type) throws -> String { try primitive(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try primitive(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try primitive(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try primitive(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try primitive(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try primitive(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try primitive(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try primitive(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try primitive(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try primitive(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try primitive(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try primitive(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try primitive(type) }

    private mutating func primitive<T>(_ type: T.Type) throws -> T {
        let path = codingPath + [OverlayIndexKey(currentIndex)]
        return try decoder.unwrap(try next(), as: type, at: path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type)
    throws -> KeyedDecodingContainer<NestedKey> {
        let key = OverlayIndexKey(currentIndex)
        return try decoder.child(try next(), forKey: key).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let key = OverlayIndexKey(currentIndex)
        return try decoder.child(try next(), forKey: key).unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        let key = OverlayIndexKey(currentIndex)
        return decoder.child(try next(), forKey: key)
    }
}

struct OverlayIndexKey: CodingKey {
    let index: Int
    init(_ index: Int) { self.index = index }
    var stringValue: String { "Index \(index)" }
    var intValue: Int? { index }
    init?(stringValue: String) { nil }
    init?(intValue: Int) { self.init(intValue) }
}

// MARK: - Single value

private struct OverlaySingleValueContainer: SingleValueDecodingContainer {
    let value: OverlayValue
    let decoder: OverlayDecoderImpl

    var codingPath: [any CodingKey] { decoder.codingPath }

    /// The encoder wraps a bare primitive in its own single-value container, so a
    /// request for the value has to look through that.
    private var effective: OverlayValue {
        if case .container(let node) = value, node.kind == .singleValue,
           node.elements.count == 1 { return node.elements[0] }
        return value
    }

    func decodeNil() -> Bool { OverlayDecoderImpl.isNull(value) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try decoder.child(effective, forKey: nil).decodeTopLevel(type)
    }

    func decode(_ type: Bool.Type) throws -> Bool { try primitive(type) }
    func decode(_ type: String.Type) throws -> String { try primitive(type) }
    func decode(_ type: Double.Type) throws -> Double { try primitive(type) }
    func decode(_ type: Float.Type) throws -> Float { try primitive(type) }
    func decode(_ type: Int.Type) throws -> Int { try primitive(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try primitive(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try primitive(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try primitive(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try primitive(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try primitive(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try primitive(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try primitive(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try primitive(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try primitive(type) }

    private func primitive<T>(_ type: T.Type) throws -> T {
        try decoder.unwrap(effective, as: type, at: codingPath)
    }
}
