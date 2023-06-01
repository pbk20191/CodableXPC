//
//  XPCFileDescriptorProtocol.swift
//  a
//
//  Created by pbk on 2023/05/25.
//

import Foundation
import System

public protocol XPCFileDescriptorProtocol: Codable & RawRepresentable<CInt> {


}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension FileDescriptor: XPCFileDescriptorProtocol {}

public struct FileHandleHolder: XPCFileDescriptorProtocol {
    
    public init(rawValue: Int32) {
        self.fileHandle = .init(fileDescriptor: rawValue, closeOnDealloc: true)
    }
    
    public var rawValue: Int32 {
        fileHandle.fileDescriptor
    }
    
    public let fileHandle:FileHandle
    
}
