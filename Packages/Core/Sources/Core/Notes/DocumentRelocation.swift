import Foundation
import GRDB

/// A durable, same-host rename. IDs and review history survive; paths alone change.
public struct DocumentRelocation: Codable, Sendable, Equatable {
    public let hostID: HostID
    public let from: String
    public let to: String
    public let directory: Bool
    public var metadataApplied: Bool? = false
    public var expectedFingerprint: Fingerprint?
    public init(hostID: HostID, from: String, to: String, directory: Bool) {
        self.hostID = hostID; self.from = from; self.to = to; self.directory = directory
    }
    public var settingKey: String { "files.pendingRename.\(hostID.rawValue)" }
    public func destination(for path: String) -> String? {
        func normalize(_ value: String) -> String {
            let value = (value as NSString).standardizingPath
            if hostID == .local {
                for prefix in ["/tmp", "/var", "/etc"] where value == "/private" + prefix || value.hasPrefix("/private" + prefix + "/") {
                    return String(value.dropFirst(8))
                }
            }
            return value
        }
        let path = normalize(path), old = normalize(from)
        guard path == old || (directory && path.hasPrefix(old + "/")) else { return nil }
        return to + path.dropFirst(old.count)
    }
}

extension NoteStore {
    public func prepareRelocation(_ move: DocumentRelocation) async throws {
        let value = String(decoding: try JSONEncoder().encode(move), as: UTF8.self)
        try await database.queue.write { db in
            if try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [move.settingKey]) != nil {
                throw FileSystemError.io("Finish the previous rename on this host first.")
            }
            try Self.checkRelocation(move, db)
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, ?)", arguments: [move.settingKey, value])
        }
    }

    public func pendingRelocation(hostID: HostID) async throws -> DocumentRelocation? {
        guard let value = try await setting("files.pendingRename.\(hostID.rawValue)") else { return nil }
        return try JSONDecoder().decode(DocumentRelocation.self, from: Data(value.utf8))
    }

    public func finishRelocation(_ move: DocumentRelocation) async throws {
        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [move.settingKey])
        }
    }

    private static func checkRelocation(_ move: DocumentRelocation, _ db: Database) throws {
        let rows = try DocumentRecord.filter(Column("host_id") == move.hostID.rawValue).fetchAll(db)
        let moving = Set(rows.filter { move.destination(for: $0.path) != nil }.map(\.id))
        let destination = DocumentRelocation(hostID: move.hostID, from: move.to, to: move.to, directory: move.directory)
        for target in rows where !moving.contains(target.id) && destination.destination(for: target.path) != nil {
            if try NoteRecord.filter(Column("document_id") == target.id).fetchCount(db) > 0 || IterationRecord.filter(Column("document_id") == target.id).fetchCount(db) > 0 {
                throw FileSystemError.io("\(target.path) already has review history. Choose a different name to keep both histories intact.")
            }
        }
    }

    /// Idempotent for recovery after the filesystem rename or a crash after this transaction.
    public func applyRelocation(_ move: DocumentRelocation) async throws {
        try await database.queue.write { db in
            let stored = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [move.settingKey])
            let pending = try stored.map { try JSONDecoder().decode(DocumentRelocation.self, from: Data($0.utf8)) }
            if pending?.metadataApplied == true { return }
            try Self.checkRelocation(move, db)
            let rows = try DocumentRecord.filter(Column("host_id") == move.hostID.rawValue).fetchAll(db)
            for var row in rows {
                guard let path = move.destination(for: row.path) else { continue }
                let destination = DocumentRelocation(hostID: move.hostID, from: path, to: path, directory: false)
                if let empty = rows.first(where: { $0.id != row.id && destination.destination(for: $0.path) != nil }) { _ = try empty.delete(db) }
                row.path = path
                try row.update(db)
            }
            for var root in try RootRecord.filter(Column("host_id") == move.hostID.rawValue).fetchAll(db) {
                guard let path = move.destination(for: root.path) else { continue }
                if let target = try RootRecord.filter(Column("host_id") == move.hostID.rawValue && Column("path") == path).fetchOne(db), target.id != root.id {
                    root.pinned = root.pinned || target.pinned
                    _ = try target.delete(db)
                }
                root.path = path
                try root.update(db)
            }
            if stored != nil {
                var committed = move
                committed.metadataApplied = true
                let value = String(decoding: try JSONEncoder().encode(committed), as: UTF8.self)
                try db.execute(sql: "UPDATE setting SET value = ? WHERE key = ?", arguments: [value, move.settingKey])
            }
        }
    }
}
