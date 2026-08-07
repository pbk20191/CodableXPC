import Foundation

final class OverlayEncoderImpl: Encoder {
    let node: OverlayEncodingNode
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    init(node: OverlayEncodingNode, codingPath: [any CodingKey], userInfo: [CodingUserInfoKey: Any]) {
        self.node = node
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    func encodeTopLevel<T: Encodable>(_ value: T) throws {
        try value.encode(to: self)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.kind = .keyed
        return KeyedEncodingContainer(OverlayKeyedEncodingContainer(encoder: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        node.kind = .unkeyed
        return OverlayUnkeyedEncodingContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        node.kind = .singleValue
        return OverlaySingleValueEncodingContainer(encoder: self)
    }

    /// A child node for a nested `Encodable`.
    ///
    /// Every value encoded through the generic overload gets one of these, which is
    /// why an element of `[UInt8]` becomes its own single-value container while a
    /// `UInt8` *property* is written inline: the property resolves to the primitive
    /// overload, the element does not.
    func child(forKey key: (any CodingKey)?) -> (OverlayEncodingNode, OverlayEncoderImpl) {
        let child = OverlayEncodingNode()
        let encoder = OverlayEncoderImpl(
            node: child,
            codingPath: key.map { codingPath + [$0] } ?? codingPath,
            userInfo: userInfo)
        return (child, encoder)
    }
}

// MARK: - Keyed

private struct OverlayKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: OverlayEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }

    private func put(_ item: OverlayEncodingItem, _ key: Key?) {
        encoder.node.entries.append((key?.stringValue, item))
    }

    mutating func encodeNil(forKey key: Key) throws { put(.value(.null), key) }

    mutating func encode(_ value: Bool, forKey key: Key) throws { put(.value(.bool(value)), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { put(.value(.string(value)), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { put(.value(.double(value)), key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { put(.value(.float(value)), key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { put(.value(.int(value)), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { put(.value(.int8(value)), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { put(.value(.int16(value)), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { put(.value(.int32(value)), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { put(.value(.int64(value)), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { put(.value(.uint(value)), key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { put(.value(.uint8(value)), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { put(.value(.uint16(value)), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { put(.value(.uint32(value)), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { put(.value(.uint64(value)), key) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let (child, childEncoder) = encoder.child(forKey: key)
        put(.child(child), key)
        try value.encode(to: childEncoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let (child, childEncoder) = encoder.child(forKey: key)
        put(.child(child), key)
        return childEncoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let (child, childEncoder) = encoder.child(forKey: key)
        put(.child(child), key)
        return childEncoder.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let (child, childEncoder) = encoder.child(forKey: nil)
        put(.child(child), nil)     // the keyless entry, wire tag 16
        return childEncoder
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        let (child, childEncoder) = encoder.child(forKey: key)
        put(.child(child), key)
        return childEncoder
    }
}

// MARK: - Unkeyed

private struct OverlayUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: OverlayEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int { encoder.node.items.count }

    private func put(_ item: OverlayEncodingItem) { encoder.node.items.append(item) }

    mutating func encodeNil() throws { put(.value(.null)) }

    mutating func encode(_ value: Bool) throws { put(.value(.bool(value))) }
    mutating func encode(_ value: String) throws { put(.value(.string(value))) }
    mutating func encode(_ value: Double) throws { put(.value(.double(value))) }
    mutating func encode(_ value: Float) throws { put(.value(.float(value))) }
    mutating func encode(_ value: Int) throws { put(.value(.int(value))) }
    mutating func encode(_ value: Int8) throws { put(.value(.int8(value))) }
    mutating func encode(_ value: Int16) throws { put(.value(.int16(value))) }
    mutating func encode(_ value: Int32) throws { put(.value(.int32(value))) }
    mutating func encode(_ value: Int64) throws { put(.value(.int64(value))) }
    mutating func encode(_ value: UInt) throws { put(.value(.uint(value))) }
    mutating func encode(_ value: UInt8) throws { put(.value(.uint8(value))) }
    mutating func encode(_ value: UInt16) throws { put(.value(.uint16(value))) }
    mutating func encode(_ value: UInt32) throws { put(.value(.uint32(value))) }
    mutating func encode(_ value: UInt64) throws { put(.value(.uint64(value))) }

    /// The one place bulk bytes leave the stream.
    ///
    /// `Data.encode(to:)` is the only Foundation conformance that reaches here —
    /// `Array<UInt8>` loops through the generic overload instead, which is why an
    /// array of bytes and a `Data` of the same bytes encode completely differently.
    mutating func encode<T: Sequence>(contentsOf sequence: T) throws where T.Element == UInt8 {
        put(.outOfLineData(Data(sequence)))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let (child, childEncoder) = encoder.child(forKey: OverlayIndexKey(count))
        put(.child(child))
        try value.encode(to: childEncoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let (child, childEncoder) = encoder.child(forKey: OverlayIndexKey(count))
        put(.child(child))
        return childEncoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let (child, childEncoder) = encoder.child(forKey: OverlayIndexKey(count))
        put(.child(child))
        return childEncoder.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let (child, childEncoder) = encoder.child(forKey: OverlayIndexKey(count))
        put(.child(child))
        return childEncoder
    }
}

// MARK: - Single value

private struct OverlaySingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: OverlayEncoderImpl
    var codingPath: [any CodingKey] { encoder.codingPath }

    private func put(_ item: OverlayEncodingItem) {
        // Apple traps when a single-value container is written twice. Overwriting
        // is the same programmer error with a quieter failure, so replace rather
        // than append and let the value be the last one written.
        encoder.node.items = [item]
    }

    mutating func encodeNil() throws { put(.value(.null)) }

    mutating func encode(_ value: Bool) throws { put(.value(.bool(value))) }
    mutating func encode(_ value: String) throws { put(.value(.string(value))) }
    mutating func encode(_ value: Double) throws { put(.value(.double(value))) }
    mutating func encode(_ value: Float) throws { put(.value(.float(value))) }
    mutating func encode(_ value: Int) throws { put(.value(.int(value))) }
    mutating func encode(_ value: Int8) throws { put(.value(.int8(value))) }
    mutating func encode(_ value: Int16) throws { put(.value(.int16(value))) }
    mutating func encode(_ value: Int32) throws { put(.value(.int32(value))) }
    mutating func encode(_ value: Int64) throws { put(.value(.int64(value))) }
    mutating func encode(_ value: UInt) throws { put(.value(.uint(value))) }
    mutating func encode(_ value: UInt8) throws { put(.value(.uint8(value))) }
    mutating func encode(_ value: UInt16) throws { put(.value(.uint16(value))) }
    mutating func encode(_ value: UInt32) throws { put(.value(.uint32(value))) }
    mutating func encode(_ value: UInt64) throws { put(.value(.uint64(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let (child, childEncoder) = encoder.child(forKey: nil)
        put(.child(child))
        try value.encode(to: childEncoder)
    }
}
