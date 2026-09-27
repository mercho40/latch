// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatchiOS",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "LatchiOSUI", targets: ["LatchiOSUI"]),
    ],
    dependencies: [
        .package(path: "../../Packages/LatchACP"),
        .package(path: "../../Packages/LatchServiceProtocol"),
    ],
    targets: [
        .target(name: "LatchiOSUI", dependencies: [
            "LatchACP", "LatchServiceProtocol",
            .product(name: "LatchRemoteProtocol", package: "LatchServiceProtocol"),
            .product(name: "LatchRemoteClient", package: "LatchServiceProtocol"),
        ]),
        // UIKit tests: they run in the iOS Simulator through the `Latch iOS` scheme, not `swift test`.
        .testTarget(name: "LatchiOSUITests", dependencies: [
            "LatchiOSUI",
            .product(name: "LatchRemoteProtocol", package: "LatchServiceProtocol"),
        ]),
    ]
)
