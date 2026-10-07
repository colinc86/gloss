import Core
import Foundation
import Observation

/// The live pages visited, newest first with pinned ones ahead: the explorer's Web section and Open Quickly's web
/// rows. Every change is written to the `web_page` table and read back.
@MainActor
@Observable
final class WebPagesModel {
    private(set) var pages: [WebPage] = []
    @ObservationIgnored private let noteStore: NoteStore

    var pinned: [WebPage] { pages.filter(\.pinned) }
    var recent: [WebPage] { pages.filter { !$0.pinned } }

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    func load() async {
        if let pages = try? await noteStore.webPages() { self.pages = pages }
    }

    /// A page shown in the viewer: `url` is its document key, `hostID` the web host or the ssh host it was
    /// reached through.
    func recordVisit(url: String, hostID: HostID, title: String? = nil) {
        update { try await $0.recordWebPageVisit(url: url, hostID: hostID, title: title) }
    }

    /// The page's title once it loaded. Written even when the visit is not in `pages` yet: the two writes queue in
    /// order on the database, and a title for a page never visited changes nothing.
    func setTitle(_ title: String, url: String, hostID: HostID) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !pages.contains(where: { $0.url == url && $0.hostID == hostID && $0.title == title }) else { return }
        update { try await $0.setWebPageTitle(url: url, hostID: hostID, title: title) }
    }

    func setPinned(_ page: WebPage, _ pinned: Bool) {
        update { try await $0.setWebPagePinned(url: page.url, hostID: page.hostID, pinned) }
    }

    func remove(_ page: WebPage) {
        update { try await $0.removeWebPage(url: page.url, hostID: page.hostID) }
    }

    /// Writes, then reads the list back. Writes queue on the database in the order they were made.
    private func update(_ write: @escaping @Sendable (NoteStore) async throws -> Void) {
        let store = noteStore
        Task {
            try? await write(store)
            await load()
        }
    }

    /// The pages matching `query` by title or address (characters in order, as Open Quickly matches files), best
    /// first; all of them, newest first, for an empty query.
    static func matching(_ query: String, in pages: [WebPage]) -> [WebPage] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return pages.sorted { $0.lastVisitedAt > $1.lastVisitedAt } }
        var byCandidate: [String: [WebPage]] = [:]
        for page in pages { byCandidate[candidate(page), default: []].append(page) }
        return FuzzyMatcher.rank(needle, in: Array(byCandidate.keys)).flatMap { byCandidate[$0] ?? [] }
    }

    /// What a page is matched on: its title and its address as the explorer shows it (no scheme).
    private static func candidate(_ page: WebPage) -> String {
        [page.title, Core.Document.displayName(of: page.url)].compactMap { $0 }.joined(separator: " ")
    }
}
