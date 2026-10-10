import Core
import Foundation
import Testing
@testable import Gloss

struct URLRouterTests {
    let hosts: [String: HostID] = ["asus": HostID(rawValue: "h_01ARZ3NDEKTSV4RRFFQ69G5FAV")]

    @Test func parsesOpen() {
        let route = URLRouter.parse(URL(string: "gloss://open?host=local&path=/Users/colin/proj/a.md")!, hosts: hosts)
        #expect(route == .open(hostID: .local, path: "/Users/colin/proj/a.md"))
        let remote = URLRouter.parse(URL(string: "gloss://open?host=asus&path=/home/colin/x.md")!, hosts: hosts)
        #expect(remote == .open(hostID: hosts["asus"]!, path: "/home/colin/x.md"))
        #expect(URLRouter.parse(URL(string: "gloss://open?path=relative")!, hosts: hosts) == nil)
        #expect(URLRouter.parse(URL(string: "gloss://open?path=/a/b.swift&line=42")!, hosts: hosts) == .open(hostID: .local, path: "/a/b.swift", line: 42))
        #expect(URLRouter.parse(URL(string: "gloss://open?path=/a/b.swift&line=0")!, hosts: hosts) == .open(hostID: .local, path: "/a/b.swift"), "line numbers are 1-based")
        #expect(URLRouter.parse(URL(string: "https://example.com/open?path=/x")!, hosts: hosts) == nil)
    }

    @Test func parsesNote() {
        let route = URLRouter.parse(URL(string: "gloss://note?host=local&path=/p/a.md&line=12&text=Fix%20this")!, hosts: hosts)
        #expect(route == .note(hostID: .local, path: "/p/a.md", cwd: nil, line: 12, text: "Fix this", file: nil))
        let selection = URLRouter.parse(URL(string: "gloss://note?cwd=/p&file=/tmp/sel.txt")!, hosts: hosts)
        #expect(selection == .note(hostID: .local, path: nil, cwd: "/p", line: nil, text: "", file: "/tmp/sel.txt"))
        #expect(URLRouter.parse(URL(string: "gloss://note?path=/p/a.md")!, hosts: hosts) == nil, "a note needs text or a file")
        #expect(URLRouter.parse(URL(string: "gloss://note?path=/p/a.md&text=x&color=Blue")!, hosts: hosts)
                == .note(hostID: .local, path: "/p/a.md", cwd: nil, line: nil, text: "x", file: nil, color: .blue), "colour names ignore case")
        #expect(URLRouter.parse(URL(string: "gloss://note?path=/p/a.md&text=x&color=teal")!, hosts: hosts)
                == .note(hostID: .local, path: "/p/a.md", cwd: nil, line: nil, text: "x", file: nil), "an unknown colour falls back to the default")
    }

    /// Notes are keyed by path: a link spelling it with `./` or `../` opens the same document, not a second one.
    @Test func pathsAreNormalized() {
        #expect(URLRouter.parse(URL(string: "gloss://open?path=/p/./docs/../a.md")!, hosts: hosts) == .open(hostID: .local, path: "/p/a.md"))
        #expect(URLRouter.parse(URL(string: "gloss://note?cwd=/p//sub/..&text=x")!, hosts: hosts)
                == .note(hostID: .local, path: nil, cwd: "/p", line: nil, text: "x", file: nil))
    }

    @Test func linksThatCreateNotesMustCarryTheUsersToken() {
        let token = "ab" + String(repeating: "c", count: 62)
        #expect(URLRouter.carriesToken(URL(string: "gloss://note?text=x&token=\(token)")!, expected: token))
        #expect(!URLRouter.carriesToken(URL(string: "gloss://note?text=x")!, expected: token), "a web page cannot know it")
        #expect(!URLRouter.carriesToken(URL(string: "gloss://note?text=x&token=abc")!, expected: token))
        #expect(!URLRouter.carriesToken(URL(string: "gloss://note?text=x&token=\(token)")!, expected: nil))
    }
}


/// A gloss://open link (the Herdr plugin's, on this Mac) shows a location as open_in_viewer does.
@MainActor
struct URLOpenTests {
    @Test func aLinkToAFolderOpensItInTheExplorer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-link-open-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(root)/docs", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        await URLRouter.open(hostID: .local, path: "\(root)/docs", line: nil, model: model)
        #expect(model.explorer.selectedTab?.path == "\(root)/docs")
        #expect(model.session(hostID: .local, path: "\(root)/docs") == nil, "no tab trying to read a folder")
        await model.shutDown()
    }
}
