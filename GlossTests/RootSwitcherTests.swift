import Core
import Foundation
import Testing
@testable import Gloss

struct RootSwitcherTests {
    private static let box = HostID(rawValue: "h_box")

    private func root(_ path: String, on hostID: HostID = .local, pinned: Bool = false) -> Root {
        Root(id: .new(), hostID: hostID, path: path, lastOpenedAt: Date(), pinned: pinned)
    }

    @Test func sectionsOrderOpenFavoritesRecentAndSkipOpenSpellings() {
        let tabs = [(id: RootID.new(), hostID: HostID.local, path: "/private/tmp/play")]
        let favorites = [root("/Users/c/app", pinned: true)]
        let recents = [root("/tmp/play")] + favorites + (0..<8).map { root("/Users/c/r\($0)") }
        let sections = SwitcherEntry.sections(tabs: tabs, favorites: favorites, recents: recents, query: "")
        #expect(sections.map(\.section) == [.open, .favorites, .recent])
        #expect(sections[0].entries.map(\.title) == ["play"])
        #expect(sections[1].entries.map(\.title) == ["app"])
        #expect(sections[2].entries.count == 6)
        #expect(!sections[2].entries.contains { $0.title == "play" || $0.title == "app" })
    }

    @Test func favoritesListEveryHostOnceAndMarkTheOpenOnes() throws {
        let app = root("/Users/c/app", pinned: true)
        let remote = root("/srv/api", on: Self.box, pinned: true)
        let tab = (id: RootID.new(), hostID: HostID.local, path: "/Users/c/app")
        let other = (id: RootID.new(), hostID: HostID.local, path: "/Users/c/scratch")
        // Local is picked: its recents only, while the favorite on box is listed too.
        let recents = [app, root("/Users/c/scratch"), root("/Users/c/old")]
        let sections = SwitcherEntry.sections(tabs: [tab, other], favorites: [remote, app], recents: recents, query: "")
        #expect(sections.map(\.section) == [.open, .favorites, .recent])
        #expect(sections[0].entries.map(\.title) == ["scratch"], "open, and not a favorite")
        let favorites = sections[1].entries
        #expect(favorites.map(\.title) == ["api", "app"], "by name, whichever host")
        #expect(favorites.map(\.hostID) == [Self.box, .local])
        let open = try #require(favorites.last)
        #expect(open.isOpen && open.id == tab.id && open.pinned, "the open favorite is the tab, listed once")
        #expect(!favorites[0].isOpen && favorites[0].id == remote.id)
        #expect(sections[2].entries.map(\.title) == ["old"], "Recent leaves out open folders and favorites")
        #expect(sections.flatMap(\.entries).filter { $0.path == "/Users/c/app" }.count == 1)
        #expect(SwitcherEntry.sections(tabs: [tab, other], favorites: [remote, app], recents: recents, query: "api").flatMap(\.entries).map(\.id) == [remote.id],
                "the filter applies to Favorites too")
    }

    @Test func filteringPrefersNamesThenPaths() {
        let recents = [root("/Users/c/docs/notes"), root("/Users/c/docs"), root("/Users/c/web")]
        let sections = SwitcherEntry.sections(tabs: [], favorites: [], recents: recents, query: "Docs")
        #expect(sections.flatMap(\.entries).map(\.title) == ["docs", "notes"])
        #expect(SwitcherEntry.sections(tabs: [], favorites: [], recents: recents, query: "zzz").isEmpty)
    }

    @Test @MainActor func aHostPickedInTheDropdownGoesWhereItShould() async {
        let box = HostID(rawValue: "h_box")
        #expect(HostMenu.pick(.local, kind: .local, status: .idle) == .show(.local))
        #expect(HostMenu.pick(.web, kind: .web, status: .idle) == .webPages)
        #expect(HostMenu.pick(.github, kind: .github, status: .idle) == .openPullRequest)
        #expect(HostMenu.pick(.atlassian, kind: .atlassian, status: .idle) == .openAtlassian)
        #expect(HostMenu.pick(box, kind: .ssh, status: .connected) == .show(box), "a connected host lists its folders")
        #expect(HostMenu.pick(box, kind: .ssh, status: .idle) == .connect(box))
        #expect(HostMenu.pick(box, kind: .ssh, status: .failed("refused")) == .connect(box), "picking it again retries")
        #expect(!HostMenu.Pick.show(.local).dismisses && HostMenu.Pick.webPages.dismisses && HostMenu.Pick.connect(box).dismisses)
        #expect(HostMenu.label(.local, name: "local") == "This Mac")
        #expect(HostMenu.label(box, name: "box") == "box")
        #expect(HostMenu.openTitle(.local, name: "this Mac") == "Open Folder on this Mac…")
        #expect(HostMenu.openTitle(.web, name: "web") == "Open Location…")
        #expect(HostMenu.symbol(box, status: .failed("x")) == "exclamationmark.triangle")

        let entries = [HostsModel.Entry(id: .local, name: "local", kind: .local, origin: .local), HostsModel.web,
                       HostsModel.Entry(id: box, name: "box", kind: .ssh)]
        #expect(HostMenu.matching(entries, query: "").count == 3)
        #expect(HostMenu.matching(entries, query: "mac").map(\.id) == [.local], "matched by what it is called")
        #expect(HostMenu.matching(entries, query: "BOX").map(\.id) == [box])

        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        model.browse(.webPages)
        #expect(model.pickedHost == .web)
        model.browse(.show(.local))
        #expect(model.pickedHost == .local)
        model.presentOpenFolder(on: box)
        #expect(model.remotePathPrompt?.hostID == box && model.remotePathPrompt?.hostName == "h_box")
        model.browse(.openPullRequest)
        #expect(model.pickedHost == .github && model.pullRequestPicker.isPresented)
        model.pullRequestPicker.dismiss()
        model.browse(.openAtlassian)
        #expect(model.pickedHost == .atlassian && model.atlassianPicker.isPresented)
        model.atlassianPicker.dismiss()
        // An unknown host connects to nothing; the explorer still shows it, so its status row can say so.
        model.browse(.connect(box))
        #expect(model.pickedHost == box)
        await model.shutDown()
    }

    @Test func theHighlightStartsWhereReturnShouldGo() {
        let here = SwitcherEntry(id: .new(), hostID: .local, path: "/a/github-notes", pinned: false, section: .open, isOpen: true)
        let other = SwitcherEntry(id: .new(), hostID: .local, path: "/a/b", pinned: false, section: .recent, isOpen: false)
        let items: [SwitcherItem] = [.host(.local), .host(.web), .host(.github), .folder(here), .folder(other)]
        #expect(SwitcherItem.start(in: items, query: "", selectedTabID: here.id, pickedHost: .local) == 3, "the folder in front")
        #expect(SwitcherItem.start(in: items, query: "", selectedTabID: nil, pickedHost: .web) == 1, "the host, when no folder of it is in front")
        #expect(SwitcherItem.start(in: items, query: "git", selectedTabID: here.id, pickedHost: .local) == 3, "a filter starts on a folder, not GitHub")
        #expect(SwitcherItem.start(in: [.host(.github)], query: "git", selectedTabID: nil, pickedHost: .local) == 0)
    }

    @Test @MainActor func theShownHostFollowsTheFolderInFront() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.explorer.openRoot(hostID: .local, path: base)
        let tab = try #require(model.explorer.selectedTab)
        model.browse(.webPages)
        #expect(model.pickedHost == .web)
        model.browse(.show(.local))
        #expect(model.pickedHost == .local && model.explorer.selectedTabID == tab.id)
        model.pickedHost = .web
        model.explorer.selectedTabID = nil
        model.explorer.selectedTabID = tab.id
        #expect(model.pickedHost == .local, "however the folder came to the front")
        await model.shutDown()
    }

    /// A favorite on a host that isn't connected connects first, its host picked meanwhile, instead of failing
    /// with "Not connected".
    @Test @MainActor func choosingAFavoriteOnAnotherHostConnectsThenOpens() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        // Nothing listens on port 1 of the loopback: ssh is refused at once.
        let host = try await model.noteStore.saveHost(id: nil, name: "gloss-test-refused", options: HostOptions(hostName: "127.0.0.1", port: 1))
        await model.hosts.refresh()
        let root = try await model.noteStore.recordRootOpened(hostID: host.id, path: "/srv/app")
        await model.explorer.setPinned(root.id, hostID: host.id, path: "/srv/app", true)
        #expect(model.explorer.favorites.map(\.id) == [root.id] && model.explorer.isPinned(hostID: host.id, path: "/srv/app"))
        #expect(model.pickedHost == .local)
        let entry = try #require(SwitcherEntry.sections(tabs: [], favorites: model.explorer.favorites, recents: [], query: "").first?.entries.first)
        model.explorer.lastError = nil
        await model.choose(entry)
        #expect(model.pickedHost == host.id)
        let tried = if case .failed = model.hosts.status(for: host.id) { true } else { false }
        #expect(tried, "it tried to connect")
        #expect(model.explorer.lastError == nil, "not “Not connected”")
        #expect(model.explorer.tabs.isEmpty)
        await model.shutDown()
    }

    @Test @MainActor func aFolderWaitingForAHostKeyIsTakenOnceByItsHost() throws {
        let explorer = ExplorerModel(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        explorer.pathAwaitingHostKey = (Self.box, "/srv/app")
        #expect(explorer.takePathAwaitingHostKey(.local) == nil, "another host's key opens its home, not this folder")
        #expect(explorer.takePathAwaitingHostKey(Self.box) == "/srv/app")
        #expect(explorer.takePathAwaitingHostKey(Self.box) == nil)
    }

    @Test @MainActor func closingAFolderStaysOnItsHost() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-close-\(UUID().uuidString)").path
        for name in ["a", "b", "c"] { try FileManager.default.createDirectory(atPath: "\(base)/\(name)", withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: base) }
        let explorer = ExplorerModel(noteStore: NoteStore(database: try AppDatabase.inMemory()))
        let local = LocalFileSystem(deleteBehavior: .permanent)
        explorer.fileSystemProvider = { _ in local }
        let box = HostID(rawValue: "h_box")
        await explorer.openRoot(hostID: .local, path: "\(base)/a")
        await explorer.openRoot(hostID: box, path: "\(base)/b")
        await explorer.openRoot(hostID: .local, path: "\(base)/c")
        var selections = 0
        explorer.onSelect = { selections += 1 }
        let a = try #require(explorer.tabs.first { $0.path.hasSuffix("/a") })
        explorer.selectedTabID = a.id
        #expect(selections == 1)
        explorer.closeTab(a.id)
        #expect(explorer.selectedTab?.path.hasSuffix("/c") == true, "the next folder on the same host, not the other host's")
        explorer.closeTab(try #require(explorer.selectedTabID))
        #expect(explorer.selectedTabID == nil, "none left on this host: nothing open here, rather than another host's folder")
        #expect(selections == 1, "a close changes no host")
        explorer.stopWatching()
    }

    @Test @MainActor func folderCommandsActOnlyOnTheFolderShown() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-shown-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.explorer.openRoot(hostID: .local, path: base)
        #expect(model.shownTab?.path == model.explorer.selectedTab?.path)
        model.browse(.webPages)
        #expect(model.explorer.selectedTab != nil && model.shownTab == nil, "hidden under Web")
        model.explorer.contentSearch.query = "anything"
        model.runContentSearch()
        #expect(!model.explorer.contentSearch.isSearching && model.explorer.contentSearch.searchedPattern == nil, "Find in Files leaves the hidden folder alone")
        await model.shutDown()
    }

    /// A host that won't connect is passed over on launch, and the folder in front shows with its own host.
    @Test @MainActor func restoringPastAHostThatWontConnectShowsTheFolderInFront() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-restore-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        // Nothing listens on port 1 of the loopback: ssh is refused at once.
        let host = try await model.noteStore.saveHost(id: nil, name: "gloss-test-refused", options: HostOptions(hostName: "127.0.0.1", port: 1))
        await model.hosts.refresh()
        var workspace = Workspace()
        workspace.folders = [.init(host: HostID.local.rawValue, path: base), .init(host: host.id.rawValue, path: "/srv/app")]
        workspace.selectedFolder = 0
        await model.restore(workspace)
        #expect(model.explorer.tabs.map(\.hostID) == [.local])
        #expect(model.pickedHost == .local && model.shownTab?.path == base)
        await model.shutDown()
    }
}

