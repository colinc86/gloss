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
        var quoteDepth = 0
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
            return inline(children)
        case "heading":
            let level = min(max(attrs["level"] as? Int ?? 1, 1), 6)
            return String(repeating: "#", count: level) + " " + inline(children)
        case "bulletList":
            return list(children, ordered: false, context: context)
        case "orderedList":
            return list(children, ordered: true, start: attrs["order"] as? Int ?? 1, context: context)
        case "taskList":
            return children.map { item in
                let done = (item["attrs"] as? [String: Any])?["state"] as? String == "DONE"
                return "- [" + (done ? "x" : " ") + "] " + inline(item["content"] as? [[String: Any]] ?? [])
            }.joined(separator: "\n")
        case "codeBlock":
            let language = attrs["language"] as? String ?? ""
            return "```" + language + "\n" + plainText(children) + "\n```"
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
                let name = mediaAttrs["alt"] as? String ?? mediaAttrs["id"] as? String ?? "attachment"
                return "[image: \(name)]"
            }.joined(separator: "\n")
        case "expand", "nestedExpand":
            let title = attrs["title"] as? String ?? "Details"
            return "**" + title + "**\n\n" + render(blocks: children, context: context).joined(separator: "\n\n")
        case "layoutSection", "layoutColumn", "bodiedExtension", "extension", "inlineExtension":
            let inner = render(blocks: children, context: context)
            return inner.isEmpty ? nil : inner.joined(separator: "\n\n")
        case "decisionList", "decisionItem":
            return children.map { "- ✓ " + inline($0["content"] as? [[String: Any]] ?? [$0]) }.joined(separator: "\n")
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

    /// A GFM table when every cell is one paragraph; otherwise each row as a list, so nothing is squashed.
    static func table(_ rows: [[String: Any]], context: Context) -> String {
        let cells = rows.map { ($0["content"] as? [[String: Any]] ?? []) }
        let simple = cells.allSatisfy { row in row.allSatisfy { cell in (cell["content"] as? [[String: Any]])?.count ?? 0 <= 1 } }
        guard simple, let first = cells.first, !first.isEmpty else {
            return rows.enumerated().map { index, row in
                let items = (row["content"] as? [[String: Any]] ?? []).map { render(blocks: $0["content"] as? [[String: Any]] ?? [], context: context).joined(separator: " ") }
                return "- Row \(index + 1): " + items.joined(separator: " · ")
            }.joined(separator: "\n")
        }
        let text = cells.map { row in row.map { cell in inline((cell["content"] as? [[String: Any]])?.first?["content"] as? [[String: Any]] ?? []).replacingOccurrences(of: "|", with: "\\|") } }
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
                return marked(node["text"] as? String ?? "", marks: node["marks"] as? [[String: Any]] ?? [])
            case "hardBreak":
                return "  \n"
            case "mention":
                return "@" + ((attrs["text"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@")))
            case "emoji":
                return attrs["text"] as? String ?? attrs["shortName"] as? String ?? ""
            case "inlineCard", "blockCard", "embedCard":
                let url = attrs["url"] as? String ?? ""
                return url.isEmpty ? "" : "<" + url + ">"
            case "date":
                if let stamp = attrs["timestamp"] as? String, let millis = Double(stamp) {
                    return Date(timeIntervalSince1970: millis / 1000).formatted(.iso8601.year().month().day())
                }
                return ""
            case "status":
                return "[" + (attrs["text"] as? String ?? "") + "]"
            case "inlineExtension", "placeholder":
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
            case "underline": result = "<u>" + result + "</u>"
            case "link": link = attrs["href"] as? String
            default: break
            }
        }
        if let link, !link.isEmpty { result = "[" + result + "](" + link + ")" }
        return result
    }

    static func plainText(_ nodes: [[String: Any]]) -> String {
        nodes.map { ($0["text"] as? String ?? "") + plainText($0["content"] as? [[String: Any]] ?? []) }.joined()
    }
}
