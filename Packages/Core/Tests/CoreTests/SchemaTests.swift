import Foundation
import GRDB
import Testing
@testable import Core

struct SchemaTests {
    /// Column name → declared type, for every table in docs/PRODUCT.md. A schema drift fails here.
    static let expected: [String: [(String, String)]] = [
        "host": [("id", "TEXT"), ("name", "TEXT"), ("kind", "TEXT"), ("last_connected_at", "DATETIME"), ("origin", "TEXT"), ("options_json", "TEXT")],
        "root": [("id", "TEXT"), ("host_id", "TEXT"), ("path", "TEXT"), ("last_opened_at", "DATETIME"), ("pinned", "BOOLEAN")],
        "document": [("id", "TEXT"), ("host_id", "TEXT"), ("path", "TEXT"), ("kind", "TEXT"), ("last_hash", "TEXT"), ("last_mtime", "DATETIME"), ("last_size", "INTEGER"), ("current_iteration", "INTEGER")],
        "note": [("id", "TEXT"), ("document_id", "TEXT"), ("anchor_json", "TEXT"), ("anchor_type", "TEXT"), ("body", "TEXT"), ("state", "TEXT"), ("created_at", "DATETIME"), ("updated_at", "DATETIME"), ("color", "TEXT"), ("resolve_outcome", "TEXT"), ("resolve_message", "TEXT"), ("previous_state", "TEXT"), ("author", "TEXT"), ("resolve_agent", "TEXT"), ("waiting_on_user", "INTEGER"), ("original_anchor_json", "TEXT"), ("original_anchor_type", "TEXT"), ("deleted_at", "DATETIME"), ("iteration", "INTEGER"), ("review_requested", "INTEGER"), ("accepted_at", "DATETIME"), ("iteration_joined_at", "DATETIME")],
        "attachment": [("id", "TEXT"), ("note_id", "TEXT"), ("kind", "TEXT"), ("local_path", "TEXT"), ("width", "INTEGER"), ("height", "INTEGER")],
        "send": [("id", "TEXT"), ("target_json", "TEXT"), ("transport", "TEXT"), ("packet_text", "TEXT"), ("sent_at", "DATETIME"), ("outcome", "TEXT"), ("review", "INTEGER")],
        "send_note": [("send_id", "TEXT"), ("note_id", "TEXT")],
        "staged_file": [("id", "TEXT"), ("send_id", "TEXT"), ("host_id", "TEXT"), ("remote_path", "TEXT"), ("expires_at", "DATETIME")],
        "target": [("id", "TEXT"), ("host_id", "TEXT"), ("transport", "TEXT"), ("identity_json", "TEXT"), ("label", "TEXT"), ("last_used_at", "DATETIME")],
        "setting": [("key", "TEXT"), ("value", "TEXT")],
        "web_page": [("url", "TEXT"), ("host_id", "TEXT"), ("title", "TEXT"), ("last_visited_at", "DATETIME"), ("pinned", "BOOLEAN")],
        "note_message": [("id", "TEXT"), ("note_id", "TEXT"), ("author", "TEXT"), ("kind", "TEXT"), ("body", "TEXT"), ("meta_json", "TEXT"), ("created_at", "DATETIME"), ("sent_at", "DATETIME"), ("choices_json", "TEXT"), ("in_reply_to", "TEXT"), ("selected_options_json", "TEXT"), ("custom_answer", "INTEGER")],
        "refinement": [("document_id", "TEXT"), ("generation", "TEXT"), ("status", "TEXT"), ("round", "INTEGER"), ("request_note_id", "TEXT"), ("target_json", "TEXT"), ("started_at", "DATETIME"), ("completed_at", "DATETIME"), ("summary", "TEXT"), ("error", "TEXT"), ("awaiting_next_round", "INTEGER"), ("has_answers", "INTEGER"), ("dismissed", "INTEGER")],
        "iteration": [("document_id", "TEXT"), ("number", "INTEGER"), ("name", "TEXT"), ("started_at", "DATETIME"), ("ended_at", "DATETIME"), ("snapshot_hash", "TEXT"), ("git_commit", "TEXT"), ("start_hash", "TEXT"), ("completion_generation", "INTEGER"), ("handled_generation", "INTEGER"), ("completed_at", "DATETIME")],
        "snapshot": [("hash", "TEXT"), ("data", "BLOB"), ("size", "INTEGER"), ("created_at", "DATETIME")],
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
        // The config also says `Host github-ssh`: that alias gets its own row, not the one standing in for github.
        let real = try await store.upsertHost(name: "github-ssh", kind: .ssh)
        #expect(real.id != alias.id && real.name == "github-ssh-2" && real.options?.alias == "github-ssh")
        // Saving an app-added host keeps an alias the editor knows nothing of.
        let saved = try await store.saveHost(id: alias.id, name: alias.name, options: HostOptions(hostName: "10.0.0.5"))
        #expect(saved.options?.alias == "github" && saved.options?.hostName == "10.0.0.5")
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
                INSERT INTO host (id, name, kind, last_connected_at, origin, options_json) VALUES ('h_01ATSS', 'atlassian-ssh', 'ssh', NULL, 'ssh_config', NULL);
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
        // Tables later migrations create are not part of the comparison.
        let tables = try queue.read { db in try Schema.tableNames.filter { try db.tableExists($0) } }
        let before = try queue.read { db in try tables.map { try rows(db, $0) } }
        try Schema.migrator.migrate(queue)
        let after = try queue.read { db in try tables.map { try rows(db, $0) } }
        for (index, table) in tables.enumerated() where table != "host" {
            // Columns later migrations add (empty for old rows) are not part of the comparison.
            let kept = after[index].map { row in row.filter { before[index].first?.keys.contains($0.key) ?? true } }
            #expect(before[index] == kept, "\(table) rows survive the rebuild")
        }
        try queue.read { (db: Database) throws in
            #expect(try rows(db, "host").count == before[0].count + 3, "the three virtual hosts are added, no host is lost")
            #expect(try String.fetchOne(db, sql: "SELECT name FROM host WHERE id = 'h_01GITH'") == "github-ssh", "an ssh alias that took a virtual host's name is renamed, not lost")
            let options = { (id: String) in try String.fetchOne(db, sql: "SELECT options_json FROM host WHERE id = ?", arguments: [id]).flatMap { try? JSONDecoder().decode(HostOptions.self, from: Data($0.utf8)) } }
            #expect(try options("h_01GITH")?.alias == "github", "it remembers the alias ssh knows it by")
            #expect(try String.fetchOne(db, sql: "SELECT name FROM host WHERE id = 'h_01WEB1'") == "web-ssh-2", "web-ssh was taken, so the next free name")
            #expect(try options("h_01WEB1")?.alias == "web")
            #expect(try options("h_01WEB2")?.alias == nil && options("h_01WEB2")?.hostName == "10.0.0.9", "an app-added host that happens to be called web-ssh is left alone")
            // A config alias really called atlassian-ssh existed before v4, so nothing renamed it; v5 cannot tell it
            // from a renamed one and tags it, and the host list clears the tag against the config.
            #expect(try String.fetchOne(db, sql: "SELECT name FROM host WHERE id = 'h_01ATSS'") == "atlassian-ssh")
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

    @Test func anOlderDatabaseIsBackedUpBeforeMigrating() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("notes.sqlite")

        // A database last opened by an older build, holding a row the user cares about.
        let old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v3-send-note-index")
        let before = try old.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM host") ?? 0 }
        try old.close()

        let database = try AppDatabase.open(at: url)
        try database.queue.close()
        let backup = directory.appendingPathComponent("notes.before-v3-send-note-index.sqlite")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let copy = try DatabaseQueue(path: backup.path)
        let (rows, applied) = try copy.read { (try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM host") ?? 0, try Schema.migrator.appliedIdentifiers($0)) }
        try copy.close()
        #expect(rows == before)
        #expect(!applied.contains("v4-integrations"), "the backup is the database as it was, before the new migrations")

        // An up-to-date database and a brand-new one are not copied.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("notes.before-") }
        #expect(leftovers == ["notes.before-v3-send-note-index.sqlite"], "one file, no WAL sidecars: \(leftovers)")
        try FileManager.default.removeItem(at: backup)
        try AppDatabase.open(at: url).queue.close()
        let fresh = directory.appendingPathComponent("fresh.sqlite")
        try AppDatabase.open(at: fresh).queue.close()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.contains(".before-") }, "\(names)")
    }
}
