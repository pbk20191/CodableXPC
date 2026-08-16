// swift-tools-version: 6.1
// Raised from 5.9 for **traits** (see `traits:` below), which are the only user-facing
// opt-in SwiftPM offers a library target. As with the 5.7 -> 5.9 raise for `.macro`, this
// moves the minimum *toolchain* that can build the package and not the platforms it runs
// on -- the deployment floor below is untouched.
//
// `swiftLanguageModes: [.v5]` is not tidiness. From tools-version 6.0 the default language
// mode becomes v6, so raising the version would otherwise switch every target to strict
// concurrency checking -- a behaviour change smuggled in by a build-system version bump.
// Pinned so this change does exactly one thing.

import PackageDescription
import CompilerPluginSupport

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
            name: "XPCCodable",
            targets: ["XPCCodable"]),
        .library(
            name: "XPCOverlayCoder",
            targets: ["XPCOverlayCoder"]),
    ],
    // ─────────────────────────────────────────────────────────────────────────────────
    // Off by default, and it has to stay that way.
    //
    // `NSXPCConnection.delegate` and its `replacementObjectForXPCConnection:encoder:object:`
    // hook are **private API**. They are real and they work; every line below was measured
    // against an in-process `NSXPCListener`, not inferred:
    //
    //   - `NSXPCEncoder` consults the connection's delegate while encoding each `id`
    //     argument, on the sending side, and the substituted object is what the peer
    //     actually receives.
    //   - It fires for reply values too, from the replying side. So both directions are
    //     interceptable, which is what would make it useful.
    //   - The hook must **return an object**. Returning nil raises
    //     `NSInvalidArgumentException` from `-[NSXPCEncoder _replaceObject:]` -- "The
    //     replacement object must not be nil." Returning the argument unchanged is how "do
    //     not replace" is spelled, and reading the header the other way crashes on the first
    //     argument you did not want to touch.
    //   - `setDelegate:` and `delegate` are present on `NSXPCConnection` in the Objective-C
    //     runtime; `_handoffCurrentReplyToQueue:block:`, which the exploratory code also
    //     named, is not.
    //
    // Why it is tempting: the boxing `@XPCService` generates could move into the coder, so a
    // generated shim signature would stop naming `NSXPCCodableBridgeBox` at all. Why it is
    // not the default: a shipping binary that calls this is calling private API, and a future
    // OS is free to delete it. A trait is the compromise -- absent unless a consumer asks for
    // it, and the default build cannot so much as name the symbols.
    // ─────────────────────────────────────────────────────────────────────────────────
    traits: [
        .trait(
            name: "NSXPCPrivateAPI",
            description: "Bind NSXPCConnection's private delegate hook and proxy overloads. Private API: not for a shipping binary."),
    ],
    dependencies: [
        // Only the macro plugin needs this. SwiftPM resolves it for anyone who
        // depends on the package at all, so it is a real cost imposed on consumers
        // who only want CodableXPC -- accepted deliberately to keep one repository.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"604.0.0"),
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
        // `libswiftXPC` symbols with `@_silgen_name`), so it no longer depends on the
        // `XPCOverlayCoder` reconstruction. That reconstruction remains its own target, verified
        // against Apple's coder in tests.
        .target(
            name: "XPCActors",
            dependencies: []),
        // Carrying Codable values over NSXPC, which can only move NSSecureCoding
        // objects. Foundation only -- no dependency on CodableXPC, and no platform
        // floor above the package's own, so a 10.13 consumer can use it.
        .target(
            name: "XPCCodable",
            dependencies: ["XPCCodableMacros", "CodableXPC"]),
        // Reproduces every wire format Apple's XPC Swift overlay has used for
        // Codable -- the iOS 17/18 byte stream and the iOS 26+ encoding graph.
        // They share no tag values, no framing and no envelope, only a lineage, so
        // they are two implementations behind one generation-selecting surface.
        // Separate from CodableXPC on purpose: that one builds a native xpc tree.
        .target(
            name: "XPCOverlayCoder",
            dependencies: ["XPCDispatchDataBridge"]),
        // The macro plugin. Runs in the compiler, never in a consumer binary, so it
        // carries no deployment floor of its own.
        .macro(
            name: "XPCCodableMacros",
            dependencies: [
                "XPCCodableMacrosCore",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]),
        // The expansion logic, as a plain library. Split from the plugin host above
        // so tests can link it with an ordinary import: `@testable import` of a
        // `.macro` executable fails to link under the swiftbuild build system.
        .target(
            name: "XPCCodableMacrosCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]),
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
        // Declares a public @XPCService protocol and nothing else. Its only job is
        // to be a *different module* from the tests that consume it.
        .target(
            name: "XPCCodableSharedInterfaceFixture",
            dependencies: ["XPCCodable"]),
        .testTarget(
            name: "XPCCodableTests",
            dependencies: ["XPCCodable", "XPCCodableSharedInterfaceFixture"]),
        // Expansion tests run the plugin in-process against source text, so unlike a
        // consumer they link swift-syntax directly rather than going through the
        // compiler's plugin host.
        .testTarget(
            name: "XPCCodableMacrosTests",
            dependencies: [
                "XPCCodableMacrosCore",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]),
    ],
    // See the tools-version note at the top: pinned so raising to 6.1 does not also switch
    // every target to the Swift 6 language mode.
    swiftLanguageModes: [.v5]
)
