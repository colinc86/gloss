import Foundation
import GRDB
import Testing
@testable import Core

struct SchemaTests {
    /// Column name → declared type, for every table in docs/PRODUCT.md. A schema drift fails here.
    static let expected: [String: [(String, String)]] = [
        "host": [("id", "TEXT"), ("name", "TEXT"), ("kind", "TEXT"), ("last_connected_at", "DATETIME")],
        "root": [("id", "TEXT"), ("host_id", "TEXT"), ("path", "TEXT"), ("last_opened_at", "DATETIME"), ("pinned", "BOOLEAN")],
        "document": [("id", "TEXT"), ("host_id", "TEXT"), ("path", "TEXT"), ("kind", "TEXT"), ("last_hash", "TEXT"), ("last_mtime", "DATETIME"), ("last_size", "INTEGER")],
        "note": [("id", "TEXT"), ("document_id", "TEXT"), ("anchor_json", "TEXT"), ("anchor_type", "TEXT"), ("body", "TEXT"), ("state", "TEXT"), ("created_at", "DATETIME"), ("updated_at", "DATETIME"), ("color", "TEXT"), ("resolve_outcome", "TEXT"), ("resolve_message", "TEXT")],
        "attachment": [("id", "TEXT"), ("note_id", "TEXT"), ("kind", "TEXT"), ("local_path", "TEXT"), ("width", "INTEGER"), ("height", "INTEGER")],
        "send": [("id", "TEXT"), ("target_json", "TEXT"), ("transport", "TEXT"), ("packet_text", "TEXT"), ("sent_at", "DATETIME"), ("outcome", "TEXT")],
        "send_note": [("send_id", "TEXT"), ("note_id", "TEXT")],
        "staged_file": [("id", "TEXT"), ("send_id", "TEXT"), ("host_id", "TEXT"), ("remote_path", "TEXT"), ("expires_at", "DATETIME")],
        "target": [("id", "TEXT"), ("host_id", "TEXT"), ("transport", "TEXT"), ("identity_json", "TEXT"), ("label", "TEXT"), ("last_used_at", "DATETIME")],
        "setting": [("key", "TEXT"), ("value", "TEXT")],
    ]

    @Test func everyTableMatchesTheProductDoc() throws {
        let database = try AppDatabase.inMemory()
        try database.queue.read { db in
            for table in Schema.tableNames {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { ($0["name"] as String, $0["type"] as String) }
                let expected = try #require(Self.expected[table], "no expectation for \(table)")
                #expect(columns.map(\.0) == expected.map(\.0), "\(table) column names")
                #expect(columns.map(\.1) == expected.map(\.1), "\(table) column types")
            }
        }
    }

    @Test func localHostIsSeeded() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let hosts = try await store.hosts()
        #expect(hosts.map(\.name) == ["local"])
        #expect(hosts.first?.id == HostID.local)
        #expect(hosts.first?.kind == .local)
    }

    @Test func foreignKeysAreEnforcedAndCascade() async throws {
        let database = try AppDatabase.inMemory()
        let store = NoteStore(database: database)
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/a.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "x", color: .yellow)
        _ = try await store.addAttachment(noteID: note.id, kind: .crop, localPath: "/tmp/c.png", width: 1, height: 1)
        try await database.queue.write { db in
            _ = try DocumentRecord.deleteOne(db, key: document.id.rawValue)
        }
        let remainingNotes = try await database.queue.read { db in try NoteRecord.fetchCount(db) }
        let remainingAttachments = try await database.queue.read { db in try AttachmentRecord.fetchCount(db) }
        #expect(remainingNotes == 0)
        #expect(remainingAttachments == 0)
        await #expect(throws: (any Error).self) {
            _ = try await store.createNote(documentID: DocumentID.new(), anchor: .wholeFile, body: "orphan", color: .blue)
        }
    }

    @Test func temporaryDatabaseIsRemovedOnClose() throws {
        let database = try AppDatabase.temporary()
        let path = database.queue.path
        #expect(FileManager.default.fileExists(atPath: path))
        try database.close()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
