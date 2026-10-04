import Foundation
import Testing
@testable import Integrations

struct GitHubClientTests {
    let base = "https://api.github.com"

    func client(_ stub: Stub) -> GitHubClient {
        GitHubClient(token: "t0k", session: stub.session())
    }

    @Test func viewerReadsLoginAndScopes() async throws {
        let stub = Stub()
        stub.respond(to: "\(base)/user", with: .json(#"{"login":"colinc86"}"#, headers: ["X-OAuth-Scopes": "repo, user"]))
        let viewer = try await client(stub).viewer()
        #expect(viewer == GitHubViewer(login: "colinc86", scopes: ["repo", "user"]))
        let request = try #require(stub.recorded.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test func everyRequestIsAGet() async throws {
        let stub = Stub()
        let pr = #"{"number":7,"title":"T","state":"open","html_url":"https://github.com/o/r/pull/7","body":"b","user":{"login":"a"},"head":{"ref":"f","sha":"abc","repo":{"full_name":"o/r"}},"base":{"ref":"main","sha":"def"},"updated_at":"2026-10-03T10:00:00Z","labels":[{"name":"bug"}]}"#
        stub.respond(to: "\(base)/repos/o/r/pulls/7", with: .json(pr))
        stub.respond(to: "\(base)/repos/o/r/pulls/7/files?page=1&per_page=100", with: .json(#"[{"filename":"a.swift","status":"modified","additions":1,"deletions":0,"patch":"@@ -1 +1 @@\n-a\n+b"}]"#))
        stub.respond(to: "\(base)/repos/o/r/contents/Sources/App.swift?ref=abc", with: .init(headers: ["Content-Type": "application/vnd.github.raw"], body: Data("let x = 1\n".utf8)))
        stub.respond(to: "\(base)/repos/o/r/issues/7/comments?per_page=100", with: .json(#"[{"id":1,"html_url":"https://github.com/o/r/pull/7#issuecomment-1","user":{"login":"b"},"body":"hi","created_at":"2026-10-03T10:00:00Z"}]"#))
        stub.respond(to: "\(base)/repos/o/r/pulls/7/comments?per_page=100", with: .json(#"[{"id":2,"html_url":"https://github.com/o/r/pull/7#discussion_r2","user":{"login":"b"},"body":"here","created_at":"2026-10-03T10:00:00Z","path":"a.swift","line":3,"side":"RIGHT","diff_hunk":"@@ -1 +1 @@"}]"#))
        stub.respond(to: "\(base)/search/issues?per_page=30&q=is:pr%20is:open%20involves:colinc86&sort=updated", with: .json(#"{"items":[{"number":7,"title":"T","state":"open","html_url":"https://github.com/o/r/pull/7","updated_at":"2026-10-03T10:00:00Z","repository_url":"https://api.github.com/repos/o/r"}]}"#))
        let client = client(stub)
        let pull = try await client.pullRequest(owner: "o", repo: "r", number: 7)
        #expect(pull.head.sha == "abc" && pull.labels.map(\.name) == ["bug"] && pull.head.repo?.fullName == "o/r")
        let files = try await client.pullRequestFiles(owner: "o", repo: "r", number: 7)
        #expect(files.first?.patch?.hasPrefix("@@") == true)
        #expect(String(decoding: try await client.fileContent(owner: "o", repo: "r", path: "Sources/App.swift", ref: "abc"), as: UTF8.self) == "let x = 1\n")
        #expect(try await client.issueComments(owner: "o", repo: "r", number: 7).first?.body == "hi")
        #expect(try await client.reviewComments(owner: "o", repo: "r", number: 7).first?.line == 3)
        let summaries = try await client.openPullRequests(involving: "colinc86")
        #expect(summaries.first?.repository == "o/r")
        let methods = Set(stub.recorded.map { $0.httpMethod ?? "" })
        #expect(methods == ["GET"], "the client can only read: \(methods)")
        #expect(stub.recorded.count == 6)
    }

    @Test func cachedReadsPresentTheirETag() async throws {
        let stub = Stub()
        stub.respond(to: "\(base)/user", with: .json(#"{"login":"colinc86"}"#, headers: ["ETag": "\"v1\""]))
        let client = client(stub)
        _ = try await client.viewer()
        let again = try await client.viewer()
        #expect(again.login == "colinc86", "a 304 hands back the cached body")
        #expect(stub.recorded.last?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }

    @Test func errorsAreNamed() async throws {
        let stub = Stub()
        stub.respond(to: "\(base)/user", with: .json(#"{"message":"Bad credentials"}"#, status: 401))
        await #expect(throws: IntegrationError.unauthorized("Bad credentials")) { try await client(stub).viewer() }
        stub.respond(to: "\(base)/user", with: .json(#"{"message":"API rate limit exceeded"}"#, status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"]))
        await #expect(throws: IntegrationError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000))) { try await client(stub).viewer() }
        stub.respond(to: "\(base)/repos/o/r/pulls/9", with: .json(#"{"message":"Not Found"}"#, status: 404))
        await #expect(throws: IntegrationError.notFound("/repos/o/r/pulls/9")) { try await client(stub).pullRequest(owner: "o", repo: "r", number: 9) }
    }

    @Test(.enabled(if: TestGates.githubToken != nil))
    func liveTokenCanReadItsViewer() async throws {
        let client = GitHubClient(token: try #require(TestGates.githubToken))
        let viewer = try await client.viewer()
        #expect(!viewer.login.isEmpty)
        let open = try await client.openPullRequests(involving: viewer.login, limit: 5)
        #expect(open.count <= 5)
    }
}
