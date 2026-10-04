// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Integrations",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Integrations", targets: ["Integrations"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "Integrations",
            dependencies: [
                .product(name: "Core", package: "Core"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "IntegrationsTests",
            dependencies: ["Integrations"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
