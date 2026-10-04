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
}
