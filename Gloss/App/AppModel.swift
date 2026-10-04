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
    let send: SendCoordinator
    let settings: SettingsStore
    let hosts: HostsModel
    let hooks = HooksModel()
    let integrations: IntegrationsModel
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
    func beginNoteInMainWindow() {
        guard let session = activeSession else { return }
        if let window = mainWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { session.beginNote() }
        } else {
            session.beginNote()
        }
    }
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
    var showNotesPanel = true

    /// Open documents keyed by `host:path`; `activeSession` is the one in the viewer pane.
    private(set) var sessions: [String: DocumentSession] = [:]
    private(set) var activeSession: DocumentSession? {
        didSet {
            explorer.setActiveDocument(hostID: activeSession?.hostID, path: activeSession?.path)
            rememberLastDocument()
        }
    }

    init(launchOptions: AppLaunchOptions) {
        // A test host or a throwaway run keeps keys in memory: no Keychain prompt, nothing left behind.
        integrations = IntegrationsModel(store: launchOptions.resetDatabase || launchOptions.isTestHost ? MemoryCredentialStore() : KeychainCredentialStore())
        self.launchOptions = launchOptions
        let database: AppDatabase
        do {
            database = launchOptions.resetDatabase ? try AppDatabase.temporary() : try AppDatabase.open(at: AppDatabase.defaultURL)
        } catch {
            Log.database.fault("Could not open the database: \(error, privacy: .public). Using a temporary one.")
            // swiftlint:disable:next force_try
            database = try! AppDatabase.temporary()
        }
        self.database = database
        let store = NoteStore(database: database)
        noteStore = store
        explorer = ExplorerModel(noteStore: store)
        notesPanel = NotesPanelModel(noteStore: store)
        settings = SettingsStore(noteStore: store)
        hosts = HostsModel(noteStore: store)
        send = SendCoordinator(noteStore: store, transports: [ClipboardTransport()], stagers: [.local: LocalAttachmentStager()])
        herdrTransport = HerdrTransport(registry: connectionRegistry)
        fileSystems[.local] = LocalFileSystem()
        send.fileSystemProvider = { [weak self] hostID in self?.fileSystems[hostID] }
        // Excerpts come from what is on disk, which is what the agent will read; stored anchors match that text.
        send.openTextProvider = { [weak self] hostID, path in self?.sessions["\(hostID.rawValue):\(path)"]?.baseText }
        send.packetResourceProvider = { [weak self] hostID, path, line in
            switch hostID {
            case .github: await self?.pullRequests?.resource(for: path, line: line)
            case .atlassian: await self?.atlassianDocuments?.resource(for: path, line: line)
            default: nil
            }
        }
        send.register(herdrTransport)
        send.register(TmuxTransport(registry: connectionRegistry))
        let settings = settings
        send.register(OpenCodeTransport(servers: { await MainActor.run { OpenCodeServer.parse(settings.opencodeServers) } }))
        hooks.installerProvider = { [weak self] hostID in self?.makeHookInstaller(for: hostID) }
        notesPanel.start()
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
            let alias = self.hosts.entry(for: hostID)?.name ?? hostID.rawValue
            Task {
                await self.connectionRegistry.register(connection, alias: alias, for: hostID)
                if let tools = try? await connection.tools(), !tools.home.isEmpty { self.hostHomes[hostID] = tools.home }
                await self.forwardMCPPort(to: connection, alias: alias)
                if self.followHerdr { self.startFollowing() }
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
        hosts.onDisconnected = { [weak self] hostID in
            guard let self else { return }
            self.connections[hostID] = nil
            self.fileSystems[hostID] = nil
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
        explorer.fileSystemProvider = { [weak self] hostID in self?.fileSystems[hostID] }
        fileSystems[.web] = UnavailableFileSystem(hostID: .web)
        // A page moves the viewer only while it is what the viewer shows: one left running behind another document
        // (a redirect, a refresh, a script) never pulls the reader away.
        browser.onOpenFile = { [weak self] hostID, path, previous in
            guard let self, previous != nil, activeSession?.html === previous, let hostID = hostID ?? activeSession?.hostID, hostID != .web else { return }
            openDocument(hostID: hostID, path: path)
        }
        browser.onDocumentChange = { [weak self] url, via, previous in self?.webDocumentDidChange(url, via: via, previous: previous) }
        browser.onNeedsTunnel = { [weak self] hostID, port in
            guard let self else { throw CancellationError() }
            return try await tunnel(hostID: hostID, port: port)
        }
        explorer.onSelectFile = { [weak self] hostID, path in self?.openDocument(hostID: hostID, path: path) }
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
        case .remote(let target, _): hosts.entries.first { $0.name == target }.map { .host($0.id) } ?? .none
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

    /// The user picked a target: remember it, and show the agent's working directory when the target has one.
    func choose(target: AgentTarget) {
        send.rememberTarget(target)
        guard target.transport == .herdr || target.transport == .tmux, let path = target.detail, path.hasPrefix("/") else { return }
        Task {
            guard await ensureConnected(target.hostID) else { return }
            pickedHost = target.hostID
            await explorer.openRoot(hostID: target.hostID, path: path)
        }
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
        // The deepest open root holding the file bounds what a rendered HTML page may read; looked up per request,
        // since the root can open after the document (launch with --open, a jump from a note).
        session.resourceRoot = { [weak explorer] in
            // Compare resolved folders: a root opened as `/private/tmp/x` is stored as `/tmp/x`.
            let file = ExplorerModel.canonical(path, hostID: hostID)
            return explorer?.tabs.filter { tab in
                let root = ExplorerModel.canonical(tab.path, hostID: hostID)
                return tab.hostID == hostID && file.hasPrefix(root == "/" ? "/" : root + "/")
            }.max { $0.path.count < $1.path.count }?.path
        }
        if hostID == .github {
            session.lineChangesProvider = { [weak self] path in await self?.pullRequests?.changes(forPath: path) }
        }
        sessions[key] = session
        activeSession = session
        Task { await session.open() }
        trimSessions()
    }

    // MARK: Integration hosts

    /// The GitHub host exists while a token is saved: its provider serves pull requests with that token. When the
    /// token goes, so do the host and its open documents.
    private func registerIntegrationHosts() async {
        if let client = integrations.githubClient {
            fileSystems[.github] = GitHubPullRequestFileSystem(client: client)
        } else {
            fileSystems[.github] = nil
            for (key, session) in sessions where session.hostID == .github {
                retire(session)
                sessions[key] = nil
                if activeSession === session { activeSession = nil }
            }
            for tab in explorer.tabs where tab.hostID == .github { explorer.closeTab(tab.id) }
        }
        await hosts.setVirtualHost(.github, name: "github", kind: .github, enabled: integrations.github != nil)
        let site = integrations.atlassian?.site
        let previousSite = atlassianSite.withLock { previous in
            defer { previous = site }
            return previous
        }
        if let client = integrations.atlassianClient {
            fileSystems[.atlassian] = AtlassianFileSystem(client: client)
        } else {
            fileSystems[.atlassian] = nil
        }
        if previousSite != nil, site != previousSite {
            // Another site, or none: the open issues and pages were that site's and their paths mean nothing here.
            for (key, session) in sessions where session.hostID == .atlassian {
                retire(session)
                sessions[key] = nil
                if activeSession === session { activeSession = nil }
            }
            for tab in explorer.tabs where tab.hostID == .atlassian { explorer.closeTab(tab.id) }
        }
        await hosts.setVirtualHost(.atlassian, name: "atlassian", kind: .atlassian, enabled: integrations.atlassian != nil)
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
        case .confluencePageFolder(let space, _), .confluencePage(let space, _, _):
            await explorer.openRoot(hostID: .atlassian, path: AtlassianPath.confluenceSpace(space).path)
            guard let document = await provider.documentPath(for: reference) else { return }
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
        guard let previous, activeSession?.html === previous else { return }
        openWebPage(url, via: via)
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
    func openDocument(hostID: HostID, path: String, line: Int, select: Bool = true) {
        if hostID == .atlassian, let reference = AtlassianPath(path), case .confluencePageFolder = reference {
            // A page URL names the page's folder; the document inside it opens once its title is known.
            Task { await openAtlassian(reference, line: line) }
            return
        }
        openDocument(hostID: hostID, path: path)
        guard let session = sessions["\(hostID.rawValue):\(path)"] else { return }
        Task {
            for _ in 0..<50 where session.textController == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard let controller = session.textController else { return }
            let line = controller.lineIndex.contentRange(ofLine: line)
            let range = select ? line : NSRange(location: line.location, length: 0)
            if let rendered = session.rendered { rendered.scroll(toSource: range, select: select) } else { controller.scroll(to: range) }
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
    func presentQuickOpen() {
        guard let tab = explorer.selectedTab else { return }
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
        guard let tab = explorer.selectedTab else { return }
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
        guard await ensureConnected(hostID) else { return }
        if explorer.tabs.contains(where: { $0.hostID == hostID && ExplorerModel.inRootSpelling(path, root: $0.path, hostID: hostID) != nil }) { return }
        if hostID == .github, let pull = PullRequestPath(path) {
            await explorer.openRoot(hostID: hostID, path: pull.root)
            return
        }
        if hostID == .atlassian, let reference = AtlassianPath(path) {
            switch reference {
            case .jiraIssue(let project, _): await explorer.openRoot(hostID: hostID, path: AtlassianPath.jiraProject(project).path)
            case .confluencePage(let space, _, _), .confluencePageFolder(let space, _): await explorer.openRoot(hostID: hostID, path: AtlassianPath.confluenceSpace(space).path)
            default: break
            }
            return
        }
        await explorer.openRoot(hostID: hostID, path: PathUtilities.parent(of: path))
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

    /// Ends a session; a page it showed stops running in the shared web view.
    private func retire(_ session: DocumentSession) {
        if let html = session.html, browser.current === html { browser.unload() }
        session.close()
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

    /// Applies `--root` and `--open`, or reopens the most recent root. Runs once even if several windows appear.
    func start() async {
        guard !started, !launchOptions.isTestHost else { return }
        started = true
        await settings.load()
        send.stagedFileExpiryDays = settings.stagedFileExpiryDays
        settings.onStagedExpiryChange = { [weak self] days in self?.send.stagedFileExpiryDays = days }
        settings.onDockSettingChange = { [weak self] in self?.updateDockBadge() }
        updateDockBadge()
        sweepAttachments()
        await hosts.load()
        integrations.onChange = { [weak self] in Task { await self?.registerIntegrationHosts() } }
        #if DEBUG
        if let path = launchOptions.integrationsEnv {
            await integrations.importEnvironmentFile(at: path, atlassianSite: launchOptions.atlassianSite)
        }
        #endif
        await integrations.load()
        await registerIntegrationHosts()
        explorer.showDotfiles = settings.showDotfilesByDefault
        let launchHost = launchOptions.host == "local" ? HostID.local : hosts.entries.first { $0.name == launchOptions.host }?.id
        if let launchHost, launchHost != .local {
            // `--host <alias>` connects first; `--root` names a directory there, else the home directory.
            await openRemoteRoot(hostID: launchHost, path: launchOptions.root)
        } else if let root = launchOptions.root {
            await explorer.openRoot(hostID: .local, path: root)
        } else if settings.openLastRootOnLaunch {
            await reopenMostRecentRoot()
        }
        if let open = launchOptions.open {
            openDocument(hostID: .local, path: open)
        }
        await startMCPServer()
        if launchOptions.follow { followHerdr = true }
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

    /// The document in front, kept so the next launch reopens it with its folder.
    private func rememberLastDocument(line: Int? = nil) {
        guard let session = activeSession else {
            // Everything closed: the next launch should start without a document, not reopen the closed one.
            guard !isShutDown else { return }
            let store = noteStore
            Task { try? await store.setSetting("general.lastDocument", nil) }
            return
        }
        let value = "\(session.hostID.rawValue)\n\(session.path)" + (line.map { "\n\($0)" } ?? "")
        let store = noteStore
        Task { try? await store.setSetting("general.lastDocument", value) }
    }

    /// At quit, the caret's line too, so the next launch lands where reading stopped.
    private func rememberLastPosition() async {
        guard let session = activeSession, let controller = session.textController else { return }
        // Reading rendered markdown moves the rendered selection, not the source caret: map it back to the source.
        var location = controller.selection.location
        if let markdown = session.markdown, markdown.mode == .rendered, let mapping = markdown.renderedSelectionMapping {
            location = mapping.source.location
        }
        let line = controller.lineIndex.position(forUTF16Offset: location).line
        let value = "\(session.hostID.rawValue)\n\(session.path)\n\(line)"
        try? await noteStore.setSetting("general.lastDocument", value)
    }

    /// Reopens the document that was in front last time, when it lives in `root` (and, on this Mac, still exists).
    private func reopenLastDocument(in root: Root) async {
        guard let value = try? await noteStore.setting("general.lastDocument") else { return }
        let parts = value.split(separator: "\n").map(String.init)
        guard parts.count >= 2, HostID(rawValue: parts[0]) == root.hostID,
              ExplorerModel.inRootSpelling(parts[1], root: root.path, hostID: root.hostID) != nil else { return }
        if root.hostID == .local, !FileManager.default.fileExists(atPath: parts[1]) { return }
        if parts.count >= 3, let line = Int(parts[2]), line > 1 {
            openDocument(hostID: root.hostID, path: parts[1], line: line, select: false)
        } else {
            openDocument(hostID: root.hostID, path: parts[1])
        }
    }

    private func reopenMostRecentRoot() async {
        let hosts = (try? await noteStore.hosts()) ?? []
        var best: Root?
        for host in hosts {
            for root in (try? await noteStore.roots(for: host.id)) ?? [] where best.map({ root.lastOpenedAt > $0.lastOpenedAt }) ?? true {
                best = root
            }
        }
        guard let best else { return }
        if best.hostID == .local {
            await explorer.openRoot(hostID: .local, path: best.path)
        } else if best.hostID.isVirtual {
            guard fileSystems[best.hostID] != nil else { return }
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
            hookText: { flavour, host, cwd in
                let hostID = host == "local" ? HostID.local : try await store.hosts().first { $0.name == host }?.id
                if host != "local", hostID == nil { return "" }
                let (text, noteIDs) = try await send.hookText(hostID: hostID, cwd: cwd)
                // Drained notes count as sent through that hook; the agent resolves them over MCP afterwards.
                if !noteIDs.isEmpty {
                    let transport = flavour == "codex" ? TransportKind.codexHook : .claudeHook
                    let targetJSON = (try? JSONSerialization.data(withJSONObject: ["cwd": cwd ?? ""])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    _ = try? await store.recordSend(transport: transport.rawValue, targetJSON: targetJSON, packetText: text, noteIDs: noteIDs, outcome: .delivered)
                }
                return text
            },
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
        dependencies.openDocument = { [weak self] host, path, line in
            let hostID = host == "local" ? HostID.local : try await store.hosts().first { $0.name == host }?.id
            guard let hostID else { throw DeliveryError.failed("unknown host \(host)") }
            await MainActor.run {
                guard let self else { return }
                Task {
                    await self.openRootIfNeeded(hostID: hostID, containing: path)
                    if let line { self.openDocument(hostID: hostID, path: path, line: line) } else { self.openDocument(hostID: hostID, path: path) }
                }
            }
        }
        let server = MCPServer(dependencies: dependencies, port: settings.mcpPort)
        do {
            try await server.start()
            mcpServer = server
            mcpStatus = nil
            mcpListeningPort = settings.mcpPort
            for (hostID, connection) in connections {
                await forwardMCPPort(to: connection, alias: hosts.entry(for: hostID)?.name ?? hostID.rawValue)
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
            return HookInstaller(fileSystem: LocalFileSystem(), home: NSHomeDirectory(), port: port) { try await LocalShell.run($0) }
        }
        guard let fileSystem = fileSystems[hostID], let connection = connections[hostID], let alias = hosts.entry(for: hostID)?.name else { return nil }
        guard let home = hostHomes[hostID] else { return nil }
        return HookInstaller(fileSystem: fileSystem, home: home, hostAlias: alias, port: port) { line in
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

    /// Copies these notes as one packet; like any send, drafts in it become sent.
    func copyPacket(noteIDs: [NoteID]) async {
        guard !noteIDs.isEmpty else { return }
        await send.send(noteIDs: noteIDs, to: ClipboardTransport.target)
    }

    /// Opens the note's document and scrolls to it.
    func reveal(note: Note, in document: Core.Document, select: Bool = true) {
        openDocument(hostID: document.hostID, path: document.path)
        guard let session = sessions["\(document.hostID.rawValue):\(document.path)"] else { return }
        Task {
            // The session may still be opening.
            for _ in 0..<50 where !session.isLoaded { try? await Task.sleep(for: .milliseconds(50)) }
            session.reveal(note, select: select)
        }
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
        openDocument(hostID: document.hostID, path: document.path)
        guard let session = sessions["\(document.hostID.rawValue):\(document.path)"] else { return }
        Task {
            for _ in 0..<50 where session.document == nil { try? await Task.sleep(for: .milliseconds(50)) }
            session.beginReanchor(note)
        }
    }

    func edit(note: Note, in document: Core.Document) {
        openDocument(hostID: document.hostID, path: document.path)
        guard let session = sessions["\(document.hostID.rawValue):\(document.path)"] else { return }
        Task {
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
        _ = await withDeadline(.seconds(1)) { await self.rememberLastPosition() }
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
