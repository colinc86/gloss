import AppKit
import Core
import Foundation
import os
import Observation
import OSLog
import Integrations
import Remote
import Transports
import Viewers

/// Root object for the app: owns the database, the file systems per host, and the explorer.
@MainActor
@Observable
final class AppModel {
    let database: AppDatabase
    let noteStore: NoteStore
    private(set) var fileSystems: [HostID: any FileSystemProvider] = [:]
    let explorer: ExplorerModel
    let notesPanel: NotesPanelModel
    let noteLink: NoteLinkModel
    let send: SendCoordinator
    let settings: SettingsStore
    let hosts: HostsModel
    let hooks = HooksModel()
    let integrations: IntegrationsModel
    let updates: UpdaterService
    /// Why the notes database could not be opened at launch, shown until dismissed; nil when it opened.
    var databaseFailure: String?

    /// A file a `gloss://open` link without the token asked to open, waiting for the user to confirm.
    struct PendingLinkOpen: Equatable {
        var hostID: HostID
        /// The ssh host's name, nil for this Mac.
        var hostName: String?
        var path: String
        var line: Int?
    }
    var pendingLinkOpen: PendingLinkOpen?
    let quickOpen = QuickOpenModel()
    let pullRequestPicker = PullRequestPickerModel()
    let atlassianPicker = AtlassianPickerModel()
    /// The one web view, shared by every HTML document and live page.
    let browser = WebBrowserController()
    let launchOptions: AppLaunchOptions
    /// Live ssh connections by host, for transports and search.
    private(set) var connections: [HostID: SSHConnection] = [:]
    /// The host the sidebar's host menu shows: whichever was picked or connected last, so a connect started from
    /// a launch flag or a URL is visible in the status row too.
    var pickedHost: HostID = .local
    /// The same connections, readable by the transports without touching the main actor.
    let connectionRegistry = ConnectionRegistry()
    let herdrTransport: HerdrTransport
    private(set) var mcpServer: MCPServer?
    private(set) var mcpStatus: String?
    /// The port the MCP server actually bound; the setting can differ until the next launch.
    private(set) var mcpListeningPort: Int?
    /// The main window (explorer, viewer, notes), for commands that must act there whatever window is in front.
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// What was just copied ("Path copied"), shown briefly at the bottom of the window; the id restarts the timer.
    private(set) var copyFlash: (id: Int, text: String)?

    func flashCopied(_ text: String) {
        copyFlash = ((copyFlash?.id ?? 0) + 1, text)
    }

    func clearCopyFlash(_ id: Int) {
        if copyFlash?.id == id { copyFlash = nil }
    }

    /// Starts a note on the open document. The composer is a popover on the main window, so a command chosen
    /// while Settings or Keyboard Shortcuts is in front brings the main window forward first.
    /// The Add Note button is showing: a selection waits for a note, so ⌘↩ makes one instead of sending.
    var selectionAwaitsNote: Bool { activeSession?.selectionAffordanceRect != nil }

    func beginNoteInMainWindow() {
        guard let session = activeSession else { return }
        if let window = mainWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { session.beginNote() }
        } else {
            session.beginNote()
        }
    }
    /// The machines with Herdr installed: this Mac when its binary is found, a host when its probe saw one. Herdr's
    /// follow mode and plugin are offered only where it exists.
    private(set) var herdrHosts: Set<HostID> = HerdrTransport.locateHerdr() == nil ? [] : [.local]
    /// Remote home directories, learned from the probe when a host connects (hook installs need them).
    private(set) var hostHomes: [HostID: String] = [:]
    @ObservationIgnored private var cleanupTasks: [HostID: Task<Void, Never>] = [:]
    @ObservationIgnored private var warnedNonAtomic: Set<HostID> = []
    /// Follow mode: the explorer opens the directory of whichever Herdr agent pane has focus.
    var followHerdr = false {
        didSet { followHerdr ? startFollowing() : stopFollowing() }
    }
    private(set) var followStatus: String?
    /// The followed pane, for the sidebar's follow card: host (nil on this Mac), agent, status, pane, folder.
    struct FollowedPane: Equatable {
        var host: String?
        var agent: String
        var status: String?
        var paneID: String
        var path: String?
    }
    private(set) var followedPane: FollowedPane?
    @ObservationIgnored private var followTasks: [HostID: Task<Void, Never>] = [:]
    /// The machine the Herdr client is showing, read from its state files while following; nil when Herdr has
    /// not written one (then every server's focus events are applied, as before machines existed).
    private(set) var herdrMachine: HerdrMachineSelection?
    @ObservationIgnored private var machineWatcherTask: Task<Void, Never>?
    /// The last focused agent pane per Herdr server, applied when the client switches back to that machine.
    @ObservationIgnored private var latestFocus: [HostID: FollowEvent] = [:]
    /// Bumped whenever the machine selection changes or following stops, so work resumed after an await can
    /// tell that the world moved on.
    @ObservationIgnored private var followGeneration = 0
    var showNotesPanel = true {
        didSet { if showNotesPanel != oldValue { scheduleWorkspaceSave() } }
    }

    /// Open documents keyed by `host:path`; `activeSession` is the one in the viewer pane.
    private(set) var sessions: [String: DocumentSession] = [:]
    private(set) var activeSession: DocumentSession? {
        didSet {
            explorer.setActiveDocument(hostID: activeSession?.hostID, path: activeSession?.path)
            rememberLastDocument()
            if let session = activeSession {
                let entry = DocumentHistory.Entry(hostID: session.hostID, path: session.path)
                // Arriving where Back or Forward was headed is not a new visit; arriving anywhere else (that open
                // failed, or something else took over) forgets the target.
                if entry == historyTarget { historyTarget = nil } else { historyTarget = nil; history.visit(entry) }
            }
        }
    }
    /// Back and Forward through the documents shown (issue #3).
    private(set) var history = DocumentHistory()
    /// Where Back or Forward is opening, until it is shown.
    @ObservationIgnored private var historyTarget: DocumentHistory.Entry?

    func goBack() {
        guard let entry = history.goBack(skipping: Self.isGone) else { return }
        show(entry)
    }

    func goForward() {
        guard let entry = history.goForward(skipping: Self.isGone) else { return }
        show(entry)
    }

    /// Goes back or forward several steps at once, from the toolbar's menus.
    func goBack(to entry: DocumentHistory.Entry) {
        while history.canGoBack, let step = history.goBack(skipping: Self.isGone), step != entry {}
        if let current = history.current { show(current) }
    }

    func goForward(to entry: DocumentHistory.Entry) {
        while history.canGoForward, let step = history.goForward(skipping: Self.isGone), step != entry {}
        if let current = history.current { show(current) }
    }

    /// Opens a place from the history, connecting its host and opening its folder as any open does, with the
    /// explorer following.
    private func show(_ entry: DocumentHistory.Entry) {
        historyTarget = entry
        openDocument(hostID: entry.hostID, path: entry.path)
        revealActiveDocumentInExplorer()
    }

    /// A local file deleted since it was shown: Back and Forward pass over it.
    nonisolated static func isGone(_ entry: DocumentHistory.Entry) -> Bool {
        entry.hostID == .local && !DocumentKindDetector.isWebURL(entry.path) && !FileManager.default.fileExists(atPath: entry.path)
    }

    /// - integrationsSession: what the integration clients talk through; tests pass a stubbed session so nothing
    ///   reaches a real service.
    init(launchOptions: AppLaunchOptions, integrationsSession: URLSession = .shared) {
        // A test host or a throwaway run keeps keys in memory: no Keychain prompt, nothing left behind.
        let integrations = IntegrationsModel(store: launchOptions.resetDatabase || launchOptions.isTestHost ? MemoryCredentialStore() : KeychainCredentialStore(), session: integrationsSession)
        self.integrations = integrations
        #if DEBUG
        let updatable = false
        #else
        let updatable = !launchOptions.isTestHost
        #endif
        updates = UpdaterService(enabled: updatable) { [weak integrations] in integrations?.github?.token }
        self.launchOptions = launchOptions
        let database: AppDatabase
        do {
            database = launchOptions.resetDatabase ? try AppDatabase.temporary() : try AppDatabase.open(at: AppDatabase.defaultURL)
        } catch {
            Log.database.fault("Could not open the database: \(error, privacy: .public). Using a temporary one.")
            // Said out loud, not only logged: notes made this session would otherwise vanish at quit unnoticed.
            databaseFailure = "Your notes couldn't be opened (\(error.localizedDescription)). This session keeps notes in a temporary store that is discarded when you quit. The notes database is at \(AppDatabase.defaultURL.path); any backup made before an update is beside it."
            // swiftlint:disable:next force_try
            database = try! AppDatabase.temporary()
        }
        self.database = database
        let store = NoteStore(database: database)
        noteStore = store
        explorer = ExplorerModel(noteStore: store)
        notesPanel = NotesPanelModel(noteStore: store)
        noteLink = NoteLinkModel(noteStore: store)
        settings = SettingsStore(noteStore: store)
        hosts = HostsModel(noteStore: store)
        send = SendCoordinator(noteStore: store, transports: [ClipboardTransport()], stagers: [.local: LocalAttachmentStager()])
        herdrTransport = HerdrTransport(registry: connectionRegistry)
        fileSystems[.local] = LocalFileSystem()
        send.fileSystemProvider = { [weak self] hostID in self?.fileSystems[hostID] }
        // Excerpts come from what is on disk, which is what the agent will read; stored anchors match that text.
        send.openTextProvider = { [weak self] hostID, path in self?.sessions["\(hostID.rawValue):\(path)"]?.baseText }
        send.currentFolder = { [weak self] in self?.agentFolder }
        send.packetResourceProvider = { [weak self] hostID, path, line in
            switch hostID {
            case .github: await self?.pullRequests?.resource(for: path, line: line)
            case .atlassian: await self?.atlassianDocuments?.resource(for: path, line: line)
            default: nil
            }
        }
        send.register(herdrTransport)
        send.register(TmuxTransport(registry: connectionRegistry))
        send.register(OpenCodeTransport(servers: { await OpenCodeServer.discoverLocal() }))
        hooks.installerProvider = { [weak self] hostID in self?.makeHookInstaller(for: hostID) }
        notesPanel.start()
        noteLink.start()
        noteLink.noteStyles = { [weak self] in
            Dictionary((self?.activeSession?.notes ?? []).map { note in
                (note.id, (color: note.color, strength: Theme.strength(for: note.displayState)))
            }, uniquingKeysWith: { first, _ in first })
        }
        hosts.onFileSystemReady = { [weak self] hostID, fileSystem, connection in
            guard let self else { return }
            var fileSystem = fileSystem
            fileSystem.onNonAtomicSave = { [weak self] in
                Task { @MainActor in
                    guard let self, !self.warnedNonAtomic.contains(hostID) else { return }
                    self.warnedNonAtomic.insert(hostID)
                    self.hosts.noteWarning("This host's sftp server lacks posix-rename; saves there replace the file in two steps.", for: hostID)
                }
            }
            let firstRegistration = self.fileSystems[hostID] == nil
            self.fileSystems[hostID] = fileSystem
            self.connections[hostID] = connection
            let alias = self.hosts.entry(for: hostID)?.alias ?? hostID.rawValue
            Task {
                await self.connectionRegistry.register(connection, alias: alias, for: hostID)
                if let tools = try? await connection.tools() {
                    if !tools.home.isEmpty { self.hostHomes[hostID] = tools.home }
                    if tools.herdr { self.herdrHosts.insert(hostID) }
                }
                await self.forwardMCPPort(to: connection, alias: alias)
                if self.followHerdr { self.startFollowing() }
                // The host's agents (#10), once its home and the forwarded MCP address are known.
                if firstRegistration { await self.hooks.refresh(hosts: [hostID], agents: HooksModel.launchCheckedAgents) }
            }
            let stager = RemoteAttachmentStager(hostID: hostID, connection: connection, fileSystem: fileSystem, noteStore: self.noteStore)
            self.send.register(stager: stager, for: hostID)
            // Expired staging directories are swept when the host first comes up and every 24 h after that.
            if firstRegistration {
                self.cleanupTasks[hostID] = Task {
                    while !Task.isCancelled {
                        await stager.cleanupExpired()
                        try? await Task.sleep(for: .seconds(24 * 3600))
                    }
                }
            }
        }
        hosts.onForwardsLost = { [weak self] hostID, lost in
            guard let self else { return }
            for forward in lost {
                if case .localPort(_, let remote) = forward.kind { tunnels[hostID]?[remote] = nil }
            }
            // Pages through those ports get a new tunnel the next time they load (Reload goes through it).
            let proxy = proxy(for: hostID)
            for session in sessions.values where session.hostID == hostID && session.kind == .web {
                session.proxy = proxy
                session.html?.proxy = proxy
            }
        }
        hosts.onDisconnected = { [weak self] hostID in
            guard let self else { return }
            self.connections[hostID] = nil
            self.fileSystems[hostID] = nil
            self.herdrHosts.remove(hostID)
            // The forwards died with the connection; pages through this host start over on the next connect.
            self.tunnels[hostID] = nil
            for session in self.sessions.values where session.hostID == hostID && session.kind == .web {
                session.proxy = WebProxyMap(hostID: hostID)
                session.html?.proxy = WebProxyMap(hostID: hostID)
            }
            self.followTasks[hostID]?.cancel()
            self.followTasks[hostID] = nil
            self.latestFocus[hostID] = nil
            self.cleanupTasks[hostID]?.cancel()
            self.cleanupTasks[hostID] = nil
            Task {
                await self.connectionRegistry.remove(hostID)
                await self.herdrTransport.forget(hostID)
            }
        }
        // Pull requests, tickets and pages are not polled while the app is in the background (a launch that never
        // came to the front included; a test host never pauses, since it is not an app launch).
        if !launchOptions.isTestHost, !NSApplication.shared.isActive { PollGate.shared.isPaused = true }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in PollGate.shared.isPaused = true }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in PollGate.shared.isPaused = false }
        explorer.fileSystemProvider = { [weak self] hostID in self?.fileSystems[hostID] }
        explorer.webURL = { [weak self] hostID, path in self?.webURL(hostID: hostID, path: path) }
        fileSystems[.web] = UnavailableFileSystem(hostID: .web)
        // A page moves the viewer only while it is what the viewer shows: one left running behind another document
        // (a redirect, a refresh, a script) never pulls the reader away.
        browser.onOpenFile = { [weak self] hostID, path, previous in
            guard let self, browserMayMoveViewer(from: previous), let hostID = hostID ?? activeSession?.hostID, hostID != .web else { return }
            openDocument(hostID: hostID, path: path)
            browserOpened = activeSession
        }
        browser.tunnelOwner = { [weak self] local in
            guard let self, let (hostID, _) = tunnels.lazy.compactMap({ host, ports in ports.values.contains(local) ? (host, ()) : nil }).first else { return nil }
            return proxy(for: hostID)
        }
        browser.fileDocument = { [weak self] hostID, path in self?.sessions["\(hostID.rawValue):\(path)"]?.html }
        browser.onDocumentChange = { [weak self] url, via, previous in self?.webDocumentDidChange(url, via: via, previous: previous) }
        browser.onNeedsTunnel = { [weak self] hostID, port in
            guard let self else { throw CancellationError() }
            return try await tunnel(hostID: hostID, port: port)
        }
        explorer.onSelectFile = { [weak self] hostID, path in self?.openDocument(hostID: hostID, path: path) }
        explorer.onTabsChange = { [weak self] in self?.scheduleWorkspaceSave() }
        notesPanel.onGroupsChange = { [weak self, weak explorer] groups in
            explorer?.updateNoteMarks(groups)
            self?.updateDockBadge(groups)
        }
        explorer.onCopied = { [weak self] text in self?.flashCopied(text) }
        explorer.onCreateFileNote = { [weak self] hostID, path, body, color in
            Task { await self?.createWholeFileNote(hostID: hostID, path: path, body: body, color: color) }
        }
        quickOpen.onOpen = { [weak self] hostID, path in self?.openDocument(hostID: hostID, path: path) }
        pullRequestPicker.onOpen = { [weak self] pull in Task { await self?.openPullRequest(pull) } }
        atlassianPicker.onOpen = { [weak self] reference in Task { await self?.openAtlassian(reference) } }
        // Without a key a pasted pull request, issue or page URL is still worth reading: as a web page.
        pullRequestPicker.onOpenWeb = { [weak self] url in self?.openWebPage(url) }
        atlassianPicker.onOpenWeb = { [weak self] url in self?.openWebPage(url) }
    }

    // MARK: Follow mode

    /// Which Herdr server's focus the explorer acts on.
    private enum FollowScope: Equatable {
        /// Herdr has not said which machine it shows: act on every server, as before machines existed.
        case any
        case host(HostID)
        /// Herdr shows a machine this app has no host for.
        case none
    }

    private var followScope: FollowScope {
        switch herdrMachine {
        case nil: .any
        case .local: .host(.local)
        // Herdr names the ssh destination, which is the alias (`github` for a host listed as `github-ssh`).
        case .remote(let target, _): hosts.entries.first { $0.kind == .ssh && $0.alias == target }.map { .host($0.id) } ?? .none
        case .unknown: .none
        }
    }

    private func startFollowing() {
        startWatchingHerdrMachine()
        var hostIDs: [HostID] = [.local]
        hostIDs += connections.keys.sorted { $0.rawValue < $1.rawValue }
        for hostID in hostIDs where followTasks[hostID] == nil {
            followTasks[hostID] = Task { [weak self] in
                guard let self, let socket = await self.herdrTransport.socketPath(for: hostID) else {
                    if hostID == .local { self?.followStatus = "Herdr is not running" }
                    return
                }
                let service = HerdrFollowService(hostID: hostID, socketPath: socket)
                await service.start()
                defer { Task { await service.stop() } }
                self.followStatus = self.followStatus ?? "Following Herdr…"
                for await event in service.events {
                    if Task.isCancelled { return }
                    await self.apply(event)
                }
            }
        }
    }

    /// Herdr's socket API knows nothing about machines, so the client's own state files say which server it shows.
    private func startWatchingHerdrMachine() {
        guard machineWatcherTask == nil else { return }
        machineWatcherTask = Task { [weak self] in
            let watcher = HerdrMachineWatcher()
            await watcher.start()
            defer { Task { await watcher.stop() } }
            for await selection in watcher.events {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.herdrMachineChanged(to: selection)
            }
        }
    }

    /// The Herdr client switched machines: connect the matching host when needed and show its focused pane.
    private func herdrMachineChanged(to selection: HerdrMachineSelection) async {
        // Herdr writes the selection before the endpoint catalogue when a machine is added; an id the catalogue
        // does not know yet keeps the previous scope until the next read instead of dropping events.
        if case .unknown = selection, herdrMachine != nil { return }
        herdrMachine = selection
        followGeneration += 1
        switch followScope {
        case .any:
            return
        case .none:
            if case .remote(let target, let label) = selection {
                followStatus = "Herdr is on \(label), which is not one of this app's hosts (\(target))"
            }
        case .host(let hostID):
            if hostID != .local, fileSystems[hostID] == nil {
                let name = hosts.entry(for: hostID)?.name ?? hostID.rawValue
                pickedHost = hostID
                followStatus = "Connecting to \(name) for Herdr…"
                // The connection callback starts following this host; its first event is the focused pane.
                let generation = followGeneration
                guard await hosts.connect(hostID) != nil else {
                    if followGeneration == generation { followStatus = "Could not connect to \(name) for Herdr" }
                    return
                }
            }
            if let event = latestFocus[hostID] { await apply(event) }
        }
    }

    private func stopFollowing() {
        for task in followTasks.values { task.cancel() }
        followTasks = [:]
        machineWatcherTask?.cancel()
        machineWatcherTask = nil
        herdrMachine = nil
        latestFocus = [:]
        followGeneration += 1
        followStatus = nil
        followedPane = nil
    }

    private func apply(_ event: FollowEvent) async {
        if event.path != nil { latestFocus[event.hostID] = event }
        guard followScope == .any || followScope == .host(event.hostID) else { return }
        // Status changes arrive for every agent pane; the row describes the focused one.
        if let agent = event.agent, event.path != nil || latestFocus[event.hostID]?.paneID == event.paneID {
            let host = event.hostID == .local ? "" : "\(hosts.entry(for: event.hostID)?.name ?? event.hostID.rawValue): "
            followStatus = "\(host)\(agent) \(event.status ?? "") · \(event.paneID)"
            followedPane = FollowedPane(
                host: event.hostID == .local ? nil : (hosts.entry(for: event.hostID)?.name ?? event.hostID.rawValue),
                agent: agent, status: event.status, paneID: event.paneID,
                path: event.path ?? (followedPane?.paneID == event.paneID ? followedPane?.path : nil)
            )
        }
        guard let path = event.path, !path.isEmpty else { return }
        if event.hostID != .local, fileSystems[event.hostID] == nil { return }
        pickedHost = event.hostID
        let generation = followGeneration
        await explorer.openRoot(hostID: event.hostID, path: path)
        // Herdr may have switched machines (or follow mode been turned off) while a remote root was opening;
        // the machine selected now wins, so only its pane becomes the target.
        guard followGeneration == generation, followScope == .any || followScope == .host(event.hostID) else { return }
        pickedHost = event.hostID
        let hostLabel = event.hostID == .local ? nil : hosts.entry(for: event.hostID)?.name
        if let info = event.info, let target = HerdrTransport.target(for: info, hostID: event.hostID, hostLabel: hostLabel) {
            adopt(target: target)
        }
    }

    /// Makes a target the one packets go to, discovering again when the list does not show it yet.
    private func adopt(target: AgentTarget) {
        send.rememberTarget(target)
        if !send.targets.contains(where: { $0.id == target.id }) {
            Task { await send.refreshTargets() }
        }
    }

    /// The user picked a target: remember it, and show the agent's working directory when the target has one. The
    /// folder that ends up in front remembers the choice, so coming back to it comes back to this agent.
    func choose(target: AgentTarget) {
        send.rememberTarget(target)
        guard target.transport == .herdr || target.transport == .tmux, let path = target.detail, path.hasPrefix("/") else {
            Task { await rememberForCurrentFolder(target) }
            return
        }
        // Opening the agent's folder switches tabs; that switch must not hand the folder's older agent back.
        choosingTargetID = target.id
        Task {
            defer { if choosingTargetID == target.id { choosingTargetID = nil } }
            guard await ensureConnected(target.hostID) else { return }
            pickedHost = target.hostID
            await explorer.openRoot(hostID: target.hostID, path: path)
            await rememberForCurrentFolder(target)
        }
    }

    /// A choice being carried out by `choose(target:)`, while it opens the agent's folder.
    @ObservationIgnored private var choosingTargetID: String?

    private func rememberForCurrentFolder(_ target: AgentTarget) async {
        guard let tab = explorer.selectedTab else { return }
        await send.remember(target, forFolder: SendCoordinator.folderKey(hostID: tab.hostID, path: tab.path))
    }

    /// The folder whose agent sends go to: the one in front, except while following Herdr (which pairs folders and
    /// panes itself) or while `choose(target:)` opens the folder of the agent just picked.
    private var agentFolder: (hostID: HostID, path: String)? {
        guard !followHerdr, choosingTargetID == nil, let tab = explorer.selectedTab else { return nil }
        return (tab.hostID, tab.path)
    }

    /// A folder came to the front: switch to the agent last chosen there, or the one working in it.
    func folderBecameCurrent() async {
        await send.folderBecameCurrent()
    }

    func openDocument(hostID: HostID, path: String) {
        if DocumentKindDetector.isWebURL(path), let url = URL(string: path) {
            openWebPage(url, via: hostID == .local || hostID == .web ? nil : hostID)
            return
        }
        let key = "\(hostID.rawValue):\(path)"
        if let existing = sessions[key] {
            activeSession = existing
            trimSessions()
            return
        }
        if hostID == .atlassian, case .confluencePageFolder? = AtlassianPath(path) {
            // A page URL names the page's folder; the document inside it needs the page's title.
            Task { if let reference = AtlassianPath(path) { await openAtlassian(reference) } }
            return
        }
        if hostID == .atlassian, AtlassianPath(path)?.pageID != nil, !canonicalPages.contains(path) {
            // A page is opened at the path the tree shows it today, its notes from earlier paths with it. The
            // result is always marked, so a page that cannot be looked up opens as it is rather than retrying.
            Task {
                let canonical = await canonicalConfluencePath(path)
                openDocument(hostID: .atlassian, path: canonical)
            }
            return
        }
        guard let fileSystem = fileSystems[hostID] else {
            if hostID == .github {
                // No token saved: the picker says where it goes instead of nothing happening.
                presentOpenPullRequest()
                return
            }
            if hostID == .atlassian {
                presentOpenAtlassian()
                return
            }
            Task {
                if await ensureConnected(hostID) { openDocument(hostID: hostID, path: path) }
            }
            return
        }
        let session = DocumentSession(hostID: hostID, path: path, fileSystem: fileSystem, noteStore: noteStore)
        session.openLinkedDocument = { [weak self] target in self?.openDocument(hostID: hostID, path: target) }
        // The deepest open root holding the file bounds what a rendered HTML page may read; looked up per request,
        // since the root can open after the document (launch with --open, a jump from a note).
        let home = hostID == .local ? NSHomeDirectory() : hostHomes[hostID]
        session.resourceRoot = { [weak explorer] in
            // Compare resolved folders: a root opened as `/private/tmp/x` is stored as `/tmp/x`.
            let file = ExplorerModel.canonical(path, hostID: hostID)
            let root = explorer?.tabs.filter { tab in
                let root = ExplorerModel.canonical(tab.path, hostID: hostID)
                return tab.hostID == hostID && file.hasPrefix(root == "/" ? "/" : root + "/")
            }.max { $0.path.count < $1.path.count }?.path
            return Self.boundedResourceRoot(root, documentPath: path, home: home)
        }
        if hostID == .github {
            session.lineChangesProvider = { [weak self] path in await self?.pullRequests?.changes(forPath: path) }
            session.patchOmittedProvider = { [weak self] path in await self?.pullRequests?.patchOmitted(forPath: path) ?? false }
            session.changeSummaryProvider = { [weak self] path in await self?.pullRequests?.changeSummary(for: path) }
        }
        if hostID == .atlassian {
            session.changeSummaryProvider = { [weak self] path in await self?.atlassianDocuments?.changeSummary(for: path) }
        }
        sessions[key] = session
        activeSession = session
        Task { await session.open() }
        trimSessions()
    }

    // MARK: Integration hosts

    /// The keys the integration hosts are serving with, so a change to one service's key leaves the other alone.
    @ObservationIgnored private var registeredGitHub: GitHubCredentials?
    @ObservationIgnored private var registeredAtlassian: AtlassianCredentials?

    /// The GitHub host exists while a token is saved: its provider serves pull requests with that token. A new
    /// token goes into the same provider, so open pull requests carry on; when the token goes, so do the host and
    /// its open documents. Saving one service's key never touches the other's provider.
    /// Registrations run one after another: one that suspends (a provider swapping its key) never lets a later
    /// one (a removal) finish first and then put the host back.
    @ObservationIgnored private(set) var registration: Task<Void, Never>?

    private func scheduleIntegrationRegistration() {
        let previous = registration
        registration = Task { [weak self] in
            await previous?.value
            await self?.registerIntegrationHosts()
        }
    }

    private func registerIntegrationHosts() async {
        let github = integrations.github
        if github != registeredGitHub || fileSystems[.github] == nil {
            await registerGitHub(github)
        }
        let atlassian = integrations.atlassian
        if atlassian != registeredAtlassian || fileSystems[.atlassian] == nil {
            await registerAtlassian(atlassian)
        }
    }

    private func registerGitHub(_ credentials: GitHubCredentials?) async {
        registeredGitHub = credentials
        if credentials != nil, let client = integrations.githubClient {
            if let provider = pullRequests { await provider.replaceClient(client) } else { fileSystems[.github] = GitHubPullRequestFileSystem(client: client) }
        } else {
            fileSystems[.github] = nil
            for (key, session) in sessions where session.hostID == .github {
                retire(session)
                sessions[key] = nil
                if activeSession === session { activeSession = nil }
            }
            for tab in explorer.tabs where tab.hostID == .github { explorer.closeTab(tab.id) }
        }
        await hosts.setVirtualHost(.github, name: "github", kind: .github, enabled: credentials != nil)
    }

    private func registerAtlassian(_ credentials: AtlassianCredentials?) async {
        registeredAtlassian = credentials
        let site = credentials?.site
        let previousSite = atlassianSite.withLock { previous in
            defer { previous = site }
            return previous
        }
        if credentials != nil, let client = integrations.atlassianClient {
            if let provider = atlassianDocuments, previousSite == site { await provider.replaceClient(client) } else { fileSystems[.atlassian] = AtlassianFileSystem(client: client) }
        } else {
            fileSystems[.atlassian] = nil
        }
        // The site the stored documents are about survives relaunches in the host row. Another site's
        // `/jira/CP/CP-7.md` is a different issue: the old site's documents move under `/previous-sites/<host>`
        // with their notes, and its recent roots go, so nothing of it is ever shown as the new site's.
        let row = try? await noteStore.hosts().first { $0.id == .atlassian }
        let storedSite = row?.options?.site
        let sameSite = { (stored: String, site: URL) in URL(string: stored)?.host()?.lowercased() == site.host()?.lowercased() }
        if let site, let storedSite, !sameSite(storedSite, site) {
            let old = URL(string: storedSite)?.host() ?? storedSite
            try? await noteStore.archiveDocuments(hostID: .atlassian, under: "/previous-sites/\(old)")
        }
        if let site, storedSite.map({ !sameSite($0, site) }) ?? true {
            var options = row?.options ?? HostOptions()
            options.site = site.absoluteString
            try? await noteStore.setHostOptions(.atlassian, options)
        }
        if previousSite != nil, site != previousSite {
            canonicalPages = []
            // Another site, or none: the open issues and pages were that site's and their paths mean nothing here.
            for (key, session) in sessions where session.hostID == .atlassian {
                retire(session)
                sessions[key] = nil
                if activeSession === session { activeSession = nil }
            }
            for tab in explorer.tabs where tab.hostID == .atlassian { explorer.closeTab(tab.id) }
        }
        await hosts.setVirtualHost(.atlassian, name: "atlassian", kind: .atlassian, enabled: credentials != nil)
    }

    /// What a rendered page may read: the explorer root holding it, but never a home folder, `/`, or anything
    /// above a home (a root opened on ~ would let a downloaded page read ~/Library and send it anywhere); then
    /// only the page's own folder.
    nonisolated static func boundedResourceRoot(_ root: String?, documentPath: String, home: String?) -> String? {
        guard let root else { return nil }
        let normalized = (root as NSString).standardizingPath
        if normalized == "/" { return (documentPath as NSString).deletingLastPathComponent }
        if let home {
            let base = (home as NSString).standardizingPath
            if normalized == base || base.hasPrefix(normalized + "/") { return (documentPath as NSString).deletingLastPathComponent }
        }
        return root
    }

    /// Confluence page paths known to be where the tree shows the page today.
    @ObservationIgnored private var canonicalPages: Set<String> = []

    /// Where a Confluence page is today (its title and ancestors may have changed since `path` was made), with
    /// the notes made on any earlier path of the same page moved there, so a renamed or moved page keeps them.
    func canonicalConfluencePath(_ path: String) async -> String {
        guard let reference = AtlassianPath(path), let id = reference.pageID, let provider = atlassianDocuments,
              let canonical = await provider.documentPath(for: reference) else {
            // Not resolvable now (no key, offline, a deleted page): open as it is, and never ask again this run.
            canonicalPages.insert(path)
            return path
        }
        let earlier = ((try? await noteStore.documentsWithNotes()) ?? []).map(\.document).filter { document in
            document.hostID == .atlassian && document.path != canonical && AtlassianPath(document.path)?.pageID == id
        }
        for document in earlier {
            try? await noteStore.relocateDocument(hostID: .atlassian, from: document.path, to: canonical)
        }
        canonicalPages.insert(canonical)
        return canonical
    }

    /// The web address of a path on an integration host: a pull request (or its changed file), a Jira issue or a
    /// Confluence page; nil for anything else.
    func webURL(hostID: HostID, path: String) -> URL? {
        switch hostID {
        case .github:
            guard let pull = PullRequestPath(path) else { return nil }
            return pull.webURL
        case .atlassian:
            guard let site = integrations.atlassian?.site else { return nil }
            switch AtlassianPath(path) {
            case .jiraIssue(_, let key)?: return site.appendingPathComponent("browse/\(key)")
            case .jiraProject(let project)?: return site.appendingPathComponent("browse/\(project)")
            case .confluenceSpace(let space)?: return site.appendingPathComponent("wiki/spaces/\(space)")
            case let reference?: return reference.pageID.map { site.appendingPathComponent("wiki/spaces/\(Self.space(of: reference))/pages/\($0)") }
            case nil: return nil
            }
        default:
            return nil
        }
    }

    private nonisolated static func space(of reference: AtlassianPath) -> String {
        switch reference {
        case .confluencePageFolder(let space, _, _), .confluencePage(let space, _, _, _): space
        default: ""
        }
    }

    /// The Atlassian provider, for what the viewer asks beyond files.
    var atlassianDocuments: AtlassianFileSystem? { fileSystems[.atlassian] as? AtlassianFileSystem }

    func presentOpenAtlassian(_ product: AtlassianPickerModel.Product? = nil) {
        atlassianPicker.present(client: integrations.atlassianClient, product: product)
    }

    /// Opens an issue (its project as the root), a space, or a page (its space as the root) from a reference.
    func openAtlassian(_ reference: AtlassianPath, line: Int? = nil) async {
        guard let provider = atlassianDocuments else {
            presentOpenAtlassian()
            return
        }
        pickedHost = .atlassian
        switch reference {
        case .jiraIssue(let project, _):
            await explorer.openRoot(hostID: .atlassian, path: AtlassianPath.jiraProject(project).path)
            if let line { openDocument(hostID: .atlassian, path: reference.path, line: line) } else { openDocument(hostID: .atlassian, path: reference.path) }
        case .jiraProject, .confluenceSpace:
            await explorer.openRoot(hostID: .atlassian, path: reference.path)
        case .confluencePageFolder(let space, _, _), .confluencePage(let space, _, _, _):
            await explorer.openRoot(hostID: .atlassian, path: AtlassianPath.confluenceSpace(space).path)
            var document = await canonicalConfluencePath(reference.path)
            if case .confluencePage? = AtlassianPath(document) {} else {
                // A page URL whose place could not be read: open the page at the top of its space, moving nothing.
                guard let unplaced = await provider.documentPath(for: reference, allowUnplaced: true) else { return }
                document = unplaced
                canonicalPages.insert(unplaced)
            }
            if let line { openDocument(hostID: .atlassian, path: document, line: line) } else { openDocument(hostID: .atlassian, path: document) }
        default:
            break
        }
    }

    /// The PR provider, for what the viewer asks beyond files (changed lines, the packet's resource).
    var pullRequests: GitHubPullRequestFileSystem? { fileSystems[.github] as? GitHubPullRequestFileSystem }

    func presentOpenPullRequest() {
        pullRequestPicker.present(client: integrations.githubClient, login: integrations.githubLogin)
    }

    /// Opens a pull request as a root and shows its description (or the named changed file).
    func openPullRequest(_ pull: PullRequestPath, line: Int? = nil) async {
        guard fileSystems[.github] != nil else {
            presentOpenPullRequest()
            return
        }
        pickedHost = .github
        await explorer.openRoot(hostID: .github, path: pull.root)
        let document = pull.isRoot ? pull.root + "/" + PullRequestPath.descriptionName : pull.path
        if let line { openDocument(hostID: .github, path: document, line: line) } else { openDocument(hostID: .github, path: document) }
    }

    /// A GitHub pull request URL as the host and path the app opens it under; nil for any other URL.
    nonisolated static func resolveResourceURL(_ url: URL) -> (host: String, path: String)? {
        guard let pull = PullRequestPath.parse(reference: url.absoluteString) else { return nil }
        return ("github", pull.isRoot ? pull.root + "/" + PullRequestPath.descriptionName : pull.path)
    }

    /// The saved Atlassian site, readable off the main actor by the MCP server's URL resolver.
    nonisolated private let atlassianSite = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// A pull request, issue or page URL as the host and path it opens under: Atlassian URLs count only for the
    /// saved site. A Confluence page resolves to its folder; opening it finds the page's document.
    nonisolated func resolveURL(_ url: URL) -> (host: String, path: String)? {
        if let github = Self.resolveResourceURL(url) { return github }
        guard let site = atlassianSite.withLock({ $0 }), let reference = AtlassianPath.parse(reference: url.absoluteString, site: site) else { return nil }
        switch reference {
        case .jiraIssue, .confluencePageFolder, .confluencePage: return ("atlassian", reference.path)
        default: return nil
        }
    }

    // MARK: Web pages

    /// Shows a live page as a document: on the web host, or on an ssh host when `via` names one, in which case
    /// loopback addresses reach that host through tunnels on its connection and the document belongs to it (so a
    /// packet's `File:` line is right where the agent runs).
    func openWebPage(_ url: URL, via: HostID? = nil) {
        let hostID = via ?? .web
        let path = WebDocumentKey.normalize(url)
        let key = "\(hostID.rawValue):\(path)"
        if let existing = sessions[key] {
            activeSession = existing
            trimSessions()
            return
        }
        guard let fileSystem = fileSystems[hostID] else {
            Task { if await ensureConnected(hostID) { openWebPage(url, via: via) } }
            return
        }
        let session = DocumentSession(hostID: hostID, path: path, fileSystem: fileSystem, noteStore: noteStore)
        if let via { session.proxy = proxy(for: via) }
        sessions[key] = session
        activeSession = session
        Task { await session.open() }
        trimSessions()
    }

    /// The browser moved to another page by itself (a link, Back, a route change): that page becomes the document,
    /// when the browser is what the viewer shows. A page that redirects itself while another document is in front
    /// must not pull the viewer away from it. A page on the host's loopback stays on that host; an outside page
    /// reached from it is the open web's.
    private func webDocumentDidChange(_ url: URL, via: HostID?, previous: HTMLViewerController?) {
        guard browserMayMoveViewer(from: previous) else { return }
        openWebPage(url, via: via)
        browserOpened = activeSession
    }

    /// The document the browser itself last moved the viewer to; while it is still opening (no page attached yet)
    /// a redirect or a click on the page that led there may move the viewer on again.
    @ObservationIgnored private weak var browserOpened: DocumentSession?

    /// Whether the page the browser just left was what the viewer showed, or the viewer shows a document the
    /// browser opened that has not attached yet. A page left running behind another document never moves it.
    private func browserMayMoveViewer(from previous: HTMLViewerController?) -> Bool {
        guard let active = activeSession else { return false }
        if let previous, active.html === previous { return true }
        return active === browserOpened && (active.html == nil || active.html === browser.released)
    }

    /// Loopback ports forwarded from each ssh host: remote port → local port, for the pages opened through it.
    @ObservationIgnored private var tunnels: [HostID: [UInt16: UInt16]] = [:]

    /// The tunnels known for a host, shared by every page opened through it.
    private func proxy(for hostID: HostID) -> WebProxyMap {
        WebProxyMap(hostID: hostID, tunnels: tunnels[hostID] ?? [:])
    }

    /// Forwards `port` on `hostID`'s loopback to a port here, on the host's existing connection, and tells every
    /// page open through that host about it.
    func tunnel(hostID: HostID, port: UInt16) async throws -> UInt16 {
        if let local = tunnels[hostID]?[port] { return local }
        guard await ensureConnected(hostID), let connection = connections[hostID] else { throw FileSystemError.io("not connected") }
        let forward = try await connection.forwardLocalPort(toRemotePort: port)
        guard case .localPort(let local, _) = forward.kind else { throw FileSystemError.io("unexpected forward") }
        tunnels[hostID, default: [:]][port] = local
        let proxy = proxy(for: hostID)
        for session in sessions.values where session.hostID == hostID && session.kind == .web {
            session.proxy = proxy
            session.html?.proxy = proxy
        }
        return local
    }

    var isOpenLocationPresented = false

    func presentOpenLocation() {
        isOpenLocationPresented = true
    }

    var isReportPresented = false

    func presentReport() {
        isReportPresented = true
    }

    /// Keeps a handful of recent clean sessions open; closes the rest so watchers and observations do not pile up.
    static let maximumOpenSessions = 8
    @ObservationIgnored private var activationOrder: [String] = []

    private func trimSessions() {
        if let active = activeSession {
            activationOrder.removeAll { $0 == active.id }
            activationOrder.append(active.id)
        }
        while sessions.count > Self.maximumOpenSessions {
            guard let victim = activationOrder.first(where: { id in sessions[id].map { $0 !== activeSession && !$0.isDirty } ?? false }) else { break }
            activationOrder.removeAll { $0 == victim }
            if let session = sessions[victim] { retire(session) }
            sessions[victim] = nil
        }
    }

    /// Opens a document and scrolls its text view to a 1-based line once it has loaded.
    /// Opens at a line: selected for a jump (a link, an agent pointing somewhere), or just the caret at its start
    /// when resuming, so the reopened file doesn't greet you with a selection and an Add Note button.
    func openDocument(hostID: HostID, path: String, line: Int, endLine: Int? = nil, select: Bool = true) {
        if hostID == .atlassian, let reference = AtlassianPath(path), reference.pageID != nil, !canonicalPages.contains(path) {
            // A page URL names the page's folder, and a page path may be from before a rename or a move: the
            // document opens at today's path once that is known.
            Task { await openAtlassian(reference, line: line) }
            return
        }
        openDocument(hostID: hostID, path: path)
        guard let session = sessions["\(hostID.rawValue):\(path)"] else { return }
        Task {
            for _ in 0..<50 where session.textController == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard let controller = session.textController else { return }
            let first = controller.lineIndex.contentRange(ofLine: line)
            let last = controller.lineIndex.contentRange(ofLine: max(line, endLine ?? line))
            let lines = NSRange(location: first.location, length: last.location + last.length - first.location)
            let range = select ? lines : NSRange(location: first.location, length: 0)
            // A jump shows its lines; resuming puts the line where reading stopped back at the top.
            if let markdown = session.markdown {
                markdown.scroll(toSource: range, select: select, atTop: !select)
            } else if let rendered = session.rendered {
                rendered.scroll(toSource: range, select: select)
            } else {
                controller.scroll(to: range, select: select, atTop: !select)
            }
        }
    }

    /// Connects a remote host when its file system is not registered yet.
    func ensureConnected(_ hostID: HostID) async -> Bool {
        if fileSystems[hostID] != nil { return true }
        return await hosts.connect(hostID) != nil
    }

    /// Clears attachment files nothing references, off the main actor. Only with the real database: a throwaway
    /// one (`--reset-db`) has no notes, and the files on disk belong to the real one.
    private func sweepAttachments() {
        guard !launchOptions.resetDatabase else { return }
        let store = noteStore
        let expiry = TimeInterval(settings.stagedFileExpiryDays) * 24 * 3600
        Task.detached(priority: .background) {
            guard let referenced = try? await store.allAttachmentPaths() else { return }
            let removed = AttachmentCache.sweep(referenced: referenced, stagedExpiry: expiry)
            if removed.noteFiles + removed.sendFolders > 0 {
                Log.notes.info("swept \(removed.noteFiles) unreferenced note attachments and \(removed.sendFolders) expired send folders")
            }
        }
    }

    /// Open Quickly over the selected root, on whichever host it belongs to.
    /// A pull request, a Jira project or a Confluence space: browsed, not searched (its files are not on a disk
    /// that ssh or rg can reach).
    var selectedRootIsVirtual: Bool { explorer.selectedTab?.hostID.isVirtual ?? false }

    func presentQuickOpen() {
        guard let tab = explorer.selectedTab, !tab.hostID.isVirtual else { return }
        guard tab.hostID != .local else {
            quickOpen.present(root: tab.path, hostID: .local, connection: nil)
            return
        }
        // A remote root's host may have dropped since the tab opened: reconnect rather than list this Mac.
        Task {
            _ = await ensureConnected(tab.hostID)
            quickOpen.present(root: tab.path, hostID: tab.hostID, connection: connections[tab.hostID])
        }
    }

    /// Find in Files over the selected root, reconnecting a remote host first; never searches this Mac for a
    /// remote root.
    func runContentSearch() {
        guard let tab = explorer.selectedTab, !tab.hostID.isVirtual else { return }
        let search = explorer.contentSearch
        guard tab.hostID != .local else {
            search.search(in: tab.path)
            return
        }
        Task {
            guard await ensureConnected(tab.hostID), let connection = connections[tab.hostID] else {
                search.fail("Not connected to this folder's host")
                return
            }
            search.search(in: tab.path, connection: connection)
        }
    }

    /// Shows the open document in the explorer, opening its folder as a root when no root contains it.
    func revealActiveDocumentInExplorer() {
        guard let session = activeSession, session.kind != .web else { return }
        Task {
            if await !explorer.reveal(hostID: session.hostID, path: session.path) {
                await openRootIfNeeded(hostID: session.hostID, containing: session.path)
                await explorer.reveal(hostID: session.hostID, path: session.path)
            }
            pickedHost = session.hostID
        }
    }

    /// Makes sure a root containing `path` is open, opening the parent directory when none is (a pull request's
    /// documents open their pull request).
    func openRootIfNeeded(hostID: HostID, containing path: String) async {
        // A web page has no folder to open.
        guard !DocumentKindDetector.isWebURL(path) else { return }
        guard await ensureConnected(hostID) else { return }
        if explorer.tabs.contains(where: { $0.hostID == hostID && ExplorerModel.inRootSpelling(path, root: $0.path, hostID: hostID) != nil }) { return }
        if hostID == .github, let pull = PullRequestPath(path) {
            await explorer.openRoot(hostID: hostID, path: pull.root)
            return
        }
        if hostID == .atlassian, let reference = AtlassianPath(path) {
            switch reference {
            case .jiraIssue(let project, _), .jiraAttachments(let project, _), .jiraAttachment(let project, _, _):
                await explorer.openRoot(hostID: hostID, path: AtlassianPath.jiraProject(project).path)
            case .confluencePage(let space, _, _, _), .confluencePageFolder(let space, _, _), .confluenceAttachments(let space, _, _), .confluenceAttachment(let space, _, _, _):
                await explorer.openRoot(hostID: hostID, path: AtlassianPath.confluenceSpace(space).path)
            default: break
            }
            return
        }
        await explorer.openRoot(hostID: hostID, path: PathUtilities.parent(of: path))
    }

    // MARK: Agent control (issue #4)

    /// Shows the main window above the agent's terminal without taking the keyboard from it: the agent asked to
    /// show the user something, not to move their typing.
    func bringForwardForAgent() {
        guard let window = mainWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
    }

    private func hostID(named name: String) async throws -> HostID {
        if name == "local" { return .local }
        guard let id = try await noteStore.hosts().first(where: { $0.name == name })?.id else { throw DeliveryError.failed("unknown host \(name)") }
        return id
    }

    /// `add_favorite`: pins the folder in the explorer and opens it. False when it already was a favorite.
    func addFavorite(host: String, path: String) async throws -> Bool {
        let hostID = try await hostID(named: host)
        guard await ensureConnected(hostID), let fileSystem = fileSystems[hostID] else { throw DeliveryError.failed("couldn't connect to \(host)") }
        guard (try await fileSystem.stat(path)).kind == .directory else { throw DeliveryError.failed("\(path) is not a folder") }
        let root = try await noteStore.recordRootOpened(hostID: hostID, path: path)
        let added = !explorer.isPinned(hostID: hostID, path: path)
        if added { await explorer.setPinned(root.id, hostID: hostID, path: path, true) }
        await explorer.openRoot(hostID: hostID, path: path)
        return added
    }

    /// `ask_user`: an agent's question about a place in a file becomes a note asking for the user, on the exact
    /// text when it is found (nearest the given line), else on the lines, else on the whole file. The document
    /// opens to it unless the user is in the middle of writing a note; either way it waits under Attention.
    func ask(_ question: AgentQuestion) async throws -> NoteID {
        let hostID = try await hostID(named: question.host)
        guard await ensureConnected(hostID), let fileSystem = fileSystems[hostID] else { throw DeliveryError.failed("couldn't connect to \(question.host)") }
        let attributes = try await fileSystem.stat(question.path)
        guard attributes.kind == .file else { throw DeliveryError.failed("\(question.path) is not a file") }
        var anchor = Anchor.wholeFile
        if question.line != nil || question.text != nil, attributes.size <= DocumentSession.refuseThreshold {
            let data = try await fileSystem.read(question.path)
            if let text = String(data: data, encoding: .utf8) {
                let index = LineIndex(text)
                var range: NSRange?
                if let quoted = question.text {
                    range = Self.occurrence(of: quoted, in: text, index: index, nearLine: question.line)
                }
                if range == nil, let line = question.line {
                    let first = index.contentRange(ofLine: line)
                    let last = index.contentRange(ofLine: max(line, question.endLine ?? line))
                    range = NSRange(location: first.location, length: last.location + last.length - first.location)
                }
                if let range { anchor = .text(ReAnchorer.make(from: range, in: text, index: index, hash: data.sha256Hex)) }
            }
        }
        let document = try await noteStore.upsertDocument(hostID: hostID, path: question.path, kind: DocumentKindDetector.kind(forPath: question.path), fingerprint: attributes.fingerprint)
        let note = try await noteStore.askUser(documentID: document.id, anchor: anchor, question: question.question, author: question.agent)
        if activeSession?.noteEditor == nil {
            await openRootIfNeeded(hostID: hostID, containing: question.path)
            showNotesPanel = true
            // Shown, not selected: a selection would offer Add Note over the agent's question.
            reveal(note: note, in: document, select: false)
            bringForwardForAgent()
        }
        return note.id
    }

    /// Where `needle` occurs in `text`, nearest `line` when it occurs more than once.
    nonisolated static func occurrence(of needle: String, in text: String, index: LineIndex, nearLine line: Int?) -> NSRange? {
        let ns = text as NSString
        var found: [NSRange] = []
        var from = 0
        while from < ns.length {
            let range = ns.range(of: needle, options: [.literal], range: NSRange(location: from, length: ns.length - from))
            guard range.location != NSNotFound else { break }
            found.append(range)
            from = range.location + max(1, range.length)
        }
        guard let line else { return found.first }
        return found.min { abs(index.position(forUTF16Offset: $0.location).line - line) < abs(index.position(forUTF16Offset: $1.location).line - line) }
    }

    /// Creates a note from a URL or plugin: on `line` of the file, or on the whole file.
    func createNote(hostID: HostID, path: String, line: Int?, body: String, color: NoteColor = .yellow) async {
        guard await ensureConnected(hostID), let fileSystem = fileSystems[hostID] else { return }
        do {
            var anchor = Anchor.wholeFile
            let size = (try? await fileSystem.stat(path))?.size ?? 0
            // The viewer refuses files above this size; downloading one just to place a line anchor would be worse.
            if let line, size <= DocumentSession.refuseThreshold, let data = try? await fileSystem.read(path), let text = String(data: data, encoding: .utf8) {
                let index = LineIndex(text)
                let range = index.contentRange(ofLine: line)
                anchor = .text(ReAnchorer.make(from: range, in: text, index: index, hash: data.sha256Hex))
            }
            let kind = DocumentKindDetector.kind(forPath: path)
            let fingerprint = (try? await fileSystem.stat(path))?.fingerprint ?? Fingerprint()
            let document = try await noteStore.upsertDocument(hostID: hostID, path: path, kind: kind, fingerprint: fingerprint)
            _ = try await noteStore.createNote(documentID: document.id, anchor: anchor, body: body, color: color)
            showNotesPanel = true
        } catch {
            Log.notes.error("URL note failed: \(error, privacy: .public)")
        }
    }

    /// Open documents with edits not written to disk, most recently used first.
    var unsavedSessions: [DocumentSession] {
        sessions.values.filter(\.isDirty).sorted { lhs, rhs in
            (activationOrder.lastIndex(of: lhs.id) ?? -1) > (activationOrder.lastIndex(of: rhs.id) ?? -1)
        }
    }

    /// Whether any document is writing to disk right now.
    var isSavingAnything: Bool { sessions.values.contains(where: \.isSaving) }

    /// Saves every unsaved document and returns those still unsaved afterwards (a failed write, or a conflict
    /// with a newer version on disk, which then waits in its conflict sheet).
    func saveAll() async -> [DocumentSession] {
        for session in unsavedSessions { await session.save() }
        return unsavedSessions
    }

    /// Ends a session; a page it showed stops running in the shared web view, and a tunnel no other open page
    /// uses is closed.
    private func retire(_ session: DocumentSession) {
        if let html = session.html, browser.current === html || browser.released === html { browser.unload() }
        session.close()
        releaseTunnel(of: session)
    }

    private func releaseTunnel(of session: DocumentSession) {
        guard session.kind == .web, let url = session.webURL, let port = WebProxyMap.loopbackPort(of: url),
              tunnels[session.hostID]?[port] != nil else { return }
        let stillUsed = sessions.values.contains { other in
            other !== session && other.hostID == session.hostID && other.kind == .web && other.webURL.flatMap(WebProxyMap.loopbackPort(of:)) == port
        }
        guard !stillUsed else { return }
        let hostID = session.hostID
        tunnels[hostID]?[port] = nil
        let proxy = proxy(for: hostID)
        for other in sessions.values where other !== session && other.hostID == hostID && other.kind == .web {
            other.proxy = proxy
            other.html?.proxy = proxy
        }
        if let connection = connections[hostID] { Task { await connection.cancelLocalPort(remotePort: port) } }
    }

    func closeDocument(_ session: DocumentSession) {
        retire(session)
        sessions[session.id] = nil
        if activeSession === session { activeSession = sessions.values.first }
    }

    func fileSystem(for hostID: HostID) -> (any FileSystemProvider)? {
        fileSystems[hostID]
    }

    @ObservationIgnored private var started = false

    /// The tab Settings opens on; the update toast sends it to Agents.
    var settingsTab = SettingsTab.general

    @ObservationIgnored private var escapeMonitor: Any?

    /// Escape dismisses the Add Note button (and an open composer) from wherever the keyboard is in the main window.
    /// The viewers' own views don't see it reliably: NSTextView takes Escape for word completion and PDFView and the
    /// web view ignore it. A field editor (a search or filter field) keeps its own Escape.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard event.keyCode == 53, modifiers.isEmpty else { return event }
            let handled = MainActor.assumeIsolated { self?.handleEscape(in: event.window) ?? false }
            return handled ? nil : event
        }
    }

    func handleEscape(in window: NSWindow?) -> Bool {
        guard let window, window === mainWindow, window.attachedSheet == nil else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return false }
        // A note being written or edited in a card cancels itself.
        if window.firstResponder is NoteBodyEditor.SubmitTextView { return false }
        return activeSession?.dismissNoteAffordance() ?? false
    }

    /// Applies `--root` and `--open`, or reopens what was open (as Settings › General says). Runs once even if
    /// several windows appear.
    func start() async {
        guard !started, !launchOptions.isTestHost else { return }
        started = true
        installEscapeMonitor()
        await settings.load()
        send.stagedFileExpiryDays = settings.stagedFileExpiryDays
        settings.onStagedExpiryChange = { [weak self] days in self?.send.stagedFileExpiryDays = days }
        settings.onDockSettingChange = { [weak self] in self?.updateDockBadge() }
        updateDockBadge()
        sweepAttachments()
        await hosts.load()
        // The token note links must carry exists before the Herdr plugin first reads it.
        if !launchOptions.isTestHost { _ = URLRouter.token() }
        // Set before anything can save a key, so no save is missed; registrations are queued and only act on what
        // changed, so the explicit one below adds nothing but waiting for them.
        integrations.onChange = { [weak self] in self?.scheduleIntegrationRegistration() }
        #if DEBUG
        if let path = launchOptions.integrationsEnv {
            await integrations.importEnvironmentFile(at: path, atlassianSite: launchOptions.atlassianSite)
        }
        #endif
        await integrations.load()
        // After the keys are loaded: a check due at launch must find the GitHub key.
        updates.start()
        scheduleIntegrationRegistration()
        await registration?.value
        explorer.showDotfiles = settings.showDotfilesByDefault
        // Before folders open: a restore can wait on a host or a document, and agents shouldn't wait with it.
        await startMCPServer()
        // Agents are found while folders open; the folder in front picks its agent once they are.
        Task { [weak self] in await self?.send.refreshTargets() }
        // An agent whose set-up an update changed (#10) is found at launch, not only when Settings opens; after the
        // MCP server is up, so the address it is checked against is the real one.
        Task { [weak self] in await self?.hooks.refresh(hosts: [.local], agents: HooksModel.launchCheckedAgents) }
        // `--host` takes an ssh alias; a listed name is accepted too.
        let launchHost = launchOptions.host == "local" ? HostID.local
            : (hosts.entries.first { $0.kind == .ssh && $0.alias == launchOptions.host } ?? hosts.entries.first { $0.name == launchOptions.host })?.id
        if let launchHost, launchHost != .local {
            // `--host <alias>` connects first; `--root` names a directory there, else the home directory.
            await openRemoteRoot(hostID: launchHost, path: launchOptions.root)
        } else if let root = launchOptions.root {
            await explorer.openRoot(hostID: .local, path: root)
        } else {
            switch settings.launchRestore.resolved() {
            case .everything: await restoreSavedWorkspace()
            case .lastFolder: await reopenMostRecentRoot()
            case .nothing, .system: break
            }
        }
        if let open = launchOptions.open {
            openDocument(hostID: .local, path: open)
        }
        if launchOptions.follow { followHerdr = true }
        await folderBecameCurrent()
    }

    /// The root opened most recently on any host; a remote one connects the host first (the agent prompt may show).
    /// Questions back from agents, on the Dock icon: the app often sits behind the agent's terminal, and a note
    /// waiting on an answer should be visible from there, as unread mail is.
    func updateDockBadge(_ groups: [DocumentNotes]? = nil) {
        let groups = groups ?? notesPanel.groups
        let waiting = settings.showsQuestionsOnDock
            ? groups.reduce(0) { $0 + $1.notes.filter { $0.state == .resolved && $0.resolveOutcome == .needsInput }.count }
            : 0
        NSApp.dockTile.badgeLabel = waiting > 0 ? String(waiting) : nil
    }

    /// The document in front changed: the next launch reopens it with its folder.
    private func rememberLastDocument() {
        guard !isShutDown else { return }
        scheduleWorkspaceSave()
    }

    @ObservationIgnored private var workspaceSave: Task<Void, Never>?
    /// Set while a launch restores the workspace, so its half-built state isn't saved over the whole one.
    @ObservationIgnored private var isRestoringWorkspace = false

    /// Saves what's open shortly after it changes (a crash still finds it); the quit saves it once more with the caret.
    func scheduleWorkspaceSave() {
        guard started, !isRestoringWorkspace, !isShutDown else { return }
        workspaceSave?.cancel()
        workspaceSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, !isShutDown else { return }
            await saveWorkspace()
        }
    }

    private func saveWorkspace() async {
        guard let value = currentWorkspace().encoded() else { return }
        try? await noteStore.setSetting(Workspace.key, value)
    }

    /// What is open now (#9).
    func currentWorkspace() -> Workspace {
        var workspace = Workspace()
        workspace.folders = explorer.tabs.map { Workspace.Place(host: $0.hostID.rawValue, path: $0.path) }
        workspace.selectedFolder = explorer.tabs.firstIndex { $0.id == explorer.selectedTabID }
        if let session = activeSession {
            workspace.document = Workspace.Document(place: Workspace.Place(host: session.hostID.rawValue, path: session.path),
                                                    line: caretLine(of: session), showsSource: session.markdown.map { $0.mode == .source })
        }
        workspace.back = history.back.map(Workspace.Place.init)
        workspace.forward = history.forward.map(Workspace.Place.init)
        workspace.showsNotesPanel = showNotesPanel
        return workspace
    }

    /// The line at the top of the view, so the next launch lands where reading stopped; the caret's line when the
    /// view can't say (a web page's source, a view not on screen).
    private func caretLine(of session: DocumentSession) -> Int? {
        guard let controller = session.textController else { return nil }
        if let top = session.markdown.map({ $0.topVisibleSourceLocation }) ?? (session.html == nil ? controller.topVisibleLocation : nil) {
            return controller.lineIndex.position(forUTF16Offset: top).line
        }
        // Reading rendered markdown moves the rendered selection, not the source caret: map it back to the source.
        var location = controller.selection.location
        if let markdown = session.markdown, markdown.mode == .rendered, let mapping = markdown.renderedSelectionMapping {
            location = mapping.source.location
        }
        return controller.lineIndex.position(forUTF16Offset: location).line
    }

    /// The workspace saved at the last quit, or the document setting from before #9.
    private func savedWorkspace() async -> Workspace? {
        if let value = try? await noteStore.setting(Workspace.key) { return Workspace.decoded(value) }
        return (try? await noteStore.setting("general.lastDocument")).flatMap(Workspace.fromLastDocument)
    }

    /// Reopens everything that was open at the last quit; with nothing saved, the most recent folder.
    private func restoreSavedWorkspace() async {
        guard let workspace = await savedWorkspace(), !workspace.folders.isEmpty else { return await reopenMostRecentRoot() }
        await restore(workspace)
    }

    /// Opens the workspace's folders in order, on hosts that are still there (a remote host that won't connect is
    /// passed over, as is a missing local folder), then its history and the document in front, where it was.
    func restore(_ workspace: Workspace) async {
        isRestoringWorkspace = true
        defer {
            isRestoringWorkspace = false
            // Whatever changed while restoring (the user didn't wait) is saved now.
            scheduleWorkspaceSave()
        }
        showNotesPanel = workspace.showsNotesPanel
        var opened: [Int: RootID] = [:]
        for (index, folder) in workspace.folders.enumerated() {
            let hostID = folder.hostID
            if hostID == .local {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                await explorer.openRoot(hostID: .local, path: folder.path)
            } else if hostID.isVirtual {
                guard fileSystems[hostID] != nil else { continue }
                await explorer.openRoot(hostID: hostID, path: folder.path)
            } else {
                guard hosts.entries.contains(where: { $0.id == hostID }) else { continue }
                await openRemoteRoot(hostID: hostID, path: folder.path)
            }
            let key = ExplorerModel.markKey(hostID, folder.path)
            if let tab = explorer.tabs.first(where: { ExplorerModel.markKey($0.hostID, $0.path) == key }) { opened[index] = tab.id }
        }
        if let selected = workspace.selectedFolder, let id = opened[selected] { explorer.selectedTabID = id }
        history = DocumentHistory(back: workspace.back.map(\.entry), current: workspace.document?.place.entry, forward: workspace.forward.map(\.entry))
        guard let document = workspace.document else { return }
        let place = document.place
        // Only from a host that is there now: a failed connection must not be retried for the document.
        guard place.hostID == .local ? !Self.isGone(place.entry) : fileSystems[place.hostID] != nil else { return }
        openDocument(hostID: place.hostID, path: place.path)
        guard let session = sessions["\(place.hostID.rawValue):\(place.path)"] else {
            // A page opening at today's path (Atlassian) goes the way a link to it does.
            if let line = document.line, line > 1 { openDocument(hostID: place.hostID, path: place.path, line: line, select: false) }
            return
        }
        // Source or rendered first, then the line: the rendered view keeps its own caret.
        // Until it has loaded: a picture, PDF or spreadsheet never gets a text view, and nothing waits on one.
        for _ in 0..<100 { if case .loading = session.state { try? await Task.sleep(for: .milliseconds(50)) } else { break } }
        guard session.textController != nil else { return }
        if document.showsSource == true, session.markdown?.mode == .rendered { session.toggleMarkdownMode() }
        if let line = document.line, line > 1 { openDocument(hostID: place.hostID, path: place.path, line: line, select: false) }
    }

    /// Reopens the document that was in front last time, when it lives in `root` (and, on this Mac, still exists).
    private func reopenLastDocument(in root: Root) async {
        guard let document = await savedWorkspace()?.document else { return }
        let place = document.place
        guard place.hostID == root.hostID, ExplorerModel.inRootSpelling(place.path, root: root.path, hostID: root.hostID) != nil else { return }
        if root.hostID == .local, !FileManager.default.fileExists(atPath: place.path) { return }
        if let line = document.line, line > 1 {
            openDocument(hostID: root.hostID, path: place.path, line: line, select: false)
        } else {
            openDocument(hostID: root.hostID, path: place.path)
        }
    }

    private func reopenMostRecentRoot() async {
        let hosts = (try? await noteStore.hosts()) ?? []
        var roots: [Root] = []
        for host in hosts { roots += (try? await noteStore.roots(for: host.id)) ?? [] }
        // The most recent root whose host is there: a pull request or ticket whose key was removed since is
        // passed over for the next one, rather than opening nothing.
        let usable = roots.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.first { !$0.hostID.isVirtual || fileSystems[$0.hostID] != nil }
        guard let best = usable else { return }
        if best.hostID == .local {
            await explorer.openRoot(hostID: .local, path: best.path)
        } else if best.hostID.isVirtual {
            await explorer.openRoot(hostID: best.hostID, path: best.path)
        } else {
            await openRemoteRoot(hostID: best.hostID, path: best.path)
        }
        // Only into a folder that actually opened: a failed connection must not be retried for the document.
        guard explorer.tabs.contains(where: { ExplorerModel.markKey($0.hostID, $0.path) == ExplorerModel.markKey(best.hostID, best.path) }) else { return }
        await reopenLastDocument(in: best)
    }

    // MARK: MCP

    private func startMCPServer() async {
        let store = noteStore
        let send = send
        var dependencies = MCPDependencies(
            noteStore: store,
            packet: { ids in try await send.packet(noteIDs: ids) },
            createDraft: { host, path, cwd, text in
                let hostID = host == "local" ? HostID.local : try await store.hosts().first { $0.name == host }?.id
                guard let hostID else { throw DeliveryError.failed("unknown host \(host)") }
                guard let documentPath = path ?? cwd.map({ PathUtilities.join($0, ".gloss-inbox.md") }) else {
                    throw DeliveryError.failed("path or cwd is required")
                }
                return try await AppModel.createPluginDraft(store: store, hostID: hostID, path: documentPath, text: text)
            },
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
        dependencies.resolveURL = { [weak self] url in self?.resolveURL(url) }
        dependencies.openDocument = { [weak self] host, path, line, endLine in
            let hostID = host == "local" ? HostID.local : try await store.hosts().first { $0.name == host }?.id
            guard let hostID else { throw DeliveryError.failed("unknown host \(host)") }
            await MainActor.run {
                guard let self else { return }
                Task {
                    await self.openRootIfNeeded(hostID: hostID, containing: path)
                    if let line { self.openDocument(hostID: hostID, path: path, line: line, endLine: endLine) } else { self.openDocument(hostID: hostID, path: path) }
                    self.bringForwardForAgent()
                }
            }
        }
        dependencies.addFavorite = { [weak self] host, path in
            guard let self else { return false }
            return try await self.addFavorite(host: host, path: path)
        }
        dependencies.askUser = { [weak self] question in
            guard let self else { throw DeliveryError.failed("Gloss is closing") }
            return try await self.ask(question)
        }
        // A test host serves without a token (its tests talk to the server directly); a real launch never does.
        let server = MCPServer(dependencies: dependencies, port: settings.mcpPort, token: launchOptions.isTestHost ? nil : MCPServer.loadOrCreateToken())
        do {
            try await server.start()
            mcpServer = server
            mcpStatus = nil
            mcpListeningPort = settings.mcpPort
            for (hostID, connection) in connections {
                await forwardMCPPort(to: connection, alias: hosts.entry(for: hostID)?.alias ?? hostID.rawValue)
            }
        } catch {
            mcpStatus = "MCP server could not bind port \(settings.mcpPort): \(error)"
            Log.transport.error("MCP server failed to start: \(error, privacy: .public)")
        }
    }

    /// The hook installer for a host: local files and shell, or the host's SFTP file system and exec channel.
    func makeHookInstaller(for hostID: HostID) -> HookInstaller? {
        // Hooks must point where the server listens now, not at a port the setting names for the next launch.
        let port = mcpListeningPort ?? settings.mcpPort
        if hostID == .local {
            return HookInstaller(fileSystem: LocalFileSystem(), home: NSHomeDirectory(), port: port, token: mcpServer?.token) { try await LocalShell.run($0) }
        }
        guard let fileSystem = fileSystems[hostID], let connection = connections[hostID], let alias = hosts.entry(for: hostID)?.name else { return nil }
        guard let home = hostHomes[hostID] else { return nil }
        return HookInstaller(fileSystem: fileSystem, home: home, hostAlias: alias, port: port, token: mcpServer?.token) { line in
            try await connection.exec(LocalShell.pathPrefix + line, timeout: .seconds(60))
        }
    }

    /// A whole-file note from the explorer's context menu. An open session for the file picks it up through its
    /// note observation.
    func createWholeFileNote(hostID: HostID, path: String, body: String, color: NoteColor) async {
        do {
            let fingerprint = (try? await fileSystems[hostID]?.stat(path))?.fingerprint ?? Fingerprint()
            let document = try await noteStore.upsertDocument(hostID: hostID, path: path, kind: DocumentKindDetector.kind(forPath: path), fingerprint: fingerprint)
            _ = try await noteStore.createNote(documentID: document.id, anchor: .wholeFile, body: body, color: color)
            showNotesPanel = true
        } catch {
            Log.notes.error("file note for \(path, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// Makes `http://127.0.0.1:<port>/mcp` reachable on the host through the control connection.
    private func forwardMCPPort(to connection: SSHConnection, alias: String) async {
        guard let port = await mcpServer?.port else { return }
        do {
            _ = try await connection.forwardRemotePort(UInt16(port))
        } catch {
            Log.transport.error("Reverse forward of the MCP port to \(alias, privacy: .public) failed: \(error, privacy: .public)")
            mcpStatus = "\(alias): port \(port) is busy there; agents on that host cannot reach the MCP server"
        }
    }

    /// A whole-file draft created by the Herdr plugin (the user re-anchors it in the app if needed).
    nonisolated static func createPluginDraft(store: NoteStore, hostID: HostID, path: String, text: String) async throws -> NoteID {
        let kind = DocumentKindDetector.kind(forPath: path)
        let document = try await store.upsertDocument(hostID: hostID, path: path, kind: kind, fingerprint: Fingerprint())
        return try await store.createNote(documentID: document.id, anchor: .wholeFile, body: text, color: .yellow).id
    }

    enum SendScope {
        case activeDocument
        case all
    }

    func send(noteIDs: [NoteID]) async {
        guard let target = send.lastTarget else { return }
        await send.send(noteIDs: noteIDs, to: target)
    }

    /// The open document's drafts you can see: all of them, or only the colours the notes panel is filtered to.
    /// What the Send button and ⌘↩ send, so nothing hidden from view goes to the agent.
    var visibleDrafts: [Note] {
        guard let session = activeSession else { return [] }
        let drafts = session.notes.filter { $0.state == .draft }
        // With the panel closed nothing is filtered on screen, so nothing is filtered here either.
        guard showNotesPanel, let documentID = session.document?.id else { return drafts }
        // Exactly the cards the panel shows for this document: state tab, colours, and search all apply.
        let shown = Set(notesPanel.visibleGroups.first { $0.document.id == documentID }?.notes.map(\.id) ?? [])
        return drafts.filter { shown.contains($0.id) }
    }

    /// Whether the panel is narrowing what Send takes (for wording: "the 2 shown drafts").
    var draftsAreFiltered: Bool {
        showNotesPanel && (notesPanel.filter != .all || !notesPanel.colorFilter.isEmpty || !notesPanel.searchText.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Opens the main window when it was closed (the app keeps running), for the Dock menu.
    @ObservationIgnored var openMainWindow: () -> Void = {}

    func sendVisibleDrafts() async {
        let ids = visibleDrafts.map(\.id)
        guard !ids.isEmpty else { return }
        await send(noteIDs: ids)
    }

    /// The same notes Send would send, as a packet on the clipboard instead.
    func copyVisibleDrafts() async {
        await copyPacket(noteIDs: visibleDrafts.map(\.id))
    }

    func sendAllDrafts(scope: SendScope) async {
        let ids = await send.draftNoteIDs(documentID: scope == .all ? nil : activeSession?.document?.id)
        guard !ids.isEmpty else { return }
        await send(noteIDs: ids)
    }

    /// Copies these notes as one packet. They stay drafts: only Send marks a note sent.
    func copyPacket(noteIDs: [NoteID]) async {
        await send.copy(noteIDs: noteIDs)
    }

    /// Opens the note's document and scrolls to it.
    func reveal(note: Note, in document: Core.Document, select: Bool = true) {
        withSession(for: document) { session in
            // The session may still be opening.
            for _ in 0..<50 where !session.isLoaded { try? await Task.sleep(for: .milliseconds(50)) }
            session.reveal(note, select: select)
        }
    }

    /// Opens a note's document and hands its session to `body`: for a Confluence page, at today's path once it
    /// is known (the note moves there with it).
    private func withSession(for document: Core.Document, _ body: @escaping @MainActor (DocumentSession) async -> Void) {
        Task {
            var path = document.path
            if document.hostID == .atlassian, AtlassianPath(path)?.pageID != nil, !canonicalPages.contains(path) {
                path = await canonicalConfluencePath(path)
            }
            openDocument(hostID: document.hostID, path: path)
            guard let session = sessions["\(document.hostID.rawValue):\(path)"] else { return }
            await body(session)
        }
    }

    /// Link on opens the notes panel: following a panel that isn't there would do nothing visible.
    func setNotesLinked(_ linked: Bool) {
        noteLink.isLinked = linked
        if linked { showNotesPanel = true }
    }

    /// Next or Previous Note: the active document's next open note, with its card selected in the notes panel.
    func stepNote(forward: Bool) {
        guard let note = activeSession?.stepNote(forward: forward) else { return }
        notesPanel.selectedNoteID = note.id
    }

    /// Notes › Next Change / Previous Change: the hunks of a pull request's file.
    func stepChange(forward: Bool) {
        activeSession?.stepChange(forward: forward)
    }

    func reanchor(note: Note, in document: Core.Document) {
        withSession(for: document) { session in
            for _ in 0..<50 where session.document == nil { try? await Task.sleep(for: .milliseconds(50)) }
            session.beginReanchor(note)
        }
    }

    func edit(note: Note, in document: Core.Document) {
        withSession(for: document) { session in
            for _ in 0..<50 where session.document == nil { try? await Task.sleep(for: .milliseconds(50)) }
            session.editNote(note)
        }
    }

    /// Connects to a remote host and opens its home directory (or the given path) as a root.
    func openRemoteRoot(hostID: HostID, path: String? = nil) async {
        pickedHost = hostID
        guard let home = await hosts.connect(hostID) else { return }
        await explorer.openRoot(hostID: hostID, path: path ?? home)
    }

    private(set) var isShutDown = false

    /// Stops watchers, disconnects every host (waiting up to six seconds for the masters to exit), and closes the database.
    func shutDown() async {
        guard !isShutDown else { return }
        isShutDown = true
        // Bounded: a slow or locked database must not hold up quitting.
        workspaceSave?.cancel()
        // Quitting while a restore still waits (a host's key agent) keeps the saved workspace whole.
        if !isRestoringWorkspace { _ = await withDeadline(.seconds(1)) { await self.saveWorkspace() } }
        notesPanel.stop()
        explorer.stopWatching()
        for session in sessions.values { session.close() }
        let hosts = hosts
        // `withDeadline` returns at the deadline even if a disconnect hangs; the kill below covers that case.
        let server = mcpServer
        _ = await withDeadline(.seconds(6)) {
            await server?.stop()
            await hosts.disconnectAll()
        }
        hosts.killMasters()
        closeDatabase()
    }

    /// Last resort when the app terminates without `shutDown` having run (crash reporter, force quit path): kills the masters outright.
    func shutDownSynchronously() {
        // Even after an async shutdown began: if the process ends before it finished, the masters must still go.
        hosts.killMasters()
        guard !isShutDown else { return }
        isShutDown = true
        notesPanel.stop()
        explorer.stopWatching()
        for session in sessions.values { session.close() }
        hosts.killMasters()
        closeDatabase()
    }

    private func closeDatabase() {
        do {
            try database.close()
        } catch {
            Log.database.error("Database close failed: \(error, privacy: .public)")
        }
    }
}
