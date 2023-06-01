//
//  XPCEncoder.swift
//  a
//
//  Created by pbk on 2023/05/24.
//

import Foundation
import XPC
import Combine

public struct XPCEncoder {
    
    
    public init() {

    }
    
    public var userInfo:[CodingUserInfoKey:Any] = [:]
    
    public func encode<T:Encodable>(_ value:T) throws -> xpc_object_t {
        let encoderImp = _XPCEncoderImp(codingPath: [], userInfo: userInfo)
        var container = encoderImp.singleValueContainer()
        try container.encode(value)
       
        guard let xpc = encoderImp.xpc else {
            throw EncodingError.invalidValue(value,
                                             EncodingError.Context(codingPath: [], debugDescription: "Top-level \(T.self) did not encode any values."))
        }
        
        return xpc
    }
    
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension XPCEncoder: TopLevelEncoder {
    public typealias Output = xpc_object_t

}

private class _XPCEncoderImp: Encoder, SingleValueEncodingContainer {
    
    @usableFromInline
    internal init(codingPath: [CodingKey], userInfo: [CodingUserInfoKey : Any]) {
        self.codingPath = codingPath
        self.userInfo = userInfo
        self.xpc = nil
    }

    
    var xpc:xpc_object_t?
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey : Any]
    
    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key : CodingKey {
        if let xpc {
            if xpc_get_type(xpc) == XPC_TYPE_DICTIONARY {
                return .init(_XPCKeyedEncodingContainer(ref: xpc, path: codingPath, userInfo: userInfo))
            } else {
                preconditionFailure("Attempt to create new keyed encoding container when already previously encoded at this path.")
            }
            
        } else {
            let container = xpc_dictionary_create(nil, nil, 0)
            xpc = container
            
            return .init(_XPCKeyedEncodingContainer(ref: container, path: codingPath, userInfo: userInfo))
        }
    }
    
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        if let xpc {
            if xpc_get_type(xpc) == XPC_TYPE_ARRAY {
                return _XPCUnkeyedEncodingContainer(ref: xpc, path: codingPath, userInfo: userInfo)
            } else {
                preconditionFailure("Attempt to create new unkeyed encoding container when already previously encoded at this path.")
            }
        } else {
            let buffer = xpc_array_create(nil, 0)
            xpc = buffer
            return _XPCUnkeyedEncodingContainer(ref: buffer, path: codingPath, userInfo: userInfo)
        }
    }
    
    func singleValueContainer() -> SingleValueEncodingContainer {
        return self
    }
    
    private func assertCanEncodeNewValue() {
        precondition(xpc == nil, "Attempt to encode value through single value container when previously value already encoded.")
    }
    
    func encodeNil() throws {
        assertCanEncodeNewValue()
        xpc = xpc_null_create()
    }
    
    func encode(_ value: Bool) throws {
        assertCanEncodeNewValue()
        xpc = xpc_bool_create(value)
    }
    
    func encode(_ value: String) throws {
        assertCanEncodeNewValue()
        xpc = xpc_string_create(value)
    }
    
    func encode(_ value: Double) throws {
        assertCanEncodeNewValue()
        xpc = xpc_double_create(value)
    }
    
    func encode(_ value: Float) throws {
        // Float.signalingNaN is not converted to Double.signalingNaN when calling Double(...) with a Float so this
        // needs to be done manually
        let double = value.isSignalingNaN ? Double.signalingNaN : Double(value)
        try encode(double)
    }
    
    func encode(_ value: Int) throws {
        try encode(Int64(value))
    }
    
    func encode(_ value: Int8) throws {
        try encode(Int64(value))
    }
    
    func encode(_ value: Int16) throws {
        try encode(Int64(value))
    }
    
    func encode(_ value: Int32) throws {
        try encode(Int64(value))
    }
    
    func encode(_ value: Int64) throws {
        assertCanEncodeNewValue()
        xpc = xpc_int64_create(value)
    }
    
    func encode(_ value: UInt) throws {
        try encode(UInt64(value))
    }
    
    func encode(_ value: UInt8) throws {
        try encode(UInt64(value))
    }
    
    func encode(_ value: UInt16) throws {
        try encode(UInt64(value))
    }
    
    func encode(_ value: UInt32) throws {
        try encode(UInt64(value))
    }
    
    func encode(_ value: UInt64) throws {
        assertCanEncodeNewValue()
        xpc = xpc_uint64_create(value)
    }
    
    @usableFromInline
    func encode<T>(_ value: T) throws where T : Encodable {
        assertCanEncodeNewValue()
        switch value {
        case let data as Data:
            xpc = data.xpcData
            break
        case let fd as any XPCFileDescriptorProtocol:
            if let xpcObject = xpc_fd_create(fd.rawValue) {
                xpc = xpcObject
            } else {
                let context = EncodingError.Context(codingPath: codingPath, debugDescription: "XPC doesn't recognize this FileDescriptor")
                throw EncodingError.invalidValue(fd, context)
            }
        case let date as Date:
           xpc = date.xpcRepresentation
        case let uid as UUID:
            xpc = uid.xpcUUID
            break
        default:
            let encoder = _XPCEncoderImp(codingPath: codingPath, userInfo: userInfo)
            try value.encode(to: encoder)
            if let xpc = encoder.xpc {
                self.xpc = xpc
            }
            break
        }
    }
    
}


private struct _XPCKeyedEncodingContainer<Key : CodingKey>: KeyedEncodingContainerProtocol {

    
    mutating func encodeNil(forKey key: Key) throws {
        xpc_dictionary_set_value(ref, key.stringValue, xpc_null_create())
    }
    
    mutating func encode(_ value: Bool, forKey key: Key) throws {
        xpc_dictionary_set_value(ref, key.stringValue, xpc_bool_create(value))
    }
    
    mutating func encode(_ value: String, forKey key: Key) throws {
        xpc_dictionary_set_value(ref, key.stringValue, xpc_string_create(value))
    }
    
    mutating func encode(_ value: Double, forKey key: Key) throws {
        encodeBinaryFloat(value, forKey: key)
    }
    
    mutating func encode(_ value: Float, forKey key: Key) throws {
        encodeBinaryFloat(value, forKey: key)
    }
    
    mutating func encode(_ value: Int, forKey key: Key) throws {
        encodeSignedInt(value, forKey: key)
    }
    
    mutating func encode(_ value: Int8, forKey key: Key) throws {
        encodeSignedInt(value, forKey: key)
    }
    
    mutating func encode(_ value: Int16, forKey key: Key) throws {
        encodeSignedInt(value, forKey: key)
    }
    
    mutating func encode(_ value: Int32, forKey key: Key) throws {
        encodeSignedInt(value, forKey: key)
    }
    
    mutating func encode(_ value: Int64, forKey key: Key) throws {
        encodeSignedInt(value, forKey: key)
    }
    
    mutating func encode(_ value: UInt, forKey key: Key) throws {
        encodeUnsignedInt(value, forKey: key)
    }
    
    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        encodeUnsignedInt(value, forKey: key)
    }
    
    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        encodeUnsignedInt(value, forKey: key)
    }
    
    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        encodeUnsignedInt(value, forKey: key)
    }
    
    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        encodeUnsignedInt(value, forKey: key)
    }
    
    mutating func encode<T>(_ value: T, forKey key: Key) throws where T : Encodable {
        switch value {
        case let data as Data:
            xpc_dictionary_set_value(ref, key.stringValue, data.xpcData)
            break
        case let fd as any XPCFileDescriptorProtocol:
            if let xpcObject = xpc_fd_create(fd.rawValue) {
                xpc_dictionary_set_value(ref, key.stringValue, xpcObject)
            } else {
                let context = EncodingError.Context(codingPath: codingPath, debugDescription: "XPC doesn't recognize this FileDescriptor")
                throw EncodingError.invalidValue(fd, context)
            }
        case let date as Date:
            xpc_dictionary_set_value(ref, key.stringValue, date.xpcRepresentation)
        case let uid as UUID:
            xpc_dictionary_set_value(ref, key.stringValue, uid.xpcUUID)
            break
        default:
            let encoder = _XPCEncoderImp(codingPath: codingPath + [key], userInfo: userInfo)
            try value.encode(to: encoder)
            if let xpc = encoder.xpc {
                xpc_dictionary_set_value(ref, key.stringValue, xpc)
            }
            
            break
        }
        
    }
    
    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey : CodingKey {
        let newPath = codingPath + [key]
        let newRef = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(ref, key.stringValue, newRef)
        let childContainer = _XPCKeyedEncodingContainer<NestedKey>(ref: ref, path: newPath, userInfo: userInfo)
        return KeyedEncodingContainer<NestedKey>(childContainer)
    }
    
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let newPath = codingPath + [key]
        let newRef =  xpc_array_create(nil, 0)
        xpc_dictionary_set_value(ref, key.stringValue, newRef)
        let childContainer = _XPCUnkeyedEncodingContainer(ref: ref, path: newPath, userInfo: userInfo)
        return childContainer
    }
    
    mutating func superEncoder() -> Encoder {
        __XPCReferenceEncoder(codingPath: codingPath, userInfo: userInfo, key: XPCCodingKey.super, wrapping: ref)
    }
    
    mutating func superEncoder(forKey key: Key) -> Encoder {
        __XPCReferenceEncoder(codingPath: codingPath, userInfo: userInfo, key: key, wrapping: ref)
    }
    
    
    internal init(ref: xpc_object_t, path:[CodingKey], userInfo:[CodingUserInfoKey:Any]) {
        precondition(xpc_get_type(ref) == XPC_TYPE_DICTIONARY)
        self.ref = ref
        self.codingPath = path
        self.userInfo = userInfo
    }
    
    private let ref:xpc_object_t
    let userInfo: [CodingUserInfoKey : Any]
    let codingPath: [CodingKey]
    
    mutating func encodeBinaryFloat(_ value:some BinaryFloatingPoint,  forKey key: Key) {
        // Float.signalingNaN is not converted to Double.signalingNaN when calling Double(...) with a Float so this
        // needs to be done manually
        let double = value.isSignalingNaN ? Double.signalingNaN : Double(value)
        xpc_dictionary_set_double(ref, key.stringValue, double)
        
    }
    
    mutating func encodeUnsignedInt(_ value: some UnsignedInteger,  forKey key: Key) {
        xpc_dictionary_set_uint64(ref, key.stringValue, .init(value))
    }
    
    mutating func encodeSignedInt(_ value: some SignedInteger,  forKey key: Key) {
        xpc_dictionary_set_int64(ref, key.stringValue, .init(value))
    }
    
}


private struct _XPCUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    
    
    
    internal init(ref: xpc_object_t, path:[CodingKey], userInfo: [CodingUserInfoKey:Any]) {
        precondition(xpc_get_type(ref) == XPC_TYPE_ARRAY)
        self.ref = ref
        self.codingPath = path
        self.userInfo = userInfo
    }
    
    private let ref:xpc_object_t
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey : Any]
    
    var count: Int {
        xpc_array_get_count(ref)
    }
    
    mutating func encodeNil() throws {
        xpc_array_append_value(ref, xpc_null_create())
    }
    
    mutating func encode(_ value: Bool) throws {
        xpc_array_append_value(ref, xpc_bool_create(value))
    }
    
    mutating func encode(_ value: String) throws {
        xpc_array_append_value(ref, xpc_string_create(value))
    }
    
    mutating func encode(_ value: Double) throws {
        encodeBinaryFloat(value)
    }
    
    mutating func encode(_ value: Float) throws {
        encodeBinaryFloat(value)
    }
    
    mutating func encode(_ value: Int) throws {
        encodeSignedInt(value)
    }
    
    mutating func encode(_ value: Int8) throws {
        encodeSignedInt(value)
    }
    
    mutating func encode(_ value: Int16) throws {
        encodeSignedInt(value)
    }
    
    mutating func encode(_ value: Int32) throws {
        encodeSignedInt(value)
    }
    
    mutating func encode(_ value: Int64) throws {
        encodeSignedInt(value)
    }
    
    mutating func encode(_ value: UInt) throws {
        encodeUnsignedInt(value)
    }
    
    mutating func encode(_ value: UInt8) throws {
        encodeUnsignedInt(value)
    }
    
    mutating func encode(_ value: UInt16) throws {
        encodeUnsignedInt(value)
    }
    
    mutating func encode(_ value: UInt32) throws {
        encodeUnsignedInt(value)
    }
    
    mutating func encode(_ value: UInt64) throws {
        encodeUnsignedInt(value)
    }
    
    mutating func encode<T>(_ value: T) throws where T : Encodable {
        switch value {
        case let data as Data:
            xpc_array_append_value(ref, data.xpcData)
            break
        case let fd as any XPCFileDescriptorProtocol:
            if let xpcObject = xpc_fd_create(fd.rawValue) {
                
                xpc_array_append_value(ref, xpcObject)
            } else {
                let context = EncodingError.Context(codingPath: codingPath, debugDescription: "XPC doesn't recognize this FileDescriptor")
                throw EncodingError.invalidValue(fd, context)
            }
        case let date as Date:
            xpc_array_append_value(ref, date.xpcRepresentation)
        case let uid as UUID:
            xpc_array_append_value(ref, uid.xpcUUID)
            break
        default:
            let encoder = _XPCEncoderImp(codingPath: codingPath + [XPCCodingKey(index: count)], userInfo: userInfo)
            try value.encode(to: encoder)
            if let xpc = encoder.xpc {
                xpc_array_append_value(ref, xpc)
            }
            break
        }
    }
    
    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey : CodingKey {
        let newPath = codingPath + [XPCCodingKey(index: count)]
        let newRef = xpc_dictionary_create(nil, nil, 0)
        xpc_array_append_value(ref, newRef)
        let childContainer = _XPCKeyedEncodingContainer<NestedKey>(ref: newRef, path: newPath, userInfo: userInfo)
        return KeyedEncodingContainer(childContainer)
    }
    
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let newPath = codingPath + [XPCCodingKey(index: count)]
        let newRef = xpc_array_create(nil, 0)
        xpc_array_append_value(ref, newRef)
        let childContainer = _XPCUnkeyedEncodingContainer(ref: newRef, path: newPath, userInfo: userInfo)
        return childContainer
    }
    
    mutating func superEncoder() -> Encoder {
        __XPCReferenceEncoder.init(codingPath: codingPath, userInfo: userInfo, at: count, wrapping: ref)
    }
    
    mutating func encodeBinaryFloat(_ value:some BinaryFloatingPoint) {
        // Float.signalingNaN is not converted to Double.signalingNaN when calling Double(...) with a Float so this
        // needs to be done manually
        let double = value.isSignalingNaN ? Double.signalingNaN : Double(value)
        xpc_array_append_value(ref, xpc_double_create(double))
    }
    
    mutating func encodeUnsignedInt(_ value: some UnsignedInteger) {
        xpc_array_append_value(ref, xpc_uint64_create(UInt64(value)))
    }
    
    mutating func encodeSignedInt(_ value: some SignedInteger) {
        xpc_array_append_value(ref, xpc_int64_create(Int64(value)))
    }
    
}


private final class __XPCReferenceEncoder: _XPCEncoderImp {
    
    
    /// The type of container we're referencing.
    private enum Reference {
        /// Referencing a specific index in an array container.
        case array(xpc_object_t, Int)

        /// Referencing a specific key in a dictionary container.
        case dictionary(xpc_object_t, String)
    }

    /// The container reference itself.
    private let reference: Reference

    // MARK: - Initialization

    /// Initializes `self` by referencing the given array container in the given encoder.
    init(codingPath:[CodingKey], userInfo:[CodingUserInfoKey:Any], at index: Int, wrapping ref: xpc_object_t) {
        self.reference = .array(ref, index)
        super.init(codingPath: codingPath + [XPCCodingKey(index: index)], userInfo: userInfo)
    }

    /// Initializes `self` by referencing the given dictionary container in the given encoder.
    init(codingPath:[CodingKey], userInfo:[CodingUserInfoKey:Any], key: CodingKey, wrapping dictionary: xpc_object_t) {
        self.reference = .dictionary(dictionary, key.stringValue)
        super.init(codingPath: codingPath + [key], userInfo: userInfo)
    }
    
    override func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key : CodingKey {
        let container = super.container(keyedBy: type)
        sendToParent()
        return container
    }
    
    override func unkeyedContainer() -> UnkeyedEncodingContainer {
        let container = super.unkeyedContainer()
        sendToParent()
        return container
    }
    
    func sendToParent() {
        guard let xpc else { return }
        switch reference {
        case let .array(array, index):
            xpc_array_set_value(array, index, xpc)
        case let .dictionary(dictionary, key):
            xpc_dictionary_set_value(dictionary, key, xpc)
        }
    }
    
    override func encodeNil() throws {
        try super.encodeNil()
        sendToParent()
    }
    
    override func encode(_ value: Bool) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: String) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: Double) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: Float) throws {
        try super.encode(value)
        sendToParent()
        
    }
    
    override func encode(_ value: Int) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: Int8) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: Int16) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: Int32) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: Int64) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: UInt) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: UInt8) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: UInt16) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: UInt32) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode(_ value: UInt64) throws {
        try super.encode(value)
        sendToParent()
    }
    
    override func encode<T>(_ value: T) throws where T : Encodable {
        try super.encode(value)
        sendToParent()
    }
    
}
