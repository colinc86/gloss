import Foundation
import OSLog
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterGo
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// Tree-sitter languages the app ships, found by file extension or by the name an injection query uses.
/// Query bundles are located here rather than by SwiftTreeSitter so `swift test` and the app both work.
public nonisolated enum GrammarCatalog {
    nonisolated private static let log = Logger(subsystem: "com.cnc.Gloss", category: "viewer")

    nonisolated private struct Grammar: Sendable {
        let name: String            // SwiftTreeSitter name, e.g. "Swift"
        let bundleName: String      // SwiftPM resource bundle, e.g. "TreeSitterSwift_TreeSitterSwift"
        /// Grammar function; TSLanguage pointers are immutable statics, so calling it anywhere is safe.
        let language: @Sendable () -> OpaquePointer
    }

    nonisolated private static let grammars: [String: Grammar] = [
        "swift": Grammar(name: "Swift", bundleName: "TreeSitterSwift_TreeSitterSwift", language: { tree_sitter_swift() }),
        "markdown": Grammar(name: "Markdown", bundleName: "TreeSitterMarkdown_TreeSitterMarkdown", language: { tree_sitter_markdown() }),
        "markdown_inline": Grammar(name: "MarkdownInline", bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline", language: { tree_sitter_markdown_inline() }),
        "json": Grammar(name: "JSON", bundleName: "TreeSitterJSON_TreeSitterJSON", language: { tree_sitter_json() }),
        "bash": Grammar(name: "Bash", bundleName: "TreeSitterBash_TreeSitterBash", language: { tree_sitter_bash() }),
        "python": Grammar(name: "Python", bundleName: "TreeSitterPython_TreeSitterPython", language: { tree_sitter_python() }),
        "c": Grammar(name: "C", bundleName: "TreeSitterC_TreeSitterC", language: { tree_sitter_c() }),
        "javascript": Grammar(name: "JavaScript", bundleName: "TreeSitterJavaScript_TreeSitterJavaScript", language: { tree_sitter_javascript() }),
        "typescript": Grammar(name: "TypeScript", bundleName: "TreeSitterTypeScript_TreeSitterTypeScript", language: { tree_sitter_typescript() }),
        "tsx": Grammar(name: "TSX", bundleName: "TreeSitterTypeScript_TreeSitterTSX", language: { tree_sitter_tsx() }),
        "yaml": Grammar(name: "YAML", bundleName: "TreeSitterYAML_TreeSitterYAML", language: { tree_sitter_yaml() }),
        "toml": Grammar(name: "TOML", bundleName: "TreeSitterTOML_TreeSitterTOML", language: { tree_sitter_toml() }),
        "rust": Grammar(name: "Rust", bundleName: "TreeSitterRust_TreeSitterRust", language: { tree_sitter_rust() }),
        "go": Grammar(name: "Go", bundleName: "TreeSitterGo_TreeSitterGo", language: { tree_sitter_go() }),
    ]

    nonisolated private static let extensions: [String: String] = [
        "swift": "swift",
        "md": "markdown", "markdown": "markdown", "mdown": "markdown", "mkd": "markdown", "mdx": "markdown",
        "json": "json", "jsonc": "json", "jsonl": "json", "ndjson": "json",
        "sh": "bash", "bash": "bash", "zsh": "bash", "bashrc": "bash", "zshrc": "bash",
        "py": "python", "pyi": "python",
        "c": "c", "h": "c",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "tsx",
        "yaml": "yaml", "yml": "yaml",
        "toml": "toml",
        "rs": "rust",
        "go": "go",
        // No grammar: `Highlighter` colours a diff by its lines' first characters.
        "diff": "diff", "patch": "diff",
    ]

    nonisolated private static let fileNames: [String: String] = [
        ".zshrc": "bash", ".bashrc": "bash", ".bash_profile": "bash", ".profile": "bash", "makefile": "bash",
        ".zprofile": "bash", ".zshenv": "bash", ".zlogin": "bash", ".zlogout": "bash", ".bash_aliases": "bash",
        ".bash_logout": "bash", ".envrc": "bash", "pkgbuild": "bash",
        // Lockfiles that are TOML under another extension.
        "cargo.lock": "toml", "poetry.lock": "toml", "uv.lock": "toml", "pipfile": "toml",
    ]

    /// Every extension and file name a grammar colors, so the kind detector can be checked to open them as code.
    nonisolated static var highlightedExtensions: Set<String> { Set(extensions.keys) }
    nonisolated static var highlightedFileNames: Set<String> { Set(fileNames.keys) }

    /// The injection language name tree-sitter queries use for a file, or nil when unsupported.
    public nonisolated static func languageName(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let byName = fileNames[name] { return byName }
        return extensions[(path as NSString).pathExtension.lowercased()]
    }

    public nonisolated static func supportedLanguageNames() -> [String] {
        Array(grammars.keys).sorted()
    }

    /// Cached per language; nil when the grammar or its queries cannot be found.
    public nonisolated static func configuration(forLanguage name: String) -> LanguageConfiguration? {
        cache.withLock { cache in
            if let cached = cache[name] { return cached.value }
            let built = build(name)
            cache[name] = Cached(value: built)
            return built
        }
    }

    nonisolated private struct Cached: Sendable { let value: LanguageConfiguration? }
    nonisolated private static let cache = Mutex<[String: Cached]>([:])

    nonisolated private static func build(_ name: String) -> LanguageConfiguration? {
        guard let grammar = grammars[name] else { return nil }
        guard let queries = queriesURL(bundleName: grammar.bundleName) else {
            log.error("No query bundle for \(name, privacy: .public) (\(grammar.bundleName, privacy: .public))")
            return nil
        }
        do {
            return try LanguageConfiguration(grammar.language(), name: grammar.name, queriesURL: queries)
        } catch {
            log.error("Loading queries for \(name, privacy: .public) failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// Looks in the main bundle, then beside every loaded bundle (where SwiftPM puts resource bundles for tests).
    nonisolated static func queriesURL(bundleName: String) -> URL? {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: bundleName, withExtension: "bundle") { candidates.append(url) }
        // Static linking puts this module inside the host (app or .xctest); SwiftPM copies resource bundles into
        // that host's Resources and also leaves them beside it in the products directory.
        let hosts = [Bundle(for: BundleAnchor.self), Bundle.main] + Bundle.allBundles
        var directories: [URL] = []
        for host in hosts {
            if let resources = host.resourceURL { directories.append(resources) }
            directories.append(host.bundleURL.deletingLastPathComponent())
        }
        var seen: Set<String> = []
        for directory in directories where seen.insert(directory.path).inserted {
            candidates.append(directory.appendingPathComponent("\(bundleName).bundle"))
        }
        for bundle in candidates {
            for queries in [bundle.appendingPathComponent("queries"), bundle.appendingPathComponent("Contents/Resources/queries")] {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: queries.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return queries
                }
            }
        }
        return nil
    }
}

import Synchronization

/// Only exists so `Bundle(for:)` can find the bundle this module was linked into.
private final class BundleAnchor {}
