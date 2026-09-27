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
            dependencies: ["LatchServiceProtocol", "LatchACP"]
        ),
        .testTarget(
            name: "LatchRemoteProtocolTests",
            dependencies: ["LatchRemoteProtocol", "LatchServiceProtocol", "LatchACP"]
        ),
    ]
)
