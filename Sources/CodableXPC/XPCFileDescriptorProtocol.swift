//
//  XPCFileDescriptorProtocol.swift
//  a
//
//  Created by pbk on 2023/05/25.
//

import Foundation

// This file must not `import System`. Linking `libswiftSystem.dylib` is a hard
// `LC_LOAD_DYLIB` on the consumer binary, and that dylib does not exist before
// macOS 11 and is not in any Swift back-deployment set — so a consumer of
// `CodableXPC` would fail to launch on macOS 10.15 before any `@available`
// check could run. The `System.FileDescriptor` conformance therefore lives in
// the separate `CodableXPCSystem` target/product.

public protocol XPCFileDescriptorProtocol: Codable & RawRepresentable<CInt> {


}

public struct FileHandleHolder: XPCFileDescriptorProtocol {

    public init(rawValue: Int32) {
        self.fileHandle = .init(fileDescriptor: rawValue, closeOnDealloc: true)
    }

    public var rawValue: Int32 {
        fileHandle.fileDescriptor
    }

    public let fileHandle:FileHandle

}
