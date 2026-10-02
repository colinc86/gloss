import Core
import Foundation
import Observation
import OSLog

/// Root object for the app: owns the database, the file systems per host, and the explorer.
@MainActor
@Observable
final class AppModel {
    let database: AppDatabase
    let noteStore: NoteStore
    private(set) var fileSystems: [HostID: any FileSystemProvider] = [:]
    let explorer: ExplorerModel
    let launchOptions: AppLaunchOptions

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
        fileSystems[.local] = LocalFileSystem()
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

    func shutDown() {
        explorer.stopWatching()
        for session in sessions.values { session.close() }
        do {
            try database.close()
        } catch {
            Log.database.error("Database close failed: \(error, privacy: .public)")
        }
    }
}
