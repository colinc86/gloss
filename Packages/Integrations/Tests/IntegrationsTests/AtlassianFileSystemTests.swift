import Core
import Foundation
import Testing
@testable import Integrations

struct AtlassianPathTests {
    @Test func parsesTreePathsAndReferences() {
        #expect(AtlassianPath("/jira/CP/CP-7.md") == .jiraIssue(project: "CP", key: "CP-7"))
        #expect(AtlassianPath("/jira/CP") == .jiraProject("CP"))
        #expect(AtlassianPath("/jira/A1_2") == .jiraProject("A1_2"))
        #expect(AtlassianPath("/jira/CP OR assignee is not EMPTY") == nil, "a root is a project key, never JQL")
        for bad in ["CP--7", "-CP-7-", "CP-+7", "CP-", "1CP-7"] { #expect(!AtlassianPath.isIssueKey(bad), Comment(rawValue: bad)) }
        #expect(AtlassianPath("/confluence/ENG/100/Release plan.md") == .confluencePage(space: "ENG", id: "100", title: "Release plan"))
        #expect(AtlassianPath("/confluence/ENG/100") == .confluencePageFolder(space: "ENG", id: "100"))
        #expect(AtlassianPath("/confluence/ENG/100/101") == .confluencePageFolder(space: "ENG", id: "101", ancestors: ["100"]), "a child's folder nests in its parent's")
        #expect(AtlassianPath("/confluence/ENG/100/101/Phase 1.md") == .confluencePage(space: "ENG", id: "101", title: "Phase 1", ancestors: ["100"]))
        #expect(AtlassianPath("/confluence/ENG/100/101/Phase 1.md")?.pageID == "101")
        #expect(AtlassianPath.confluencePageFolder(space: "ENG", id: "100").childFolder("101")?.path == "/confluence/ENG/100/101")
        #expect(AtlassianPath("/jira/cp/cp-7.md") == .jiraIssue(project: "CP", key: "CP-7"), "keys are upper case however they were typed")
        for bad in ["/jira/CP/XX-7.md", "/jira/CP/CP-7", "/confluence/ENG/abc", "/confluence/ENG/100/abc/x.md", "/x", "/jira/../CP"] { #expect(AtlassianPath(bad) == nil, Comment(rawValue: bad)) }
        let site = URL(string: "https://x.atlassian.net")!
        #expect(AtlassianPath.parse(reference: "cp-7", site: site) == .jiraIssue(project: "CP", key: "CP-7"))
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/browse/CP-7?focused=1", site: site) == .jiraIssue(project: "CP", key: "CP-7"))
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/wiki/spaces/ENG/pages/100/Release+plan", site: site) == .confluencePageFolder(space: "ENG", id: "100"))
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/wiki/spaces/ENG/pages/edit-v2/100?draftShareId=abc", site: site) == .confluencePageFolder(space: "ENG", id: "100"), "a page being edited")
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/wiki/spaces/ENG/pages/edit/100", site: site) == .confluencePageFolder(space: "ENG", id: "100"))
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/wiki/spaces/ENG/pages/edit-v2", site: site) == nil)
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/jira/software/projects/CP/boards/1?selectedIssue=CP-7", site: site) == .jiraIssue(project: "CP", key: "CP-7"), "an issue open on a board")
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/jira/software/c/projects/CP/issues/CP-7?jql=x", site: site) == .jiraIssue(project: "CP", key: "CP-7"), "an issue open in the list")
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/jira/software/projects/CP/boards/1", site: site) == nil, "a board alone is no issue")
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/jira/software/projects/CP/issues", site: site) == nil)
        #expect(AtlassianPath.parse(reference: "https://other.atlassian.net/browse/CP-7", site: site) == nil, "another site's issue is not this account's")
        #expect(AtlassianPath.parse(reference: "https://other.atlassian.net/browse/CP-7", site: nil) == .jiraIssue(project: "CP", key: "CP-7"))
        #expect(AtlassianPath.fileTitle(" A/B: c ") == "A∕B∶ c")
    }
}

@Suite(.serialized)
struct AtlassianFileSystemTests {
    static let site = "https://x.atlassian.net"

    static func serve(_ stub: Stub, updated: String = "2026-10-03T12:00:00.000+0100") {
        stub.respond(to: "\(site)/rest/api/3/issue/CP-7?fields=summary,issuetype,status,priority,assignee,reporter,labels,parent,created,updated,description,comment,project,attachment", with: .json(AtlassianReadTests.issueJSON.replacingOccurrences(of: "2026-10-03T12:00:00.000+0100", with: updated)))
        stub.respond(to: "\(site)/rest/api/3/search/jql?fields=summary,status,issuetype,project,updated,attachment&jql=project%20%3D%20%22CP%22%20AND%20(assignee%20%3D%20currentUser()%20OR%20reporter%20%3D%20currentUser()%20OR%20watcher%20%3D%20currentUser())%20ORDER%20BY%20updated%20DESC&maxResults=100", with: .json(#"{"issues":[{"key":"CP-7","fields":{"summary":"Name the receiver","status":{"name":"In Progress"},"issuetype":{"name":"Task"},"project":{"key":"CP"},"updated":"2026-10-03T12:00:00.000+0100"}}],"isLast":true}"#))
        stub.respond(to: "\(site)/wiki/api/v2/spaces?limit=250&sort=name", with: .json(#"{"results":[{"id":"11","key":"ENG","name":"Engineering"}]}"#))
        stub.respond(to: "\(site)/wiki/api/v2/spaces/11/pages?depth=root&limit=250&sort=title", with: .json(#"{"results":[{"id":"100","title":"Release plan","spaceId":"11","version":{"number":7,"createdAt":"2026-10-03T12:00:00.000Z"},"_links":{"webui":"/spaces/ENG/pages/100/Release+plan"}}]}"#))
        stub.respond(to: "\(site)/wiki/api/v2/pages/100/children?limit=250", with: .json(#"{"results":[{"id":"101","title":"Phase 1/2","spaceId":"11","parentId":"100","version":{"number":2}}]}"#))
        stub.respond(to: "\(site)/wiki/api/v2/pages/100?body-format=atlas_doc_format", with: .json(#"{"id":"100","title":"Release plan","spaceId":"11","version":{"number":7,"createdAt":"2026-10-03T12:00:00.000Z"},"_links":{"webui":"/spaces/ENG/pages/100/Release+plan"},"body":{"atlas_doc_format":{"value":"{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"Ship it.\"}]}]}"}}}"#))
        stub.respond(to: "\(site)/wiki/api/v2/pages/100/ancestors", with: .json(#"{"results":[],"_links":{}}"#))
    }

    func provider(_ stub: Stub, poll: Duration = .seconds(10)) -> AtlassianFileSystem {
        AtlassianFileSystem(client: AtlassianClient(site: URL(string: Self.site)!, email: "c@x.com", token: "t", session: stub.session()), pollInterval: poll)
    }

    @Test func listsIssuesAndReadsOne() async throws {
        let stub = Stub()
        Self.serve(stub)
        let fs = provider(stub)
        #expect(try await fs.list("/jira/CP").map(\.name) == ["CP-7.md"])
        // The issue's summary rides along for the tree to show; the name and path stay the key.
        #expect(try await fs.list("/jira/CP").first?.title?.isEmpty == false)
        let text = String(decoding: try await fs.read("/jira/CP/CP-7.md"), as: UTF8.self)
        #expect(text.hasPrefix("# CP-7: Name the receiver\n\n- **Task** · In Progress · High\n- Assignee: Sam Rivera · Reporter: Sam\n- Labels: infra\n- Parent: CP-1\n- Updated 2026-10-03T11:00:00Z · created 2026-10-01T08:00:00Z\n- <https://x.atlassian.net/browse/CP-7>\n\n## Description\n\nRename it.\n\n## Comments\n\n### Sam Rivera · 2026-10-01T09:00:00Z\nWhy?\n\n### Sam · 2026-10-02T09:00:00Z\nAgreed.\n"), Comment(rawValue: text))
        #expect(try await fs.stat("/jira/CP/CP-7.md").mtime == ISO8601DateFormatter().date(from: "2026-10-03T11:00:00Z"))
        let url = URL(string: "https://x.atlassian.net/browse/CP-7")!
        #expect(await fs.resource(for: "/jira/CP/CP-7.md", line: 12) == PacketResource(url: url, details: ["Field: description", "Updated: 2026-10-03T11:00:00Z"]))
        #expect(await fs.resource(for: "/jira/CP/CP-7.md", line: 1) == PacketResource(url: url, details: ["Field: summary", "Updated: 2026-10-03T11:00:00Z"]))
        #expect(await fs.resource(for: "/jira/CP/CP-7.md", line: 3) == PacketResource(url: url, details: ["Updated: 2026-10-03T11:00:00Z"]), "a fact line is the issue as a whole")
        #expect(await fs.resource(for: "/jira/CP/CP-7.md") == PacketResource(url: url, details: ["Updated: 2026-10-03T11:00:00Z"]), "so is a whole-file note")
        #expect(await fs.resource(for: "/jira/CP/CP-7.md", line: 17) == PacketResource(url: url, details: ["Comment: https://x.atlassian.net/browse/CP-7?focusedCommentId=1"]))
        #expect(await fs.resource(for: "/jira/CP/CP-7.md", line: 20) == PacketResource(url: url, details: ["Comment: https://x.atlassian.net/browse/CP-7?focusedCommentId=2"]))
        #expect(await fs.title(for: "/jira/CP/CP-7.md") == "CP-7 · Name the receiver")
        await #expect(throws: FileSystemError.permissionDenied("/jira/CP/x")) { try await fs.makeDirectory("/jira/CP/x") }
        #expect(Set(stub.recorded.map { $0.httpMethod ?? "" }) == ["GET"])
    }

    @Test func changeSummariesNameWhoChangedIt() async throws {
        let stub = Stub()
        Self.serve(stub)
        stub.respond(to: "\(Self.site)/rest/api/3/issue/CP-7?expand=changelog&fields=updated", with: .json(#"{"changelog":{"histories":[{"created":"2026-10-01T09:00:00.000+0000","author":{"displayName":"Old Editor"}},{"created":"2026-10-05T09:00:00.000+0000","author":{"displayName":"Bo Chen"}}]}}"#))
        let fs = provider(stub)
        #expect(await fs.changeSummary(for: "/jira/CP/CP-7.md") == "Updated by Bo Chen", "the newest field change, later than any comment")
        stub.respond(to: "\(Self.site)/rest/api/3/issue/CP-7?expand=changelog&fields=updated", with: .json(#"{"changelog":{"histories":[{"created":"2026-09-01T09:00:00.000+0000","author":{"displayName":"Old Editor"}}]}}"#))
        let fresh = provider(stub)
        #expect(await fresh.changeSummary(for: "/jira/CP/CP-7.md") == "Updated by Sam", "Sam's comment came after the last field change")
        #expect(await fs.changeSummary(for: "/confluence/ENG/100/Release plan.md") == "Updated to version 7", "no author known: the version alone")
    }

    @Test func listsASpaceAndReadsAPage() async throws {
        let stub = Stub()
        Self.serve(stub)
        let fs = provider(stub)
        let root = try await fs.list("/confluence/ENG")
        #expect(root.map { "\($0.name):\($0.kind)" } == ["Release plan:directory"])
        #expect(root[0].path == "/confluence/ENG/100")
        let folder = try await fs.list("/confluence/ENG/100")
        #expect(folder.map(\.name) == ["Release plan.md", "Phase 1∕2"], "the page itself, then its children")
        #expect(folder.map(\.path) == ["/confluence/ENG/100/Release plan.md", "/confluence/ENG/100/101"], "a child's folder sits under its parent's path, as the tree shows it")
        let text = String(decoding: try await fs.read("/confluence/ENG/100/Release plan.md"), as: UTF8.self)
        #expect(text == "# Release plan\n\n- **Confluence** · ENG · version 7 · 2026-10-03T12:00:00Z\n- <https://x.atlassian.net/wiki/spaces/ENG/pages/100/Release+plan>\n\nShip it.\n", Comment(rawValue: text))
        #expect(await fs.resource(for: "/confluence/ENG/100/Release plan.md") == PacketResource(url: URL(string: "https://x.atlassian.net/wiki/spaces/ENG/pages/100/Release+plan")!, details: ["Version: 7"]))
        #expect(await fs.documentPath(for: .confluencePageFolder(space: "ENG", id: "100")) == "/confluence/ENG/100/Release plan.md")
        // A page URL names only the page; its ancestors put it where the tree has it.
        stub.respond(to: "\(Self.site)/wiki/api/v2/pages/101/ancestors", with: .json(#"{"results":[{"id":"100","type":"page"},{"id":"9","type":"folder"}],"_links":{}}"#))
        stub.respond(to: "\(Self.site)/wiki/api/v2/pages/101?body-format=atlas_doc_format", with: .json(#"{"id":"101","title":"Phase 1/2","spaceId":"11","parentId":"100","version":{"number":2},"body":{"atlas_doc_format":{"value":"{\"type\":\"doc\",\"content\":[]}"}}}"#))
        #expect(await fs.documentPath(for: .confluencePageFolder(space: "ENG", id: "101")) == "/confluence/ENG/100/101/Phase 1∕2.md")
        #expect(await fs.documentPath(for: .confluencePage(space: "ENG", id: "101", title: "Old name")) == "/confluence/ENG/100/101/Phase 1∕2.md", "a path from before a rename comes back with today's")
        #expect(try await fs.read("/confluence/ENG/100/Other.md") == Data(text.utf8), "the title in the path is cosmetic: a renamed page keeps its notes")
        await #expect(throws: FileSystemError.notFound("/confluence/NOPE")) { try await fs.list("/confluence/NOPE") }
    }

    @Test(.timeLimit(.minutes(1))) func watchingSeesAnUpdatedIssue() async throws {
        let stub = Stub()
        Self.serve(stub)
        let issueURL = "\(Self.site)/rest/api/3/issue/CP-7?fields=summary,issuetype,status,priority,assignee,reporter,labels,parent,created,updated,description,comment,project,attachment"
        stub.respond(to: issueURL, inOrder: [.json(AtlassianReadTests.issueJSON), .json(AtlassianReadTests.issueJSON), .json(AtlassianReadTests.issueJSON.replacingOccurrences(of: "2026-10-03T12:00:00.000+0100", with: "2026-10-04T09:00:00.000+0100"))])
        let fs = provider(stub, poll: .milliseconds(30))
        _ = try await fs.read("/jira/CP/CP-7.md")
        var events: [FileSystemEvent] = []
        for await event in fs.watch("/jira/CP/CP-7.md") {
            events.append(event)
            break
        }
        #expect(events == [.changed(["/jira/CP/CP-7.md"])])
        #expect(try await fs.stat("/jira/CP/CP-7.md").mtime == ISO8601DateFormatter().date(from: "2026-10-04T08:00:00Z"))
    }
}
