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
    
    @usableFromInline
    var xpcRepresentation:xpc_object_t {
        xpc_date_create(Int64.init(timeIntervalSince1970 * 1_000_000_000))
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

internal extension Data {
    
    @usableFromInline
    var xpcData: xpc_object_t {
        return withUnsafeBytes {
            xpc_data_create($0.baseAddress, $0.count)
        }
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
