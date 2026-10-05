import Core
import Foundation
import Testing
@testable import Integrations

/// Issue #2: images and PDFs attached to Jira issues and Confluence pages are files beside them, shown inline in
/// their Markdown and opened in the image and PDF viewers for region notes. Still GET only.
@Suite(.serialized)
struct AtlassianAttachmentTests {
    static let site = "https://x.atlassian.net"
    static let fields = "summary,issuetype,status,priority,assignee,reporter,labels,parent,created,updated,description,comment,project,attachment"
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

    /// CP-7 with a pasted screenshot in its description, a log file, a PDF, and two files of the same name.
    static let issueJSON = #"""
    {"id":"10001","key":"CP-7","fields":{"summary":"Fix the chart","issuetype":{"name":"Bug"},"status":{"name":"Open"},"project":{"key":"CP"},
    "created":"2026-10-01T09:00:00.000+0100","updated":"2026-10-03T12:00:00.000+0100",
    "description":{"type":"doc","version":1,"content":[
      {"type":"paragraph","content":[{"type":"text","text":"The legend overlaps:"}]},
      {"type":"mediaSingle","content":[{"type":"media","attrs":{"id":"7c1e-uuid","type":"file","collection":"","alt":"chart (1).png"}}]},
      {"type":"mediaSingle","content":[{"type":"media","attrs":{"id":"9a9a-uuid","type":"file","collection":""}}]}]},
    "comment":{"comments":[]},
    "attachment":[
      {"id":"501","filename":"chart (1).png","mimeType":"image/png","size":9},
      {"id":"502","filename":"server.log","mimeType":"text/plain","size":20},
      {"id":"503","filename":"spec.pdf","mimeType":"application/pdf","size":30},
      {"id":"504","filename":"shot.png","mimeType":"image/png","size":9},
      {"id":"505","filename":"shot.png","mimeType":"image/png","size":9}]}}
    """#

    func provider(_ stub: Stub) -> AtlassianFileSystem {
        AtlassianFileSystem(client: AtlassianClient(site: URL(string: Self.site)!, email: "c@x.com", token: "t", session: stub.session()))
    }

    @Test func pathsForAttachments() {
        #expect(AtlassianPath("/jira/CP/CP-7 attachments") == .jiraAttachments(project: "CP", key: "CP-7"))
        #expect(AtlassianPath("/jira/CP/CP-7 attachments/chart (1).png") == .jiraAttachment(project: "CP", key: "CP-7", name: "chart (1).png"))
        #expect(AtlassianPath("/jira/CP/XX-7 attachments/a.png") == nil, "the key must be the project's")
        #expect(AtlassianPath("/confluence/ENG/100/101/attachments") == .confluenceAttachments(space: "ENG", id: "101", ancestors: ["100"]))
        #expect(AtlassianPath("/confluence/ENG/100/attachments/notes.md") == .confluenceAttachment(space: "ENG", id: "100", name: "notes.md"), "an attachment, not a page, whatever its name")
        for path in ["/jira/CP/CP-7 attachments/x.png", "/confluence/ENG/100/101/attachments/a b.png", "/confluence/ENG/100/attachments"] {
            #expect(AtlassianPath(path)?.path == path)
        }
    }

    @Test func anIssueListsReadsAndShowsItsImages() async throws {
        let stub = Stub()
        stub.respond(to: "\(Self.site)/rest/api/3/issue/CP-7?fields=\(Self.fields)", with: .json(Self.issueJSON))
        stub.respond(to: "\(Self.site)/rest/api/3/attachment/content/501?redirect=false", with: .init(headers: ["Content-Type": "image/png"], body: Self.png))
        let fs = provider(stub)
        let text = String(decoding: try await fs.read("/jira/CP/CP-7.md"), as: UTF8.self)
        #expect(text.contains("![chart (1).png](CP-7%20attachments/chart%20%281%29.png)"), "the pasted image, matched by its file name: \(text)")
        #expect(text.contains("\\[image: 9a9a-uuid\\]"), "a media node with no name stays named")
        #expect(text.contains("## Attachments") && text.contains("- [spec.pdf](CP-7%20attachments/spec.pdf)"))
        #expect(!text.contains("server.log"), "only what a viewer can show")
        #expect(text.contains("![shot.png](CP-7%20attachments/shot.png)") && text.contains("![shot.png](CP-7%20attachments/shot%20%282%29.png)"), "two files of one name link to each of them")

        let names = try await fs.list("/jira/CP/CP-7 attachments").map(\.name)
        #expect(names == ["chart (1).png", "shot (2).png", "shot.png", "spec.pdf"])
        #expect(try await fs.stat("/jira/CP/CP-7 attachments/spec.pdf").kind == .file)
        #expect(try await fs.read("/jira/CP/CP-7 attachments/chart (1).png") == Self.png)
        _ = try await fs.read("/jira/CP/CP-7 attachments/chart (1).png")
        #expect(stub.recorded.filter { $0.url?.path.contains("attachment/content") == true }.count == 1, "bytes are kept: an attachment never changes")
        await #expect(throws: FileSystemError.self) { _ = try await fs.read("/jira/CP/CP-7 attachments/server.log") }
        #expect(await fs.resource(for: "/jira/CP/CP-7 attachments/chart (1).png") == PacketResource(url: URL(string: "https://x.atlassian.net/browse/CP-7")!, details: ["Attachment: chart (1).png"]))
        #expect(Set(stub.recorded.map { $0.httpMethod ?? "" }) == ["GET"])
    }

    @Test func aPageShowsItsImagesByFileID() async throws {
        let stub = Stub()
        let adf = #"{"type":"doc","content":[{"type":"mediaSingle","content":[{"type":"media","attrs":{"id":"file-abc","type":"file","collection":"contentId-100"}}]}]}"#
        let page: [String: Any] = ["id": "100", "title": "Plan", "spaceId": "11", "version": ["number": 3], "body": ["atlas_doc_format": ["value": adf]]]
        stub.respond(to: "\(Self.site)/wiki/api/v2/pages/100?body-format=atlas_doc_format", with: .json(String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self)))
        stub.respond(to: "\(Self.site)/wiki/api/v2/pages/100/attachments?limit=250", with: .json(#"{"results":[{"id":"att9","title":"diagram.png","mediaType":"image/png","fileSize":9,"fileId":"file-abc","downloadLink":"/download/attachments/100/diagram.png?version=1&api=v2"}]}"#))
        stub.respond(to: "\(Self.site)/wiki/download/attachments/100/diagram.png?version=1&api=v2", with: .init(headers: ["Content-Type": "image/png"], body: Self.png))
        let fs = provider(stub)
        let text = String(decoding: try await fs.read("/confluence/ENG/100/Plan.md"), as: UTF8.self)
        #expect(text.contains("![attachment](attachments/diagram.png)"), "\(text)")
        #expect(try await fs.list("/confluence/ENG/100/attachments").map(\.name) == ["diagram.png"])
        #expect(try await fs.read("/confluence/ENG/100/attachments/diagram.png") == Self.png)
    }

    /// A redirect to another host (an attachment's media host) is followed without the user's key.
    @Test func theKeyStaysOnItsOwnHost() async {
        let session = URLSession(configuration: .ephemeral)
        var original = URLRequest(url: URL(string: "https://x.atlassian.net/wiki/download/a.png")!)
        original.setValue("Basic abc", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var away = URLRequest(url: URL(string: "https://api.media.atlassian.com/file/x/binary?token=t")!)
        away.setValue("Basic abc", forHTTPHeaderField: "Authorization")
        let followed = await KeyStaysHome().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: away)
        #expect(followed?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!KeyStaysHome.sameOrigin(URL(string: "https://x.atlassian.net/a"), URL(string: "http://x.atlassian.net/a")), "never in the clear")
        #expect(!KeyStaysHome.sameOrigin(URL(string: "https://x.atlassian.net/a"), URL(string: "https://x.atlassian.net:8443/a")))
        #expect(KeyStaysHome.sameOrigin(URL(string: "https://x.atlassian.net/a"), URL(string: "https://X.atlassian.net:443/b")))
        var home = URLRequest(url: URL(string: "https://x.atlassian.net/wiki/other")!)
        home.setValue("Basic abc", forHTTPHeaderField: "Authorization")
        let stayed = await KeyStaysHome().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: home)
        #expect(stayed?.value(forHTTPHeaderField: "Authorization") == "Basic abc")
        task.cancel()
    }
}
