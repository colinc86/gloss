import Core
import Foundation
import Observation
import OSLog
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
    let launchOptions: AppLaunchOptions
    /// Live ssh connections by host, for transports and search.
    private(set) var connections: [HostID: SSHConnection] = [:]
    /// The same connections, readable by the transports without touching the main actor.
    let connectionRegistry = ConnectionRegistry()
    let herdrTransport: HerdrTransport
    private(set) var mcpServer: MCPServer?
    private(set) var mcpStatus: String?
    /// Remote home directories, learned from the probe when a host connects (hook installs need them).
    private(set) var hostHomes: [HostID: String] = [:]
    /// Follow mode: the explorer opens the directory of whichever Herdr agent pane has focus.
    var followHerdr = false {
        didSet { followHerdr ? startFollowing() : stopFollowing() }
    }
    private(set) var followStatus: String?
    @ObservationIgnored private var followTasks: [HostID: Task<Void, Never>] = [:]
    var showNotesPanel = true

    /// Open documents keyed by `host:path`; `activeSession` is the one in the viewer pane.
    private(set) var sessions: [String: DocumentSession] = [:]
    private(set) var activeSession: DocumentSession?

    init(launchOptions: AppLaunchOptions) {
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
        send.register(herdrTransport)
        send.register(TmuxTransport(registry: connectionRegistry))
        let settings = settings
        send.register(OpenCodeTransport(servers: { await MainActor.run { OpenCodeServer.parse(settings.opencodeServers) } }))
        hooks.installerProvider = { [weak self] hostID in self?.makeHookInstaller(for: hostID) }
        notesPanel.start()
        hosts.onFileSystemReady = { [weak self] hostID, fileSystem, connection in
            guard let self else { return }
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
            // Expired staging directories are swept once per host per launch, not on every host click.
            if firstRegistration { Task { await stager.cleanupExpired() } }
        }
        hosts.onDisconnected = { [weak self] hostID in
            guard let self else { return }
            self.connections[hostID] = nil
            self.fileSystems[hostID] = nil
            self.followTasks[hostID]?.cancel()
            self.followTasks[hostID] = nil
            Task {
                await self.connectionRegistry.remove(hostID)
                await self.herdrTransport.forget(hostID)
            }
        }
        explorer.fileSystemProvider = { [weak self] hostID in self?.fileSystems[hostID] }
        explorer.onSelectFile = { [weak self] hostID, path in self?.openDocument(hostID: hostID, path: path) }
    }

    // MARK: Follow mode

    private func startFollowing() {
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

    private func stopFollowing() {
        for task in followTasks.values { task.cancel() }
        followTasks = [:]
        followStatus = nil
    }

    private func apply(_ event: FollowEvent) async {
        if let agent = event.agent {
            followStatus = "\(agent) \(event.status ?? "") · \(event.paneID)"
        }
        guard let path = event.path, !path.isEmpty else { return }
        if event.hostID != .local, fileSystems[event.hostID] == nil { return }
        await explorer.openRoot(hostID: event.hostID, path: path)
    }

    func openDocument(hostID: HostID, path: String) {
        let key = "\(hostID.rawValue):\(path)"
        if let existing = sessions[key] {
            activeSession = existing
            trimSessions()
            return
        }
        guard let fileSystem = fileSystems[hostID] else {
            Task {
                if await ensureConnected(hostID) { openDocument(hostID: hostID, path: path) }
            }
            return
        }
        let session = DocumentSession(hostID: hostID, path: path, fileSystem: fileSystem, noteStore: noteStore)
        sessions[key] = session
        activeSession = session
        Task { await session.open() }
        trimSessions()
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
            sessions[victim]?.close()
            sessions[victim] = nil
        }
    }

    /// Opens a document and scrolls its text view to a 1-based line once it has loaded.
    func openDocument(hostID: HostID, path: String, line: Int) {
        openDocument(hostID: hostID, path: path)
        guard let session = sessions["\(hostID.rawValue):\(path)"] else { return }
        Task {
            for _ in 0..<50 where session.textController == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard let controller = session.textController else { return }
            let range = controller.lineIndex.contentRange(ofLine: line)
            if let markdown = session.markdown { markdown.scroll(toSource: range) } else { controller.scroll(to: range) }
        }
    }

    /// Connects a remote host when its file system is not registered yet.
    func ensureConnected(_ hostID: HostID) async -> Bool {
        if fileSystems[hostID] != nil { return true }
        return await hosts.connect(hostID) != nil
    }

    /// Makes sure a root containing `path` is open, opening the parent directory when none is.
    func openRootIfNeeded(hostID: HostID, containing path: String) async {
        guard await ensureConnected(hostID) else { return }
        if explorer.tabs.contains(where: { $0.hostID == hostID && path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }) { return }
        await explorer.openRoot(hostID: hostID, path: PathUtilities.parent(of: path))
    }

    /// Creates a note from a URL or plugin: on `line` of the file, or on the whole file.
    func createNote(hostID: HostID, path: String, line: Int?, body: String) async {
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
            _ = try await noteStore.createNote(documentID: document.id, anchor: anchor, body: body, color: .yellow)
            showNotesPanel = true
        } catch {
            Log.notes.error("URL note failed: \(error, privacy: .public)")
        }
    }

    func closeDocument(_ session: DocumentSession) {
        session.close()
        sessions[session.id] = nil
        if activeSession === session { activeSession = sessions.values.first }
    }

    func fileSystem(for hostID: HostID) -> (any FileSystemProvider)? {
        fileSystems[hostID]
    }

    @ObservationIgnored private var started = false

    /// Applies `--root` and `--open`, or reopens the most recent root. Runs once even if several windows appear.
    func start() async {
        guard !started else { return }
        started = true
        await settings.load()
        send.stagedFileExpiryDays = settings.stagedFileExpiryDays
        await hosts.refresh()
        explorer.showDotfiles = settings.showDotfilesByDefault
        if let root = launchOptions.root {
            await explorer.openRoot(hostID: .local, path: root)
        } else if settings.openLastRootOnLaunch {
            await explorer.reopenRecentRoot(hostID: .local)
        }
        if let open = launchOptions.open {
            openDocument(hostID: .local, path: open)
        }
        await startMCPServer()
    }

    // MARK: MCP

    private func startMCPServer() async {
        let store = noteStore
        let send = send
        let dependencies = MCPDependencies(
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
                guard let hostID else { throw DeliveryError.targetUnavailable("unknown host \(host)") }
                guard let documentPath = path ?? cwd.map({ PathUtilities.join($0, ".gloss-inbox.md") }) else {
                    throw DeliveryError.failed("path or cwd is required")
                }
                return try await AppModel.createPluginDraft(store: store, hostID: hostID, path: documentPath, text: text)
            },
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
        let server = MCPServer(dependencies: dependencies, port: settings.mcpPort)
        do {
            try await server.start()
            mcpServer = server
            mcpStatus = nil
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
        let port = settings.mcpPort
        if hostID == .local {
            return HookInstaller(fileSystem: LocalFileSystem(), home: NSHomeDirectory(), port: port) { try await LocalShell.run($0) }
        }
        guard let fileSystem = fileSystems[hostID], let connection = connections[hostID], let alias = hosts.entry(for: hostID)?.name else { return nil }
        guard let home = hostHomes[hostID] else { return nil }
        return HookInstaller(fileSystem: fileSystem, home: home, hostAlias: alias, port: port) { line in
            try await connection.exec(LocalShell.pathPrefix + line, timeout: .seconds(60))
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

    func sendAllDrafts(scope: SendScope) async {
        let ids = await send.draftNoteIDs(documentID: scope == .all ? nil : activeSession?.document?.id)
        guard !ids.isEmpty else { return }
        await send(noteIDs: ids)
    }

    func copyPacket(scope: SendScope) async {
        let ids = await send.draftNoteIDs(documentID: scope == .all ? nil : activeSession?.document?.id)
        guard !ids.isEmpty else { return }
        await send.send(noteIDs: ids, to: ClipboardTransport.target)
    }

    /// Opens the note's document and scrolls to it.
    func reveal(note: Note, in document: Core.Document) {
        openDocument(hostID: document.hostID, path: document.path)
        guard let session = sessions["\(document.hostID.rawValue):\(document.path)"] else { return }
        Task {
            // The session may still be opening.
            for _ in 0..<50 where !session.isLoaded { try? await Task.sleep(for: .milliseconds(50)) }
            session.reveal(note)
        }
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
        guard let home = await hosts.connect(hostID) else { return }
        await explorer.openRoot(hostID: hostID, path: path ?? home)
    }

    private(set) var isShutDown = false

    /// Stops watchers, disconnects every host (waiting up to six seconds for the masters to exit), and closes the database.
    func shutDown() async {
        guard !isShutDown else { return }
        isShutDown = true
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
