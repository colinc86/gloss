import Foundation

/// Maps a file name to the viewer that opens it. Pure, so every host uses the same rules.
public enum DocumentKindDetector {
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "svg", "tiff", "tif", "bmp"]
    public static let csvExtensions: Set<String> = ["csv", "tsv"]
    public static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp", "rs", "go", "py", "rb", "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "java", "kt", "kts", "scala", "cs", "php", "pl", "pm", "lua", "sh", "bash", "zsh", "fish", "ps1", "sql", "r", "jl",
        "json", "jsonc", "jsonl", "ndjson", "yaml", "yml", "toml", "xml", "plist", "html", "htm", "css", "scss", "less", "vue", "svelte",
        "dart", "ex", "exs", "erl", "hs", "ml", "clj", "cljs", "lisp", "el", "nix", "zig", "proto", "graphql", "gql",
        "cmake", "make", "mk", "gradle", "tf", "hcl", "dockerfile", "ini", "cfg", "conf", "env", "lock", "pbxproj",
        "entitlements", "xcconfig", "strings", "xcstrings", "podspec", "rake", "gemspec",
    ]
    public static let textExtensions: Set<String> = ["txt", "text", "log", "rst", "org", "adoc", "asciidoc", "tex", "bib", "diff", "patch", "nfo", "me", "1st"]
    public static let textFileNames: Set<String> = [
        "makefile", "dockerfile", "readme", "license", "licence", "copying", "authors", "changelog", "todo", "notes",
        "gemfile", "rakefile", "podfile", "cartfile", "brewfile", "justfile", "procfile", "vagrantfile", ".gitignore",
        ".gitattributes", ".editorconfig", ".env", ".zshrc", ".bashrc", ".bash_profile", ".profile", ".vimrc", ".tmux.conf", ".ssh_config",
    ]

    public static func kind(forPath path: String) -> DocumentKind {
        if isWebURL(path) { return .web }
        let name = (path as NSString).lastPathComponent
        let lowered = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if textFileNames.contains(lowered) { return lowered == "makefile" || lowered == "dockerfile" ? .code : .text }
        if markdownExtensions.contains(ext) { return .markdown }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if csvExtensions.contains(ext) { return .csv }
        if codeExtensions.contains(ext) { return .code }
        if textExtensions.contains(ext) { return .text }
        if ext.isEmpty, lowered.hasPrefix(".") { return .text }   // dotfiles without an extension are usually config text
        return .file
    }

    /// A document path that is a live page's URL rather than a file path.
    public static func isWebURL(_ path: String) -> Bool {
        let lowered = path.prefix(8).lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    /// A last resort for unknown extensions: looks at the first 8 KiB. Binary is a NUL byte or more than 1 % C0
    /// control bytes beyond tab, newline, return, form feed, and escape. Decoding is no help here: every byte
    /// sequence is valid Latin-1, and control bytes are valid UTF-8, so the viewer's decoder (UTF-8, then Latin-1)
    /// takes whatever passes.
    public static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        if sample.isEmpty { return true }
        if sample.contains(0) { return false }
        let allowed: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x0C, 0x1B]
        let controls = sample.filter { $0 < 0x20 && !allowed.contains($0) }.count
        return controls * 100 < sample.count
    }
}
