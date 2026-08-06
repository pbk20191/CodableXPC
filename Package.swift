// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

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
// needs `System.FileDescriptor` lives in `CodableXPCSystem` / `XPCCompatSystem`,
// which are macOS 11+ throughout and which a 10.15 consumer simply does not link.
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
            name: "CodableXPCSystem",
            targets: ["CodableXPCSystem"]),
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
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "CodableXPC",
            dependencies: []),
        // macOS 11+ only: adds the System.FileDescriptor conformance. Links libswiftSystem.
        .target(
            name: "CodableXPCSystem",
            dependencies: ["CodableXPC"]),
        .target(
            name: "XPCCompat",
            dependencies: ["CodableXPC"]),
        // macOS 11+ only: adds the System.FileDescriptor subscripts. Links libswiftSystem.
        .target(
            name: "XPCCompatSystem",
            dependencies: ["XPCCompat"]),
        // macOS 14+ only: a DistributedActorSystem over XPC. Split out because
        // `import Distributed` puts an LC_LOAD_DYLIB on libswiftDistributed.dylib,
        // which is macOS 13+ and in no back-deployment set -- the same trap
        // `import System` set for CodableXPC. A 10.15 consumer links CodableXPC
        // and never loads it.
        .target(
            name: "XPCActors",
            dependencies: ["CodableXPC"]),
        // Carrying Codable values over NSXPC, which can only move NSSecureCoding
        // objects. Foundation only -- no dependency on CodableXPC, and no platform
        // floor above the package's own, so a 10.13 consumer can use it.
        .target(
            name: "XPCCodable",
            dependencies: []),
        .testTarget(
            name: "CodableXPCTests",
            dependencies: ["CodableXPC"]),
        .testTarget(
            name: "XPCCompatTests",
            dependencies: ["XPCCompat"]),
        .testTarget(
            name: "XPCCompatSystemTests",
            dependencies: ["XPCCompatSystem"]),
        .testTarget(
            name: "XPCActorsTests",
            dependencies: ["XPCActors"]),
        .testTarget(
            name: "XPCCodableTests",
            dependencies: ["XPCCodable"]),
    ]
)
