import Core
import Foundation
import Testing
@testable import Integrations

struct PullRequestPathTests {
    @Test func parsesTreePaths() {
        let root = PullRequestPath("/o/r/pull/12")
        #expect(root?.owner == "o" && root?.repo == "r" && root?.number == 12 && root?.rest == "" && root?.isRoot == true)
        #expect(PullRequestPath("/o/r/pull/12/")?.isRoot == true)
        #expect(PullRequestPath("/o/r/pull/12/changes/Sources/A.swift")?.changedFile == "Sources/A.swift")
        #expect(PullRequestPath("/o/r/pull/12/changes")?.isChangesDirectory == true)
        #expect(PullRequestPath("/o/r/pull/12/Pull request.md")?.rest == "Pull request.md")
        #expect(PullRequestPath("/o/r/pull/12")?.diffName == "pull-12.diff")
        #expect(PullRequestPath("/o/r/pull/12")?.webURL == URL(string: "https://github.com/o/r/pull/12"))
        for bad in ["/o/r", "/o/r/pulls/12", "/o/r/pull/x", "/o/r/pull/0", "/", "/o//pull/1", "/../../pull/1", "/o/./pull/1"] {
            #expect(PullRequestPath(bad) == nil, Comment(rawValue: bad))
        }
    }

    @Test func parsesReferences() {
        #expect(PullRequestPath.parse(reference: "https://github.com/o/r/pull/12") == PullRequestPath(owner: "o", repo: "r", number: 12))
        #expect(PullRequestPath.parse(reference: "github.com/o/r/pull/12/files") == PullRequestPath(owner: "o", repo: "r", number: 12))
        #expect(PullRequestPath.parse(reference: "https://github.com/o/r/pull/12/files/Sources/A.swift")?.changedFile == "Sources/A.swift")
        #expect(PullRequestPath.parse(reference: " o/r#12 ") == PullRequestPath(owner: "o", repo: "r", number: 12))
        for bad in ["#12", "o/r", "https://gitlab.com/o/r/pull/1", "https://github.com/o/r/issues/12", "o/r#x", "", "o/r #12", "../x#1"] {
            #expect(PullRequestPath.parse(reference: bad) == nil, Comment(rawValue: bad))
        }
    }
}

struct PatchHunksTests {
    @Test func addedModifiedAndDeletedLines() {
        let patch = """
        @@ -1,4 +1,5 @@
         a
        -b
        +B
        +B2
         c
        -d
         e
        @@ -20,3 +21,4 @@
         x
        +y
         z
        """
        let changes = PatchHunks.parse(patch)
        #expect(changes.added == [2...3, 22...22], "a rewritten line and an insertion tint; context does not")
        #expect(changes.deletions == [5], "d was taken out just before e, which is now line 5")
        #expect(changes.hunks == [2...3, 5...5, 22...22])
    }

    @Test func deletionAtTheEndAndNoNewlineMarkers() {
        let patch = """
        @@ -1,3 +1,2 @@
         a
         b
        -c
        \\ No newline at end of file
        """
        #expect(PatchHunks.parse(patch) == LineChanges(added: [], deletions: [3]))
        #expect(PatchHunks.parse("@@ -0,0 +1,2 @@\n+new\n+file") == LineChanges(added: [1...2]))
        #expect(PatchHunks.parse("").isEmpty)
    }

    @Test func aDiffTooLargeForGitHubSaysSoAndAFileWithoutAPatchIsFlagged() async throws {
        let stub = Stub()
        GitHubPullRequestFileSystemTests.serve(stub)
        stub.respond(to: "\(GitHubPullRequestFileSystemTests.base)/repos/o/r/pulls/2", accept: "application/vnd.github.diff", with: .json(#"{"message":"Sorry, the diff exceeded the maximum number of lines"}"#, status: 406))
        let fs = GitHubPullRequestFileSystem(client: GitHubClient(token: "t", session: stub.session()))
        let text = String(decoding: try await fs.read("/o/r/pull/2/pull-2.diff"), as: UTF8.self)
        #expect(text.hasPrefix("This diff is too large for GitHub to send."))
        #expect(await fs.patchOmitted(forPath: "/o/r/pull/2/changes/Sources/App.swift") == false)
        #expect(await fs.patchOmitted(forPath: "/o/r/pull/2/changes/Gone.swift") == false, "a removed file is not shown at all")

        let large = Stub()
        GitHubPullRequestFileSystemTests.serve(large)
        large.respond(to: "\(GitHubPullRequestFileSystemTests.base)/repos/o/r/pulls/2/files?page=1&per_page=100", with: .json(#"[{"filename":"Assets/model.bin","status":"added","additions":12,"deletions":0}]"#))
        let other = GitHubPullRequestFileSystem(client: GitHubClient(token: "t", session: large.session()))
        #expect(await other.patchOmitted(forPath: "/o/r/pull/2/changes/Assets/model.bin"), "GitHub sent no patch for it")
        #expect(await other.changes(forPath: "/o/r/pull/2/changes/Assets/model.bin") == nil)
    }

    @Test func crlfHeadersWithoutCountsAndSeparatorsInContent() {
        // A CRLF file: Swift reads "\r\n" as one Character, so the patch must still split into its lines.
        #expect(PatchHunks.parse("@@ -1,2 +1,2 @@\r\n-a\r\n+b\r\n c\r\n") == LineChanges(added: [1...1]))
        // A one-line file's hunk header leaves the counts out.
        #expect(PatchHunks.parse("@@ -1 +1 @@\n-old\n+new") == LineChanges(added: [1...1]))
        // A U+2028 inside a line is content to git, not a line end.
        #expect(PatchHunks.parse("@@ -1,2 +1,2 @@\n let s = \"a\u{2028}b\"\n-x\n+y") == LineChanges(added: [2...2]))
        // A renamed file with no changes has no patch hunks; a binary file has no patch at all.
        #expect(PatchHunks.parse("").isEmpty)
    }
}

@Suite(.serialized)
struct GitHubPullRequestFileSystemTests {
    static let base = "https://api.github.com"

    static func pullJSON(sha: String, updated: String = "2026-10-03T10:00:00Z") -> String {
        #"{"number":2,"title":"Name the receiver","state":"closed","merged":true,"html_url":"https://github.com/o/r/pull/2","body":"Why:\r\n\r\nbecause.","user":{"login":"colinc86"},"head":{"ref":"fix","sha":"\#(sha)","repo":{"full_name":"o/r"}},"base":{"ref":"main","sha":"base000"},"updated_at":"\#(updated)","labels":[{"name":"infra"}],"requested_reviewers":[{"login":"sam"}],"additions":5,"deletions":5,"changed_files":3}"#
    }

    static func serve(_ stub: Stub, sha: String = "f00d123abcdef") {
        stub.respond(to: "\(base)/repos/o/r/pulls/2", with: .json(pullJSON(sha: sha)))
        stub.respond(to: "\(base)/repos/o/r/pulls/2/files?page=1&per_page=100", with: .json(#"[{"filename":"Sources/App.swift","status":"modified","additions":1,"deletions":1,"patch":"@@ -1,2 +1,2 @@\n-old\n+new\n ctx"},{"filename":"Sources/Deep/Nested.swift","status":"added","additions":2,"deletions":0,"patch":"@@ -0,0 +1,2 @@\n+a\n+b"},{"filename":"Gone.swift","status":"removed","additions":0,"deletions":4}]"#))
        stub.respond(to: "\(base)/repos/o/r/issues/2/comments?page=1&per_page=100", with: .json(#"[{"id":1,"html_url":"https://github.com/o/r/pull/2#issuecomment-1","user":{"login":"sam"},"body":"Looks right.\r\n\r\nTwo more\nlines.","created_at":"2026-10-03T11:00:00Z"},{"id":3,"html_url":"https://github.com/o/r/pull/2#issuecomment-3","user":{"login":"colinc86"},"body":"Thanks.","created_at":"2026-10-03T11:10:00Z"}]"#))
        stub.respond(to: "\(base)/repos/o/r/pulls/2/comments?page=1&per_page=100", with: .json(#"[{"id":2,"html_url":"https://github.com/o/r/pull/2#discussion_r2","user":{"login":"sam"},"body":"Rename this.","created_at":"2026-10-03T11:30:00Z","path":"Sources/App.swift","line":2,"side":"RIGHT"}]"#))
        stub.respond(to: "\(base)/repos/o/r/contents/Sources/App.swift?ref=\(sha)", with: .init(headers: ["Content-Type": "application/vnd.github.raw"], body: Data("new\nctx\n".utf8)))
        stub.respond(to: "\(base)/repos/o/r/contents/Sources/Deep/Nested.swift?ref=\(sha)", with: .init(headers: ["Content-Type": "application/vnd.github.raw"], body: Data("a\nb\n".utf8)))
        stub.respond(to: "\(base)/repos/o/r/pulls/2", with: .json(pullJSON(sha: sha)))
    }

    func provider(_ stub: Stub, poll: Duration = .seconds(10)) -> GitHubPullRequestFileSystem {
        GitHubPullRequestFileSystem(client: GitHubClient(token: "t", session: stub.session()), pollInterval: poll)
    }

    @Test func listsTheTreeAndReadsEveryDocument() async throws {
        let stub = Stub()
        Self.serve(stub)
        let fs = provider(stub)
        let root = try await fs.list("/o/r/pull/2")
        #expect(root.map(\.name) == ["Pull request.md", "Conversation.md", "changes", "pull-2.diff"])
        #expect(root[2].kind == .directory && root[0].mode == 0o444)
        let changes = try await fs.list("/o/r/pull/2/changes")
        #expect(changes.map(\.name) == ["Sources"] && changes[0].kind == .directory, "removed files are not at head")
        let sources = try await fs.list("/o/r/pull/2/changes/Sources")
        #expect(sources.map { "\($0.name):\($0.kind)" } == ["App.swift:file", "Deep:directory"])

        let description = String(decoding: try await fs.read("/o/r/pull/2/Pull request.md"), as: UTF8.self)
        #expect(description.hasPrefix("# Name the receiver\n\n- **o/r #2** · merged · by @colinc86\n- `main` ← `fix` (f00d123) · +5 −5 in 3 files\n- Labels: infra\n- Reviewers: @sam\n- Removed: Gone.swift\n- <https://github.com/o/r/pull/2>\n\nWhy:\n\nbecause.\n\n## Reviews\n\n### Sources/App.swift:2 · @sam · 2026-10-03T11:30:00Z\nRename this.\n"), Comment(rawValue: description))
        let conversation = String(decoding: try await fs.read("/o/r/pull/2/Conversation.md"), as: UTF8.self)
        #expect(conversation == "# Conversation\n\n### @sam · 2026-10-03T11:00:00Z\nLooks right.\n\nTwo more\nlines.\n\n### @colinc86 · 2026-10-03T11:10:00Z\nThanks.\n", Comment(rawValue: conversation))
        await #expect(throws: FileSystemError.notADirectory("/o/r/pull/2/changes/Sources/App.swift")) { try await fs.list("/o/r/pull/2/changes/Sources/App.swift") }
        #expect(String(decoding: try await fs.read("/o/r/pull/2/changes/Sources/App.swift"), as: UTF8.self) == "new\nctx\n")
        #expect(try await fs.stat("/o/r/pull/2/changes/Sources/Deep").kind == .directory)
        #expect(try await fs.stat("/o/r/pull/2/changes/Sources/App.swift").size == 8)
        #expect(try await fs.stat("/o/r/pull/2").mtime == ISO8601DateFormatter().date(from: "2026-10-03T10:00:00Z"))
        await #expect(throws: FileSystemError.notFound("/o/r/pull/2/changes/Gone.swift")) { try await fs.read("/o/r/pull/2/changes/Gone.swift") }
        await #expect(throws: FileSystemError.permissionDenied("/o/r/pull/2/x")) { try await fs.makeDirectory("/o/r/pull/2/x") }
        await #expect(throws: FileSystemError.notFound("/elsewhere")) { try await fs.list("/elsewhere") }
        #expect(Set(stub.recorded.map { $0.httpMethod ?? "" }) == ["GET"])
        #expect(stub.recorded.filter { $0.url!.path == "/repos/o/r/pulls/2" }.count == 1, "the pull request is fetched once for every document")

        // Callers arriving together share the one fetch.
        let other = Stub()
        Self.serve(other)
        let shared = provider(other)
        async let a = shared.list("/o/r/pull/2")
        async let b = shared.stat("/o/r/pull/2/Pull request.md")
        _ = try await (a, b)
        #expect(other.recorded.filter { $0.url!.path == "/repos/o/r/pulls/2" }.count == 1, "two concurrent callers, one fetch")

        // The same facts render the same bytes, so anchors in the Markdown stay put across re-renders.
        #expect(try await fs.read("/o/r/pull/2/Pull request.md") == Data(description.utf8))
    }

    @Test func changesAndResources() async throws {
        let stub = Stub()
        Self.serve(stub)
        let fs = provider(stub)
        #expect(await fs.changes(forPath: "/o/r/pull/2/changes/Sources/App.swift") == LineChanges(added: [1...1]))
        #expect(await fs.changes(forPath: "/o/r/pull/2/changes/Sources/Deep/Nested.swift") == LineChanges(added: [1...2]))
        #expect(await fs.changes(forPath: "/o/r/pull/2/Pull request.md") == nil)
        let url = URL(string: "https://github.com/o/r/pull/2")!
        #expect(await fs.resource(for: "/o/r/pull/2/changes/Sources/App.swift") == PacketResource(url: url, details: ["Path: Sources/App.swift at f00d123"]))
        #expect(await fs.resource(for: "/o/r/pull/2/Pull request.md") == PacketResource(url: url), "a whole-file note is the pull request as a whole")
        #expect(await fs.resource(for: "/o/r/pull/2/Pull request.md", line: 12) == PacketResource(url: url, details: ["Field: description"]), "a line of the body")
        #expect(await fs.resource(for: "/o/r/pull/2/Pull request.md", line: 4) == PacketResource(url: url), "a fact line is the pull request as a whole")
        #expect(await fs.resource(for: "/o/r/pull/2/Pull request.md", line: 17) == PacketResource(url: url, details: ["Comment: https://github.com/o/r/pull/2#discussion_r2"]), "a review comment by its own link")
        #expect(await fs.resource(for: "/o/r/pull/2/Conversation.md", line: 4) == PacketResource(url: url, details: ["Comment: https://github.com/o/r/pull/2#issuecomment-1"]))
        #expect(await fs.resource(for: "/o/r/pull/2/Conversation.md", line: 7) == PacketResource(url: url, details: ["Comment: https://github.com/o/r/pull/2#issuecomment-1"]), "a multi-line body is still the first comment")
        #expect(await fs.resource(for: "/o/r/pull/2/Conversation.md", line: 10) == PacketResource(url: url, details: ["Comment: https://github.com/o/r/pull/2#issuecomment-3"]), "the second comment starts after the first's lines")
        #expect(await fs.resource(for: "/o/r/pull/2/Conversation.md", line: 1) == PacketResource(url: url, details: ["Field: conversation"]))
        #expect(await fs.resource(for: "/o/r/pull/2/pull-2.diff") == PacketResource(url: url))
    }

    /// A new token mid-watch: the next poll reads with it and still reports the head that moved meanwhile.
    @Test(.timeLimit(.minutes(1))) func aNewKeyKeepsWatchingAndReportsTheMovedHead() async throws {
        let old = Stub()
        Self.serve(old)
        let fs = provider(old, poll: .milliseconds(30))
        _ = try await fs.read("/o/r/pull/2/changes/Sources/App.swift")
        let new = Stub()
        Self.serve(new, sha: "b222222222222")
        await fs.replaceClient(GitHubClient(token: "new-token", session: new.session()))
        var events: [FileSystemEvent] = []
        for await event in fs.watch("/o/r/pull/2/changes/Sources/App.swift") {
            events.append(event)
            break
        }
        #expect(events == [.changed(["/o/r/pull/2/changes/Sources/App.swift"])] || events.first.map { if case .changed = $0 { true } else { false } } == true)
        #expect(String(decoding: try await fs.read("/o/r/pull/2/changes/Sources/App.swift"), as: UTF8.self) == "new\nctx\n")
        #expect(await fs.resource(for: "/o/r/pull/2/changes/Sources/App.swift")?.details == ["Path: Sources/App.swift at b222222"], "the packet follows the new head")
        #expect(new.recorded.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasSuffix("new-token") == true }, "everything after the swap reads with the new key")
        #expect(!new.recorded.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func watchingSeesANewHead() async throws {
        let stub = Stub()
        Self.serve(stub)
        stub.respond(to: "\(Self.base)/repos/o/r/pulls/2", inOrder: [.json(Self.pullJSON(sha: "f00d123abcdef")), .json(Self.pullJSON(sha: "f00d123abcdef")), .json(Self.pullJSON(sha: "b222222222222", updated: "2026-10-03T12:00:00Z"))])
        stub.respond(to: "\(Self.base)/repos/o/r/contents/Sources/App.swift?ref=b222222222222", with: .init(headers: ["Content-Type": "application/vnd.github.raw"], body: Data("newer\nctx\n".utf8)))
        let fs = provider(stub, poll: .milliseconds(30))
        _ = try await fs.list("/o/r/pull/2")
        // The root (the explorer) hears the change and re-lists; a document hears only the change.
        var rootEvents: [FileSystemEvent] = []
        var fileEvents: [FileSystemEvent] = []
        let root = fs.watch("/o/r/pull/2")
        let file = fs.watch("/o/r/pull/2/changes/Sources/App.swift")
        for await event in root {
            rootEvents.append(event)
            if rootEvents.count == 2 { break }
        }
        for await event in file {
            fileEvents.append(event)
            break
        }
        guard case .changed(let paths) = rootEvents[0] else { Issue.record("expected changed first"); return }
        #expect(paths.contains("/o/r/pull/2/changes/Sources/App.swift") && paths.contains("/o/r/pull/2/Pull request.md"))
        #expect(rootEvents[1] == .rescan("/o/r/pull/2"))
        #expect(fileEvents.first == rootEvents[0])
        #expect(String(decoding: try await fs.read("/o/r/pull/2/changes/Sources/App.swift"), as: UTF8.self) == "newer\nctx\n", "the head moved: content is read at the new sha")
        #expect(try await fs.stat("/o/r/pull/2").mtime == ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z"))
        #expect(fs.watch("/nowhere").makeAsyncIterator() != nil)
    }

    /// `GLOSS_LIVE_PULL_REQUEST=owner/repo#n` with a token in `integrations.env`: reads that pull request, read-only.
    @Test(.enabled(if: TestGates.githubToken != nil && TestGates.livePullRequest != nil))
    func livePullRequestReadsItsTree() async throws {
        let fs = GitHubPullRequestFileSystem(client: GitHubClient(token: try #require(TestGates.githubToken)))
        let pull = try #require(TestGates.livePullRequest)
        let root = try await fs.list(pull.root)
        #expect(root.map(\.name) == ["Pull request.md", "Conversation.md", "changes", "pull-\(pull.number).diff"])
        let description = String(decoding: try await fs.read(pull.root + "/Pull request.md"), as: UTF8.self)
        #expect(description.contains("**\(pull.repository) #\(pull.number)**"))
        func walk(_ directory: String) async throws -> [String] {
            var files: [String] = []
            for entry in try await fs.list(directory) {
                if entry.kind == .directory { files += try await walk(entry.path) } else { files.append(entry.path) }
            }
            return files
        }
        let changed = try await walk(pull.root + "/changes")
        #expect(!changed.isEmpty, "\(changed)")
        for file in changed {
            #expect(await fs.changes(forPath: file) != nil, "\(file) has a patch")
        }
    }
}
