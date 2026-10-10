import Foundation
import Markdown

/// What a click on a link in rendered Markdown does. Markdown comes from anyone (a stranger's pull request, a Jira
/// ticket, a cloned README), and NSTextView's default hands every URL to the system: `file://…/Terminal.app`
/// launches an app and `smb://` mounts a share in one click. Only web and mail links leave the app.
public enum MarkdownLink: Equatable, Sendable {
    /// http, https or mailto: opened by the system.
    case external(URL)
    /// A relative or file: link to another document on the same host, by absolute path, with the heading its
    /// `#fragment` names (percent escapes undone) when it has one.
    case document(String, fragment: String? = nil)
    /// `#heading` in this document: the fragment, percent escapes undone (empty for a bare `#`).
    case sameDocument(String)
    /// Any other scheme, or a relative link with no folder to resolve against.
    case refused(String)

    public static func classify(_ link: Any, documentDirectory: String?) -> MarkdownLink {
        let raw = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { return .sameDocument(String(trimmed.dropFirst()).removingPercentEncoding ?? String(trimmed.dropFirst())) }
        guard let url = URL(string: trimmed) ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) else {
            return .refused(trimmed)
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .external(url)
        case "file":
            // Only a plain local path, and only where this document's folder is on the same machine.
            guard documentDirectory != nil, url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/") else {
                return .refused(trimmed)
            }
            return .document((url.path as NSString).standardizingPath, fragment: url.fragment(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 })
        case nil:
            // `//server/path` names another machine, not a file beside this one.
            guard let documentDirectory, url.host == nil || url.host == "" else { return .refused(trimmed) }
            let path = url.path   // already percent-decoded; decoding again turned %2541 into A
            if path.isEmpty { return .sameDocument(url.fragment(percentEncoded: false) ?? "") }
            let absolute = path.hasPrefix("/") ? path : (documentDirectory as NSString).appendingPathComponent(path)
            return .document((absolute as NSString).standardizingPath, fragment: url.fragment(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 })
        default:
            return .refused(trimmed)
        }
    }
}

/// Where a `#fragment` link lands: the heading GitHub would give that anchor (lowercased, punctuation but `-` and `_`
/// dropped, spaces as hyphens, a repeat numbered `-1`, `-2`), so a README's table of contents works here as there.
public enum MarkdownAnchors {
    /// The anchor of each heading in `source`, in order, with its line.
    public static func headings(in source: String) -> [(anchor: String, line: Int)] {
        var seen: [String: Int] = [:]
        var result: [(anchor: String, line: Int)] = []
        for case let heading as Heading in Document(parsing: source).children {
            guard let line = heading.range?.lowerBound.line else { continue }
            let base = slug(heading.plainText)
            let count = seen[base, default: 0]
            seen[base] = count + 1
            result.append((count == 0 ? base : "\(base)-\(count)", line))
        }
        return result
    }

    /// The line of the heading `fragment` names, matched as GitHub matches it (case aside).
    public static func line(of fragment: String, in source: String) -> Int? {
        let wanted = fragment.lowercased()
        return headings(in: source).first { $0.anchor == wanted }?.line
    }

    static func slug(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if scalar == " " { return "-" }
            if scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return nil
        })
    }
}
