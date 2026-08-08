//
//  XPCObjectEnum.swift
//  
//
//  Created by pbk on 2023/05/26.
//

import Foundation
#if canImport(XPC)
import XPC



internal extension Date {
    
    /// `xpc_date_create` takes nanoseconds in an `Int64`, which reaches roughly
    /// ±292 years around 1970. `Date.distantPast` and `Date.distantFuture` are
    /// thousands of years outside it, and the conversion used to trap on the way
    /// — a crash, in an encoder, for a value `Date` hands out as a constant.
    @usableFromInline
    func xpcRepresentation(at path: [any CodingKey]) throws -> xpc_object_t {
        let nanos = timeIntervalSince1970 * 1_000_000_000
        guard nanos >= -9.223372036854775e18, nanos <= 9.223372036854775e18,
              nanos.isFinite else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: path,
                debugDescription: "an xpc date is nanoseconds in an Int64, which "
                    + "reaches about ±292 years around 1970; this one is outside that"))
        }
        return xpc_date_create(Int64(nanos))
    }

    @usableFromInline
    init(fromEpochNanos nanosecs:Int64) {
        self.init(timeIntervalSince1970: Double(nanosecs) / 1_000_000_000)
    }
    
}


internal extension UUID {
    
    @usableFromInline
    var xpcUUID: xpc_object_t {
        let bridge = self as NSUUID
    
        var buffer = [UInt8](repeating: 0, count: MemoryLayout.size(ofValue: uuid))
        bridge.getBytes(&buffer)
        return xpc_uuid_create(buffer)
    }
    
}

internal extension String {

    /// `xpc_string_create` takes a C string, so it stops at the first NUL while a
    /// Swift `String` may contain one. Encoding such a value would silently drop
    /// everything after it, which is worse than refusing.
    @usableFromInline
    func xpcString(at path: [any CodingKey]) throws -> xpc_object_t {
        guard !utf8.contains(0) else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: path,
                debugDescription: "an xpc string cannot carry an embedded NUL; "
                    + "this one would be truncated there, silently, so it is refused"))
        }
        return xpc_string_create(self)
    }
}

internal extension Data {
    
    /// Routed through ``DispatchDataBridge``, which takes the cheaper of two
    /// copies at size and the plain one below it.
    @usableFromInline
    var xpcData: xpc_object_t {
        DispatchDataBridge.xpcData(for: self)
    }
    
    
}


internal func xpcTypeName(_ type:xpc_type_t) -> String {
    
    if #available(macOS 10.15, macCatalyst 13.1, *) {
        return String(cString: xpc_type_get_name(type))
    } else {
        switch type {
        case XPC_TYPE_NULL:
            return "null"
        case XPC_TYPE_BOOL:
            return "Bool"
        case XPC_TYPE_DATA:
            return "Data"
        case XPC_TYPE_DATE:
            return "Date"
        case XPC_TYPE_UUID:
            return "UUID"
        case XPC_TYPE_ARRAY:
            return "Array"
        case XPC_TYPE_FD:
            return "FileDescriptor"
        case XPC_TYPE_ERROR:
            return "Error"
        case XPC_TYPE_SHMEM:
            return "SHMEM"
        case XPC_TYPE_DOUBLE:
            return "Double"
        case XPC_TYPE_INT64:
            return "Int64"
        case XPC_TYPE_DICTIONARY:
            return "Dictionary"
        case XPC_TYPE_ACTIVITY:
            return "Activity"
        case XPC_TYPE_UINT64:
            return "UInt64"
        case XPC_TYPE_CONNECTION:
            return "Connection"
        case XPC_TYPE_ENDPOINT:
            return "EndPoint"
        case XPC_TYPE_STRING:
            return "String"
        default:
            return "Unknown"
        }
    }
    
}


#endif
