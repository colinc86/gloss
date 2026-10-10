import Foundation

/// The documents a Jira issue and a Confluence page are read through, rendered the same way every time.
enum AtlassianMarkdown {
    static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    /// `KEY.md`: a fact list, the description, then the comments; the lines each comment occupies are returned so a
    /// note inside one can name it.
    /// The issue as Markdown, with the lines its description and each comment take (1-based), so a note can say
    /// which part of the ticket it is about.
    static func issue(_ issue: JiraIssue, url: URL) -> (text: String, description: ClosedRange<Int>, comments: [(range: ClosedRange<Int>, id: String)]) {
        // Text from the ticket is text: a summary "Fix __init__" must not turn bold, nor a name with `*` in it.
        let plain = ADFMarkdown.escapeInline
        var lines: [String] = ["# " + ADFMarkdown.headingText("\(issue.key): \(plain(issue.summary))"), ""]
        lines.append("- **\(plain(issue.issueType))** · \(plain(issue.status))" + (issue.priority.map { " · \(plain($0))" } ?? ""))
        var people: [String] = []
        if let assignee = issue.assignee { people.append("Assignee: \(plain(assignee))") }
        if let reporter = issue.reporter { people.append("Reporter: \(plain(reporter))") }
        if !people.isEmpty { lines.append("- " + people.joined(separator: " · ")) }
        if !issue.labels.isEmpty { lines.append("- Labels: " + issue.labels.map(plain).joined(separator: ", ")) }
        if let parent = issue.parentKey { lines.append("- Parent: \(parent)") }
        lines.append("- Updated \(stamp(issue.updated)) · created \(stamp(issue.created))")
        lines.append("- <\(url.absoluteString)>")
        lines.append("")
        lines.append("## Description")
        lines.append("")
        let descriptionStart = lines.count + 1
        lines.append(contentsOf: bodyLines(issue.description ?? "_No description._"))
        let description = descriptionStart...lines.count
        var map: [(ClosedRange<Int>, String)] = []
        // Every image and PDF, whether or not the text shows it (Jira's media nodes can't always be matched to a
        // file): each opens in its viewer for region notes.
        let viewable = AtlassianAttachment.listed(issue.attachments)
        let names = AtlassianAttachment.listedNames(viewable)
        if !viewable.isEmpty {
            lines.append("")
            lines.append("## Attachments")
            lines.append("")
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "()")
            for attachment in viewable {
                let link = AtlassianClient.jiraAttachmentLink(key: issue.key, name: names[attachment.id] ?? attachment.fileName)
                let destination = link.addingPercentEncoding(withAllowedCharacters: allowed) ?? link
                let label = attachment.filename.replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
                lines.append(attachment.mimeType.hasPrefix("image/") ? "![\(label)](\(destination))" : "- [\(label)](\(destination))")
            }
        }
        if !issue.comments.isEmpty {
            lines.append("")
            lines.append("## Comments")
            for comment in issue.comments {
                lines.append("")
                let start = lines.count + 1
                lines.append("### " + ADFMarkdown.headingText("\(plain(comment.author)) · \(stamp(comment.created))"))
                lines.append(contentsOf: bodyLines(comment.body))
                map.append((start...lines.count, comment.id))
            }
        }
        lines.append("")
        return (lines.joined(separator: "\n"), description, map)
    }

    /// `<Title>.md`: a fact list, then the body.
    static func page(_ page: ConfluencePage, spaceKey: String, url: URL) -> String {
        var lines: [String] = ["# " + ADFMarkdown.headingText(ADFMarkdown.escapeInline(page.title)), ""]
        lines.append("- **Confluence** · \(ADFMarkdown.escapeInline(spaceKey)) · version \(page.version)" + (page.versionDate.map { " · \(stamp($0))" } ?? ""))
        lines.append("- <\(url.absoluteString)>")
        lines.append("")
        lines.append(contentsOf: bodyLines(page.body ?? "_No content._"))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func bodyLines(_ text: String) -> [String] {
        // Every way text can break a line becomes "\n", so the line map counts lines as the editor does.
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        for separator in ["\r", "\u{2028}", "\u{2029}", "\u{85}"] { text = text.replacingOccurrences(of: separator, with: "\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    }
}
