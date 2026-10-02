// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transports",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Transports", targets: ["Transports"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Remote"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "Transports",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "Remote", package: "Remote"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            resources: [.copy("Resources/HookScripts")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "TransportsTests", dependencies: ["Transports"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
