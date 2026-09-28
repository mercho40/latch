// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LatchAgentCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "LatchAgentCore", targets: ["LatchAgentCore"]),
        .library(name: "LatchAgentXPC", targets: ["LatchAgentXPC"]),
        .library(name: "LatchAgentServer", targets: ["LatchAgentServer"]),
        .executable(name: "LatchXPCProcessProbe", targets: ["LatchXPCProcessProbe"]),
        .executable(name: "latch-server", targets: ["latch-server"]),
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
        .target(
            name: "LatchAgentServer",
            dependencies: [
                "LatchAgentCore", "LatchACP", "LatchServiceProtocol",
                .product(name: "LatchRemoteProtocol", package: "LatchServiceProtocol"),
            ]
        ),
        .testTarget(
            name: "LatchAgentServerTests",
            dependencies: [
                "LatchAgentServer", "LatchAgentCore", "LatchACP", "LatchServiceProtocol",
                .product(name: "LatchRemoteProtocol", package: "LatchServiceProtocol"),
                // The client against the real server; its sources are Apple-only.
                .product(name: "LatchRemoteClient", package: "LatchServiceProtocol", condition: .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "latch-server",
            dependencies: ["LatchAgentServer"],
            linkerSettings: [
                // musl gives every thread 128 KiB of stack unless PT_GNU_STACK asks for more,
                // and decoding deeply nested JSON needs more; glibc already gives 8 MiB.
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "stack-size=8388608"], .when(platforms: [.linux])),
            ]
        ),
        .executableTarget(
            name: "LatchXPCProcessProbe",
            dependencies: ["LatchAgentXPC", "LatchAgentCore", "LatchServiceProtocol"]
        ),
    ]
)
