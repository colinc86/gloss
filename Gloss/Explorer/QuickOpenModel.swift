import Core
import Foundation
import Observation
import Remote

/// Open Quickly (⌘P): every file under the selected root, ranked by `FuzzyMatcher` as the query changes, below
/// the web pages visited that match and, when the query is an address, a row that opens it.
@MainActor
@Observable
final class QuickOpenModel {
    /// One row of the panel, in order: the typed address, then pages, then files.
    enum Row: Hashable {
        case address(URL)
        case page(WebPage)
        case file(String)

        var id: String {
            switch self {
            case .address: "address"
            case .page(let page): "page " + page.id
            case .file(let path): "file " + path
            }
        }
    }

    var isPresented = false
    var query = "" {
        // Return makes the field write the same text back; re-ranking then would reset the selection to the
        // top row just before it opens.
        didSet { if query != oldValue { matchWeb(); rerank() } }
    }
    /// The files matching, relative to the root.
    private(set) var results: [String] = []
    /// The line the results open at: the query's `:line` when they were found without it.
    private(set) var resultsLine: Int?
    /// How many files matched, of which `results` holds only the best.
    private(set) var matchCount = 0
    /// The query as an address to open, when it reads as one.
    private(set) var address: URL?
    /// Whether the address row leads (the query can only be an address, or there are no files to put first) or
    /// trails the files unselected (`README.md` is far likelier a file than a website).
    private(set) var addressLeads = true
    /// The visited pages matching the query.
    private(set) var pageResults: [WebPage] = []
    var selectedIndex = 0
    private(set) var isLoading = false
    /// The results describe an older query; a ranking for the current one is running.
    private(set) var isRanking = false
    /// Return arrived before the results did: open the top result as soon as they arrive.
    @ObservationIgnored private var submitWhenReady = false
    /// Opens a path on `hostID`; set by the app.
    @ObservationIgnored var onOpen: (HostID, String) -> Void = { _, _ in }
    /// Opens a path at a line, for a query ending in `:line` (as agents print locations); set by the app.
    @ObservationIgnored var onOpenAtLine: (HostID, String, Int) -> Void = { _, _, _ in }

    /// `Sources/App.swift:42` (or `:42:7`) is that file at line 42: the files are matched on what comes before.
    nonisolated static func splitLine(_ query: String) -> (text: String, line: Int?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: /(.*?[^:\s]):(\d{1,7})(?::\d{1,7})?/), let line = Int(match.output.2), line > 0 else {
            return (query, nil)
        }
        return (String(match.output.1), line)
    }
    /// Opens a typed address; set by the app.
    @ObservationIgnored var onOpenAddress: (URL) -> Void = { _ in }
    /// Opens a visited page; set by the app.
    @ObservationIgnored var onOpenPage: (WebPage) -> Void = { _ in }
    /// The pages visited, read when the panel opens; set by the app.
    @ObservationIgnored var pages: () -> [WebPage] = { [] }
    @ObservationIgnored private var visited: [WebPage] = []
    /// Why there is nothing to show (the host is not connected, the listing failed).
    private(set) var errorMessage: String?
    private(set) var root: String?
    private(set) var hostID: HostID = .local
    @ObservationIgnored private var candidates: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rankTask: Task<Void, Never>?

    /// Shows the panel for a root and lists its files (local tools, or over the host's exec channel); without a
    /// root (no folder open, or one that is browsed rather than listed) only addresses and pages are offered.
    /// `connection` is required for a remote host: a remote root is never listed on this Mac.
    func present(root: String?, hostID: HostID, connection: SSHConnection?) {
        self.root = root
        self.hostID = hostID
        query = ""
        selectedIndex = 0
        results = []
        candidates = []
        errorMessage = nil
        submitWhenReady = false
        visited = pages()
        matchWeb()
        isPresented = true
        loadTask?.cancel()
        guard let root else {
            isLoading = false
            isRanking = false
            return
        }
        if hostID != .local, connection == nil {
            isLoading = false
            errorMessage = "Not connected to this folder's host"
            return
        }
        isLoading = true
        loadTask = Task { [weak self] in
            var failure: String?
            let paths = await Self.list(root: root, connection: connection, failure: &failure)
            guard !Task.isCancelled, let self, self.root == root else { return }
            if paths.isEmpty, let failure { self.errorMessage = failure }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            self.candidates = paths.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
            self.isLoading = false
            self.rerank()
        }
    }

    /// Off the main actor and in the caller's task, so cancelling `loadTask` stops `rg`/`find` or the remote command.
    @concurrent nonisolated private static func list(root: String, connection: SSHConnection?, failure: inout String?) async -> [String] {
        guard let connection else { return await FileListing.listLocally(root: root, ripgrep: ContentSearchModel.ripgrepPath) }
        do {
            return try await FileListing.list(root: root, over: connection)
        } catch {
            failure = "Listing failed: \(error.userMessage)"
            return []
        }
    }

    /// Files for the query as typed; when it ends in `:line` and nothing matches it whole, files for what comes
    /// before, with that line (a file really named `notes 10:30` is found by its name, not split).
    @concurrent nonisolated private static func rank(_ query: String, _ candidates: [String]) async -> (files: [String], line: Int?, total: Int) {
        let split = splitLine(query)
        let whole = FuzzyMatcher.rankCounted(query, in: candidates)
        guard let line = split.line, whole.paths.isEmpty else { return (whole.paths, nil, whole.total) }
        let before = FuzzyMatcher.rankCounted(split.text, in: candidates)
        return (before.paths, line, before.total)
    }

    /// An absolute path or `file://` link inside the root (as an agent prints a location) as the root-relative path
    /// the files are listed by, `:line` kept; any other query as typed.
    static func withinRoot(_ query: String, root: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") || trimmed.lowercased().hasPrefix("file://"),
              case .path(let path)? = AddressInput.parse(trimmed, home: nil) else { return query }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : query
    }

    /// The part of a query a file's name is lit by: as ranked (a path inside the root made relative), without a
    /// `:line`, and from its last `/` on, since only the name is lit (`src/main` lights `main`).
    static func nameQuery(_ query: String, root: String) -> String {
        let relative = withinRoot(query, root: root)
        let split = splitLine(relative)
        let text = split.line == nil ? relative : split.text
        return text.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? text
    }

    /// Every row in order.
    var rows: [Row] {
        let addressRow = address.map { [Row.address($0)] } ?? []
        return (addressLeads ? addressRow : []) + pageResults.map(Row.page) + results.map(Row.file) + (addressLeads ? [] : addressRow)
    }

    /// At most this many pages above the files; more when there are no files to show.
    private var pageLimit: Int { root == nil ? 30 : 6 }

    /// The address row and the page rows follow the query at once: they need no listing.
    private func matchWeb() {
        if let url = AddressInput.webURL(from: query) {
            address = url
            addressLeads = true
        } else {
            address = AddressInput.possibleWebURL(from: query)
            addressLeads = root == nil
        }
        pageResults = Array(WebPagesModel.matching(query, in: visited).prefix(pageLimit))
        selectedIndex = 0
    }

    /// Return: opens the selected row. A file row waits while the list is still loading or ranking the latest
    /// query, and then opens the top row once it is ready (pressing Return right after typing used to do nothing);
    /// an address or a page opens at once.
    func submit() {
        let rows = rows
        let selected = rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
        // A trailing address waits too: while the files load it is the only row, not the one the reader chose.
        let waitsForFiles: Bool = switch selected {
        case nil, .file?: true
        case .address?: !addressLeads
        case .page?: false
        }
        if isLoading || isRanking, waitsForFiles {
            submitWhenReady = true
            return
        }
        switch selected {
        case .address(let url)?:
            dismiss()
            onOpenAddress(url)
        case .page(let page)?:
            dismiss()
            onOpenPage(page)
        case .file?:
            guard let path = selectedPath else { return }
            let hostID = hostID
            dismiss()
            if let line = resultsLine { onOpenAtLine(hostID, path, line) } else { onOpen(hostID, path) }
        case nil:
            break
        }
    }

    func dismiss() {
        isPresented = false
        loadTask?.cancel()
        rankTask?.cancel()
    }

    /// The absolute path of the selected row, when it is a file.
    var selectedPath: String? {
        let rows = rows
        guard let root, rows.indices.contains(selectedIndex), case .file(let path) = rows[selectedIndex] else { return nil }
        return PathUtilities.join(root, path)
    }

    func moveSelection(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
    }

    /// Ranks off the main actor; a newer query cancels an older ranking.
    private func rerank() {
        rankTask?.cancel()
        guard root != nil else { return }
        let query = Self.withinRoot(query, root: root ?? "/")
        let candidates = candidates
        isRanking = true
        rankTask = Task { [weak self] in
            let (ranked, line, total) = await Self.rank(query, candidates)
            guard !Task.isCancelled, let self else { return }
            let before = self.rows
            let onFile = !before.indices.contains(self.selectedIndex) || { if case .file = before[self.selectedIndex] { true } else { false } }()
            self.results = ranked
            self.resultsLine = line
            self.matchCount = total
            self.isRanking = false
            if self.submitWhenReady, !self.isLoading {
                // Return was pressed on a file row (or before there were rows): it opens the best file, never an
                // address or a page that happens to sit above it.
                self.submitWhenReady = false
                if let first = self.rows.firstIndex(where: { if case .file = $0 { true } else { false } }) {
                    self.selectedIndex = first
                    self.submit()
                }
                return
            }
            // A selection the reader moved onto an address or a page stays where it is.
            if onFile { self.selectedIndex = 0 }
        }
    }
}
