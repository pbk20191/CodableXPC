import System
import CodableXPC

// `System.FileDescriptor`'s conformance to `XPCFileDescriptorProtocol` lives in
// this separate target because `import System` forces an `LC_LOAD_DYLIB` on
// `/usr/lib/swift/libswiftSystem.dylib`, which is macOS 11+ and is not in any
// Swift back-deployment set. Keeping it out of `CodableXPC` is what lets a
// `CodableXPC` consumer launch on macOS 10.15.
//
// The conformance is retroactive now that it no longer lives beside the protocol.
// That is the deliberate trade for the deployment floor; `@retroactive` documents
// it, and is spelled conditionally because the attribute needs a Swift 6 compiler
// while this package is still tools-version 5.7.
#if compiler(>=6.0)
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
extension FileDescriptor: @retroactive XPCFileDescriptorProtocol {}
#else
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
extension FileDescriptor: XPCFileDescriptorProtocol {}
#endif
