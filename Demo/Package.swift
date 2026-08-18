// swift-tools-version: 6.0
import PackageDescription

// A package of its own, depending on the library by path, rather than three more targets in
// the root `Package.swift`.
//
// The root package's whole deployment story is that a consumer who wants `CodableXPC` on
// macOS 10.15 does not link `libswiftDistributed` or `libswiftSystem` -- there are two long
// comments in it about exactly that. Executables that need macOS 15 and `import Distributed`
// have no business inside that graph: they would raise the toolchain's view of the package for
// everyone who merely resolves it, and `swift build` at the root would start building two
// binaries nobody asked for.
let package = Package(
    name: "XPCActorsDemo",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        // The contract. Linked by both processes and by neither's implementation.
        .target(
            name: "DemoProtocol",
            dependencies: [.product(name: "XPCActors", package: "CodableXPC")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // Runs inside the `.xpc` bundle, started by launchd on demand.
        .executableTarget(
            name: "DemoService",
            dependencies: ["DemoProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // Runs as the application. Dials the service.
        .executableTarget(
            name: "DemoHost",
            dependencies: ["DemoProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
