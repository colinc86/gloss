import Foundation

/// Real keys for live checks live in the repository's gitignored `integrations.env`; without it those tests skip.
/// They only ever read.
enum TestGates {
    nonisolated(unsafe) static let environment: [String: String] = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("integrations.env")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                var values: [String: String] = [:]
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, !parts[0].hasPrefix("#") { values[parts[0]] = parts[1] }
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
    /// The site is not in the file; the live Atlassian tests take it from `GLOSS_ATLASSIAN_SITE`.
    static var atlassianSite: URL? {
        ProcessInfo.processInfo.environment["GLOSS_ATLASSIAN_SITE"].flatMap { URL(string: $0.contains("://") ? $0 : "https://" + $0) }
    }
}
