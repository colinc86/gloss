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
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.25.1"),
        // Newer tags add src/scanner.c only when a cwd-relative FileManager check passes, which fails under SwiftPM.
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", from: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", from: "0.7.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", from: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", from: "0.25.0"),
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
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
            ],
            // Mermaid (MIT, pinned; see MermaidRenderer.version) draws diagrams offline.
            resources: [.copy("Resources/Mermaid")],
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
