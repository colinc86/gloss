import Foundation

public struct GitHubViewer: Sendable, Equatable {
    public var login: String
    /// A classic token's scopes from `X-OAuth-Scopes`; empty for a fine-grained token, which reports none.
    public var scopes: [String]
}

public struct GitHubUser: Codable, Sendable, Equatable {
    public var login: String
}

public struct GitHubRef: Codable, Sendable, Equatable {
    public struct Repository: Codable, Sendable, Equatable {
        public var fullName: String
    }
    public var ref: String
    public var sha: String
    public var repo: Repository?
}

public struct GitHubLabel: Codable, Sendable, Equatable {
    public var name: String
}

public struct GitHubPullRequest: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var state: String
    public var draft: Bool?
    public var merged: Bool?
    public var htmlUrl: URL
    public var body: String?
    public var user: GitHubUser
    public var head: GitHubRef
    public var base: GitHubRef
    public var updatedAt: Date
    public var labels: [GitHubLabel]
    public var requestedReviewers: [GitHubUser]?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
}

public struct GitHubPullRequestFile: Codable, Sendable, Equatable {
    public var filename: String
    public var status: String
    public var additions: Int
    public var deletions: Int
    public var patch: String?
    public var previousFilename: String?
    public var sha: String?
}

public struct GitHubComment: Codable, Sendable, Equatable {
    public var id: Int
    public var htmlUrl: URL
    public var user: GitHubUser
    public var body: String
    public var createdAt: Date
    /// Review comments only: the file and line the comment sits on.
    public var path: String?
    public var line: Int?
    public var originalLine: Int?
    public var side: String?
    public var diffHunk: String?
}

public struct GitHubPullRequestSummary: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var state: String
    public var draft: Bool?
    public var htmlUrl: URL
    public var updatedAt: Date
    public var repositoryUrl: URL

    public init(number: Int, title: String, state: String, draft: Bool? = nil, htmlUrl: URL, updatedAt: Date, repositoryUrl: URL) {
        self.number = number
        self.title = title
        self.state = state
        self.draft = draft
        self.htmlUrl = htmlUrl
        self.updatedAt = updatedAt
        self.repositoryUrl = repositoryUrl
    }

    /// `owner/repo` from the API's repository URL.
    public var repository: String { repositoryUrl.pathComponents.suffix(2).joined(separator: "/") }
}

/// Reads pull requests with a personal access token. Only `GetOnlyHTTP` touches the network, so nothing here can
/// write to GitHub whatever the token allows.
public actor GitHubClient {
    public static let apiBase = URL(string: "https://api.github.com")!
    private let http: GetOnlyHTTP
    private let token: String
    private let base: URL

    public init(token: String, session: URLSession = .shared, base: URL = GitHubClient.apiBase, log: @escaping GetOnlyHTTP.Logger = { _ in }) {
        self.token = token
        self.base = base
        http = GetOnlyHTTP(session: session, log: log)
    }

    private func headers(accept: String = "application/vnd.github+json") -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": accept, "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Gloss"]
    }

    private func url(_ path: String, query: [String: String] = [:]) -> URL {
        GetOnlyHTTP.url(base, path: path, query: query)
    }

    private func decode<T: Decodable>(_ type: T.Type, from reply: HTTPReply) throws -> T {
        let decoder = JSONDecoder.integrations
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(type, from: reply.data) } catch { throw IntegrationError.malformed("\(error)") }
    }

    /// Who the token belongs to and what it may read.
    public func viewer() async throws -> GitHubViewer {
        let reply = try await http.get(url("user"), headers: headers())
        let user = try decode(GitHubUser.self, from: reply)
        let scopes = (reply.header("x-oauth-scopes") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return GitHubViewer(login: user.login, scopes: scopes)
    }

    public func pullRequest(owner: String, repo: String, number: Int) async throws -> GitHubPullRequest {
        try decode(GitHubPullRequest.self, from: try await http.get(url("repos/\(owner)/\(repo)/pulls/\(number)"), headers: headers()))
    }

    /// Every changed file, following the API's pages of 100.
    public func pullRequestFiles(owner: String, repo: String, number: Int) async throws -> [GitHubPullRequestFile] {
        var files: [GitHubPullRequestFile] = []
        for page in 1...30 {
            let reply = try await http.get(url("repos/\(owner)/\(repo)/pulls/\(number)/files", query: ["per_page": "100", "page": String(page)]), headers: headers())
            let batch = try decode([GitHubPullRequestFile].self, from: reply)
            files.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return files
    }

    /// The whole pull request as a unified diff.
    public func diff(owner: String, repo: String, number: Int) async throws -> String {
        let reply = try await http.get(url("repos/\(owner)/\(repo)/pulls/\(number)"), headers: headers(accept: "application/vnd.github.diff"))
        return String(decoding: reply.data, as: UTF8.self)
    }

    /// A file's size at a commit, and its bytes when GitHub includes them (files up to 1 MB come base64-encoded;
    /// larger ones come without, which is what makes this cheap where downloading would not be). The object media
    /// type is the one GitHub documents for files up to 100 MB (checked read-only against a 24 MB file).
    public func fileMetadata(owner: String, repo: String, path: String, ref: String) async throws -> (size: Int64, content: Data?) {
        struct Metadata: Decodable { var size: Int64; var content: String?; var encoding: String? }
        let metadata = try decode(Metadata.self, from: try await http.get(url("repos/\(owner)/\(repo)/contents/\(path)", query: ["ref": ref]), headers: headers(accept: "application/vnd.github.object")))
        let content = metadata.encoding == "base64" ? metadata.content.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } : nil
        return (metadata.size, content)
    }

    /// A file's bytes at a commit. The path goes in unescaped: `appendingPathComponent` escapes spaces, `#`, `%`
    /// and non-ASCII once (escaping first made `%20` into `%2520` and every such file a 404).
    public func fileContent(owner: String, repo: String, path: String, ref: String) async throws -> Data {
        try await http.get(url("repos/\(owner)/\(repo)/contents/\(path)", query: ["ref": ref]), headers: headers(accept: "application/vnd.github.raw+json")).data
    }

    /// Conversation comments on the pull request (issue comments), oldest first.
    public func issueComments(owner: String, repo: String, number: Int) async throws -> [GitHubComment] {
        try await pages("repos/\(owner)/\(repo)/issues/\(number)/comments")
    }

    /// Review comments, each on a file and line.
    public func reviewComments(owner: String, repo: String, number: Int) async throws -> [GitHubComment] {
        try await pages("repos/\(owner)/\(repo)/pulls/\(number)/comments")
    }

    /// Every page of a list endpoint, 100 at a time.
    private func pages<T: Decodable>(_ path: String) async throws -> [T] {
        var items: [T] = []
        for page in 1...30 {
            let batch = try decode([T].self, from: try await http.get(url(path, query: ["per_page": "100", "page": String(page)]), headers: headers()))
            items.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return items
    }

    /// Open pull requests the user is involved in, most recently updated first.
    /// Open pull requests the user is involved in; `@me` is whoever the token belongs to.
    public func openPullRequests(involving login: String = "@me", limit: Int = 30) async throws -> [GitHubPullRequestSummary] {
        struct Search: Decodable { var items: [GitHubPullRequestSummary] }
        let reply = try await http.get(url("search/issues", query: ["q": "is:pr is:open involves:\(login)", "sort": "updated", "per_page": String(limit)]), headers: headers())
        return try decode(Search.self, from: reply).items
    }
}
