import Core
import Foundation
import Observation
import OSLog
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
    let launchOptions: AppLaunchOptions
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
        send = SendCoordinator(noteStore: store, transports: [ClipboardTransport()], stagers: [.local: LocalAttachmentStager()])
        fileSystems[.local] = LocalFileSystem()
        send.fileSystemProvider = { [weak self] hostID in self?.fileSystems[hostID] }
        // Excerpts come from what is on disk, which is what the agent will read; stored anchors match that text.
        send.openTextProvider = { [weak self] hostID, path in self?.sessions["\(hostID.rawValue):\(path)"]?.baseText }
        notesPanel.start()
        explorer.fileSystemProvider = { [weak self] hostID in self?.fileSystems[hostID] }
        explorer.onSelectFile = { [weak self] hostID, path in self?.openDocument(hostID: hostID, path: path) }
    }

    func openDocument(hostID: HostID, path: String) {
        let key = "\(hostID.rawValue):\(path)"
        if let existing = sessions[key] {
            activeSession = existing
            trimSessions()
            return
        }
        guard let fileSystem = fileSystems[hostID] else { return }
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

    /// Makes sure a root containing `path` is open, opening the parent directory when none is.
    func openRootIfNeeded(hostID: HostID, containing path: String) async {
        if explorer.tabs.contains(where: { $0.hostID == hostID && path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }) { return }
        await explorer.openRoot(hostID: hostID, path: PathUtilities.parent(of: path))
    }

    /// Creates a note from a URL or plugin: on `line` of the file, or on the whole file.
    func createNote(hostID: HostID, path: String, line: Int?, body: String) async {
        guard let fileSystem = fileSystems[hostID] else { return }
        do {
            var anchor = Anchor.wholeFile
            if let line, let data = try? await fileSystem.read(path), let text = String(data: data, encoding: .utf8) {
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
        explorer.showDotfiles = settings.showDotfilesByDefault
        if let root = launchOptions.root {
            await explorer.openRoot(hostID: .local, path: root)
        } else if settings.openLastRootOnLaunch {
            await explorer.reopenRecentRoot(hostID: .local)
        }
        if let open = launchOptions.open {
            openDocument(hostID: .local, path: open)
        }
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

    func shutDown() {
        notesPanel.stop()
        explorer.stopWatching()
        for session in sessions.values { session.close() }
        do {
            try database.close()
        } catch {
            Log.database.error("Database close failed: \(error, privacy: .public)")
        }
    }
}
