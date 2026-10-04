import Core
import Foundation
import Testing
@testable import Integrations

struct AtlassianPathTests {
    @Test func parsesTreePathsAndReferences() {
        #expect(AtlassianPath("/jira/CP/CP-7.md") == .jiraIssue(project: "CP", key: "CP-7"))
        #expect(AtlassianPath("/jira/CP") == .jiraProject("CP"))
        #expect(AtlassianPath("/confluence/ENG/100/Release plan.md") == .confluencePage(space: "ENG", id: "100", title: "Release plan"))
        #expect(AtlassianPath("/confluence/ENG/100") == .confluencePageFolder(space: "ENG", id: "100"))
        for bad in ["/jira/CP/XX-7.md", "/jira/CP/CP-7", "/confluence/ENG/abc", "/x", "/jira/../CP"] { #expect(AtlassianPath(bad) == nil, Comment(rawValue: bad)) }
        let site = URL(string: "https://x.atlassian.net")!
        #expect(AtlassianPath.parse(reference: "cp-7", site: site) == .jiraIssue(project: "CP", key: "CP-7"))
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/browse/CP-7?focused=1", site: site) == .jiraIssue(project: "CP", key: "CP-7"))
        #expect(AtlassianPath.parse(reference: "https://x.atlassian.net/wiki/spaces/ENG/pages/100/Release+plan", site: site) == .confluencePageFolder(space: "ENG", id: "100"))
        #expect(AtlassianPath.parse(reference: "https://other.atlassian.net/browse/CP-7", site: site) == nil, "another site's issue is not this account's")
        #expect(AtlassianPath.parse(reference: "https://other.atlassian.net/browse/CP-7", site: nil) == .jiraIssue(project: "CP", key: "CP-7"))
        #expect(AtlassianPath.fileTitle(" A/B: c ") == "A∕B∶ c")
    }
}

@Suite(.serialized)
struct AtlassianFileSystemTests {
    static let site = "https://x.atlassian.net"

    static func serve(_ stub: Stub, updated: String = "2026-10-03T12:00:00.000+0100") {
        stub.respond(to: "\(site)/rest/api/3/issue/CP-7?fields=summary,issuetype,status,priority,assignee,reporter,labels,parent,created,updated,description,comment,project", with: .json(AtlassianReadTests.issueJSON.replacingOccurrences(of: "2026-10-03T12:00:00.000+0100", with: updated)))
        stub.respond(to: "\(site)/rest/api/3/search/jql?fields=summary,status,issuetype,project,updated&jql=project%20%3D%20CP%20AND%20(assignee%20%3D%20currentUser()%20OR%20reporter%20%3D%20currentUser()%20OR%20watcher%20%3D%20currentUser())%20ORDER%20BY%20updated%20DESC&maxResults=50", with: .json(#"{"issues":[{"key":"CP-7","fields":{"summary":"Name the receiver","status":{"name":"In Progress"},"issuetype":{"name":"Task"},"project":{"key":"CP"},"updated":"2026-10-03T12:00:00.000+0100"}}],"isLast":true}"#))
        stub.respond(to: "\(site)/wiki/api/v2/spaces?limit=250&sort=name", with: .json(#"{"results":[{"id":"11","key":"ENG","name":"Engineering"}]}"#))
        stub.respond(to: "\(site)/wiki/api/v2/spaces/11/pages?depth=root&limit=250&sort=title", with: .json(#"{"results":[{"id":"100","title":"Release plan","spaceId":"11","version":{"number":7,"createdAt":"2026-10-03T12:00:00.000Z"},"_links":{"webui":"/spaces/ENG/pages/100/Release+plan"}}]}"#))
        stub.respond(to: "\(site)/wiki/api/v2/pages/100/children?limit=250", with: .json(#"{"results":[{"id":"101","title":"Phase 1/2","spaceId":"11","parentId":"100","version":{"number":2}}]}"#))
        stub.respond(to: "\(site)/wiki/api/v2/pages/100?body-format=atlas_doc_format", with: .json(#"{"id":"100","title":"Release plan","spaceId":"11","version":{"number":7,"createdAt":"2026-10-03T12:00:00.000Z"},"_links":{"webui":"/spaces/ENG/pages/100/Release+plan"},"body":{"atlas_doc_format":{"value":"{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"Ship it.\"}]}]}"}}}"#))
    }

    func provider(_ stub: Stub, poll: Duration = .seconds(10)) -> AtlassianFileSystem {
        AtlassianFileSystem(client: AtlassianClient(site: URL(string: Self.site)!, email: "c@x.com", token: "t", session: stub.session()), pollInterval: poll)
    }

    @Test func listsIssuesAndReadsOne() async throws {
        let stub = Stub()
        Self.serve(stub)
        let fs = provider(stub)
        #expect(try await fs.list("/jira/CP").map(\.name) == ["CP-7.md"])
        let text = String(decoding: try await fs.read("/jira/CP/CP-7.md"), as: UTF8.self)
        #expect(text.hasPrefix("# CP-7: Name the receiver\n\n- **Task** · In Progress · High\n- Assignee: Colin Campbell · Reporter: Sam\n- Labels: infra\n- Parent: CP-1\n- Updated 2026-10-03T11:00:00Z · created 2026-10-01T08:00:00Z\n- <https://x.atlassian.net/browse/CP-7>\n\n## Description\n\nRename it.\n\n## Comments\n\n### Colin Campbell · 2026-10-01T09:00:00Z\nWhy?\n\n### Sam · 2026-10-02T09:00:00Z\nAgreed.\n"), Comment(rawValue: text))
        #expect(try await fs.stat("/jira/CP/CP-7.md").mtime == ISO8601DateFormatter().date(from: "2026-10-03T11:00:00Z"))
        let url = URL(string: "https://x.atlassian.net/browse/CP-7")!
        #expect(await fs.resource(for: "/jira/CP/CP-7.md", line: 12) == PacketResource(url: url, details: ["Field: description", "Updated: 2026-10-03T11:00:00Z"]))
        #expect(await fs.resource(for: "/jira/CP/CP-7.md", line: 17) == PacketResource(url: url, details: ["Comment: 1"]))
        #expect(await fs.resource(for: "/jira/CP/CP-7.md", line: 20) == PacketResource(url: url, details: ["Comment: 2"]))
        #expect(await fs.title(for: "/jira/CP/CP-7.md") == "CP-7 · Name the receiver")
        await #expect(throws: FileSystemError.permissionDenied("/jira/CP/x")) { try await fs.makeDirectory("/jira/CP/x") }
        #expect(Set(stub.recorded.map { $0.httpMethod ?? "" }) == ["GET"])
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
        let text = String(decoding: try await fs.read("/confluence/ENG/100/Release plan.md"), as: UTF8.self)
        #expect(text == "# Release plan\n\n- **Confluence** · ENG · version 7 · 2026-10-03T12:00:00Z\n- <https://x.atlassian.net/wiki/spaces/ENG/pages/100/Release+plan>\n\nShip it.\n", Comment(rawValue: text))
        #expect(await fs.resource(for: "/confluence/ENG/100/Release plan.md") == PacketResource(url: URL(string: "https://x.atlassian.net/wiki/spaces/ENG/pages/100/Release+plan")!, details: ["Version: 7"]))
        #expect(await fs.documentPath(for: .confluencePageFolder(space: "ENG", id: "100")) == "/confluence/ENG/100/Release plan.md")
        await #expect(throws: FileSystemError.notFound("/confluence/ENG/100/Other.md")) { try await fs.read("/confluence/ENG/100/Other.md") }
        await #expect(throws: FileSystemError.notFound("/confluence/NOPE")) { try await fs.list("/confluence/NOPE") }
    }

    @Test func watchingSeesAnUpdatedIssue() async throws {
        let stub = Stub()
        Self.serve(stub)
        let issueURL = "\(Self.site)/rest/api/3/issue/CP-7?fields=summary,issuetype,status,priority,assignee,reporter,labels,parent,created,updated,description,comment,project"
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
