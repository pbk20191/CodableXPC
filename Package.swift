// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

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
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "CodableXPC",
            dependencies: []),
        .target(
            name: "XPCCompat",
            dependencies: ["CodableXPC"]),
        .testTarget(
            name: "CodableXPCTests",
            dependencies: ["CodableXPC"]),
        .testTarget(
            name: "XPCCompatTests",
            dependencies: ["XPCCompat"]),
    ]
)
