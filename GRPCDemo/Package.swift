// swift-tools-version: 6.1
import PackageDescription

// A package of its own, depending on the library by path, for the same reason `Demo/` is one.
//
// This demo needs `grpc-swift-protobuf` -- for the `GRPCProtobufGenerator` build plugin and for
// the `ProtobufSerializer`/`ProtobufDeserializer` the generated code names. Adding it at the root
// would make every consumer who merely resolves `CodableXPC` also resolve `swift-protobuf`, and
// would make `swift build` at the root run `protoc` and build two executables nobody asked for,
// to demonstrate something the library itself does not need. The root package's dependency floor
// stays exactly where it was: `grpc-swift-2`, and nothing else.
let package = Package(
    name: "GRPCXPCDemo",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: ".."),
        // Named directly rather than taken transitively through `CodableXPC` or through
        // `grpc-swift-protobuf`: all three targets `import GRPCCore` themselves, and a
        // transitive import is not a dependency anyone declared. Same rule the root package
        // states for its test targets.
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.1"),
        // 2.x line. Brings `swift-protobuf` and nothing else on top of what the root already
        // resolves -- in particular no NIO, which is the entire point of the XPC transport.
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.1"),
    ],
    targets: [
        // The contract, generated from `demo.proto` by the `GRPCProtobufGenerator` build plugin.
        // Linked by both processes; implemented by neither. Exactly the role `Demo/DemoProtocol`
        // plays, except that here nobody writes it by hand.
        .target(
            name: "DemoProto",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
            ]),
        // Runs inside the `.xpc` bundle, started by launchd on demand.
        .executableTarget(
            name: "CalcService",
            dependencies: [
                "DemoProto",
                .product(name: "GRPCXPCTransport", package: "CodableXPC"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        // Runs as the application. Dials the service by bundle identifier.
        .executableTarget(
            name: "CalcHost",
            dependencies: [
                "DemoProto",
                .product(name: "GRPCXPCTransport", package: "CodableXPC"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
