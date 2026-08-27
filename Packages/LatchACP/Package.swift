// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LatchACP",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "LatchACP", targets: ["LatchACP"]),
        .executable(name: "LatchACPProbe", targets: ["LatchACPProbe"]),
    ],
    targets: [
        .target(name: "LatchACP"),
        .executableTarget(
            name: "LatchACPProbe",
            dependencies: ["LatchACP"]
        ),
        .testTarget(
            name: "LatchACPTests",
            dependencies: ["LatchACP"]
        ),
    ]
)
