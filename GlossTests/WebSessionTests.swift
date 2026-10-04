import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

@MainActor
struct WebSessionTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting", sourceLocation: sourceLocation)
    }

    @Test func openWebPageKeysSessionsByNormalisedURLAndHost() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        model.openWebPage(URL(string: "HTTPS://Example.com:443/docs/#top")!)
        let session = try #require(model.activeSession)
        #expect(session.hostID == .web)
        #expect(session.path == "https://example.com/docs/")
        #expect(session.kind == .web)
        #expect(session.fileName == "example.com/docs")
        await waitUntil { session.isLoaded }
        #expect(session.isReadOnly)
        #expect(session.html?.page == .live(URL(string: "https://example.com/docs/")!))

        // The same page with a different fragment is the same document; a different query is another.
        model.openWebPage(URL(string: "https://example.com/docs/#bottom")!)
        #expect(model.activeSession === session)
        model.openWebPage(URL(string: "https://example.com/docs/?v=2")!)
        #expect(model.activeSession !== session)
        #expect(model.sessions.count == 2)

        // Opening a URL through the ordinary document path lands on the web host too.
        model.openDocument(hostID: .local, path: "http://localhost:3000/app")
        #expect(model.activeSession?.hostID == .web)
        #expect(model.activeSession?.path == "http://localhost:3000/app")
        #expect(model.activeSession?.webURL == URL(string: "http://localhost:3000/app"))
        await model.shutDown()
    }

    @Test func webDocumentsAreNotRevealedInTheExplorer() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        model.openWebPage(URL(string: "https://example.com/")!)
        model.revealActiveDocumentInExplorer()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.explorer.tabs.isEmpty, "a page has no folder to open as a root")
        await model.shutDown()
    }

    @Test func addressesBecomeURLs() {
        let url = OpenLocationSheet.url(from:)
        #expect(url("localhost:3000") == URL(string: "http://localhost:3000"))
        #expect(url("127.0.0.1:5173/app") == URL(string: "http://127.0.0.1:5173/app"))
        #expect(url("example.com/docs") == URL(string: "https://example.com/docs"))
        #expect(url("192.168.1.5:3000") == URL(string: "http://192.168.1.5:3000"), "a box on the LAN rarely has a certificate")
        #expect(url("10.0.0.2/app") == URL(string: "http://10.0.0.2/app"))
        #expect(url("[::1]:8080") == URL(string: "http://[::1]:8080"))
        #expect(url("devbox.local:8080") == URL(string: "http://devbox.local:8080"), "an explicit port is a dev server")
        #expect(url("https://example.com/") == URL(string: "https://example.com/"))
        #expect(url("  HTTP://Example.com  ") == URL(string: "HTTP://Example.com"))
        #expect(url("") == nil)
        #expect(url("not a url") == nil)
        #expect(url("ftp://example.com/") == nil)
    }

    @Test func documentDisplayNames() {
        #expect(Core.Document.displayName(of: "/a/b/c.md") == "c.md")
        #expect(Core.Document.displayName(of: "https://example.com/") == "example.com")
        #expect(Core.Document.displayName(of: "http://localhost:3000/dashboard?tab=2") == "localhost:3000/dashboard?tab=2")
    }
}
