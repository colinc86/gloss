import Foundation

/// Atlassian's document format (the JSON Jira and Confluence store rich text in) rendered as Markdown. Every node
/// kind the apps commonly produce is covered; anything unknown degrades to its text, so nothing is lost. The output
/// is a pure function of the input, which keeps note anchors stable across re-renders.
public enum ADFMarkdown {
    public static func markdown(fromJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return markdown(from: object)
    }

    public static func markdown(from document: [String: Any]) -> String {
        let blocks = render(blocks: document["content"] as? [[String: Any]] ?? [], context: Context())
        return blocks.joined(separator: "\n\n").trimmingCharacters(in: .newlines) + "\n"
    }

    struct Context {
        var listDepth = 0
    }

    // MARK: Blocks

    static func render(blocks: [[String: Any]], context: Context) -> [String] {
        blocks.compactMap { render(block: $0, context: context) }.filter { !$0.isEmpty }
    }

    static func render(block node: [String: Any], context: Context) -> String? {
        let attrs = node["attrs"] as? [String: Any] ?? [:]
        let children = node["content"] as? [[String: Any]] ?? []
        switch node["type"] as? String ?? "" {
        case "paragraph":
            return escapeLineStart(inline(children))
        case "heading":
            let level = min(max(attrs["level"] as? Int ?? 1, 1), 6)
            return String(repeating: "#", count: level) + " " + inline(children)
        case "bulletList":
            return list(children, ordered: false, context: context)
        case "orderedList":
            return list(children, ordered: true, start: attrs["order"] as? Int ?? 1, context: context)
        case "taskList":
            return taskList(children, depth: 0)
        case "codeBlock":
            let language = attrs["language"] as? String ?? ""
            let code = plainText(children)
            // One backtick longer than the longest run inside, so the code can hold fences of its own.
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: code) + 1))
            return fence + language + "\n" + code + "\n" + fence
        case "blockquote":
            return render(blocks: children, context: context).joined(separator: "\n\n").split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        case "panel":
            let kind = (attrs["panelType"] as? String ?? "info").capitalized
            let body = render(blocks: children, context: context).joined(separator: "\n\n")
            return ("**" + kind + ".** " + body).split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        case "rule":
            return "---"
        case "table":
            return table(children, context: context)
        case "mediaSingle", "mediaGroup":
            return children.compactMap { media in
                let mediaAttrs = media["attrs"] as? [String: Any] ?? [:]
                let name = mediaAttrs["alt"] as? String ?? mediaAttrs["name"] as? String ?? mediaAttrs["id"] as? String ?? "attachment"
                return "[image: \(name)]"
            }.joined(separator: "\n")
        case "expand", "nestedExpand":
            let title = attrs["title"] as? String ?? "Details"
            return "**" + escapeInline(title) + "**\n\n" + render(blocks: children, context: context).joined(separator: "\n\n")
        case "layoutSection", "layoutColumn":
            let inner = render(blocks: children, context: context)
            return inner.isEmpty ? nil : inner.joined(separator: "\n\n")
        case "extension":
            // A macro with nothing to show here (a Jira issue list, a table of contents): named, so it is not lost.
            return "[macro: \(attrs["extensionKey"] as? String ?? "extension")]"
        case "bodiedExtension":
            let inner = render(blocks: children, context: context)
            return (["[macro: \(attrs["extensionKey"] as? String ?? "extension")]"] + inner).joined(separator: "\n\n")
        case "blockCard", "embedCard":
            let url = attrs["url"] as? String ?? ""
            return url.isEmpty ? nil : "<" + url + ">"
        case "decisionList":
            return children.map { decision($0) }.joined(separator: "\n")
        case "decisionItem":
            return decision(node)
        default:
            // A block nobody listed: its inline text, or its blocks.
            let inner = render(blocks: children, context: context)
            if !inner.isEmpty { return inner.joined(separator: "\n\n") }
            let text = inline(children)
            return text.isEmpty ? nil : text
        }
    }

    static func list(_ items: [[String: Any]], ordered: Bool, start: Int = 1, context: Context) -> String {
        var lines: [String] = []
        var inner = context
        inner.listDepth += 1
        for (index, item) in items.enumerated() {
            let marker = ordered ? "\(start + index). " : "- "
            let parts = render(blocks: item["content"] as? [[String: Any]] ?? [], context: inner)
            guard let first = parts.first else { lines.append(marker.trimmingCharacters(in: .whitespaces)); continue }
            lines.append(marker + first)
            let indent = String(repeating: " ", count: marker.count)
            for part in parts.dropFirst() {
                lines.append(part.split(separator: "\n", omittingEmptySubsequences: false).map { indent + $0 }.joined(separator: "\n"))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A decision: ✓ when decided, ○ while still open.
    static func decision(_ item: [String: Any]) -> String {
        let decided = (item["attrs"] as? [String: Any])?["state"] as? String == "DECIDED"
        return "- " + (decided ? "✓ " : "○ ") + inline(item["content"] as? [[String: Any]] ?? [])
    }

    /// Task items; a task list inside a task list (how ADF nests them) is indented under the item before it.
    static func taskList(_ children: [[String: Any]], depth: Int) -> String {
        let indent = String(repeating: "  ", count: depth)
        return children.map { item -> String in
            if item["type"] as? String == "taskList" { return taskList(item["content"] as? [[String: Any]] ?? [], depth: depth + 1) }
            let done = (item["attrs"] as? [String: Any])?["state"] as? String == "DONE"
            return indent + "- [" + (done ? "x" : " ") + "] " + inline(item["content"] as? [[String: Any]] ?? [])
        }.joined(separator: "\n")
    }

    static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0, current = 0
        for c in text {
            current = c == character ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    /// A GFM table when every cell is a single paragraph; otherwise each row as a list item holding its cells,
    /// their lines indented under it, so a list or code in a cell keeps its shape.
    static func table(_ rows: [[String: Any]], context: Context) -> String {
        let cells = rows.map { ($0["content"] as? [[String: Any]] ?? []) }
        let simple = cells.allSatisfy { row in row.allSatisfy { cell in
            let content = cell["content"] as? [[String: Any]] ?? []
            return content.isEmpty || (content.count == 1 && content[0]["type"] as? String == "paragraph")
        } }
        guard simple, let first = cells.first, !first.isEmpty else {
            return rows.enumerated().map { index, row in
                var lines = ["- Row \(index + 1):"]
                for cell in row["content"] as? [[String: Any]] ?? [] {
                    let body = render(blocks: cell["content"] as? [[String: Any]] ?? [], context: context).joined(separator: "\n\n")
                    for (number, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                        lines.append((number == 0 ? "  - " : "    ") + line)
                    }
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")
        }
        let text = cells.map { row in row.map { cell in
            inline((cell["content"] as? [[String: Any]])?.first?["content"] as? [[String: Any]] ?? [])
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "  \n", with: " / ")
                .replacingOccurrences(of: "\n", with: " ")
        } }
        let width = text.map(\.count).max() ?? 0
        var lines: [String] = []
        for (index, row) in text.enumerated() {
            let padded = row + Array(repeating: "", count: width - row.count)
            lines.append("| " + padded.joined(separator: " | ") + " |")
            if index == 0 { lines.append("|" + Array(repeating: " --- |", count: width).joined()) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Inline

    static func inline(_ nodes: [[String: Any]]) -> String {
        nodes.map { node -> String in
            let attrs = node["attrs"] as? [String: Any] ?? [:]
            switch node["type"] as? String ?? "" {
            case "text":
                let marks = node["marks"] as? [[String: Any]] ?? []
                let text = node["text"] as? String ?? ""
                // Code keeps its characters; other text is escaped so it cannot become Markdown it never was.
                return marked(marks.contains { $0["type"] as? String == "code" } ? text : escapeInline(text), marks: marks)
            case "hardBreak":
                return "  \n"
            case "mention":
                return "@" + ((attrs["text"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@")))
            case "emoji":
                return attrs["text"] as? String ?? attrs["shortName"] as? String ?? ""
            case "inlineCard", "blockCard", "embedCard":
                let url = attrs["url"] as? String ?? ""
                return url.isEmpty ? "" : "<" + url + ">"
            case "mediaInline", "media":
                return "[file: \(attrs["alt"] as? String ?? attrs["name"] as? String ?? attrs["id"] as? String ?? "attachment")]"
            case "date":
                if let stamp = attrs["timestamp"] as? String, let millis = Double(stamp) {
                    return Date(timeIntervalSince1970: millis / 1000).formatted(.iso8601.year().month().day())
                }
                return ""
            case "status":
                return "[" + (attrs["text"] as? String ?? "") + "]"
            case "inlineExtension":
                return "[macro: \(attrs["extensionKey"] as? String ?? "extension")]"
            case "placeholder":
                return attrs["text"] as? String ?? ""
            default:
                return inline(node["content"] as? [[String: Any]] ?? []) + (node["text"] as? String ?? "")
            }
        }.joined()
    }

    static func marked(_ text: String, marks: [[String: Any]]) -> String {
        var result = text
        var link: String?
        for mark in marks {
            let attrs = mark["attrs"] as? [String: Any] ?? [:]
            switch mark["type"] as? String ?? "" {
            case "code": result = "`" + result + "`"
            case "strong": result = "**" + result + "**"
            case "em": result = "_" + result + "_"
            case "strike": result = "~~" + result + "~~"
            // Markdown has no underline, and raw HTML would show as text: underlined text is plain.
            case "underline": break
            case "link": link = attrs["href"] as? String
            default: break
            }
        }
        if let link, let safe = safeLink(link) { result = "[" + result + "](" + safe + ")" }
        return result
    }

    /// A link target that stays one: script links are dropped (their text stays), and the characters that would
    /// end or break the Markdown target are percent-encoded.
    static func safeLink(_ link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scheme = trimmed.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
        if trimmed.contains(":"), ["javascript", "vbscript", "data"].contains(scheme) { return nil }
        return trimmed.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    /// Characters that would turn plain text into emphasis, code, links or HTML.
    static func escapeInline(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\*_`[]<".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A paragraph that starts like a heading, a quote, a list item or a rule is text, not that.
    static func escapeLineStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if "#>-+".contains(first) { return "\\" + text }
        // `1. ` or `1) `: an ordered list marker.
        let digits = text.prefix { $0.isNumber }
        if !digits.isEmpty, let after = text.dropFirst(digits.count).first, after == "." || after == ")" {
            return digits + "\\" + text.dropFirst(digits.count)
        }
        return text
    }

    static func plainText(_ nodes: [[String: Any]]) -> String {
        nodes.map { ($0["text"] as? String ?? "") + plainText($0["content"] as? [[String: Any]] ?? []) }.joined()
    }
}
