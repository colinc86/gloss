// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Viewers",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Viewers", targets: ["Viewers"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.9.0"),
        // The stale 0.25.0 tag sorts above the current 0.10.x line; never use `from:` here.
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", .upToNextMinor(from: "0.10.0")),
        // Only the `-with-generated-files` tags include src/parser.c.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.5.3"),
    ],
    targets: [
        .target(
            name: "Viewers",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "SwiftTreeSitterLayer", package: "swift-tree-sitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "ViewersTests",
            dependencies: ["Viewers"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
