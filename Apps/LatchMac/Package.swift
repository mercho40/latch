// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatchMac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LatchMacUI", targets: ["LatchMacUI"]),
        .library(name: "LatchAgentServiceHost", targets: ["LatchAgentServiceHost"]),
        .executable(name: "Latch", targets: ["Latch"]),
    ],
    dependencies: [
        .package(path: "../../Packages/LatchACP"),
        .package(path: "../../Packages/LatchAgentCore"),
        .package(path: "../../Packages/LatchServiceProtocol"),
    ],
    targets: [
        .target(name: "LatchMacUI", dependencies: [
            "LatchACP", "LatchAgentCore", "LatchServiceProtocol",
            .product(name: "LatchAgentXPC", package: "LatchAgentCore"),
        ]),
        .target(name: "LatchAgentServiceHost", dependencies: [
            .product(name: "LatchAgentXPC", package: "LatchAgentCore"),
        ]),
        .executableTarget(name: "Latch", dependencies: ["LatchMacUI"]),
        .testTarget(name: "LatchMacUITests", dependencies: ["LatchMacUI", "LatchServiceProtocol"]),
    ]
)
