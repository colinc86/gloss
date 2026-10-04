import Core
import Foundation
import Observation
import Remote

/// Open Quickly (⌘P): every file under the selected root, ranked by `FuzzyMatcher` as the query changes.
@MainActor
@Observable
final class QuickOpenModel {
    var isPresented = false
    var query = "" {
        // Return makes the field write the same text back; re-ranking then would reset the selection to the
        // top row just before it opens.
        didSet { if query != oldValue { rerank() } }
    }
    private(set) var results: [String] = []
    var selectedIndex = 0
    private(set) var isLoading = false
    /// The results describe an older query; a ranking for the current one is running.
    private(set) var isRanking = false
    /// Return arrived before the results did: open the top result as soon as they arrive.
    @ObservationIgnored private var submitWhenReady = false
    /// Opens a path on `hostID`; set by the app.
    @ObservationIgnored var onOpen: (HostID, String) -> Void = { _, _ in }
    /// Why there is nothing to show (the host is not connected, the listing failed).
    private(set) var errorMessage: String?
    private(set) var root: String?
    private(set) var hostID: HostID = .local
    @ObservationIgnored private var candidates: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rankTask: Task<Void, Never>?

    /// Shows the panel for a root and lists its files (local tools, or over the host's exec channel).
    /// `connection` is required for a remote host: a remote root is never listed on this Mac.
    func present(root: String, hostID: HostID, connection: SSHConnection?) {
        self.root = root
        self.hostID = hostID
        query = ""
        selectedIndex = 0
        results = []
        candidates = []
        errorMessage = nil
        submitWhenReady = false
        isPresented = true
        loadTask?.cancel()
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
            failure = "Listing failed: \(error)"
            return []
        }
    }

    @concurrent nonisolated private static func rank(_ query: String, _ candidates: [String]) async -> [String] {
        FuzzyMatcher.rank(query, in: candidates)
    }

    /// Return: opens the selected result, or, while the list is still loading or ranking the latest query,
    /// opens the top result once it is ready (pressing Return right after typing used to do nothing).
    func submit() {
        if isLoading || isRanking {
            submitWhenReady = true
            return
        }
        guard let path = selectedPath else { return }
        let hostID = hostID
        dismiss()
        onOpen(hostID, path)
    }

    func dismiss() {
        isPresented = false
        loadTask?.cancel()
        rankTask?.cancel()
    }

    /// The absolute path of the selected result.
    var selectedPath: String? {
        guard let root, results.indices.contains(selectedIndex) else { return nil }
        return PathUtilities.join(root, results[selectedIndex])
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
    }

    /// Ranks off the main actor; a newer query cancels an older ranking.
    private func rerank() {
        rankTask?.cancel()
        let query = query
        let candidates = candidates
        isRanking = true
        rankTask = Task { [weak self] in
            let ranked = await Self.rank(query, candidates)
            guard !Task.isCancelled, let self else { return }
            self.results = ranked
            self.selectedIndex = 0
            self.isRanking = false
            if self.submitWhenReady, !self.isLoading {
                self.submitWhenReady = false
                self.submit()
            }
        }
    }
}
