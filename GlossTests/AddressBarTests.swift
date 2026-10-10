import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

/// The window title's address field, the explorer's Web section, and Open Quickly's address and page rows.
@MainActor
struct AddressBarTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting", sourceLocation: sourceLocation)
    }

    @Test func typedTextIsAnAddressAPathOrNeither() {
        let parse = { AddressInput.parse($0, home: "/Users/me") }
        #expect(parse("example.com") == .web(URL(string: "https://example.com")!))
        #expect(parse("localhost:3000/app") == .web(URL(string: "http://localhost:3000/app")!))
        #expect(parse("localhost") == .web(URL(string: "http://localhost")!))
        #expect(parse("devbox:8080") == .web(URL(string: "http://devbox:8080")!), "a port makes a bare name an address")
        #expect(parse("[::1]:5173") == .web(URL(string: "http://[::1]:5173")!))
        #expect(parse("https://intranet/wiki") == .web(URL(string: "https://intranet/wiki")!), "a scheme makes anything an address")
        #expect(parse("  /Users/me/project/README.md ") == .path("/Users/me/project/README.md"))
        #expect(parse("~/notes.md") == .path("/Users/me/notes.md"))
        #expect(parse("~") == .path("/Users/me"))
        #expect(parse("/") == .path("/"))
        #expect(AddressInput.parse("~/x", home: nil) == nil, "a remote home not known yet")

        for junk in ["", "   ", "notes", "src/main", "hello world", "example.com/a b", "mailto:me@example.com", "ftp://example.com/", "example..com", "example.", "~me/x",
                     "README.md", "package.json", "AppModel.swift", "qom.s"] {
            #expect(parse(junk) == nil, "\(junk) is neither")
        }
    }

    @Test func fileNamesAreNotWebsites() {
        let address = AddressInput.webURL(from:)
        for name in ["README.md", "package.json", "AppModel.swift", "qom.s", "index.html", "notes.txt"] {
            #expect(address(name) == nil, "\(name) is a file name first")
            #expect(AddressInput.possibleWebURL(from: name) != nil, "\(name) is still offered below the files")
        }
        #expect(address("example.com") != nil && address("example.dev") != nil && address("intranet.corp") != nil)
        #expect(address("docs.example.app") != nil, "a common domain wins over the extension of the same name")
        #expect(address("readme.md/x") != nil, "a path after the host says it is an address")
        #expect(address("index.html:8080") != nil, "so does a port")
        #expect(address("192.168.0.4") != nil)

        // Beside an open document, a file name is a file in its folder.
        let beside = { AddressInput.parse($0, home: "/Users/me", folder: "/Users/me/project") }
        #expect(beside("README.md") == .path("/Users/me/project/README.md"))
        #expect(beside("src/main.swift") == .path("/Users/me/project/src/main.swift"))
        #expect(beside("example.com") == .web(URL(string: "https://example.com")!))
        #expect(beside("notes") == nil, "a bare word is still neither")
        // Documents are keyed by path: `..` and `.` are worked out, so the file isn't opened as a second document.
        #expect(beside("../shared/README.md") == .path("/Users/me/shared/README.md"))
        #expect(beside("./docs//plan.md") == .path("/Users/me/project/docs/plan.md"))
        #expect(AddressInput.parse("/Users/me/project/./a/../b.md", home: nil) == .path("/Users/me/project/b.md"))
        #expect(AddressInput.parse("~/x/../y.md", home: "/Users/me") == .path("/Users/me/y.md"))
        #expect(AddressInput.parse("file:///Users/me/notes%20draft.md", home: nil) == .path("/Users/me/notes draft.md"), "a file link is its path")
        #expect(AddressInput.parse("FILE://localhost/Users/me/src/", home: nil) == .path("/Users/me/src"))
        #expect(AddressInput.parse("file://otherbox/Users/me/a.md", home: nil) == nil, "a file link to another machine is not a path here")
    }

    @Test func outsidePagesAreNotSentThroughTheDocumentsHost() async {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        let box = HostID(rawValue: "h_box")
        #expect(model.via(for: URL(string: "https://example.com/")!, on: box, chosen: false) == nil, "the open web's, whatever document is in front")
        #expect(model.via(for: URL(string: "http://localhost:3000/")!, on: box, chosen: false) == box, "the loopback beside the files")
        #expect(model.via(for: URL(string: "https://example.com/")!, on: box, chosen: true) == box, "picked in the field's menu")
        #expect(model.via(for: URL(string: "http://localhost:3000/")!, on: .local, chosen: true) == nil)
        await model.shutDown()
    }

    @Test func showingAPageAgainIsNotAVisit() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        model.openWebPage(URL(string: "https://example.com/a")!)
        try await Task.sleep(for: .milliseconds(20))
        model.openWebPage(URL(string: "https://example.com/b")!)
        await waitUntil { model.webPages.pages.map(\.url) == ["https://example.com/b", "https://example.com/a"] }
        model.openWebPage(URL(string: "https://example.com/a")!)
        #expect(model.activeSession?.path == "https://example.com/a")
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.webPages.pages.map(\.url) == ["https://example.com/b", "https://example.com/a"], "Recent does not reorder under the cursor")
        await model.shutDown()
    }

    @Test func theWebEntryIsAlwaysAHost() async {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        #expect(model.hosts.entries.map(\.id).prefix(2) == [.local, .web], "listed after this Mac before anything loads")
        await model.hosts.refresh()
        #expect(model.hosts.entries.map(\.id).prefix(2) == [.local, .web])
        #expect(model.hosts.entry(for: .web)?.kind == .web)
        #expect(HostMenu.label(.web, name: "web") == "Web")
        await model.shutDown()
    }

    @Test func visitedPagesAreRecordedWithTheirHost() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        model.openWebPage(URL(string: "https://example.com/docs#intro")!)
        await waitUntil { model.webPages.pages.contains { $0.url == "https://example.com/docs" && $0.hostID == .web } }
        model.webPages.setTitle("Docs", url: "https://example.com/docs", hostID: .web)
        await waitUntil { model.webPages.pages.first?.title == "Docs" }
        let page = try #require(model.webPages.pages.first)
        model.webPages.setPinned(page, true)
        await waitUntil { model.webPages.pinned.count == 1 }
        model.webPages.remove(page)
        await waitUntil { model.webPages.pages.isEmpty }
        await model.shutDown()
    }

    @Test func pagesMatchByTitleOrAddress() {
        let at = Date(timeIntervalSince1970: 10)
        let pages = [
            WebPage(url: "https://example.com/docs", hostID: .web, title: "Reference", lastVisitedAt: at),
            WebPage(url: "http://localhost:3000/", hostID: .web, title: nil, lastVisitedAt: at.addingTimeInterval(5)),
        ]
        #expect(WebPagesModel.matching("", in: pages).map(\.url) == ["http://localhost:3000/", "https://example.com/docs"], "newest first")
        #expect(WebPagesModel.matching("refer", in: pages).map(\.url) == ["https://example.com/docs"])
        #expect(WebPagesModel.matching("lh3000", in: pages).map(\.url) == ["http://localhost:3000/"])
        #expect(WebPagesSection.filtered(pages, by: "EXAMPLE").map(\.url) == ["https://example.com/docs"])
        #expect(WebPagesSection.filtered(pages, by: " ").count == 2)
    }

    @Test func openQuicklyOffersTheAddressAndVisitedPagesWithoutAFolder() async {
        let quick = QuickOpenModel()
        let visited = WebPage(url: "https://example.com/guide", hostID: .web, title: "Guide", lastVisitedAt: Date())
        quick.pages = { [visited] }
        var opened: [String] = []
        quick.onOpenAddress = { opened.append("address " + $0.absoluteString) }
        quick.onOpenPage = { opened.append("page " + $0.url) }
        quick.present(root: nil, hostID: .local, connection: nil)
        #expect(quick.isPresented && !quick.isLoading)
        #expect(quick.rows == [.page(visited)], "no folder: the pages visited, no files")

        quick.query = "localhost:5173"
        #expect(quick.rows.first == .address(URL(string: "http://localhost:5173")!))
        quick.submit()
        #expect(opened == ["address http://localhost:5173"], "Return opens the address without waiting for a file listing")

        quick.present(root: nil, hostID: .local, connection: nil)
        quick.query = "guide"
        #expect(quick.rows == [.page(visited)])
        quick.query = "example.com/guide"
        #expect(quick.rows.count == 2 && quick.rows.first == .address(URL(string: "https://example.com/guide")!))
        quick.moveSelection(by: 1)
        quick.moveSelection(by: 5)
        #expect(quick.selectedIndex == 1, "arrows stop at the last row")
        quick.submit()
        #expect(opened.last == "page https://example.com/guide")
        #expect(!quick.isPresented)
    }

    @Test func aFileNameQueryKeepsFilesFirst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-quick-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("README.md"))
        let quick = QuickOpenModel()
        var opened: [String] = []
        quick.onOpen = { opened.append($1) }
        quick.onOpenAddress = { opened.append($0.absoluteString) }
        quick.pages = { [WebPage(url: "https://zebra.example/", hostID: .web, title: "Zebra", lastVisitedAt: Date())] }
        quick.present(root: root.path, hostID: .local, connection: nil)
        quick.query = "README.md"
        // Return before the listing is in: it waits for the file rather than opening https://README.md.
        quick.submit()
        await waitUntil { !opened.isEmpty }
        #expect(opened == [root.path + "/README.md"])

        quick.present(root: root.path, hostID: .local, connection: nil)
        quick.query = "README.md"
        await waitUntil { !quick.isLoading && !quick.isRanking && quick.results == ["README.md"] }
        #expect(quick.rows == [.file("README.md"), .address(URL(string: "https://README.md")!)], "the address trails, unselected")
        #expect(quick.selectedIndex == 0)
        quick.dismiss()
    }

    @Test func openQuicklyListsPagesAboveFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-quick-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("guide.md"))
        let quick = QuickOpenModel()
        let visited = WebPage(url: "https://example.com/guide", hostID: .web, title: "Guide", lastVisitedAt: Date())
        quick.pages = { [visited] }
        quick.present(root: root.path, hostID: .local, connection: nil)
        quick.query = "guide"
        await waitUntil { !quick.isLoading && !quick.isRanking && quick.results == ["guide.md"] }
        #expect(quick.rows == [.page(visited), .file("guide.md")])
        #expect(QuickOpenSheet.header(before: 0, in: quick.rows) == "Web Pages")
        #expect(QuickOpenSheet.header(before: 1, in: quick.rows) == "Files")
        #expect(QuickOpenSheet.countLine(files: 1, pages: 1) == "1 file · 1 page")
        #expect(QuickOpenSheet.countLine(files: 3, pages: 0) == "3 files")
        #expect(QuickOpenSheet.countLine(files: nil, pages: 2) == "2 pages")
        #expect(QuickOpenSheet.countLine(files: 50, of: 3_214, pages: 0) == "50 of \(3_214.formatted()) files", "only the best of more are listed")
        #expect(QuickOpenSheet.countLine(files: 50, of: 50_000, more: true, pages: 0) == "50 of \(50_000.formatted())+ files", "a listing cut at its limit says so")
        #expect(QuickOpenSheet.countLine(files: 3, of: 3, pages: 0) == "3 files")
        quick.moveSelection(by: 1)
        #expect(quick.selectedPath == root.path + "/guide.md")
        quick.dismiss()
    }

    @Test func theAddressFieldStartsWithWhatIsShown() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        #expect(TitleAddressBar.address(of: nil, model: model) == "")
        model.openWebPage(URL(string: "https://example.com/a?b=1")!)
        #expect(TitleAddressBar.address(of: model.activeSession, model: model) == "https://example.com/a?b=1")
        #expect(model.addressHost == .local, "a page on the open web is opened from this Mac")
        #expect(!model.openAddress("not an address", on: .local))
        await model.shutDown()
    }

    /// A location typed as `path:line` opens its file at the line; a file really named with `:30` opens as itself.
    @Test func aTypedLocationOpensAtItsLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-address-line-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try (1...20).map { "line \($0)" }.joined(separator: "\n").write(toFile: "\(root)/a.swift", atomically: true, encoding: .utf8)
        try "x".write(toFile: "\(root)/notes 10:30", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        #expect(model.openAddress("\(root)/a.swift:12", on: .local))
        await waitUntil { model.session(hostID: .local, path: "\(root)/a.swift")?.textController?.pendingScroll != nil }
        let controller = try #require(model.session(hostID: .local, path: "\(root)/a.swift")?.textController)
        #expect(controller.pendingScroll == controller.lineIndex.contentRange(ofLine: 12))
        #expect(model.openAddress("\(root)/notes 10:30", on: .local))
        await waitUntil { model.session(hostID: .local, path: "\(root)/notes 10:30") != nil }
        #expect(model.session(hostID: .local, path: "\(root)/notes 10:30") != nil, "a file named so opens as itself")
        await model.shutDown()
    }

    /// `open_in_viewer` given `path:line` with no line of its own opens the file at that line, as the address field does.
    @Test func anAgentsLocationOpensAtItsLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-agent-line-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try (1...20).map { "line \($0)" }.joined(separator: "\n").write(toFile: "\(root)/a.swift", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        await model.showForAgent(hostID: .local, path: "\(root)/a.swift:7", line: nil, endLine: nil)
        await waitUntil { model.session(hostID: .local, path: "\(root)/a.swift")?.textController?.pendingScroll != nil }
        let controller = try #require(model.session(hostID: .local, path: "\(root)/a.swift")?.textController)
        #expect(controller.pendingScroll == controller.lineIndex.contentRange(ofLine: 7))
        #expect(model.session(hostID: .local, path: "\(root)/a.swift:7") == nil, "no tab for a file that does not exist")
        await model.shutDown()
    }

    /// A Markdown link to a heading in another file (`guide.md#set-up`) opens the file with that heading at the top.
    @Test func aLinkToAnotherFilesHeadingShowsTheHeading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-anchor-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let guide = "# Guide\n\n" + (1...40).map { "Line \($0).\n" }.joined(separator: "\n") + "\n## Set up\n\nSteps.\n"
        try guide.write(toFile: "\(root)/guide.md", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: "\(root)/guide.md", heading: "set-up")
        // Opening asks for a scroll of its own (where reading stopped); the heading's comes once the file is loaded.
        func atHeading() -> Bool {
            guard let markdown = model.session(hostID: .local, path: "\(root)/guide.md")?.markdown, let scroll = markdown.pendingRenderedScroll else { return false }
            return NSIntersectionRange(scroll, (markdown.rendered.string as NSString).range(of: "Set up")).length > 0
        }
        await waitUntil { atHeading() }
        #expect(atHeading())
        #expect(model.session(hostID: .local, path: "\(root)/guide.md")?.markdown?.pendingRenderedScrollAtTop == true)
        await model.shutDown()
    }

    /// A Markdown link to a folder (`[docs](docs/)`) opens the folder in the explorer, not a tab that can't show it.
    @Test func aLinkToAFolderOpensItInTheExplorer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-link-folder-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(root)/docs", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: "\(root)/docs", heading: nil)
        await waitUntil { model.explorer.selectedTab?.path == "\(root)/docs" }
        #expect(model.session(hostID: .local, path: "\(root)/docs") == nil, "no document tab for a folder")
        await model.shutDown()
    }

    /// A page's link to a folder opens the folder's index page, as a web server serves `about/`; a folder without one
    /// opens in the explorer.
    @Test func aPagesLinkToAFolderOpensItsIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-page-folder-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(root)/about", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/assets", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "<h1>About</h1>".write(toFile: "\(root)/about/index.html", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        #expect(await model.linkedPage(hostID: .local, path: "\(root)/about") == "\(root)/about/index.html")
        #expect(await model.linkedPage(hostID: .local, path: "\(root)/about/index.html") == "\(root)/about/index.html", "a file is itself")
        #expect(await model.linkedPage(hostID: .local, path: "\(root)/assets") == nil)
        #expect(model.explorer.selectedTab?.path == "\(root)/assets", "a folder without an index opens in the explorer")
        await model.shutDown()
    }

    /// A page's link to an anchor on another page (`guide.html#install`) opens that page at the anchor.
    @Test func aPagesLinkToAnotherPagesAnchorCarriesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-page-anchor-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "<a href=\"guide.html#install\">Install</a>".write(toFile: "\(root)/index.html", atomically: true, encoding: .utf8)
        try "<h1>Guide</h1><h2 id=\"install\">Install</h2>".write(toFile: "\(root)/guide.html", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: "\(root)/index.html")
        await waitUntil { model.activeSession?.html != nil }
        model.browser.onOpenFile(.local, "\(root)/guide.html", "install", model.activeSession?.html)
        await waitUntil { model.session(hostID: .local, path: "\(root)/guide.html")?.html != nil }
        #expect(model.session(hostID: .local, path: "\(root)/guide.html")?.html?.pendingFragment == "install", "the page's first load scrolls to the anchor")
        await model.shutDown()
    }

    /// The explorer's Web section filters by title or address, case and accents aside.
    @Test func webPagesFilterByTitleOrAddress() {
        let at = Date()
        let pages = [WebPage(url: "https://example.com/docs", hostID: .web, title: "Référence", lastVisitedAt: at),
                     WebPage(url: "http://localhost:3000/", hostID: .web, title: nil, lastVisitedAt: at)]
        #expect(WebPagesSection.filtered(pages, by: " reference ").map(\.url) == ["https://example.com/docs"])
        #expect(WebPagesSection.filtered(pages, by: "LOCALHOST").map(\.url) == ["http://localhost:3000/"])
        #expect(WebPagesSection.filtered(pages, by: "").count == 2)
    }
}
