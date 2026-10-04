import Foundation

/// The two documents a pull request is read through, rendered the same way every time from the same facts, so note
/// anchors in them survive a re-render that changes nothing they point at.
enum PullRequestMarkdown {
    /// `2026-10-03T11:30:00Z`: the same for every reader and locale, so the rendered text is stable.
    static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    static func state(of pull: GitHubPullRequest) -> String {
        if pull.merged == true { return "merged" }
        if pull.state == "closed" { return "closed" }
        if pull.draft == true { return "draft" }
        return pull.state
    }

    /// `Pull request.md`: a header block, the description as the author wrote it, then review comments by file.
    static func description(_ pull: GitHubPullRequest, files: [GitHubPullRequestFile], reviewComments: [GitHubComment], path: PullRequestPath) -> String {
        var lines: [String] = ["# \(pull.title)", ""]
        let short = String(pull.head.sha.prefix(7))
        var facts = ["**\(path.repository) #\(pull.number)** · \(state(of: pull)) · by @\(pull.user.login) · `\(pull.base.ref)` ← `\(pull.head.ref)` (\(short))"]
        if let additions = pull.additions, let deletions = pull.deletions {
            facts.append("+\(additions) −\(deletions) in \(pull.changedFiles ?? files.count) files")
        }
        lines.append(facts.joined(separator: " · "))
        var tags: [String] = []
        if !pull.labels.isEmpty { tags.append("Labels: " + pull.labels.map(\.name).joined(separator: ", ")) }
        if let reviewers = pull.requestedReviewers, !reviewers.isEmpty { tags.append("Reviewers: " + reviewers.map { "@" + $0.login }.joined(separator: ", ")) }
        if !tags.isEmpty { lines.append(tags.joined(separator: " · ")) }
        let removed = files.filter { $0.status == "removed" }.map(\.filename)
        if !removed.isEmpty { lines.append("Removed: " + removed.joined(separator: ", ")) }
        lines.append(pull.htmlUrl.absoluteString)
        lines.append("")
        let body = (pull.body ?? "").replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(body.isEmpty ? "_No description._" : body)
        if !reviewComments.isEmpty {
            lines.append("")
            lines.append("## Reviews")
            let byFile = Dictionary(grouping: reviewComments) { $0.path ?? "" }
            for file in byFile.keys.sorted() {
                for comment in byFile[file]!.sorted(by: { $0.createdAt < $1.createdAt }) {
                    lines.append("")
                    let where_ = comment.line ?? comment.originalLine
                    lines.append("### \(file)" + (where_.map { ":\($0)" } ?? "") + " · @\(comment.user.login) · \(stamp(comment.createdAt))")
                    lines.append(comment.body.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
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
            lines.append(comment.body.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            map.append((start...lines.count, comment.htmlUrl))
            lines.append("")
        }
        return (lines.joined(separator: "\n") + (lines.last == "" ? "" : "\n"), map)
    }
}
