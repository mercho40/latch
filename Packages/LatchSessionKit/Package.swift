// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LatchSessionKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "LatchSessionKit", targets: ["LatchSessionKit"]),
        // A real latch-server on loopback, for the Mac app's tests as well as this package's.
        .library(name: "LatchSessionKitTestSupport", targets: ["LatchSessionKitTestSupport"]),
    ],
    dependencies: [
        .package(path: "../LatchACP"),
        .package(path: "../LatchServiceProtocol"),
        .package(path: "../LatchAgentCore"),
    ],
    targets: [
        .target(
            name: "LatchSessionKit",
            dependencies: [
                "LatchACP", "LatchServiceProtocol", "LatchAgentCore",
                .product(name: "LatchRemoteProtocol", package: "LatchServiceProtocol"),
                .product(name: "LatchRemoteClient", package: "LatchServiceProtocol"),
            ]
        ),
        // Built on macOS only: every source is wrapped in `#if os(macOS)`.
        .target(
            name: "LatchSessionKitTestSupport",
            dependencies: [
                "LatchSessionKit", "LatchAgentCore", "LatchServiceProtocol",
                .product(name: "LatchRemoteProtocol", package: "LatchServiceProtocol"),
                .product(name: "LatchAgentServer", package: "LatchAgentCore", condition: .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "LatchSessionKitTests",
            dependencies: [
                "LatchSessionKit", "LatchSessionKitTestSupport", "LatchACP", "LatchServiceProtocol", "LatchAgentCore",
                .product(name: "LatchRemoteProtocol", package: "LatchServiceProtocol"),
                .product(name: "LatchRemoteClient", package: "LatchServiceProtocol"),
                // A real latch-server in the test process, for remote sessions end to end.
                .product(name: "LatchAgentServer", package: "LatchAgentCore", condition: .when(platforms: [.macOS])),
            ]
        ),
    ]
)
