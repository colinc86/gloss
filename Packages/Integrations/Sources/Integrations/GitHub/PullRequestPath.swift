import Foundation

/// A path on the `github` host: `/owner/repo/pull/123` is a pull request's root, and under it live the documents
/// the provider renders. Anything else is not served.
public struct PullRequestPath: Equatable, Sendable {
    public var owner: String
    public var repo: String
    public var number: Int
    /// The part after the root: `""`, `Pull request.md`, `Conversation.md`, `pull-123.diff`, or `changes/<git path>`.
    public var rest: String

    public static let descriptionName = "Pull request.md"
    public static let conversationName = "Conversation.md"
    public static let changesName = "changes"

    public init?(_ path: String) {
        // "/o/r/pull/12/rest" → ["", "o", "r", "pull", "12", "rest"...]
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isName: (String) -> Bool = { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }
        guard parts.count >= 5, parts[0].isEmpty, isName(parts[1]), isName(parts[2]), parts[3] == "pull",
              let number = Int(parts[4]), number > 0 else { return nil }
        owner = parts[1]
        repo = parts[2]
        self.number = number
        var remainder = Array(parts.dropFirst(5))
        while remainder.last == "" { remainder.removeLast() }
        guard !remainder.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        rest = remainder.joined(separator: "/")
    }

    public init(owner: String, repo: String, number: Int, rest: String = "") {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.rest = rest
    }

    public var root: String { "/\(owner)/\(repo)/pull/\(number)" }
    public var path: String { rest.isEmpty ? root : root + "/" + rest }
    public var diffName: String { "pull-\(number).diff" }
    public var isRoot: Bool { rest.isEmpty }
    /// The git path of a changed file, when this is one.
    public var changedFile: String? {
        guard rest.hasPrefix(Self.changesName + "/") else { return nil }
        let file = String(rest.dropFirst(Self.changesName.count + 1))
        return file.isEmpty ? nil : file
    }
    public var isChangesDirectory: Bool { rest == Self.changesName || rest.hasPrefix(Self.changesName + "/") }
    public var webURL: URL { URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")! }
    public var repository: String { "\(owner)/\(repo)" }

    /// `https://github.com/o/r/pull/12`, `github.com/o/r/pull/12/files`, or `o/r#12`.
    public static func parse(reference text: String) -> PullRequestPath? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = trimmed.lastIndex(of: "#"), !trimmed.contains("/pull/") {
            let repoPart = trimmed[..<hash].split(separator: "/")
            guard repoPart.count == 2, let number = Int(trimmed[trimmed.index(after: hash)...]), number > 0 else { return nil }
            return PullRequestPath(owner: String(repoPart[0]), repo: String(repoPart[1]), number: number)
        }
        var candidate = trimmed
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), url.host()?.lowercased() == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0 else { return nil }
        var rest = ""
        if parts.count >= 6, parts[4] == "files" { rest = changesName + "/" + parts[5...].joined(separator: "/") }
        return PullRequestPath(owner: parts[0], repo: parts[1], number: number, rest: rest)
    }
}
