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
        send = SendCoordinator(noteStore: store, transports: [ClipboardTransport()], stagers: [.local: LocalAttachmentStager()])
        fileSystems[.local] = LocalFileSystem()
        send.fileSystemProvider = { [weak self] hostID in self?.fileSystems[hostID] }
        send.openTextProvider = { [weak self] hostID, path in self?.sessions["\(hostID.rawValue):\(path)"]?.textController?.text }
        notesPanel.start()
        explorer.fileSystemProvider = { [weak self] hostID in self?.fileSystems[hostID] }
        explorer.onSelectFile = { [weak self] hostID, path in self?.openDocument(hostID: hostID, path: path) }
    }

    func openDocument(hostID: HostID, path: String) {
        let key = "\(hostID.rawValue):\(path)"
        if let existing = sessions[key] {
            activeSession = existing
            return
        }
        guard let fileSystem = fileSystems[hostID] else { return }
        let session = DocumentSession(hostID: hostID, path: path, fileSystem: fileSystem, noteStore: noteStore)
        sessions[key] = session
        activeSession = session
        Task { await session.open() }
    }

    func closeDocument(_ session: DocumentSession) {
        session.close()
        sessions[session.id] = nil
        if activeSession === session { activeSession = sessions.values.first }
    }

    func fileSystem(for hostID: HostID) -> (any FileSystemProvider)? {
        fileSystems[hostID]
    }

    /// Applies `--root` and `--open`, or reopens the most recent root.
    func start() async {
        if let root = launchOptions.root {
            await explorer.openRoot(hostID: .local, path: root)
        } else {
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
            for _ in 0..<50 where session.textController == nil { try? await Task.sleep(for: .milliseconds(50)) }
            session.reveal(note)
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
