import AppKit
import Core
import Observation
import OSLog

/// What the outline view needs to hear from the model, without SwiftUI diffing in between.
@MainActor
protocol ExplorerTreeDelegate: AnyObject {
    func treeDidReplaceRoot()
    func treeDidReload(_ node: FileNode)
    func treeDidChangeFilters()
}

/// One open root directory in the sidebar.
@MainActor
final class RootTab: Identifiable {
    let id: RootID
    let hostID: HostID
    let path: String
    let node: FileNode
    var watcher: Task<Void, Never>?

    init(id: RootID, hostID: HostID, path: String, node: FileNode) {
        self.id = id
        self.hostID = hostID
        self.path = path
        self.node = node
    }

    var title: String { PathUtilities.name(of: path) }
}

@MainActor
@Observable
final class ExplorerModel {
    private let noteStore: NoteStore
    /// Set by `AppModel`; resolves a host to its file system.
    @ObservationIgnored var fileSystemProvider: (HostID) -> (any FileSystemProvider)? = { _ in nil }
    @ObservationIgnored var onSelectFile: (HostID, String) -> Void = { _, _ in }
    @ObservationIgnored weak var treeDelegate: (any ExplorerTreeDelegate)?

    private(set) var tabs: [RootTab] = []
    var selectedTabID: RootID? {
        didSet { treeDelegate?.treeDidReplaceRoot() }
    }
    private(set) var recentRoots: [Root] = []
    var showDotfiles = false {
        didSet { treeDelegate?.treeDidChangeFilters() }
    }
    var filter = "" {
        didSet { treeDelegate?.treeDidChangeFilters() }
    }
    private(set) var lastError: String?

    @ObservationIgnored private var pendingReloads: Set<String> = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    var selectedTab: RootTab? {
        tabs.first { $0.id == selectedTabID }
    }

    // MARK: Roots

    func reopenRecentRoot(hostID: HostID) async {
        await loadRecents(hostID: hostID)
        if let recent = recentRoots.first {
            await openRoot(hostID: hostID, path: recent.path)
        }
    }

    func openRoot(hostID: HostID, path: String) async {
        let normalized = (path as NSString).standardizingPath
        if let existing = tabs.first(where: { $0.hostID == hostID && $0.path == normalized }) {
            selectedTabID = existing.id
            return
        }
        guard let fileSystem = fileSystemProvider(hostID) else {
            lastError = "No connection to host \(hostID.rawValue)"
            return
        }
        do {
            let attributes = try await fileSystem.stat(normalized)
            guard attributes.kind == .directory else {
                lastError = "\(normalized) is not a directory"
                return
            }
            let root = try await noteStore.recordRootOpened(hostID: hostID, path: normalized)
            let entry = DirectoryEntry(name: PathUtilities.name(of: normalized), path: normalized, kind: .directory, mtime: attributes.mtime, mode: attributes.mode)
            let tab = RootTab(id: root.id, hostID: hostID, path: normalized, node: FileNode(hostID: hostID, entry: entry, parent: nil))
            tabs.append(tab)
            selectedTabID = tab.id
            await loadChildren(of: tab.node)
            startWatching(tab, fileSystem: fileSystem)
            await loadRecents(hostID: hostID)
        } catch {
            lastError = "Could not open \(normalized): \(error)"
            Log.explorer.error("openRoot failed: \(error, privacy: .public)")
        }
    }

    func closeTab(_ id: RootID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].watcher?.cancel()
        tabs.remove(at: index)
        if selectedTabID == id { selectedTabID = tabs.last?.id }
    }

    func chooseRootWithPanel(hostID: HostID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openRoot(hostID: hostID, path: url.path) }
    }

    private func loadRecents(hostID: HostID) async {
        do {
            recentRoots = try await noteStore.roots(for: hostID)
        } catch {
            Log.explorer.error("roots query failed: \(error, privacy: .public)")
        }
    }

    // MARK: Tree loading

    func loadChildren(of node: FileNode) async {
        guard node.isDirectory, !node.isLoading else { return }
        guard let fileSystem = fileSystemProvider(node.hostID) else { return }
        node.isLoading = true
        defer { node.isLoading = false }
        do {
            let entries = try await fileSystem.list(node.path)
            _ = node.merge(entries: entries)
            if node.hostID == .local {
                let ignored = await GitIgnoreService.ignoredNames(in: node.path, entries: entries.map { ($0.name, $0.isDirectoryLike) })
                for child in node.children ?? [] { child.isIgnored = ignored.contains(child.name) }
            }
            treeDelegate?.treeDidReload(node)
        } catch {
            Log.explorer.error("list \(node.path, privacy: .public) failed: \(error, privacy: .public)")
            node.children = node.children ?? []
            treeDelegate?.treeDidReload(node)
        }
    }

    /// Re-lists every loaded directory of the selected root.
    func refreshAll() {
        guard let tab = selectedTab else { return }
        Task { await reload(node: tab.node, recursive: true) }
    }

    private func reload(node: FileNode, recursive: Bool) async {
        guard node.isLoaded else { return }
        await loadChildren(of: node)
        if recursive {
            for child in node.children ?? [] where child.isLoaded {
                await reload(node: child, recursive: true)
            }
        }
    }

    func select(_ node: FileNode?) {
        guard let node, !node.isDirectory else { return }
        onSelectFile(node.hostID, node.path)
    }

    // MARK: Watching

    private func startWatching(_ tab: RootTab, fileSystem: any FileSystemProvider) {
        let stream = fileSystem.watch(tab.path)
        tab.watcher = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .changed(let paths):
                    for path in paths { self.scheduleReload(ofParentOf: path, in: tab) }
                case .rescan(let path):
                    self.scheduleReload(ofParentOf: PathUtilities.join(path, "."), in: tab)
                }
            }
        }
    }

    func stopWatching() {
        for tab in tabs { tab.watcher?.cancel() }
        reloadTask?.cancel()
    }

    /// The directory containing `path` is re-listed shortly, coalescing bursts of events.
    private func scheduleReload(ofParentOf path: String, in tab: RootTab) {
        let directory = PathUtilities.parent(of: path)
        // The path itself may be a loaded directory whose contents changed (mkdir, rmdir).
        for candidate in [directory, path] {
            if let node = tab.node.descendant(at: candidate), node.isDirectory, node.isLoaded {
                pendingReloads.insert(node.path)
            }
        }
        if pendingReloads.isEmpty, path.hasPrefix(tab.path) {
            pendingReloads.insert(tab.path)
        }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let paths = self.pendingReloads
            self.pendingReloads = []
            for tab in self.tabs {
                for path in paths {
                    if let node = tab.node.descendant(at: path) { await self.loadChildren(of: node) }
                }
            }
        }
    }
}
