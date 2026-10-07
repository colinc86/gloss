import Core
import Foundation
import Testing
@testable import Gloss

struct RootSwitcherTests {
    private func root(_ path: String, pinned: Bool = false) -> Root {
        Root(id: .new(), hostID: .local, path: path, lastOpenedAt: Date(), pinned: pinned)
    }

    @Test func sectionsOrderOpenFavoritesRecentAndSkipOpenSpellings() {
        let tabs = [(id: RootID.new(), hostID: HostID.local, path: "/private/tmp/play", pinned: false)]
        let recents = [root("/tmp/play"), root("/Users/c/app", pinned: true)] + (0..<8).map { root("/Users/c/r\($0)") }
        let sections = SwitcherEntry.sections(tabs: tabs, recents: recents, query: "")
        #expect(sections.map(\.section) == [.open, .favorites, .recent])
        #expect(sections[0].entries.map(\.title) == ["play"])
        #expect(sections[1].entries.map(\.title) == ["app"])
        #expect(sections[2].entries.count == 6)
    }

    @Test func filteringPrefersNamesThenPaths() {
        let recents = [root("/Users/c/docs/notes"), root("/Users/c/docs"), root("/Users/c/web")]
        let sections = SwitcherEntry.sections(tabs: [], recents: recents, query: "Docs")
        #expect(sections.flatMap(\.entries).map(\.title) == ["docs", "notes"])
        #expect(SwitcherEntry.sections(tabs: [], recents: recents, query: "zzz").isEmpty)
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
        let here = SwitcherEntry(id: .new(), hostID: .local, path: "/a/github-notes", pinned: false, section: .open)
        let other = SwitcherEntry(id: .new(), hostID: .local, path: "/a/b", pinned: false, section: .recent)
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
}

