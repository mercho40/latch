// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LatchAgentCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "LatchAgentCore", targets: ["LatchAgentCore"]),
        .library(name: "LatchAgentXPC", targets: ["LatchAgentXPC"]),
        .executable(name: "LatchXPCProcessProbe", targets: ["LatchXPCProcessProbe"]),
    ],
    dependencies: [
        .package(path: "../LatchACP"),
        .package(path: "../LatchServiceProtocol"),
    ],
    targets: [
        .target(
            name: "LatchAgentCore",
            dependencies: ["LatchACP", "LatchServiceProtocol"]
        ),
        .testTarget(
            name: "LatchAgentCoreTests",
            dependencies: ["LatchAgentCore", "LatchACP", "LatchServiceProtocol"]
        ),
        .target(
            name: "LatchAgentXPC",
            dependencies: ["LatchAgentCore", "LatchServiceProtocol"]
        ),
        .testTarget(
            name: "LatchAgentXPCTests",
            dependencies: ["LatchAgentXPC", "LatchAgentCore", "LatchServiceProtocol"]
        ),
        .executableTarget(
            name: "LatchXPCProcessProbe",
            dependencies: ["LatchAgentXPC", "LatchAgentCore", "LatchServiceProtocol"]
        ),
    ]
)
