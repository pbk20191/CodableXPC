import Foundation
import XPC

/// Decodes a `Codable` value from the pre-graph overlay byte stream.
///
/// Strictness matches Apple's: an exact tag match or a `typeMismatch`. The format
/// keeps a distinct tag per integer width, so a mismatch means the two sides
/// disagree about the type rather than about the range.
///
/// Verified against Apple's iOS 18 coder. See ``XPCLegacyOverlayEncoder``.
public struct XPCLegacyOverlayDecoder {

    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// Which build produced the message. See ``LegacyOverlayGeneration``.
    public var generation: LegacyOverlayGeneration = .iOS18

    public init() {}
    public init(generation: LegacyOverlayGeneration) { self.generation = generation }

    /// - Parameter outOfLineObjects: whatever arrived under `_CodableOutOfLine`.
    ///   The array is installed unconditionally, even when empty, because that is
    ///   what the framework does.
    ///
    /// - Warning: pass the array that came with the body. Apple's
    ///   `XPCEndpoint.init(from:)` resolves its index with `xpc_array_get_value`,
    ///   which **aborts the process** on an out-of-range index rather than
    ///   throwing. A body separated from its side array is not a decoding error
    ///   you can catch; it is a `SIGTRAP`. Nothing on this side can guard it,
    ///   because only the value being decoded knows which integers are indices.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func decode<T: Decodable>(_ type: T.Type = T.self, from body: Data,
                                     outOfLineObjects: [xpc_object_t] = []) throws -> T {
        try decode(type, from: try LegacyOverlayStreamReader.parse(body),
                   outOfLineObjects: outOfLineObjects)
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    public func decode<T: Decodable>(_ type: T.Type = T.self,
                                     from value: LegacyOverlayValue,
                                     outOfLineObjects: [xpc_object_t] = []) throws -> T {
        var info = userInfo
        if generation.carriesOutOfLineObjects {
            LegacyCodableObjects.install(outOfLineObjects, into: &info)
        }
        if T.self == Data.self, LegacyOutOfLineData.isEnabled(info) {
            return try LegacyDecoderImpl.outOfLineData(value, userInfo: info, codingPath: []) as! T
        }
        return try T(from: LegacyDecoderImpl(value: value, codingPath: [], userInfo: info))
    }
}

extension LegacyDecoderImpl {
    /// `Data` arrives as an index into the side array, never as bytes in the
    /// stream. Apple's iOS 18 coder does the same, and only for `Data`.
    static func outOfLineData(_ value: LegacyOverlayValue,
                              userInfo: [CodingUserInfoKey: Any],
                              codingPath: [any CodingKey]) throws -> Data {
        guard case .int(let index) = value else {
            throw DecodingError.typeMismatch(Data.self, .init(
                codingPath: codingPath,
                debugDescription: "expected an out-of-line index for Data, found \(describe(value))"))
        }
        return try LegacyOutOfLineData.read(at: index, from: userInfo)
    }
}

final class LegacyDecoderImpl: Decoder {
    let value: LegacyOverlayValue
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    init(value: LegacyOverlayValue, codingPath: [any CodingKey], userInfo: [CodingUserInfoKey: Any]) {
        self.value = value
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .keyed(let entries) = value else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "expected a keyed container, found \(Self.describe(value))"))
        }
        return KeyedDecodingContainer(LegacyKeyedContainer(entries: entries, decoder: self))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .unkeyed(let elements) = value else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "expected an unkeyed container, found \(Self.describe(value))"))
        }
        return LegacyUnkeyedContainer(elements: elements, decoder: self)
    }

    /// No unwrapping needed: the single-value container is transparent on the wire,
    /// so the value here *is* the value.
    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        LegacySingleValueContainer(value: value, decoder: self)
    }

    func child(_ value: LegacyOverlayValue, forKey key: (any CodingKey)?) -> LegacyDecoderImpl {
        LegacyDecoderImpl(value: value,
                          codingPath: key.map { codingPath + [$0] } ?? codingPath,
                          userInfo: userInfo)
    }

    func unwrap<T>(_ value: LegacyOverlayValue, as type: T.Type, at path: [any CodingKey]) throws -> T {
        if let extracted = Self.extract(value) as? T { return extracted }
        throw DecodingError.typeMismatch(type, .init(
            codingPath: path,
            debugDescription: "expected \(type), found \(Self.describe(value))"))
    }

    private static func extract(_ value: LegacyOverlayValue) -> Any? {
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
        case .null, .optionalNone, .keyed, .unkeyed: return nil
        }
    }

    static func describe(_ value: LegacyOverlayValue) -> String {
        switch value {
        case .null: return "null"
        case .optionalNone: return "an absent Optional"
        case .keyed: return "a keyed container"
        case .unkeyed: return "an unkeyed container"
        default: return String(describing: extract(value).map { type(of: $0) } ?? Any.self)
        }
    }

    /// Both encodings of nothing. `encodeNil` writes one, a nil `Optional` reaching
    /// the generic path writes the other, and a decoder has to accept either.
    static func isNil(_ value: LegacyOverlayValue) -> Bool {
        value == .null || value == .optionalNone
    }
}

// MARK: - Keyed

private struct LegacyKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let entries: [LegacyOverlayValue.Entry]
    let decoder: LegacyDecoderImpl
    private let byKey: [String: LegacyOverlayValue]

    init(entries: [LegacyOverlayValue.Entry], decoder: LegacyDecoderImpl) {
        self.entries = entries
        self.decoder = decoder
        byKey = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { entries.compactMap { Key(stringValue: $0.key) } }

    func contains(_ key: Key) -> Bool { byKey[key.stringValue] != nil }

    private func value(for key: Key) throws -> LegacyOverlayValue {
        guard let value = byKey[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath, debugDescription: "no value for \(key.stringValue)"))
        }
        return value
    }

    /// An absent key throws rather than reporting nil, matching Apple and the
    /// Codable contract: this answers "is the present value nil".
    func decodeNil(forKey key: Key) throws -> Bool {
        LegacyDecoderImpl.isNil(try value(for: key))
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        if type == Data.self, LegacyOutOfLineData.isEnabled(decoder.userInfo) {
            return try LegacyDecoderImpl.outOfLineData(
                try value(for: key), userInfo: decoder.userInfo,
                codingPath: decoder.codingPath + [key]) as! T
        }
        return try T(from: decoder.child(try value(for: key), forKey: key))
    }

    func decode(_ t: Bool.Type, forKey k: Key) throws -> Bool { try primitive(t, k) }
    func decode(_ t: String.Type, forKey k: Key) throws -> String { try primitive(t, k) }
    func decode(_ t: Double.Type, forKey k: Key) throws -> Double { try primitive(t, k) }
    func decode(_ t: Float.Type, forKey k: Key) throws -> Float { try primitive(t, k) }
    func decode(_ t: Int.Type, forKey k: Key) throws -> Int { try primitive(t, k) }
    func decode(_ t: Int8.Type, forKey k: Key) throws -> Int8 { try primitive(t, k) }
    func decode(_ t: Int16.Type, forKey k: Key) throws -> Int16 { try primitive(t, k) }
    func decode(_ t: Int32.Type, forKey k: Key) throws -> Int32 { try primitive(t, k) }
    func decode(_ t: Int64.Type, forKey k: Key) throws -> Int64 { try primitive(t, k) }
    func decode(_ t: UInt.Type, forKey k: Key) throws -> UInt { try primitive(t, k) }
    func decode(_ t: UInt8.Type, forKey k: Key) throws -> UInt8 { try primitive(t, k) }
    func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16 { try primitive(t, k) }
    func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32 { try primitive(t, k) }
    func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64 { try primitive(t, k) }

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
        let key = LegacySuperKey()
        guard let value = byKey[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath, debugDescription: "no super value"))
        }
        return decoder.child(value, forKey: key)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        decoder.child(try value(for: key), forKey: key)
    }
}

// MARK: - Unkeyed

private struct LegacyUnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [LegacyOverlayValue]
    let decoder: LegacyDecoderImpl
    var currentIndex = 0

    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    private mutating func next() throws -> LegacyOverlayValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(LegacyOverlayValue.self, .init(
                codingPath: codingPath, debugDescription: "unkeyed container is at end"))
        }
        defer { currentIndex += 1 }
        return elements[currentIndex]
    }

    /// Consumes only on a real nil.
    ///
    /// Apple's iOS 18 container advances its index on both branches, so a
    /// `decodeNil()` that returns `false` still counts against `isAtEnd`. That is a
    /// bug in a reader, not a property of the format, and reproducing it would
    /// break decoding of streams that are perfectly well-formed.
    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(LegacyOverlayValue.self, .init(
                codingPath: codingPath, debugDescription: "unkeyed container is at end"))
        }
        guard LegacyDecoderImpl.isNil(elements[currentIndex]) else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let key = LegacyIndexKey(currentIndex)
        if type == Data.self, LegacyOutOfLineData.isEnabled(decoder.userInfo) {
            return try LegacyDecoderImpl.outOfLineData(
                try next(), userInfo: decoder.userInfo,
                codingPath: decoder.codingPath + [key]) as! T
        }
        return try T(from: decoder.child(try next(), forKey: key))
    }

    mutating func decode(_ t: Bool.Type) throws -> Bool { try primitive(t) }
    mutating func decode(_ t: String.Type) throws -> String { try primitive(t) }
    mutating func decode(_ t: Double.Type) throws -> Double { try primitive(t) }
    mutating func decode(_ t: Float.Type) throws -> Float { try primitive(t) }
    mutating func decode(_ t: Int.Type) throws -> Int { try primitive(t) }
    mutating func decode(_ t: Int8.Type) throws -> Int8 { try primitive(t) }
    mutating func decode(_ t: Int16.Type) throws -> Int16 { try primitive(t) }
    mutating func decode(_ t: Int32.Type) throws -> Int32 { try primitive(t) }
    mutating func decode(_ t: Int64.Type) throws -> Int64 { try primitive(t) }
    mutating func decode(_ t: UInt.Type) throws -> UInt { try primitive(t) }
    mutating func decode(_ t: UInt8.Type) throws -> UInt8 { try primitive(t) }
    mutating func decode(_ t: UInt16.Type) throws -> UInt16 { try primitive(t) }
    mutating func decode(_ t: UInt32.Type) throws -> UInt32 { try primitive(t) }
    mutating func decode(_ t: UInt64.Type) throws -> UInt64 { try primitive(t) }

    private mutating func primitive<T>(_ type: T.Type) throws -> T {
        let path = codingPath + [LegacyIndexKey(currentIndex)]
        return try decoder.unwrap(try next(), as: type, at: path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type)
    throws -> KeyedDecodingContainer<NestedKey> {
        let key = LegacyIndexKey(currentIndex)
        return try decoder.child(try next(), forKey: key).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let key = LegacyIndexKey(currentIndex)
        return try decoder.child(try next(), forKey: key).unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        let key = LegacyIndexKey(currentIndex)
        return decoder.child(try next(), forKey: key)
    }
}

// MARK: - Single value

private struct LegacySingleValueContainer: SingleValueDecodingContainer {
    let value: LegacyOverlayValue
    let decoder: LegacyDecoderImpl

    var codingPath: [any CodingKey] { decoder.codingPath }

    func decodeNil() -> Bool { LegacyDecoderImpl.isNil(value) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Data.self, LegacyOutOfLineData.isEnabled(decoder.userInfo) {
            return try LegacyDecoderImpl.outOfLineData(
                value, userInfo: decoder.userInfo, codingPath: decoder.codingPath) as! T
        }
        return try T(from: decoder)
    }

    func decode(_ t: Bool.Type) throws -> Bool { try primitive(t) }
    func decode(_ t: String.Type) throws -> String { try primitive(t) }
    func decode(_ t: Double.Type) throws -> Double { try primitive(t) }
    func decode(_ t: Float.Type) throws -> Float { try primitive(t) }
    func decode(_ t: Int.Type) throws -> Int { try primitive(t) }
    func decode(_ t: Int8.Type) throws -> Int8 { try primitive(t) }
    func decode(_ t: Int16.Type) throws -> Int16 { try primitive(t) }
    func decode(_ t: Int32.Type) throws -> Int32 { try primitive(t) }
    func decode(_ t: Int64.Type) throws -> Int64 { try primitive(t) }
    func decode(_ t: UInt.Type) throws -> UInt { try primitive(t) }
    func decode(_ t: UInt8.Type) throws -> UInt8 { try primitive(t) }
    func decode(_ t: UInt16.Type) throws -> UInt16 { try primitive(t) }
    func decode(_ t: UInt32.Type) throws -> UInt32 { try primitive(t) }
    func decode(_ t: UInt64.Type) throws -> UInt64 { try primitive(t) }

    private func primitive<T>(_ type: T.Type) throws -> T {
        try decoder.unwrap(value, as: type, at: codingPath)
    }
}
