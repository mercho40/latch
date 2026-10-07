// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LatchServiceProtocol",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "LatchServiceProtocol", targets: ["LatchServiceProtocol"]),
        .library(name: "LatchRemoteProtocol", targets: ["LatchRemoteProtocol"]),
        .library(name: "LatchRemoteClient", targets: ["LatchRemoteClient"]),
    ],
    dependencies: [
        .package(path: "../LatchACP"),
    ],
    targets: [
        .target(
            name: "LatchServiceProtocol",
            dependencies: ["LatchACP"]
        ),
        .testTarget(
            name: "LatchServiceProtocolTests",
            dependencies: ["LatchServiceProtocol", "LatchACP"]
        ),
        .target(
            name: "LatchRemoteProtocol",
            dependencies: ["LatchServiceProtocol", "LatchACP", "CLatchZlib"]
        ),
        // zlib, a system library on every platform Latch builds for.
        .systemLibrary(name: "CLatchZlib"),
        .testTarget(
            name: "LatchRemoteProtocolTests",
            dependencies: ["LatchRemoteProtocol", "LatchServiceProtocol", "LatchACP"]
        ),
        // Built on Apple platforms only: every source is wrapped in `#if canImport(Network)`.
        .target(
            name: "LatchRemoteClient",
            dependencies: ["LatchRemoteProtocol", "LatchServiceProtocol", "LatchACP"]
        ),
        .testTarget(
            name: "LatchRemoteClientTests",
            dependencies: ["LatchRemoteClient", "LatchRemoteProtocol", "LatchServiceProtocol", "LatchACP"]
        ),
    ]
)
