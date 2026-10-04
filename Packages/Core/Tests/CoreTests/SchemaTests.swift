import Foundation
import GRDB
import Testing
@testable import Core

struct SchemaTests {
    /// Column name → declared type, for every table in docs/PRODUCT.md. A schema drift fails here.
    static let expected: [String: [(String, String)]] = [
        "host": [("id", "TEXT"), ("name", "TEXT"), ("kind", "TEXT"), ("last_connected_at", "DATETIME"), ("origin", "TEXT"), ("options_json", "TEXT")],
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

    @Test func fixedHostsAreSeeded() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let hosts = try await store.hosts()
        #expect(Set(hosts.map(\.name)) == ["local", "web", "github", "atlassian"])
        let byID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        #expect(byID[.local]?.kind == .local)
        #expect(byID[.web]?.kind == .web && byID[.github]?.kind == .github && byID[.atlassian]?.kind == .atlassian)
        #expect(byID[.web]?.origin == .local && byID[.web]?.isVirtual == true && byID[.local]?.isVirtual == false)
        for id in HostID.fixed {
            #expect(HostID(validating: id.rawValue) == id, "fixed ids pass validation without a ULID")
        }
        #expect(HostID(validating: "h_nope") == nil)
        let alias = try await store.upsertHost(name: "github", kind: .ssh)
        #expect(alias.name == "github-ssh" && alias.kind == .ssh, "an ssh alias never merges with the GitHub host")
        #expect(alias.options?.alias == "github", "ssh is still given the alias it knows")
        #expect(try await store.upsertHost(name: "github", kind: .ssh).id == alias.id)
        // A host somebody added as web-ssh does not stand in for the alias web.
        _ = try await store.saveHost(id: nil, name: "web-ssh", options: HostOptions(hostName: "10.0.0.9"))
        let web = try await store.upsertHost(name: "web", kind: .ssh)
        #expect(web.name == "web-ssh-2" && web.options?.alias == "web")
    }

    /// The milestone 2 migration rebuilds host, document and note to widen their CHECK constraints; every row written
    /// before it must come through byte for byte, with the references between them intact.
    @Test func v4RebuildKeepsEveryRow() throws {
        let database = try AppDatabase.inMemory()
        // `AppDatabase.inMemory` already migrated fully; build a v3 database by hand instead and migrate it.
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v3-send-note-index")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO host (id, name, kind, last_connected_at, origin, options_json) VALUES ('h_01HOST', 'asus', 'ssh', '2026-10-01 10:00:00', 'manual', '{"user":"colin"}');
                INSERT INTO host (id, name, kind, last_connected_at, origin, options_json) VALUES ('h_01GITH', 'github', 'ssh', NULL, 'ssh_config', NULL);
                INSERT INTO host (id, name, kind, last_connected_at, origin, options_json) VALUES ('h_01WEB1', 'web', 'ssh', NULL, 'ssh_config', NULL);
                INSERT INTO host (id, name, kind, last_connected_at, origin, options_json) VALUES ('h_01WEB2', 'web-ssh', 'ssh', NULL, 'manual', '{"hostName":"10.0.0.9","user":"","identityFile":""}');
                INSERT INTO root (id, host_id, path, last_opened_at, pinned) VALUES ('r_1', 'h_01HOST', '/home/colin', '2026-10-01 10:00:00', 1);
                INSERT INTO document (id, host_id, path, kind, last_hash, last_mtime, last_size) VALUES ('d_1', 'h_01HOST', '/home/colin/a.md', 'markdown', 'abc', '2026-10-01 10:00:00', 12);
                INSERT INTO note (id, document_id, anchor_json, anchor_type, body, state, created_at, updated_at, color, resolve_outcome, resolve_message)
                    VALUES ('n_1', 'd_1', '{}', 'file', 'hi', 'resolved', '2026-10-01 10:00:00', '2026-10-01 10:00:01', 'yellow', 'done', 'ok');
                INSERT INTO attachment (id, note_id, kind, local_path, width, height) VALUES ('a_1', 'n_1', 'crop', '/tmp/c.png', 1, 2);
                INSERT INTO send (id, target_json, transport, packet_text, sent_at, outcome) VALUES ('s_1', '{}', 'clipboard', 'p', '2026-10-01 10:00:00', 'ok');
                INSERT INTO send_note (send_id, note_id) VALUES ('s_1', 'n_1');
                INSERT INTO staged_file (id, send_id, host_id, remote_path, expires_at) VALUES ('f_1', 's_1', 'h_01HOST', '/tmp/x', '2026-10-08 10:00:00');
                INSERT INTO target (id, host_id, transport, identity_json, label, last_used_at) VALUES ('t_1', 'h_01HOST', 'tmux', '{}', 'pane', NULL);
                """)
        }
        func rows(_ db: Database, _ table: String) throws -> [[String: DatabaseValue]] {
            try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1").map { row in Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, row[$0] as DatabaseValue) }) }
        }
        let before = try queue.read { db in try Schema.tableNames.map { try rows(db, $0) } }
        try Schema.migrator.migrate(queue)
        let after = try queue.read { db in try Schema.tableNames.map { try rows(db, $0) } }
        for (index, table) in Schema.tableNames.enumerated() where table != "host" {
            #expect(before[index] == after[index], "\(table) rows survive the rebuild")
        }
        try queue.read { (db: Database) throws in
            #expect(try rows(db, "host").count == before[0].count + 3, "the three virtual hosts are added, no host is lost")
            #expect(try String.fetchOne(db, sql: "SELECT name FROM host WHERE id = 'h_01GITH'") == "github-ssh", "an ssh alias that took a virtual host's name is renamed, not lost")
            let options = { (id: String) in try String.fetchOne(db, sql: "SELECT options_json FROM host WHERE id = ?", arguments: [id]).flatMap { try? JSONDecoder().decode(HostOptions.self, from: Data($0.utf8)) } }
            #expect(try options("h_01GITH")?.alias == "github", "it remembers the alias ssh knows it by")
            #expect(try String.fetchOne(db, sql: "SELECT name FROM host WHERE id = 'h_01WEB1'") == "web-ssh-2", "web-ssh was taken, so the next free name")
            #expect(try options("h_01WEB1")?.alias == "web")
            #expect(try options("h_01WEB2")?.alias == nil && options("h_01WEB2")?.hostName == "10.0.0.9", "an app-added host that happens to be called web-ssh is left alone")
            #expect(try String.fetchOne(db, sql: "SELECT kind FROM host WHERE name = 'github'") == "github")
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            #expect(try Row.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'note_document_state'") != nil)
        }
        try queue.write { (db: Database) throws in
            // Cascades still follow the rebuilt references.
            try db.execute(sql: "DELETE FROM host WHERE id = 'h_01HOST'")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM note") == 0, "host → document → note cascade")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM attachment") == 0)
            // The widened constraints accept the new kinds.
            try db.execute(sql: "INSERT INTO document (id, host_id, path, kind) VALUES ('d_w', 'h_web', 'https://example.com/', 'web')")
            try db.execute(sql: """
                INSERT INTO note (id, document_id, anchor_json, anchor_type, body, state, created_at, updated_at, color)
                    VALUES ('n_e', 'd_w', '{}', 'element', 'x', 'draft', '2026-10-01 10:00:00', '2026-10-01 10:00:00', 'blue')
                """)
        }
        _ = database
    }

    @Test func addingAnAttachmentTouchesItsNote() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/a.png", kind: .image, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "x", color: .yellow, at: Date(timeIntervalSince1970: 1_000))
        _ = try await store.addAttachment(noteID: note.id, kind: .crop, localPath: "/tmp/c.png", width: 1, height: 1)
        let touched = try #require(try await store.note(note.id))
        #expect(touched.updatedAt > note.updatedAt, "the panel refreshes the card when its crop arrives")
        #expect(touched.createdAt == note.createdAt)
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
