import Foundation
import Testing
@testable import Integrations

struct AtlassianReadTests {
    static let site = "https://x.atlassian.net"

    func client(_ stub: Stub) -> AtlassianClient {
        AtlassianClient(site: URL(string: Self.site)!, email: "c@x.com", token: "t", session: stub.session())
    }

    static let issueJSON = #"{"id":"10001","key":"CP-7","fields":{"summary":"Name the receiver","issuetype":{"name":"Task"},"status":{"name":"In Progress"},"priority":{"name":"High"},"assignee":{"displayName":"Sam Rivera"},"reporter":{"displayName":"Sam"},"labels":["infra"],"parent":{"key":"CP-1"},"project":{"key":"CP"},"created":"2026-10-01T09:00:00.000+0100","updated":"2026-10-03T12:00:00.000+0100","description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Rename it."}]}]},"comment":{"comments":[{"id":"2","author":{"displayName":"Sam"},"created":"2026-10-02T10:00:00.000+0100","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Agreed."}]}]}},{"id":"1","author":{"displayName":"Sam Rivera"},"created":"2026-10-01T10:00:00.000+0100","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Why?"}]}]}}]}}}"#

    /// An issue whose discussion runs past the comments Jira sends with it reads all of them, from the comments' own
    /// listing, page by page.
    @Test func aLongDiscussionIsReadInFull() async throws {
        func comment(_ id: Int) -> String {
            #"{"id":"\#(id)","author":{"displayName":"Sam"},"created":"2026-10-0\#(1 + id % 8)T10:00:00.000+0100","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Comment \#(id)."}]}]}}"#
        }
        let issue = #"{"id":"10001","key":"CP-7","fields":{"summary":"Long","project":{"key":"CP"},"comment":{"total":3,"maxResults":1,"startAt":0,"comments":["# + comment(0) + #"]}}}"#
        let stub = Stub()
        let fields = "summary,issuetype,status,priority,assignee,reporter,labels,parent,created,updated,description,comment,project,attachment"
        stub.respond(to: "\(Self.site)/rest/api/3/issue/CP-7?fields=\(fields)", with: .json(issue))
        let listing = "\(Self.site)/rest/api/3/issue/CP-7/comment?maxResults=100&orderBy=created&startAt="
        stub.respond(to: listing + "0", with: .json(#"{"total":3,"comments":["# + comment(0) + "," + comment(1) + #"]}"#))
        stub.respond(to: listing + "2", with: .json(#"{"total":3,"comments":["# + comment(2) + #"]}"#))
        let read = try await client(stub).issue(key: "CP-7")
        #expect(read.comments.map(\.id) == ["0", "1", "2"])
        #expect(read.comments.map(\.body) == ["Comment 0.\n", "Comment 1.\n", "Comment 2.\n"])
    }

    @Test func readsAnIssueWithItsDescriptionAndComments() async throws {
        let stub = Stub()
        stub.respond(to: "\(Self.site)/rest/api/3/issue/CP-7?fields=summary,issuetype,status,priority,assignee,reporter,labels,parent,created,updated,description,comment,project,attachment", with: .json(Self.issueJSON))
        let issue = try await client(stub).issue(key: "CP-7")
        #expect(issue.key == "CP-7" && issue.summary == "Name the receiver" && issue.status == "In Progress" && issue.priority == "High")
        #expect(issue.assignee == "Sam Rivera" && issue.labels == ["infra"] && issue.parentKey == "CP-1" && issue.projectKey == "CP")
        #expect(issue.description == "Rename it.\n")
        #expect(issue.comments.map(\.id) == ["1", "2"], "oldest first")
        #expect(issue.comments[0].body == "Why?\n")
        #expect(issue.updated == ISO8601DateFormatter().date(from: "2026-10-03T11:00:00Z"))
        #expect(Set(stub.recorded.map { $0.httpMethod ?? "" }) == ["GET"])
    }

    @Test func searchFollowsPageTokens() async throws {
        let stub = Stub()
        let base = "\(Self.site)/rest/api/3/search/jql?fields=summary,status,issuetype,project,updated,attachment&jql=assignee%20%3D%20currentUser()&maxResults=50"
        stub.respond(to: base, with: .json(#"{"issues":[{"key":"CP-1","fields":{"summary":"a","status":{"name":"Done"},"issuetype":{"name":"Bug"},"project":{"key":"CP"},"updated":"2026-10-03T12:00:00.000+0100"}}],"isLast":false,"nextPageToken":"t2"}"#))
        stub.respond(to: base + "&nextPageToken=t2", with: .json(#"{"issues":[{"key":"CP-2","fields":{"summary":"b","status":{"name":"To Do"},"issuetype":{"name":"Task"},"project":{"key":"CP"},"updated":"2026-10-02T12:00:00.000+0100"}}],"isLast":true}"#))
        let issues = try await client(stub).searchIssues(jql: "assignee = currentUser()")
        #expect(issues.map(\.key) == ["CP-1", "CP-2"])
        #expect(issues[1].status == "To Do" && issues[1].issueType == "Task")
    }

    @Test func listingsFollowTheNextLink() async throws {
        let stub = Stub()
        stub.respond(to: "\(Self.site)/wiki/api/v2/spaces?limit=250&sort=name", with: .json(#"{"results":[{"id":"11","key":"ENG","name":"Engineering","type":"global"}],"_links":{"next":"/wiki/api/v2/spaces?cursor=abc&limit=250&sort=name"}}"#))
        stub.respond(to: "\(Self.site)/wiki/api/v2/spaces?cursor=abc&limit=250&sort=name", with: .json(#"{"results":[{"id":"12","key":"OPS","name":"Operations","type":"personal"}],"_links":{}}"#))
        let spaces = try await client(stub).spaces()
        #expect(spaces.map(\.key) == ["ENG", "OPS"])
        #expect(spaces.map(\.isPersonal) == [false, true])
    }

    @Test func readsSpacesPagesAndAPageBody() async throws {
        let stub = Stub()
        stub.respond(to: "\(Self.site)/wiki/api/v2/spaces?limit=250&sort=name", with: .json(#"{"results":[{"id":"11","key":"ENG","name":"Engineering","type":"global"}]}"#))
        stub.respond(to: "\(Self.site)/wiki/api/v2/spaces/11/pages?depth=root&limit=250&sort=title", with: .json(#"{"results":[{"id":"100","title":"Release plan","spaceId":"11","version":{"number":7,"createdAt":"2026-10-03T12:00:00.000Z","authorId":"u1"},"_links":{"webui":"/spaces/ENG/pages/100/Release+plan"}}]}"#))
        stub.respond(to: "\(Self.site)/wiki/api/v2/pages/100/children?limit=250", with: .json(#"{"results":[{"id":"101","title":"Phase 1","spaceId":"11","parentId":"100","version":{"number":2}}]}"#))
        stub.respond(to: "\(Self.site)/wiki/api/v2/pages/100?body-format=atlas_doc_format", with: .json(#"{"id":"100","title":"Release plan","spaceId":"11","version":{"number":7,"createdAt":"2026-10-03T12:00:00.000Z"},"_links":{"webui":"/spaces/ENG/pages/100/Release+plan"},"body":{"atlas_doc_format":{"representation":"atlas_doc_format","value":"{\"type\":\"doc\",\"content\":[{\"type\":\"heading\",\"attrs\":{\"level\":1},\"content\":[{\"type\":\"text\",\"text\":\"Plan\"}]}]}"}}}"#))
        let client = client(stub)
        let spaces = try await client.spaces()
        #expect(spaces == [ConfluenceSpace(id: "11", key: "ENG", name: "Engineering")])
        let pages = try await client.pages(inSpace: "11")
        #expect(pages.first?.title == "Release plan" && pages.first?.version == 7 && pages.first?.body == nil)
        #expect(try await client.children(ofPage: "100").map(\.title) == ["Phase 1"])
        let page = try await client.page(id: "100")
        #expect(page.body == "# Plan\n")
        #expect(client.pageURL(page) == URL(string: "https://x.atlassian.net/wiki/spaces/ENG/pages/100/Release+plan"))
        #expect(client.browseURL(forIssue: "CP-7") == URL(string: "https://x.atlassian.net/browse/CP-7"))
        #expect(Set(stub.recorded.map { $0.httpMethod ?? "" }) == ["GET"])
    }
}
