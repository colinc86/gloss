import Foundation

/// The two documents a pull request is read through, rendered the same way every time from the same facts, so note
/// anchors in them survive a re-render that changes nothing they point at.
enum PullRequestMarkdown {
    /// `2026-10-03T11:30:00Z`: the same for every reader and locale, so the rendered text is stable.
    static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    /// A body as lines of the document, CRLF and trailing blanks gone.
    static func bodyLines(_ body: String) -> [String] {
        // Every way text can break a line becomes "\n", so the line map counts lines as the editor does.
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
        for separator in ["\r", "\u{2028}", "\u{2029}", "\u{85}"] { text = text.replacingOccurrences(of: separator, with: "\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
    }

    static func state(of pull: GitHubPullRequest) -> String {
        if pull.merged == true { return "merged" }
        if pull.state == "closed" { return "closed" }
        if pull.draft == true { return "draft" }
        return pull.state
    }

    /// `Pull request.md`: a header block, the description as the author wrote it, then review comments by file;
    /// with the lines the description and each review comment take (1-based), so a note can name what it is about.
    static func description(_ pull: GitHubPullRequest, files: [GitHubPullRequestFile], reviewComments: [GitHubComment], path: PullRequestPath)
        -> (text: String, body: ClosedRange<Int>, reviews: [(range: ClosedRange<Int>, url: URL)]) {
        var lines: [String] = ["# \(pull.title)", ""]
        let short = String(pull.head.sha.prefix(7))
        // One fact per list item: Markdown would run adjacent lines into a single paragraph.
        lines.append("- **\(path.repository) #\(pull.number)** · \(state(of: pull)) · by @\(pull.user.login)")
        var branches = "- `\(pull.base.ref)` ← `\(pull.head.ref)` (\(short))"
        if let additions = pull.additions, let deletions = pull.deletions {
            branches += " · +\(additions) −\(deletions) in \(pull.changedFiles ?? files.count) files"
        }
        lines.append(branches)
        if !pull.labels.isEmpty { lines.append("- Labels: " + pull.labels.map(\.name).joined(separator: ", ")) }
        if let reviewers = pull.requestedReviewers, !reviewers.isEmpty { lines.append("- Reviewers: " + reviewers.map { "@" + $0.login }.joined(separator: ", ")) }
        let removed = files.filter { $0.status == "removed" }.map(\.filename)
        if !removed.isEmpty { lines.append("- Removed: " + removed.joined(separator: ", ")) }
        lines.append("- <\(pull.htmlUrl.absoluteString)>")
        lines.append("")
        let body = (pull.body ?? "").replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyStart = lines.count + 1
        lines.append(contentsOf: body.isEmpty ? ["_No description._"] : bodyLines(body))
        let bodyRange = bodyStart...lines.count
        var reviews: [(range: ClosedRange<Int>, url: URL)] = []
        if !reviewComments.isEmpty {
            lines.append("")
            lines.append("## Reviews")
            let byFile = Dictionary(grouping: reviewComments) { $0.path ?? "" }
            for file in byFile.keys.sorted() {
                for comment in byFile[file]!.sorted(by: { $0.createdAt < $1.createdAt }) {
                    lines.append("")
                    let start = lines.count + 1
                    let where_ = comment.line ?? comment.originalLine
                    lines.append("### \(file)" + (where_.map { ":\($0)" } ?? "") + " · @\(comment.user.login) · \(stamp(comment.createdAt))")
                    lines.append(contentsOf: bodyLines(comment.body))
                    reviews.append((start...lines.count, comment.htmlUrl))
                }
            }
        }
        lines.append("")
        return (lines.joined(separator: "\n"), bodyRange, reviews)
    }

    /// `Conversation.md` and, per comment, the 1-based lines it occupies, so a note inside one can name it.
    static func conversation(_ comments: [GitHubComment]) -> (text: String, lines: [(range: ClosedRange<Int>, url: URL)]) {
        var lines: [String] = ["# Conversation", ""]
        var map: [(ClosedRange<Int>, URL)] = []
        if comments.isEmpty {
            lines.append("_No comments yet._")
        }
        for comment in comments.sorted(by: { $0.createdAt < $1.createdAt }) {
            let start = lines.count + 1
            lines.append("### @\(comment.user.login) · \(stamp(comment.createdAt))")
            // One array element per line, or the map would drift by every newline inside a body.
            lines.append(contentsOf: bodyLines(comment.body))
            map.append((start...lines.count, comment.htmlUrl))
            lines.append("")
        }
        return (lines.joined(separator: "\n") + (lines.last == "" ? "" : "\n"), map)
    }
}
