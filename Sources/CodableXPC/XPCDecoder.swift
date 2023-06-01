//
//  XPCDecoder.swift
//  a
//
//  Created by pbk on 2023/05/24.
//
import Foundation
import XPC
import Combine


public struct XPCDecoder {
    
    public var userInfo:[CodingUserInfoKey:Any] = [:]
    
    public func decode<T>(
        _ type: T.Type,
        from: xpc_object_t
    ) throws -> T where T : Decodable {
        let decoderImp = _XPCDecoderImp(ref: from, codingPath: [], userInfo: userInfo)
        return try decoderImp.singleValueContainer().decode(type)
    }

    public init() {
       
    }
    
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension XPCDecoder: TopLevelDecoder {
    
    public typealias Input = xpc_object_t
    
}

private class _XPCDecoderImp: Decoder {
    internal init(ref: xpc_object_t, codingPath: [CodingKey], userInfo: [CodingUserInfoKey : Any]) {
        self.ref = ref
        self.codingPath = codingPath
        self.userInfo = userInfo
    }
    

    let ref:xpc_object_t
    let codingPath: [CodingKey]
    
    let userInfo: [CodingUserInfoKey : Any]
    
    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key : CodingKey {
        let xpcType = xpc_get_type(ref)
        switch xpcType {
        case XPC_TYPE_DICTIONARY:
            let newContainer = _XPCKeyedDecodingContainer<Key>(userInfo: userInfo, ref: ref, codingPath: codingPath)
            return .init(newContainer)
        case XPC_TYPE_NULL:
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected KeyedDecodingContainer but found null instead")
            throw DecodingError.valueNotFound(KeyedDecodingContainer<Key>.self, context)
        default:
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected KeyedDecodingContainer but found \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(KeyedDecodingContainer<Key>.self, context)
        }
    }
    
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard xpc_get_type(ref) == XPC_TYPE_ARRAY else {
            let keyedContainer = xpc_get_type(ref) == XPC_TYPE_DICTIONARY
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected UnkeyedContainer but found \(keyedContainer ? "KeyedContainer" : "SingleValueContainer")")
            throw DecodingError.typeMismatch(Array<xpc_object_t>.self, context)
        }
        let newContainer = _XPCUnKeyedDecodingContainer(ref: ref, path: codingPath, userInfo: userInfo)
        return newContainer
    }
    
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        self
    }
    
}

extension _XPCDecoderImp: SingleValueDecodingContainer {
    
    func decodeNil() -> Bool {
        xpc_get_type(ref) == XPC_TYPE_NULL
    }
    
    func decode(_ type: Bool.Type) throws -> Bool {
        guard xpc_get_type(ref) == XPC_TYPE_BOOL else {
            let name = xpcTypeName(xpc_get_type(ref))
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected bool but \(name) found instead")
            throw DecodingError.typeMismatch(type, context)
        }
        return xpc_bool_get_value(ref)
    }
    
    func decode(_ type: String.Type) throws -> String {
        guard xpc_get_type(ref) == XPC_TYPE_STRING else {
            let name = xpcTypeName(xpc_get_type(ref))
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected string but \(name) found instead")
            throw DecodingError.typeMismatch(type, context)
        }

        let buffer = UnsafeBufferPointer(
            start: xpc_string_get_string_ptr(ref),
            count: xpc_string_get_length(ref) + 1
        ).map{ $0 }
        return String(cString: buffer)
    }
    
    func decode(_ type: Double.Type) throws -> Double {
        try decodeBinaryFloatingPoint(type)
    }
    
    func decode(_ type: Float.Type) throws -> Float {
        try decodeBinaryFloatingPoint(type)
    }
    
    func decode(_ type: Int.Type) throws -> Int {
        try decodeSignedInteger(type)
    }
    
    func decode(_ type: Int8.Type) throws -> Int8 {
        try decodeSignedInteger(type)
    }
    
    func decode(_ type: Int16.Type) throws -> Int16 {
        try decodeSignedInteger(type)
    }
    
    func decode(_ type: Int32.Type) throws -> Int32 {
        try decodeSignedInteger(type)
    }
    
    func decode(_ type: Int64.Type) throws -> Int64 {
        try decodeSignedInteger(type)
    }
    
    func decode(_ type: UInt.Type) throws -> UInt {
        try decodeUnsignedInteger(type)
    }
    
    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try decodeUnsignedInteger(type)
    }
    
    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try decodeUnsignedInteger(type)
    }
    
    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try decodeUnsignedInteger(type)
    }
    
    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try decodeUnsignedInteger(type)
    }
    
    func decode<T>(_ type: T.Type) throws -> T where T : Decodable {
        let xpcType = xpc_get_type(ref)
        switch type {
        case is any XPCFileDescriptorProtocol.Type:
            guard xpcType == XPC_TYPE_FD else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected FileDescriptor but found \(xpcTypeName(xpcType)) instead")
                throw DecodingError.typeMismatch(type, context)
            }
            let rawFd = xpc_fd_dup(ref)
            guard rawFd != -1 else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "can't retreive FileDescriptor from xpc framework")
                throw DecodingError.dataCorrupted(context)
            }
            guard let actualFd = (type as! any XPCFileDescriptorProtocol.Type).init(rawValue: rawFd) else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "can't create \(type) from valid fileDescriptor \(rawFd)")
                throw DecodingError.dataCorrupted(context)
            }
            return actualFd as! T
        case is UUID.Type:
            guard xpcType == XPC_TYPE_UUID else {
                let context = DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected UUID but found \(xpcTypeName(xpcType)) instead"
                )
                throw DecodingError.typeMismatch(type, context)
            }
            guard let bytes = xpc_uuid_get_bytes(ref) else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Expected valid uuid bytes from xpc api failed to recognize it")
                throw DecodingError.dataCorrupted(context)
            }
            return (NSUUID.init(uuidBytes: bytes) as UUID) as! T
        case is Date.Type:
            guard xpcType == XPC_TYPE_DATE else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected Date but found \(xpcTypeName(xpcType)) instead")
                throw DecodingError.typeMismatch(type, context)
            }
            let xpcDate = xpc_date_get_value(ref)
            return Date.init(fromEpochNanos: xpcDate) as! T
        case is Data.Type:
            guard xpcType == XPC_TYPE_DATA else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected Data but found \(xpcTypeName(xpcType)) instead")
                throw DecodingError.typeMismatch(type, context)
            }
            
            guard let dataPointer = xpc_data_get_bytes_ptr(ref) else {
                if xpc_data_get_length(ref) == 0 {
                    return Data() as! T
                }
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "xpc provide invalid data object")
                throw DecodingError.dataCorrupted(context)
            }
            return Data(bytes: dataPointer, count: xpc_data_get_length(ref)) as! T
        default:
            return try T(from: self)
        }
        
    }
    
    func decodeSignedInteger<T:SignedInteger>(_ type: T.Type) throws -> T {
        guard xpc_get_type(ref) == XPC_TYPE_INT64 else {
            let name = xpcTypeName(xpc_get_type(ref))
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected Int64 but \(name) found instead")
            throw DecodingError.typeMismatch(type, context)
        }
        let rawInt = xpc_int64_get_value(ref)
        if let value = T.init(exactly: rawInt) {
            return value
        } else {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "\(rawInt) does not fit in \(type)")
            throw DecodingError.typeMismatch(type, context)
        }
    }
    
    func decodeUnsignedInteger<T:UnsignedInteger>(_ type: T.Type) throws -> T {
        guard xpc_get_type(ref) == XPC_TYPE_UINT64 else {
            let name = xpcTypeName(xpc_get_type(ref))
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected Int64 but \(name) found instead")
            throw DecodingError.typeMismatch(type, context)
        }
        let rawInt = xpc_uint64_get_value(ref)
        if let value = T.init(exactly: rawInt) {
            return value
        } else {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "\(rawInt) does not fit in \(type)")
            throw DecodingError.typeMismatch(type, context)
        }
    }
    
    func decodeBinaryFloatingPoint<T:BinaryFloatingPoint>(_ type: T.Type) throws -> T {
        let xpcType = xpc_get_type(ref)
        switch xpcType {
        case XPC_TYPE_DOUBLE:
            let rawValue = xpc_double_get_value(ref)
            return rawValue.isSignalingNaN ? T.signalingNaN : .init(rawValue)
        case XPC_TYPE_INT64:
            let rawValue = xpc_int64_get_value(ref)
            if let realValue = T.init(exactly: rawValue) {
                return realValue
            } else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "\(rawValue) does not fit in \(type)")
                throw DecodingError.typeMismatch(type, context)
            }
        case XPC_TYPE_UINT64:
            let rawValue = xpc_uint64_get_value(ref)
            if let realValue = T.init(exactly: rawValue) {
                return realValue
            } else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "\(rawValue) does not fit in \(type)")
                throw DecodingError.typeMismatch(type, context)
            }
        default:
            let name = xpcTypeName(xpc_get_type(ref))
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "expected Float but \(name) found instead")
            throw DecodingError.typeMismatch(type, context)
        }
    }
}


private struct _XPCUnKeyedDecodingContainer: UnkeyedDecodingContainer {
    
    mutating func decode(_ type: String.Type) throws -> String {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Unkeyed container is at end.")
            throw DecodingError.valueNotFound(type, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        let xpcType = xpc_get_type(object)
        guard xpcType == XPC_TYPE_STRING else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Expected String but found \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
        let buffer = UnsafeBufferPointer(
            start: xpc_string_get_string_ptr(object),
            count: xpc_string_get_length(object) + 1
        ).map{ $0 }
        currentIndex += 1
        return String(cString: buffer)
    }
    
    mutating func decode(_ type: Double.Type) throws -> Double {
        try decodeBinaryFloatingPoint(type)
    }
    
    mutating func decode(_ type: Float.Type) throws -> Float {
        try decodeBinaryFloatingPoint(type)
    }
    
    mutating func decode(_ type: Int.Type) throws -> Int {
        try decodeSignedInteger(type)
    }
    
    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        try decodeSignedInteger(type)
    }
    
    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        try decodeSignedInteger(type)
    }
    
    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        try decodeSignedInteger(type)
    }
    
    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try decodeSignedInteger(type)
    }
    
    mutating func decode(_ type: UInt.Type) throws -> UInt {
        try decodeUnsignedInteger(type)
    }
    
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try decodeUnsignedInteger(type)
    }
    
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try decodeUnsignedInteger(type)
    }
    
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try decodeUnsignedInteger(type)
    }
    
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try decodeUnsignedInteger(type)
    }
    
    mutating func decode<T>(_ type: T.Type) throws -> T where T : Decodable {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Unkeyed container is at end.")
            throw DecodingError.valueNotFound(type, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        let xpcType = xpc_get_type(object)
        let value:T
        switch type {
        case is any XPCFileDescriptorProtocol.Type:
            guard xpcType == XPC_TYPE_FD else {
                let context = DecodingError.Context(
                    codingPath: currentPath,
                    debugDescription: "Expected FileDescriptor but found \(xpcTypeName(xpcType)) instead"
                )
                throw DecodingError.typeMismatch(type, context)
            }
            let rawFD = xpc_fd_dup(object)
            guard rawFD != -1 else {
                let context = DecodingError.Context(codingPath: currentPath, debugDescription: "XPC Frame work failed recognize FileDescriptor ")
                throw DecodingError.dataCorrupted(context)
            }
            if let realFd = (type as! any XPCFileDescriptorProtocol.Type).init(rawValue: rawFD) {
                value = realFd as! T
            } else {
                let context = DecodingError.Context(codingPath: currentPath, debugDescription: "fail to create \(type) from valid fileDescriptor \(rawFD)")
                throw DecodingError.dataCorrupted(context)
            }
            break
        case is Data.Type:
            guard xpcType == XPC_TYPE_DATA else {
                let context = DecodingError.Context(
                    codingPath: currentPath,
                    debugDescription: "Expected Data but found \(xpcTypeName(xpcType)) instead"
                )
                throw DecodingError.typeMismatch(type, context)
            }
            let ptr = UnsafeRawBufferPointer(start: xpc_data_get_bytes_ptr(object), count: xpc_data_get_length(object))
            value = Data(ptr) as! T
            break
        case is Date.Type:
            guard xpcType == XPC_TYPE_DATE else {
                let context = DecodingError.Context(
                    codingPath: currentPath,
                    debugDescription: "Expected Date but found \(xpcTypeName(xpcType)) instead"
                )
                throw DecodingError.typeMismatch(type, context)
            }
            let epochNanos = xpc_date_get_value(object)
            value = Date(fromEpochNanos: epochNanos) as! T
        case is UUID.Type:
            guard xpcType == XPC_TYPE_UUID else {
                let context = DecodingError.Context(
                    codingPath: currentPath,
                    debugDescription: "Expected UUID but found \(xpcTypeName(xpcType)) instead"
                )
                throw DecodingError.typeMismatch(type, context)
            }
            guard let bytes = xpc_uuid_get_bytes(object) else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Expected valid uuid bytes from xpc api failed to recognize it")
                throw DecodingError.dataCorrupted(context)
            }
            value = (NSUUID.init(uuidBytes: bytes) as UUID) as! T

            break
        default:
            let decoder = _XPCDecoderImp(ref: object, codingPath: currentPath, userInfo: userInfo)
            value = try T.init(from: decoder)
            break
        }
        currentIndex += 1
        return value
    }
    
    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Unkeyed container is at end.")
            throw DecodingError.valueNotFound(type, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        let xpcType = xpc_get_type(object)
        guard xpcType == XPC_TYPE_BOOL else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Expected Bool but found \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
        currentIndex += 1
        return xpc_bool_get_value(object)
    }
    
    mutating func decodeBinaryFloatingPoint<T:BinaryFloatingPoint>(_ type: T.Type) throws -> T {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Unkeyed container is at end.")
            throw DecodingError.valueNotFound(type, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        let xpcType = xpc_get_type(object)
        let value:T
        switch xpcType {
        case XPC_TYPE_DOUBLE:
            let double = xpc_double_get_value(object)
            value = double.isSignalingNaN ? T.signalingNaN : T.init(double)
        case XPC_TYPE_INT64:
            let integer = xpc_int64_get_value(object)
            if let float = T(exactly: integer) {
                value = float
            } else {
                let context = DecodingError.Context(codingPath: currentPath, debugDescription: "\(integer) does not fit in \(type)")
                throw DecodingError.typeMismatch(type, context)
            }
            break
        case XPC_TYPE_UINT64:
            let integer = xpc_uint64_get_value(object)
            if let float = T(exactly: integer) {
                value = float
            } else {
                let context = DecodingError.Context(codingPath: currentPath, debugDescription: "\(integer) does not fit in \(type)")
                throw DecodingError.typeMismatch(type, context)
            }
            break
        default:
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Expected Number but found \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
        currentIndex += 1
        return value
    }
    
    mutating func decodeSignedInteger<T:SignedInteger & FixedWidthInteger>(_ type: T.Type) throws -> T {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Unkeyed container is at end.")
            throw DecodingError.valueNotFound(type, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        let xpcType = xpc_get_type(object)
        guard xpcType == XPC_TYPE_INT64 else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Expected SignedInteger but found \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
        currentIndex += 1
        let value = xpc_int64_get_value(object)
        
        if let realValue = T.init(exactly: value) {
            return realValue
        } else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "\(value) does not fit in \(type)")
            throw DecodingError.typeMismatch(type, context)
        }
    }
    
    mutating func decodeUnsignedInteger<T:UnsignedInteger & FixedWidthInteger>(_ type: T.Type) throws -> T {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Unkeyed container is at end.")
            throw DecodingError.valueNotFound(type, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        let xpcType = xpc_get_type(object)
        guard xpcType == XPC_TYPE_UINT64 else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Expected UnsignedInteger but found \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
        currentIndex += 1
        let value = xpc_uint64_get_value(object)
        if let realValue = T.init(exactly: value) {
            return realValue
        } else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "\(value) does not fit in \(type)")
            throw DecodingError.typeMismatch(type, context)
        }
    }
    
    internal init(ref: xpc_object_t, path:[CodingKey], userInfo: [CodingUserInfoKey:Any]) {
        precondition(xpc_get_type(ref) == XPC_TYPE_ARRAY)
        self.ref = ref
        self.codingPath = path
        self.userInfo = userInfo
    }
    
    private let ref:xpc_object_t
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey : Any]
    
    
    var count: Int? { xpc_array_get_count(ref) }
    
    var isAtEnd: Bool {
        let count = xpc_array_get_count(ref)
        if (count > 0) {
            return currentIndex >= count
        } else {
            return true
        }
    }
    
    private(set) var currentIndex: Int = 0
    
    mutating func decodeNil() throws -> Bool {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Unkeyed container is at end.")
            throw DecodingError.valueNotFound(Never.self, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        if xpc_get_type(object) == XPC_TYPE_NULL {
            currentIndex += 1
            return true
        } else {
            return false
        }
    }
    
    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> where NestedKey : CodingKey {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription:"Unkeyed container is at end.")
            throw DecodingError.valueNotFound(KeyedDecodingContainer<NestedKey>.self, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        if xpc_get_type(object) == XPC_TYPE_NULL {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "expected KeyedDecodingContainer but found null instead")
            throw DecodingError.valueNotFound(KeyedDecodingContainer<NestedKey>.self, context)
        }
        guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription:"expected KeyedDecodingContainer but found \(xpcTypeName(xpc_get_type(object))) instead")
            throw DecodingError.typeMismatch(KeyedDecodingContainer<NestedKey>.self, context)
        }
        currentIndex += 1
        let container = _XPCKeyedDecodingContainer<NestedKey>(userInfo: userInfo, ref: object, codingPath: currentPath)
        return .init(container)
    }
    
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription:"Cannot get nested unkeyed container -- unkeyed container is at end.")
            throw DecodingError.valueNotFound(_XPCUnKeyedDecodingContainer.self, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        if xpc_get_type(object) == XPC_TYPE_NULL {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "expected UnkeyedDecodingContainer but found null instead")
            throw DecodingError.valueNotFound(UnkeyedDecodingContainer.self, context)
        }
        guard xpc_get_type(object) == XPC_TYPE_ARRAY else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription:"expected UnkeyedDecodingContainer but found \(xpcTypeName(xpc_get_type(object))) instead")
            throw DecodingError.typeMismatch(UnkeyedDecodingContainer.self, context)
        }
        currentIndex += 1
        let container = _XPCUnKeyedDecodingContainer(ref: object, path: currentPath, userInfo: userInfo)
        
        return container
    }
    
    mutating func superDecoder() throws -> Decoder {
        let currentPath = codingPath + [XPCCodingKey(index: currentIndex)]
        if isAtEnd {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription:"Cannot get superDecoder() -- unkeyed container is at end.")
            throw DecodingError.valueNotFound(Decoder.self, context)
        }
        let object = xpc_array_get_value(ref, currentIndex)
        let xpcType = xpc_get_type(object)
        if xpcType == XPC_TYPE_NULL {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription:"Cannot get superDecoder() -- encounter null")
            throw DecodingError.valueNotFound(Decoder.self, context)
        }
        currentIndex += 1
        let container = _XPCDecoderImp(ref: object, codingPath: currentPath, userInfo: userInfo)
        return container
    }
    
}

private struct _XPCKeyedDecodingContainer<Key:CodingKey>: KeyedDecodingContainerProtocol {
    
    
    internal init(userInfo: [CodingUserInfoKey : Any], ref: xpc_object_t, codingPath: [CodingKey]) {
        precondition(xpc_get_type(ref) == XPC_TYPE_DICTIONARY, "ref must be dictionary")
        self.userInfo = userInfo
        self.ref = ref
        self.codingPath = codingPath
        var stringBuffer = [Key]()
        stringBuffer.reserveCapacity(xpc_dictionary_get_count(ref))
        xpc_dictionary_apply(ref) { key, _ in
            if let newKey = Key.init(stringValue: .init(cString: key)) {
                stringBuffer.append(newKey)
            }
            return true
        }
        self.allKeys = stringBuffer
    }
    
    
    let userInfo:[CodingUserInfoKey:Any]
    let ref:xpc_object_t
    let codingPath: [CodingKey]
    let allKeys: [Key]
    
    func contains(_ key: Key) -> Bool {
        xpc_dictionary_get_value(ref, key.stringValue) != nil
    }
    
    private func getValue(forKey key:some CodingKey) throws -> xpc_object_t {
        guard let object = xpc_dictionary_get_value(ref, key.stringValue) else {
            let context = DecodingError.Context(codingPath: codingPath + [key], debugDescription: "No value associated with key \(key) (\"\(key.stringValue)\").")
            throw DecodingError.keyNotFound(key, context)
        }
        return object
    }
    
    private func getValue<T>(_ type:T.Type, forKey key: some CodingKey) throws -> xpc_object_t {
        let currentPath = codingPath + [key]
        let object = try getValue(forKey: key)
        let xpcType = xpc_get_type(object)
        if xpcType == XPC_TYPE_NULL {
            let context = DecodingError.Context.init(codingPath: currentPath, debugDescription: "Expected \(type) but find null instead")
            throw DecodingError.valueNotFound(type, context)
        }
        return object
    }
    
    func decodeNil(forKey key: Key) throws -> Bool {
        let object = try getValue(forKey: key)
        return xpc_get_type(object) == XPC_TYPE_NULL
    }
    
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let currentPath = codingPath + [key]
        let object = try getValue(type, forKey: key)
        let xpcType = xpc_get_type(object)
        guard xpcType == XPC_TYPE_BOOL else {
            let context = DecodingError.Context.init(codingPath: currentPath, debugDescription: "Expected \(type) but find \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
        return xpc_bool_get_value(object)
    }
    
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let currentPath = codingPath + [key]
        let object = try getValue(type, forKey: key)
        let xpcType = xpc_get_type(object)
        guard xpcType == XPC_TYPE_STRING else {
            let context = DecodingError.Context.init(codingPath: currentPath, debugDescription: "Expected \(type) but find \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
        let buffer = UnsafeBufferPointer(
            start: xpc_string_get_string_ptr(object),
            count: xpc_string_get_length(object) + 1
        ).map{ $0 }
        return String(cString: buffer)
    }
    
    func decodeBinaryFloatingPoint<T:BinaryFloatingPoint>(_ type: T.Type, forKey key:Key) throws -> T {
        let currentPath = codingPath + [key]
        let object = try getValue(type, forKey: key)
        let xpcType = xpc_get_type(object)
        switch xpcType {
        case XPC_TYPE_DOUBLE:
            let rawValue = xpc_double_get_value(object)
            return .init(rawValue)
        case XPC_TYPE_UINT64:
            let rawValue = xpc_uint64_get_value(object)
            if let realValue = T.init(exactly: rawValue) {
                return realValue
            } else {
                let context = DecodingError.Context(codingPath: currentPath, debugDescription: "\(rawValue) does not fit in \(type)")
                throw DecodingError.typeMismatch(type, context)
            }
        case XPC_TYPE_INT64:
            let rawValue = xpc_int64_get_value(object)
            if let realValue = T.init(exactly: rawValue) {
                return realValue
            } else {
                let context = DecodingError.Context(codingPath: currentPath, debugDescription: "\(rawValue) does not fit in \(type)")
                throw DecodingError.typeMismatch(type, context)
            }
        default:
            let context = DecodingError.Context.init(codingPath: currentPath, debugDescription: "Expected \(type) but find \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
    }
    
    func decodeSignedInt<T:SignedInteger & FixedWidthInteger>(_ type: T.Type, forKey key:Key) throws -> T {
        let currentPath = codingPath + [key]
        let object = try getValue(type, forKey: key)
        let xpcType = xpc_get_type(object)
        guard xpcType == XPC_TYPE_INT64 else {
            let context = DecodingError.Context.init(codingPath: currentPath, debugDescription: "Expected Signed Integer but find \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
        let rawValue = xpc_int64_get_value(object)
        if let realValue = T.init(exactly: rawValue) {
            return realValue
        } else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "\(rawValue) does not fit in \(type)")
            throw DecodingError.typeMismatch(type, context)
        }
    }
    
    func decodeUnsignedInt<T:UnsignedInteger & FixedWidthInteger>(_ type:T.Type, forKey key:Key) throws -> T {
        let currentPath = codingPath + [key]
        let object = try getValue(type, forKey: key)
        let xpcType = xpc_get_type(object)
        guard xpcType == XPC_TYPE_UINT64 else {
            let context = DecodingError.Context.init(codingPath: currentPath, debugDescription: "Expected Unsigned Integer but find \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(type, context)
        }
        let rawValue = xpc_uint64_get_value(object)
        if let realValue = T.init(exactly: rawValue) {
            return realValue
        } else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "\(rawValue) does not fit in \(type)")
            throw DecodingError.typeMismatch(type, context)
        }
    }
    
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decodeBinaryFloatingPoint(type, forKey: key)
    }
    
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try decodeBinaryFloatingPoint(type, forKey: key)
    }
    
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try decodeSignedInt(type, forKey: key)
    }
    
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try decodeSignedInt(type, forKey: key)
    }
    
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try decodeSignedInt(type, forKey: key)
    }
    
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try decodeSignedInt(type, forKey: key)
    }
    
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try decodeSignedInt(type, forKey: key)
    }
    
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try decodeUnsignedInt(type, forKey: key)
    }
    
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try decodeUnsignedInt(type, forKey: key)
    }
    
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try decodeUnsignedInt(type, forKey: key)
    }
    
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try decodeUnsignedInt(type, forKey: key)
    }
    
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try decodeUnsignedInt(type, forKey: key)
    }
    
    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T : Decodable {
        let currentPath = codingPath + [key]
        let object = try getValue(type, forKey: key)
        let xpcType = xpc_get_type(object)
        let value:T
        switch type {
        case is any XPCFileDescriptorProtocol.Type:
            guard xpcType == XPC_TYPE_FD else {
                let context = DecodingError.Context(
                    codingPath: currentPath,
                    debugDescription: "Expected FileDescriptor but found \(xpcTypeName(xpcType)) instead"
                )
                throw DecodingError.typeMismatch(type, context)
            }
            let rawFD = xpc_fd_dup(object)
            guard rawFD != -1 else {
                let context = DecodingError.Context(codingPath: currentPath, debugDescription: "XPC Frame work failed recognize FileDescriptor ")
                throw DecodingError.dataCorrupted(context)
            }
            if let realFd = (type as! any XPCFileDescriptorProtocol.Type).init(rawValue: rawFD) {
                value = realFd as! T
            } else {
                let context = DecodingError.Context(codingPath: currentPath, debugDescription: "fail to create \(type) from valid fileDescriptor \(rawFD)")
                throw DecodingError.dataCorrupted(context)
            }
            break
        case is Data.Type:
            guard xpcType == XPC_TYPE_DATA else {
                let context = DecodingError.Context(
                    codingPath: currentPath,
                    debugDescription: "Expected Data but found \(xpcTypeName(xpcType)) instead"
                )
                throw DecodingError.typeMismatch(type, context)
            }
            let ptr = UnsafeRawBufferPointer(start: xpc_data_get_bytes_ptr(object), count: xpc_data_get_length(object))
            value = Data(ptr) as! T
            break
        case is Date.Type:
            guard xpcType == XPC_TYPE_DATE else {
                let context = DecodingError.Context(
                    codingPath: currentPath,
                    debugDescription: "Expected Date but found \(xpcTypeName(xpcType)) instead"
                )
                throw DecodingError.typeMismatch(type, context)
            }
            let epochNanos = xpc_date_get_value(object)
            value = Date(fromEpochNanos: epochNanos) as! T
        case is UUID.Type:
            guard xpcType == XPC_TYPE_UUID else {
                let context = DecodingError.Context(
                    codingPath: currentPath,
                    debugDescription: "Expected UUID but found \(xpcTypeName(xpcType)) instead"
                )
                throw DecodingError.typeMismatch(type, context)
            }
            guard let bytes = xpc_uuid_get_bytes(object) else {
                let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Expected valid uuid bytes from xpc api failed to recognize it")
                throw DecodingError.dataCorrupted(context)
            }
            value = (NSUUID.init(uuidBytes: bytes) as UUID) as! T

            break
        default:
            let decoder = _XPCDecoderImp(ref: object, codingPath: currentPath, userInfo: userInfo)
            value = try T.init(from: decoder)
            break
        }
        return value
    }
    
    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey : CodingKey {
        let currentPath = codingPath + [key]
        let object = try getValue(forKey: key)
        let xpcType = xpc_get_type(object)
        if xpcType == XPC_TYPE_NULL {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Expected Dictionary but find null instead")
            throw DecodingError.valueNotFound(KeyedDecodingContainer<NestedKey>.self, context)
        }
        guard xpcType == XPC_TYPE_DICTIONARY else {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Expected Dictionary but find \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(KeyedDecodingContainer<NestedKey>.self, context)
        }
        let container = _XPCKeyedDecodingContainer<NestedKey>(userInfo: userInfo, ref: object, codingPath: currentPath)
        return .init(container)
    }
    
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let currentPath = codingPath + [key]
        let object = try getValue(forKey: key)
        let xpcType = xpc_get_type(object)
        if xpcType == XPC_TYPE_NULL {
            let context = DecodingError.Context.init(codingPath: currentPath, debugDescription: "Expected Array but find null instead")
            throw DecodingError.valueNotFound(UnkeyedDecodingContainer.self, context)
        }
        guard xpcType == XPC_TYPE_ARRAY else {
            let context = DecodingError.Context.init(codingPath: currentPath, debugDescription: "Expected Array but find \(xpcTypeName(xpcType)) instead")
            throw DecodingError.typeMismatch(UnkeyedDecodingContainer.self, context)
        }
        let container = _XPCUnKeyedDecodingContainer(ref: object, path: currentPath, userInfo: userInfo)
        
        return container
    }
    
    func superDecoder() throws -> Decoder {
        let currentPath = codingPath + [XPCCodingKey.super]
        let object = try getValue(forKey: XPCCodingKey.super)
        let xpcType = xpc_get_type(object)
        if xpcType == XPC_TYPE_NULL {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Cannot get superDecoder() -- encountered null")
            throw DecodingError.valueNotFound(Decoder.self, context)
        }
        return _XPCDecoderImp(ref: object, codingPath: currentPath, userInfo: userInfo)
    }
    
    func superDecoder(forKey key: Key) throws -> Decoder {
        let currentPath = codingPath + [key]
        let object = try getValue(forKey: key)
        let xpcType = xpc_get_type(object)
        if xpcType == XPC_TYPE_NULL {
            let context = DecodingError.Context(codingPath: currentPath, debugDescription: "Cannot get superDecoder() -- encountered null")
            throw DecodingError.valueNotFound(Decoder.self, context)
        }
        return _XPCDecoderImp(ref: object, codingPath: currentPath, userInfo: userInfo)
    }
    
}
