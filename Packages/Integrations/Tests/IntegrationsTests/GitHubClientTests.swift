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
        stub.respond(to: "\(base)/user", with: .json(#"{"login":"octocat"}"#, headers: ["X-OAuth-Scopes": "repo, user"]))
        let viewer = try await client(stub).viewer()
        #expect(viewer == GitHubViewer(login: "octocat", scopes: ["repo", "user"]))
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
        stub.respond(to: "\(base)/repos/o/r/issues/7/comments?page=1&per_page=100", with: .json(#"[{"id":1,"html_url":"https://github.com/o/r/pull/7#issuecomment-1","user":{"login":"b"},"body":"hi","created_at":"2026-10-03T10:00:00Z"}]"#))
        stub.respond(to: "\(base)/repos/o/r/pulls/7/comments?page=1&per_page=100", with: .json(#"[{"id":2,"html_url":"https://github.com/o/r/pull/7#discussion_r2","user":{"login":"b"},"body":"here","created_at":"2026-10-03T10:00:00Z","path":"a.swift","line":3,"side":"RIGHT","diff_hunk":"@@ -1 +1 @@"}]"#))
        stub.respond(to: "\(base)/search/issues?per_page=30&q=is:pr%20is:open%20involves:octocat&sort=updated", with: .json(#"{"items":[{"number":7,"title":"T","state":"open","html_url":"https://github.com/o/r/pull/7","updated_at":"2026-10-03T10:00:00Z","repository_url":"https://api.github.com/repos/o/r"}]}"#))
        let client = client(stub)
        let pull = try await client.pullRequest(owner: "o", repo: "r", number: 7)
        #expect(pull.head.sha == "abc" && pull.labels.map(\.name) == ["bug"] && pull.head.repo?.fullName == "o/r")
        let files = try await client.pullRequestFiles(owner: "o", repo: "r", number: 7)
        #expect(files.first?.patch?.hasPrefix("@@") == true)
        #expect(String(decoding: try await client.fileContent(owner: "o", repo: "r", path: "Sources/App.swift", ref: "abc"), as: UTF8.self) == "let x = 1\n")
        #expect(try await client.issueComments(owner: "o", repo: "r", number: 7).first?.body == "hi")
        #expect(try await client.reviewComments(owner: "o", repo: "r", number: 7).first?.line == 3)
        let summaries = try await client.openPullRequests(involving: "octocat")
        #expect(summaries.first?.repository == "o/r")
        let methods = Set(stub.recorded.map { $0.httpMethod ?? "" })
        #expect(methods == ["GET"], "the client can only read: \(methods)")
        #expect(stub.recorded.count == 6)
    }

    @Test func filePathsAreEscapedOnce() async throws {
        let stub = Stub()
        stub.respond(to: "\(base)/repos/o/r/contents/Docs/My%20File%231.md?ref=abc", with: .init(headers: ["Content-Type": "application/vnd.github.raw"], body: Data("hi".utf8)))
        #expect(String(decoding: try await client(stub).fileContent(owner: "o", repo: "r", path: "Docs/My File#1.md", ref: "abc"), as: UTF8.self) == "hi")
        #expect(stub.recorded.first?.cachePolicy == .reloadIgnoringLocalCacheData, "the app's ETags are the only cache")
    }

    @Test func commentsFollowEveryPage() async throws {
        let stub = Stub()
        let page = (1...100).map { #"{"id":\#($0),"html_url":"https://github.com/o/r/pull/7#issuecomment-\#($0)","user":{"login":"b"},"body":"c","created_at":"2026-10-03T10:00:00Z"}"# }.joined(separator: ",")
        stub.respond(to: "\(base)/repos/o/r/issues/7/comments?page=1&per_page=100", with: .json("[\(page)]"))
        stub.respond(to: "\(base)/repos/o/r/issues/7/comments?page=2&per_page=100", with: .json(#"[{"id":101,"html_url":"https://github.com/o/r/pull/7#issuecomment-101","user":{"login":"b"},"body":"last","created_at":"2026-10-03T10:00:00Z"}]"#))
        let comments = try await client(stub).issueComments(owner: "o", repo: "r", number: 7)
        #expect(comments.count == 101 && comments.last?.body == "last")
    }

    @Test func theCacheTellsRepresentationsApart() async throws {
        let stub = Stub()
        stub.respond(to: "\(base)/repos/o/r/pulls/7", with: .json(#"{"number":7,"title":"T","state":"open","html_url":"https://github.com/o/r/pull/7","user":{"login":"a"},"head":{"ref":"f","sha":"abc"},"base":{"ref":"main","sha":"def"},"updated_at":"2026-10-03T10:00:00Z","labels":[]}"#, headers: ["ETag": "\"json\""]))
        let client = client(stub)
        _ = try await client.pullRequest(owner: "o", repo: "r", number: 7)
        stub.respond(to: "\(base)/repos/o/r/pulls/7", with: .init(headers: ["Content-Type": "text/plain", "ETag": "\"diff\""], body: Data("diff --git a b".utf8)))
        #expect(try await client.diff(owner: "o", repo: "r", number: 7) == "diff --git a b")
        #expect(stub.recorded.last?.value(forHTTPHeaderField: "If-None-Match") == nil, "the diff's first read carries no JSON tag")
        stub.respond(to: "\(base)/repos/o/r/pulls/7", with: .json("{}", headers: ["ETag": "\"json\""]))
        let again = try await client.pullRequest(owner: "o", repo: "r", number: 7)
        #expect(again.number == 7, "the JSON representation came back from its own cache entry on a 304")
    }

    @Test func cachedReadsPresentTheirETag() async throws {
        let stub = Stub()
        stub.respond(to: "\(base)/user", with: .json(#"{"login":"octocat"}"#, headers: ["ETag": "\"v1\""]))
        let client = client(stub)
        _ = try await client.viewer()
        let again = try await client.viewer()
        #expect(again.login == "octocat", "a 304 hands back the cached body")
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

struct HTTPLayerTests {
    @Test func queriesEscapeEveryReservedCharacter() {
        let url = GetOnlyHTTP.url(URL(string: "https://example.atlassian.net")!, path: "rest/api/3/search/jql", query: ["jql": "summary ~ \"a+b\" & x=1"])
        #expect(url.absoluteString.contains("a%2Bb"), "a plus is a plus, not a space")
        #expect(url.absoluteString.contains("%26") && url.absoluteString.contains("x%3D1"))
    }

    @Test func rateLimitResetsAreRead() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(GetOnlyHTTP.resetDate(["retry-after": "30"], now: now) == Date(timeIntervalSince1970: 1_030))
        #expect(GetOnlyHTTP.resetDate(["x-ratelimit-reset": "2000"], now: now) == Date(timeIntervalSince1970: 2_000))
        #expect(GetOnlyHTTP.resetDate(["x-ratelimit-reset": "1970-01-01T00:40:00Z"], now: now) == Date(timeIntervalSince1970: 2_400), "Atlassian sends an ISO time")
        #expect(GetOnlyHTTP.resetDate([:], now: now) == nil)
        #expect(GetOnlyHTTP.resetDate(["retry-after": "Thu, 01 Jan 1970 00:20:00 GMT"], now: now) == Date(timeIntervalSince1970: 1_200), "an HTTP date")
        #expect(GetOnlyHTTP.resetDate(["x-ratelimit-reset": "2000000000000"], now: now) == Date(timeIntervalSince1970: 2_000_000_000), "milliseconds are read as such")
        #expect(GetOnlyHTTP.resetDate(["retry-after": "inf"], now: now) == nil, "not a wait anyone means")
    }

    @Test func pollsBackOffAndWaitOutALimit() {
        var schedule = PollSchedule(interval: .seconds(10))
        let now = Date(timeIntervalSince1970: 0)
        #expect(schedule.delay(rateLimitedUntil: nil, now: now) == .seconds(10))
        schedule.failed()
        #expect(schedule.delay(rateLimitedUntil: nil, now: now) == .seconds(20))
        for _ in 0..<10 { schedule.failed() }
        #expect(schedule.delay(rateLimitedUntil: nil, now: now) == .seconds(300), "never more than five minutes")
        schedule.succeeded()
        #expect(schedule.delay(rateLimitedUntil: nil, now: now) == .seconds(10))
        #expect(schedule.delay(rateLimitedUntil: Date(timeIntervalSince1970: 120), now: now) == .seconds(120))
        #expect(schedule.delay(rateLimitedUntil: Date(timeIntervalSince1970: 1e9), now: now) == .seconds(3600), "never more than an hour, whatever the server says")
    }

    @Test func aPausedPollerWakesWhenTheAppComesBack() async throws {
        let gate = PollGate()
        gate.isPaused = true
        let started = ContinuousClock.now
        async let slept: Void = gate.sleep(for: .seconds(30))
        try await Task.sleep(for: .milliseconds(100))
        gate.isPaused = false
        await slept
        #expect(ContinuousClock.now - started < .seconds(5), "activation cuts the interval short")
        gate.isPaused = true
        async let waited: Void = gate.waitWhilePaused()
        try await Task.sleep(for: .milliseconds(50))
        gate.isPaused = false
        await waited
    }

    @Test func secondaryLimitsAndStrayNotModifiedAreHandled() async throws {
        let stub = Stub()
        stub.respond(to: "https://api.github.com/user", with: .json(#"{"message":"You have exceeded a secondary rate limit."}"#, status: 403, headers: ["Retry-After": "60"]))
        let client = GitHubClient(token: "t", session: stub.session())
        await #expect(throws: IntegrationError.self) { _ = try await client.viewer() }
        do { _ = try await client.viewer() } catch let error as IntegrationError {
            if case .rateLimited(let reset) = error { #expect(reset != nil) } else { Issue.record("a secondary limit is a rate limit, not a refused key: \(error)") }
        }
        // A 403 that says nothing of limits is a refusal; a 503 with Retry-After is a limit.
        let refused = Stub()
        refused.respond(to: "https://api.github.com/user", with: .json(#"{"message":"Resource not accessible by integration"}"#, status: 403))
        await #expect(throws: IntegrationError.unauthorized("Resource not accessible by integration")) { _ = try await GitHubClient(token: "t", session: refused.session()).viewer() }
        let busy = Stub()
        busy.respond(to: "https://api.github.com/user", with: .json("{}", status: 503, headers: ["Retry-After": "5"]))
        do { _ = try await GitHubClient(token: "t", session: busy.session()).viewer(); Issue.record("expected a limit") } catch let error as IntegrationError {
            if case .rateLimited = error {} else { Issue.record("a 503 with Retry-After is a limit: \(error)") }
        }
        // A server that answers 304 to a request that sent no tag is asked once more, plainly.
        let other = Stub()
        other.respond(to: "https://api.github.com/user", inOrder: [.json("", status: 304), .json(#"{"login":"octo"}"#)])
        #expect(try await GitHubClient(token: "t", session: other.session()).viewer().login == "octo")
    }
}

struct HTTPLayerProviderTests {
    @Test func aChangedFilesSizeComesFromItsMetadata() async throws {
        let stub = Stub()
        GitHubPullRequestFileSystemTests.serve(stub)
        let base = GitHubPullRequestFileSystemTests.base
        // 90 MB: the metadata says so without the bytes; nothing downloads the file to learn its size.
        stub.respond(to: "\(base)/repos/o/r/contents/Sources/App.swift?ref=f00d123abcdef", accept: "application/vnd.github.object", with: .json(#"{"size":94371840,"encoding":"none","content":""}"#))
        let fs = GitHubPullRequestFileSystem(client: GitHubClient(token: "t", session: stub.session()))
        #expect(try await fs.stat("/o/r/pull/2/changes/Sources/App.swift").size == 94_371_840)
        #expect(!stub.recorded.contains { $0.value(forHTTPHeaderField: "Accept")?.contains("raw") == true }, "the file itself was not fetched")
    }

    @Test func aRepeatedPageTokenEndsTheSearch() async throws {
        let stub = Stub()
        let site = "https://example.atlassian.net"
        let first = "\(site)/rest/api/3/search/jql?fields=summary,status,issuetype,project,updated,attachment&jql=project%20%3D%20CP&maxResults=100"
        stub.respond(to: first, with: .json(#"{"issues":[],"isLast":false,"nextPageToken":"t1"}"#))
        stub.respond(to: first + "&nextPageToken=t1", with: .json(#"{"issues":[],"isLast":false,"nextPageToken":"t1"}"#))
        let client = AtlassianClient(site: URL(string: site)!, email: "a@x.com", token: "t", session: stub.session())
        let issues = try await client.searchIssues(jql: "project = CP", limit: 200)
        #expect(issues.isEmpty)
        #expect(stub.recorded.count <= 3, "\(stub.recorded.count) requests")
    }
}
