// swift-tools-version: 6.1
// `swiftLanguageModes: [.v5]` (below) requires tools-version 6.0+, and the pin is not
// tidiness: from tools-version 6.0 the default language mode becomes v6, so a build-system
// version bump would otherwise switch every target to strict concurrency checking. Pinned so
// the toolchain version does exactly one thing. The deployment floor below is untouched by it.

import PackageDescription

// The `System` surface is split into its own targets on purpose.
//
// `import System` puts a hard `LC_LOAD_DYLIB` on `/usr/lib/swift/libswiftSystem.dylib`
// into every consumer binary. That dylib first shipped in macOS 11 and is not part of
// any Swift back-deployment set (only `libswiftXPC.dylib` is, under `swift-5.0/macosx`),
// and `@available` gates compilation rather than the load command. A consumer that
// linked it would therefore be killed by dyld on macOS 10.15 before any code ran.
//
// `CodableXPC` and `XPCCompat` consequently never `import System`. Everything that
// needs `System.FileDescriptor` lives in `XPCCompatSystem`, which is macOS 11+
// throughout and which a 10.15 consumer simply does not link.
let package = Package(
    name: "CodableXPC",
    platforms: [
        .macOS(.v10_13),
        .macCatalyst("13.1")

    ],
    products: [
        .library(
            name: "CodableXPC",
            targets: ["CodableXPC"]),
        .library(
            name: "XPCCompat",
            targets: ["XPCCompat"]),
        .library(
            name: "XPCCompatSystem",
            targets: ["XPCCompatSystem"]),
        .library(
            name: "XPCActors",
            targets: ["XPCActors"]),
        .library(
            name: "XPCOverlayCoder",
            targets: ["XPCOverlayCoder"]),
    ],
    targets: [
        // One helper, shared by the two coders that both hand a Data to libxpc.
        // A target of its own because neither coder should depend on the other.
        .target(
            name: "XPCDispatchDataBridge",
            dependencies: []),
        .target(
            name: "CodableXPC",
            dependencies: ["XPCDispatchDataBridge"]),
        .target(
            name: "XPCCompat",
            dependencies: ["CodableXPC"]),
        // macOS 11+ only: adds the System.FileDescriptor subscripts. Links libswiftSystem.
        .target(
            name: "XPCCompatSystem",
            dependencies: ["XPCCompat"]),
        // macOS 13+ only: a DistributedActorSystem over XPC. Split out because
        // `import Distributed` puts an LC_LOAD_DYLIB on libswiftDistributed.dylib,
        // which is macOS 13+ and in no back-deployment set -- the same trap
        // `import System` set for CodableXPC. A 10.15 consumer links CodableXPC
        // and never loads it. That dylib is now the *only* thing setting this
        // target's floor: the transport speaks to `xpc_connection_t` rather than to
        // the Swift overlay's macOS 14/15 `XPCSession`/`XPCListener`/`XPCEndpoint`.
        // **Standalone.** A packet body is whatever `XPCDictionary.encode(_:forKey:withUserInfo:)`
        // produces -- an overlay byte stream, not a native xpc tree -- and `XPCActors` now calls
        // *Apple's own* coder for it (`AppleCoder.swift` binds the exported-but-unheadered
        // `libswiftXPC` symbols with `@_silgen_name`), so it needs no coder dependency of its own.
        .target(
            name: "XPCActors",
            dependencies: []),
        // Reproduces every wire format Apple's XPC Swift overlay has used for
        // Codable -- the iOS 17/18 byte stream and the iOS 26+ encoding graph.
        // They share no tag values, no framing and no envelope, only a lineage, so
        // they are two implementations behind one generation-selecting surface.
        // Separate from CodableXPC on purpose: that one builds a native xpc tree.
        .target(
            name: "XPCOverlayCoder",
            dependencies: ["XPCDispatchDataBridge"]),
        .testTarget(
            name: "CodableXPCTests",
            dependencies: ["CodableXPC"]),
        .testTarget(
            name: "XPCCompatTests",
            dependencies: ["XPCCompat"]),
        .testTarget(
            name: "XPCCompatSystemTests",
            dependencies: ["XPCCompatSystem"]),
        // `XPCOverlayCoder` is named explicitly rather than picked up transitively:
        // the interop tests reach for `AppleCoderBridge` and `OverlayEnvelope`
        // directly, and a transitive import is not a dependency anyone declared.
        .testTarget(
            name: "XPCActorsTests",
            dependencies: ["XPCActors", "XPCOverlayCoder", "CodableXPC"]),
        .testTarget(
            name: "XPCOverlayCoderTests",
            dependencies: ["XPCOverlayCoder", "CodableXPC"]),
    ],
    // See the tools-version note at the top: pinned so the toolchain version does not also
    // switch every target to the Swift 6 language mode.
    swiftLanguageModes: [.v5]
)
