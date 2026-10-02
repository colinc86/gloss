// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Remote",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Remote", targets: ["Remote"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "Remote",
            dependencies: [
                .product(name: "Core", package: "Core"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "RemoteTests",
            dependencies: ["Remote"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
