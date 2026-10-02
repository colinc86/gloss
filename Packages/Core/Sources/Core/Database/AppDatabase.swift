import Foundation
import GRDB

/// The app's single SQLite database. One instance per process; `open(at:)` for the real
/// file under Application Support, `temporary()` for `--reset-db` and tests.
public final class AppDatabase: Sendable {
    public let queue: DatabaseQueue
    /// Set for temporary databases so `close()` can remove the file.
    private let temporaryURL: URL?

    private init(queue: DatabaseQueue, temporaryURL: URL?) {
        self.queue = queue
        self.temporaryURL = temporaryURL
    }

    /// Opens or creates the database at `url`, creating parent directories, and applies migrations.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration())
        try Schema.migrator.migrate(queue)
        return AppDatabase(queue: queue, temporaryURL: nil)
    }

    /// A throwaway database under `$TMPDIR`, deleted by `close()`.
    public static func temporary() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("gloss.sqlite")
        let queue = try DatabaseQueue(path: url.path, configuration: configuration())
        try Schema.migrator.migrate(queue)
        return AppDatabase(queue: queue, temporaryURL: url)
    }

    /// An in-memory database for unit tests that never need a file.
    public static func inMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        try Schema.migrator.migrate(queue)
        return AppDatabase(queue: queue, temporaryURL: nil)
    }

    /// The default location: `~/Library/Application Support/Gloss/gloss.sqlite`.
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Gloss", isDirectory: true)
            .appendingPathComponent("gloss.sqlite")
    }

    /// Closes the connection and removes a temporary database's directory.
    public func close() throws {
        try queue.close()
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent())
        }
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(2)
        configuration.journalMode = .wal
        return configuration
    }
}
