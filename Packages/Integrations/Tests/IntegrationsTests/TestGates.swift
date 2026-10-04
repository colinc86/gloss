import Foundation
@testable import Integrations

/// Real keys for live checks live in the repository's gitignored `integrations.env`; without it those tests skip.
/// They only ever read.
enum TestGates {
    static let environment: [String: String] = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("integrations.env")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                // The same rules as the app's `--integrations-env`: `export `, quotes, comments.
                var values: [String: String] = [:]
                for raw in text.split(whereSeparator: \.isNewline) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
                    var key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                    if key.hasPrefix("export ") { key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                    var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                    if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first { value = String(value.dropFirst().dropLast()) }
                    values[key] = value
                }
                return values
            }
            directory.deleteLastPathComponent()
        }
        return [:]
    }()

    static var githubToken: String? { environment["GITHUB_ACCESS_TOKEN"] }
    static var atlassian: (email: String, token: String)? {
        guard let email = environment["ATLASSIAN_USERNAME"], let token = environment["ATLASSIAN_API_KEY"] else { return nil }
        return (email, token)
    }
    /// The site, from `GLOSS_ATLASSIAN_SITE` or the file's `ATLASSIAN_SITE`.
    static var atlassianSite: URL? {
        (ProcessInfo.processInfo.environment["GLOSS_ATLASSIAN_SITE"] ?? environment["ATLASSIAN_SITE"]).flatMap { URL(string: $0.contains("://") ? $0 : "https://" + $0) }
    }

    /// A pull request the token can read, `owner/repo#n`, from `GLOSS_LIVE_PULL_REQUEST`: no repository is named
    /// in the code.
    static var livePullRequest: PullRequestPath? {
        ProcessInfo.processInfo.environment["GLOSS_LIVE_PULL_REQUEST"].flatMap { PullRequestPath.parse(reference: $0) }
    }
}
