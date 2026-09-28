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
        .package(path: "../../Packages/LatchAgentCore"),
        .package(path: "../../Packages/LatchServiceProtocol"),
        .package(path: "../../Packages/LatchSessionKit"),
    ],
    targets: [
        .target(name: "LatchiOSUI", dependencies: [
            "LatchACP", "LatchServiceProtocol", "LatchSessionKit",
            .product(name: "LatchAgentCore", package: "LatchAgentCore"),
            .product(name: "LatchRemoteProtocol", package: "LatchServiceProtocol"),
            .product(name: "LatchRemoteClient", package: "LatchServiceProtocol"),
        ]),
        // Its tests, in Tests/LatchiOSUITests, are a target of Latch.xcodeproj hosted by the app,
        // so they run with its Keychain entitlement; the `Latch iOS` scheme runs them.
    ]
)
