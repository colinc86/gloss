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
    /// Fenced-code info string to a grammar name: `swift`, `sh`, `ts`, `py` and friends. The rendered view and a
    /// Markdown source's embedded code blocks both ask it, so a ```py block is coloured in either.
    public nonisolated static func grammarName(forFence info: String?) -> String? {
        guard let word = info?.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first?.lowercased(), !word.isEmpty else { return nil }
        let aliases = ["shell": "bash", "console": "bash", "shellsession": "bash", "golang": "go", "md": "markdown"]
        if let alias = aliases[word] { return alias }
        if supportedLanguageNames().contains(word) { return word }
        return languageName(forPath: "x.\(word)")
    }

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
            let configuration = try LanguageConfiguration(grammar.language(), name: grammar.name, queriesURL: queries)
            return withInheritedHighlights(configuration, name: name, grammar: grammar, queries: queries)
        } catch {
            log.error("Loading queries for \(name, privacy: .public) failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// Looks in the main bundle, then beside every loaded bundle (where SwiftPM puts resource bundles for tests).
    /// Highlight files a grammar's own configuration joins to its `highlights.scm` (grammar, file): TypeScript's
    /// queries name the types and leave keywords, strings and functions to JavaScript's, and JSX tags and
    /// attributes are in JavaScript's `highlights-jsx.scm` (its parameters in `highlights-params.scm`). Alone, a .ts file showed only its types coloured and a
    /// .jsx or .tsx file its tags not at all. Plain TypeScript has no JSX nodes, so it takes no JSX queries.
    nonisolated private static let joinedHighlights: [String: [(grammar: String, file: String)]] = [
        // In the order the grammars' tree-sitter.json lists them, which decides which colour wins where two match.
        "typescript": [("javascript", "highlights.scm")],
        "tsx": [("javascript", "highlights-jsx.scm"), ("javascript", "highlights.scm")],
        "javascript": [("javascript", "highlights-jsx.scm"), ("javascript", "highlights-params.scm")],
    ]

    /// `configuration` with its highlights followed by the joined files', as one query; unchanged when there are none
    /// or the joined query does not load.
    nonisolated private static func withInheritedHighlights(_ configuration: LanguageConfiguration, name: String, grammar: Grammar, queries: URL) -> LanguageConfiguration {
        guard let joins = joinedHighlights[name], var data = try? Data(contentsOf: queries.appendingPathComponent("highlights.scm")) else { return configuration }
        for join in joins {
            guard let other = grammars[join.grammar], let folder = queriesURL(bundleName: other.bundleName),
                  let more = try? Data(contentsOf: folder.appendingPathComponent(join.file)) else { return configuration }
            data += Data("\n".utf8) + more
        }
        let language = Language(grammar.language())
        do {
            var joined = configuration.queries
            joined[.highlights] = try Query(language: language, data: data)
            return LanguageConfiguration(language, name: configuration.name, queries: joined)
        } catch {
            log.error("Joining highlights into \(name, privacy: .public) failed: \(error, privacy: .public)")
            return configuration
        }
    }

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
