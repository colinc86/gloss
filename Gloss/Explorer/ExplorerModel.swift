import AppKit
import Core
import Remote
import Observation
import OSLog

/// What the outline view needs to hear from the model, without SwiftUI diffing in between.
@MainActor
protocol ExplorerTreeDelegate: AnyObject {
    func treeDidReplaceRoot()
    func treeDidReload(_ node: FileNode)
    func treeDidChangeFilters()
    /// Expand every directory in `chain` but the last element, then select and scroll to the last.
    func treeReveal(_ chain: [FileNode])
    /// Open-note markers changed; redraw the visible rows.
    func treeDidChangeNoteMarks()
}

/// The open work on one file, for its row in the tree: how many notes still need something, their colours
/// (most used first, at most three), and whether any needs attention (orphaned, or the agent asked a question).
struct NoteMark: Equatable {
    var count: Int
    var colors: [NoteColor]
    var needsAttention: Bool
}

/// One open root directory in the sidebar.
@MainActor
final class RootTab: Identifiable {
    let id: RootID
    let hostID: HostID
    var path: String
    var node: FileNode
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
    /// Open-note markers by `host:path` (paths standardized, so `/private/tmp/x` and `/tmp/x` agree), and the
    /// total under each folder.
    @ObservationIgnored private(set) var fileMarks: [String: NoteMark] = [:]
    /// Observed: the root chips show their totals.
    private(set) var folderCounts: [String: Int] = [:]
    /// Saves a whole-file note made from the tree's context menu: host, path, comment, color.
    @ObservationIgnored var onCreateFileNote: (HostID, String, String, NoteColor) -> Void = { _, _, _, _ in }
    /// The color of the last note made from the tree, so the next one starts with it.
    @ObservationIgnored var lastFileNoteColor: NoteColor = .yellow
    /// Says what was just copied (the app shows it briefly).
    @ObservationIgnored var onCopied: (String) -> Void = { _ in }
    @ObservationIgnored weak var treeDelegate: (any ExplorerTreeDelegate)?

    private(set) var tabs: [RootTab] = [] {
        didSet { onTabsChange() }
    }
    var selectedTabID: RootID? {
        didSet {
            treeDelegate?.treeDidReplaceRoot()
            onLocationSelected()
            if selectedTabID != oldValue {
                onTabsChange()
                if !selectingQuietly { onSelect() }
            }
        }
    }
    /// Another folder came to the front (or none): the app shows its host.
    @ObservationIgnored var onSelect: () -> Void = {}
    @ObservationIgnored var onLocationSelected: () -> Void = {}
    /// Set while a close moves the selection within the closed folder's host, which changes no host.
    @ObservationIgnored private var selectingQuietly = false
    /// A folder opened or closed, or another came to the front: the app saves what's open (#9).
    @ObservationIgnored var onTabsChange: () -> Void = {}
    /// Recently opened roots per host, pinned first; one entry per folder.
    private(set) var recentsByHost: [HostID: [Root]] = [:]
    /// Pinned roots on every host, one per folder: the switcher's Favorites, whichever host is picked.
    private(set) var favorites: [Root] = []
    /// A folder picked on an ssh host whose key isn't known yet: it opens once the key is accepted.
    @ObservationIgnored var pathAwaitingHostKey: (hostID: HostID, path: String)?
    /// The recents of the host loaded last (the reopen-on-launch path reads it right after loading).
    private(set) var recentRoots: [Root] = []
    var showDotfiles = false {
        didSet {
            treeDelegate?.treeDidChangeFilters()
            if showDotfiles != oldValue { onShowDotfilesChange() }
        }
    }
    /// Set by the app: Find in Files' results follow the setting.
    @ObservationIgnored var onShowDotfilesChange: () -> Void = {}
    /// The web address of a node on an integration host (a pull request, issue or page); set by the app.
    @ObservationIgnored var webURL: (HostID, String) -> URL? = { _, _ in nil }

    /// Bumped by View › Filter Files to put the caret in the tree's filter field.
    var filterFocusRequest = 0
    var filter = "" {
        didSet { treeDelegate?.treeDidChangeFilters() }
    }
    var lastError: String?
    var fileNameRequest: FileNameRequest?
    @ObservationIgnored var onRename: (HostID, String, String, Bool) async throws -> Void = { _, _, _, _ in
        throw FileSystemError.io("Rename is unavailable")
    }
    let contentSearch = ContentSearchModel()

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

    /// The folder a path names, for telling roots apart: on this Mac symlinks resolve (`/tmp` is
    /// `/private/tmp`), so two spellings of one folder do not become two tabs.
    nonisolated static func markKey(_ hostID: HostID, _ path: String) -> String {
        "\(hostID.rawValue):\(hostID == .local ? aliasFree(path) : (path as NSString).standardizingPath)"
    }

    /// `path` in `root`'s spelling when it lies inside that root, else nil. File events and links name
    /// `/private/tmp/x/a` for a root the tree stores as `/tmp/x`; comparing raw strings would miss it.
    nonisolated static func inRootSpelling(_ path: String, root: String, hostID: HostID) -> String? {
        let normalize: (String) -> String = { hostID == .local ? aliasFree($0) : ($0 as NSString).standardizingPath }
        let target = normalize(path)
        let base = normalize(root)
        guard target == base || target.hasPrefix(base == "/" ? "/" : base + "/") else { return nil }
        let standardizedRoot = (root as NSString).standardizingPath
        return standardizedRoot + target.dropFirst(base.count)
    }

    /// macOS's `/tmp`, `/var`, and `/etc` are links into `/private`; Foundation drops the prefix only for paths that
    /// exist, so it is done here by rule, without touching the disk.
    nonisolated static func aliasFree(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        for alias in ["/tmp", "/var", "/etc"] where standardized == "/private" + alias || standardized.hasPrefix("/private" + alias + "/") {
            return String(standardized.dropFirst("/private".count))
        }
        return standardized
    }

    func mark(for node: FileNode) -> NoteMark? { fileMarks[Self.markKey(node.hostID, node.path)] }
    func mark(hostID: HostID, path: String) -> NoteMark? { fileMarks[Self.markKey(hostID, path)] }
    /// The open document, keyed like the note marks, so collapsed folders on its path can say they hold it.
    @ObservationIgnored private(set) var activeDocumentKey: String?

    func setActiveDocument(hostID: HostID?, path: String?) {
        let key = hostID.flatMap { host in path.map { Self.markKey(host, $0) } }
        guard key != activeDocumentKey else { return }
        activeDocumentKey = key
        treeDelegate?.treeDidChangeNoteMarks()
    }

    /// Whether `node` is a folder on the path to the open document.
    func holdsActiveDocument(_ node: FileNode) -> Bool {
        guard node.isDirectory, let active = activeDocumentKey else { return false }
        let folder = Self.markKey(node.hostID, node.path)
        return active.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    func folderCount(for node: FileNode) -> Int { folderCounts[Self.markKey(node.hostID, node.path)] ?? 0 }
    func folderCountForRoot(_ tab: RootTab) -> Int { folderCounts[Self.markKey(tab.hostID, tab.path)] ?? 0 }

    /// Rebuilds the tree's note markers from the notes panel's groups. Only open work counts: drafts, sent notes
    /// (questions from agents among them), and orphans.
    func updateNoteMarks(_ groups: [DocumentNotes]) {
        var files: [String: NoteMark] = [:]
        var folders: [String: Int] = [:]
        for group in groups {
            let open = group.notes.filter { note in
                note.state != .resolved || note.needsAttention
            }
            guard !open.isEmpty else { continue }
            var tally: [NoteColor: Int] = [:]
            for note in open { tally[note.color, default: 0] += 1 }
            let colors = tally.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.prefix(3).map(\.key)
            let attention = open.contains(where: \.needsAttention)
            let path = group.document.hostID == .local ? Self.aliasFree(group.document.path) : (group.document.path as NSString).standardizingPath
            files[Self.markKey(group.document.hostID, path)] = NoteMark(count: open.count, colors: Array(colors), needsAttention: attention)
            var folder = (path as NSString).deletingLastPathComponent
            while !folder.isEmpty {
                folders[Self.markKey(group.document.hostID, folder), default: 0] += open.count
                if folder == "/" { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        guard files != fileMarks || folders != folderCounts else { return }
        fileMarks = files
        folderCounts = folders
        treeDelegate?.treeDidChangeNoteMarks()
    }

    nonisolated static func canonical(_ path: String, hostID: HostID) -> String {
        let standardized = (path as NSString).standardizingPath
        guard hostID == .local else { return standardized }
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }

    private func existingTab(hostID: HostID, path: String) -> RootTab? {
        let target = Self.canonical(path, hostID: hostID)
        return tabs.first { $0.hostID == hostID && ($0.path == path || Self.canonical($0.path, hostID: hostID) == target) }
    }

    func openRoot(hostID: HostID, path: String) async {
        let normalized = (path as NSString).standardizingPath
        if let existing = existingTab(hostID: hostID, path: normalized) {
            selectedTabID = existing.id
            return
        }
        guard let fileSystem = fileSystemProvider(hostID) else {
            lastError = switch hostID {
            case .github: "GitHub isn't set up. Save a token in Settings → Integrations."
            case .atlassian: "Atlassian isn't set up. Save a key in Settings → Integrations."
            default: "Not connected to this folder's host."
            }
            return
        }
        do {
            let attributes = try await fileSystem.stat(normalized)
            guard attributes.kind == .directory else {
                lastError = "\(PathUtilities.name(of: normalized)) is a file, not a folder."
                return
            }
            let root = try await noteStore.recordRootOpened(hostID: hostID, path: normalized)
            // Another open of the same folder may have finished while this one waited on the host.
            if let existing = existingTab(hostID: hostID, path: normalized) {
                selectedTabID = existing.id
                return
            }
            let entry = DirectoryEntry(name: PathUtilities.name(of: normalized), path: normalized, kind: .directory, mtime: attributes.mtime, mode: attributes.mode)
            let tab = RootTab(id: root.id, hostID: hostID, path: normalized, node: FileNode(hostID: hostID, entry: entry, parent: nil))
            tabs.append(tab)
            selectedTabID = tab.id
            await loadChildren(of: tab.node)
            startWatching(tab, fileSystem: fileSystem)
            await loadRecents(hostID: hostID)
            await loadFavorites()
        } catch {
            lastError = "Couldn't open \(PathUtilities.name(of: normalized)): " + Self.folderFailure(error, virtual: hostID.isVirtual)
            Log.explorer.error("openRoot failed: \(error, privacy: .public)")
        }
    }

    func closeTab(_ id: RootID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].watcher?.cancel()
        let closed = tabs.remove(at: index)
        // The next folder on the same host, or none: the explorer stays on that host (or on Web, where the closed
        // folder was hidden) and says nothing is open rather than jumping to another host's folder.
        if selectedTabID == id {
            selectingQuietly = true
            selectedTabID = tabs.last { $0.hostID == closed.hostID }?.id
            selectingQuietly = false
        }
    }

    /// Favorite folders: pinned roots stay at the top of the root switcher whether or not they are open.
    /// Matched by folder, not by record: `/tmp/x` and `/private/tmp/x` are two records of one folder, and the
    /// recents list keeps only one of them.
    func isPinned(hostID: HostID, path: String) -> Bool {
        let key = Self.markKey(hostID, path)
        return favorites.contains { Self.markKey($0.hostID, $0.path) == key }
    }

    /// Pins or unpins the folder: the given record and any other record of the same folder.
    func setPinned(_ id: RootID, hostID: HostID, path: String, _ pinned: Bool) async {
        let key = Self.markKey(hostID, path)
        let ids = Set([id] + ((recentsByHost[hostID] ?? []) + favorites).filter { Self.markKey($0.hostID, $0.path) == key }.map(\.id))
        for root in ids {
            do {
                try await noteStore.setRootPinned(root, pinned)
            } catch {
                Log.explorer.error("pin failed: \(error, privacy: .public)")
            }
        }
        await loadRecents(hostID: hostID)
        await loadFavorites()
    }

    /// The folder waiting for `hostID`'s key to be accepted, if any; taken once.
    func takePathAwaitingHostKey(_ hostID: HostID) -> String? {
        guard let pending = pathAwaitingHostKey, pending.hostID == hostID else { return nil }
        pathAwaitingHostKey = nil
        return pending.path
    }

    /// Recent roots again for each host given (the switcher loads the picked host and every host with a tab), and
    /// the favorites.
    func refreshRecents(hostIDs: Set<HostID>) async {
        for hostID in hostIDs { await loadRecents(hostID: hostID) }
        await loadFavorites()
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
            // One entry per folder, however many spellings of it were opened.
            var seen: Set<String> = []
            recentRoots = try await noteStore.roots(for: hostID).filter { seen.insert(Self.canonical($0.path, hostID: hostID)).inserted }
            recentsByHost[hostID] = recentRoots
        } catch {
            Log.explorer.error("roots query failed: \(error, privacy: .public)")
        }
    }

    private func loadFavorites() async {
        do {
            var seen: Set<String> = []
            favorites = try await noteStore.pinnedRoots().filter { seen.insert(Self.markKey($0.hostID, $0.path)).inserted }
        } catch {
            Log.explorer.error("favorites query failed: \(error, privacy: .public)")
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

    /// Why a folder could not be opened, in a folder's words (a lost connection named as one).
    nonisolated static func folderFailure(_ error: any Error, virtual: Bool) -> String {
        if virtual { return DocumentSession.openFailure(error, virtual: true) }
        switch error as? FileSystemError {
        case .notFound: return "it isn't there any more."
        case .permissionDenied: return "you don't have permission to open it."
        case .io(let detail): return detail
        default:
            if error is SFTPClientError || error is SSHError { return "the connection to its host was lost or refused (\(error))." }
            return error.localizedDescription
        }
    }

    /// Shows `path` in the tree: picks the open root containing it (the deepest when roots nest), lists every
    /// directory on the way, and has the tree expand, select, and scroll to it. Dotfiles on the way are shown so
    /// the target is reachable. Returns false when no open root on that host contains the path.
    @discardableResult
    func reveal(hostID: HostID, path: String) async -> Bool {
        // Compare spellings the same way the tabs store them: a root opened as `/private/tmp/x` is the tab `/tmp/x`.
        let normalize: (String) -> String = { hostID == .local ? Self.aliasFree($0) : ($0 as NSString).standardizingPath }
        let target = normalize(path)
        let candidates = tabs.filter { tab in
            let root = normalize(tab.path)
            return tab.hostID == hostID && (target == root || target.hasPrefix(root == "/" ? "/" : root + "/"))
        }
        guard let tab = candidates.max(by: { $0.path.count < $1.path.count }) else { return false }
        if selectedTabID != tab.id { selectedTabID = tab.id }
        var chain = [tab.node]
        var node = tab.node
        let relative = target.dropFirst(normalize(tab.path).count).split(separator: "/")
        for component in relative {
            // A listing already under way (the user just expanded this folder) is waited for, not skipped.
            for _ in 0..<200 where node.isLoading { try? await Task.sleep(for: .milliseconds(25)) }
            if !node.isLoaded { await loadChildren(of: node) }
            // By the path's own component, not the shown name: a Confluence page's folder is named by its title
            // and addressed by its id.
            guard let child = node.children?.first(where: { ($0.path as NSString).lastPathComponent == component }) else { break }
            if child.entry.isHidden, !showDotfiles { showDotfiles = true }
            // The tree shows only names matching the filter; a filter hiding the target would make the reveal a no-op.
            if !filter.isEmpty, !child.isDirectory, !child.name.localizedCaseInsensitiveContains(filter) { filter = "" }
            chain.append(child)
            node = child
        }
        treeDelegate?.treeReveal(chain)
        return chain.last.map { normalize($0.path) } == target
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

    func applyRelocation(_ move: DocumentRelocation) async {
        for tab in tabs where tab.hostID == move.hostID {
            guard let path = move.destination(for: tab.path) else { continue }
            tab.watcher?.cancel()
            tab.path = path
            tab.node = FileNode(hostID: tab.hostID, entry: DirectoryEntry(name: PathUtilities.name(of: path), path: path, kind: .directory), parent: nil)
            if let fileSystem = fileSystemProvider(tab.hostID) { startWatching(tab, fileSystem: fileSystem) }
            await loadChildren(of: tab.node)
        }
        await loadRecents(hostID: move.hostID)
        treeDelegate?.treeDidReplaceRoot()
        onTabsChange()
    }

    func stopWatching() {
        for tab in tabs { tab.watcher?.cancel() }
        reloadTask?.cancel()
    }

    /// The directory containing `path` is re-listed shortly, coalescing bursts of events.
    private func scheduleReload(ofParentOf eventPath: String, in tab: RootTab) {
        let path = Self.inRootSpelling(eventPath, root: tab.path, hostID: tab.hostID) ?? eventPath
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
