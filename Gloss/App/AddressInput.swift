import Core
import Foundation
import UniformTypeIdentifiers
import Viewers

/// What typed text in an address field (the window title, the explorer's Web section, Open Quickly) means: a web
/// page, a path on the chosen host, or neither.
enum AddressInput: Equatable {
    case web(URL)
    case path(String)

    /// An absolute path (`/…`, or a `file://` link to one) or a home path (`~/…`, expanded with `home`); then a web address as `webURL(from:)`
    /// reads it; then, with `folder` (the open document's), a relative path with a dot or a slash in it, so
    /// `README.md` or `src/main.swift` is a file beside the document rather than a website. Nil for anything else
    /// (`README.md` without a folder included), and for a home path when the host's home is not known.
    static func parse(_ text: String, home: String?, folder: String? = nil) -> AddressInput? {
        // A path is keyed by its text: `docs/../README.md` must open the same document as `README.md`.
        switch parseUnnormalized(text, home: home, folder: folder) {
        case .path(let path)?: .path(PathUtilities.lexicallyNormalized(path))
        case let other: other
        }
    }

    private static func parseUnnormalized(_ text: String, home: String?, folder: String?) -> AddressInput? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return .path(trimmed) }
        // A `file://` link (as editors and agents print a location) is its path, percent escapes undone.
        if trimmed.lowercased().hasPrefix("file://") {
            guard let url = URL(string: trimmed), url.isFileURL, ["", "localhost"].contains(url.host(percentEncoded: false)?.lowercased() ?? ""),
                  case let path = url.path(percentEncoded: false), path.hasPrefix("/") else { return nil }
            return .path(path)
        }
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            guard let home, home.hasPrefix("/") else { return nil }
            let rest = trimmed.dropFirst(2)
            return .path(rest.isEmpty ? home : PathUtilities.join(home, String(rest)))
        }
        if let url = webURL(from: trimmed) { return .web(url) }
        if let folder, folder.hasPrefix("/"), !trimmed.hasPrefix("~"), !trimmed.contains("://"),
           trimmed.contains(".") || trimmed.contains("/") {
            return .path(PathUtilities.join(folder, trimmed))
        }
        // A bare `README.md` with no folder to be relative to is neither: never a website called that.
        return nil
    }

    /// Text that can only be a web address: a URL with an http(s) scheme, or a bare host with a port (`box:8080`),
    /// `localhost`, an IP address, a path after it (`example.com/docs`), or a top-level domain that is not also a
    /// file extension (`example.com`, but not `README.md` or `package.json`). A single word (`notes`) is not, nor
    /// is anything with a space in it.
    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = possibleWebURL(from: trimmed), let host = url.host(percentEncoded: false) else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return url }
        if url.port != nil || host.lowercased() == "localhost" || host.contains(":") { return url }
        let labels = host.split(separator: ".")
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return url }
        let authority = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if authority.count == 2 { return url }
        guard let tld = labels.last.map({ $0.lowercased() }) else { return nil }
        return commonTopLevelDomains.contains(tld) || !isFileExtension(tld) ? url : nil
    }

    /// `webURL(from:)` plus bare dotted names that may as well be files (`README.md`): what Open Quickly still
    /// offers, below the files, when the query is not unmistakably an address.
    static func possibleWebURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
              let url = WebAddress.url(from: trimmed), let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return url }
        guard host.contains(".") || host.contains(":") || url.port != nil || host.lowercased() == "localhost" else { return nil }
        // A trailing or doubled dot is a typo, not a host.
        guard !host.hasSuffix("."), !host.hasPrefix("."), !host.contains("..") else { return nil }
        return url
    }

    /// Domains typed often enough that they win over a file extension of the same name (`.app`, `.com`).
    private static let commonTopLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "io", "dev", "app", "ai", "co", "me", "info", "biz", "us", "uk", "de", "fr",
        "ca", "au", "jp", "nl", "eu", "ch", "se", "no", "es", "it", "be", "at", "nz", "in", "cloud", "tech", "site",
        "xyz", "local", "internal", "test", "lan", "home", "corp",
    ]

    /// Whether the system knows `name` as a file extension (`md`, `json`, `swift`); a made-up one is dynamic.
    private static func isFileExtension(_ name: String) -> Bool {
        UTType(filenameExtension: name).map { !$0.isDynamic } ?? false
    }
}
