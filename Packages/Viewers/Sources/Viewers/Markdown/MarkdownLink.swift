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
        // Every heading, as GitHub anchors them: one inside a quote or a list item too, in document order.
        struct Collector: MarkupWalker {
            var headings: [Heading] = []
            mutating func visitHeading(_ heading: Heading) { headings.append(heading) }
        }
        var collector = Collector()
        collector.visit(Document(parsing: source))
        for heading in collector.headings {
            guard let line = heading.range?.lowerBound.line else { continue }
            let base = slug(heading.plainText)
            let count = seen[base, default: 0]
            seen[base] = count + 1
            result.append((count == 0 ? base : "\(base)-\(count)", line))
        }
        return result
    }

    /// The line of the heading `fragment` names, matched as GitHub matches it (case aside); else of an anchor the
    /// document sets by hand in its HTML (`<a name="install"></a>`, `<a id="install">`), as READMEs do.
    public static func line(of fragment: String, in source: String) -> Int? {
        let wanted = fragment.lowercased()
        if let line = headings(in: source).first(where: { $0.anchor == wanted })?.line { return line }
        let named = htmlAnchors(in: source)
        return (named.first { $0.anchor == fragment } ?? named.first { $0.anchor.lowercased() == wanted })?.line
    }

    /// Every `name` or `id` the document's HTML sets (not in code), in order, with its line.
    static func htmlAnchors(in source: String) -> [(anchor: String, line: Int)] {
        struct Collector: MarkupWalker {
            var html: [(text: String, line: Int)] = []
            mutating func visitHTMLBlock(_ block: HTMLBlock) { if let line = block.range?.lowerBound.line { html.append((block.rawHTML, line)) } }
            mutating func visitInlineHTML(_ inline: InlineHTML) { if let line = inline.range?.lowerBound.line { html.append((inline.rawHTML, line)) } }
        }
        var collector = Collector()
        collector.visit(Document(parsing: source))
        guard let pattern = try? NSRegularExpression(pattern: #"\s(?:name|id)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))"#, options: [.caseInsensitive]) else { return [] }
        var result: [(anchor: String, line: Int)] = []
        for (text, line) in collector.html {
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let range = (1...3).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }), range.length > 0 else { continue }
                // A block spans lines: the anchor is on the line it is written on.
                let before = ns.substring(to: match.range.location).filter { $0 == "\n" }.count
                result.append((ns.substring(with: range), line + before))
            }
        }
        return result
    }

    static func slug(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if scalar == " " { return "-" }
            if scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return nil
        })
    }
}
