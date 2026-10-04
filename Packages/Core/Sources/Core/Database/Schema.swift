import Foundation
import GRDB

/// Database schema. Every change is a new migration appended to `migrator`; `v1` is never edited.
public enum Schema {
    public static let tableNames = [
        "host", "root", "document", "note", "attachment", "send", "send_note", "staged_file", "target", "setting",
    ]

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE host (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL CHECK (kind IN ('local', 'ssh')),
                    last_connected_at DATETIME
                );
                CREATE TABLE root (
                    id TEXT PRIMARY KEY NOT NULL,
                    host_id TEXT NOT NULL REFERENCES host(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    last_opened_at DATETIME NOT NULL,
                    pinned BOOLEAN NOT NULL DEFAULT 0,
                    UNIQUE (host_id, path)
                );
                CREATE TABLE document (
                    id TEXT PRIMARY KEY NOT NULL,
                    host_id TEXT NOT NULL REFERENCES host(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('text', 'code', 'markdown', 'image', 'pdf', 'csv', 'file')),
                    last_hash TEXT,
                    last_mtime DATETIME,
                    last_size INTEGER,
                    UNIQUE (host_id, path)
                );
                CREATE TABLE note (
                    id TEXT PRIMARY KEY NOT NULL,
                    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                    anchor_json TEXT NOT NULL,
                    anchor_type TEXT NOT NULL CHECK (anchor_type IN ('text', 'image', 'pdf', 'file')),
                    body TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('draft', 'sent', 'resolved', 'orphaned')),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    color TEXT NOT NULL,
                    resolve_outcome TEXT,
                    resolve_message TEXT
                );
                CREATE INDEX note_document_state ON note(document_id, state);
                CREATE TABLE attachment (
                    id TEXT PRIMARY KEY NOT NULL,
                    note_id TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK (kind IN ('crop', 'page_render')),
                    local_path TEXT NOT NULL,
                    width INTEGER NOT NULL,
                    height INTEGER NOT NULL
                );
                CREATE TABLE send (
                    id TEXT PRIMARY KEY NOT NULL,
                    target_json TEXT NOT NULL,
                    transport TEXT NOT NULL,
                    packet_text TEXT NOT NULL,
                    sent_at DATETIME NOT NULL,
                    outcome TEXT NOT NULL
                );
                CREATE TABLE send_note (
                    send_id TEXT NOT NULL REFERENCES send(id) ON DELETE CASCADE,
                    note_id TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    PRIMARY KEY (send_id, note_id)
                );
                CREATE TABLE staged_file (
                    id TEXT PRIMARY KEY NOT NULL,
                    send_id TEXT NOT NULL REFERENCES send(id) ON DELETE CASCADE,
                    host_id TEXT NOT NULL REFERENCES host(id) ON DELETE CASCADE,
                    remote_path TEXT NOT NULL,
                    expires_at DATETIME NOT NULL
                );
                CREATE INDEX staged_file_expires ON staged_file(expires_at);
                CREATE TABLE target (
                    id TEXT PRIMARY KEY NOT NULL,
                    host_id TEXT NOT NULL REFERENCES host(id) ON DELETE CASCADE,
                    transport TEXT NOT NULL,
                    identity_json TEXT NOT NULL,
                    label TEXT NOT NULL,
                    last_used_at DATETIME,
                    UNIQUE (host_id, transport, identity_json)
                );
                CREATE TABLE setting (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                INSERT INTO host (id, name, kind, last_connected_at) VALUES ('h_local', 'local', 'local', NULL);
                """)
        }
        migrator.registerMigration("v2-host-options") { db in
            // Hosts come from ~/.ssh/config or are added in the app; app-added ones carry their ssh options.
            try db.execute(sql: "ALTER TABLE host ADD COLUMN origin TEXT NOT NULL DEFAULT 'ssh_config'")
            try db.execute(sql: "ALTER TABLE host ADD COLUMN options_json TEXT")
            try db.execute(sql: "UPDATE host SET origin = 'local' WHERE kind = 'local'")
        }
        migrator.registerMigration("v3-send-note-index") { db in
            // Note cards look up their latest send by note; the primary key leads with send_id.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS send_note_note ON send_note(note_id)")
        }
        migrator.registerMigration("v4-integrations") { db in
            // Milestone 2: web pages, GitHub and Atlassian are hosts (an ssh alias that already took one of their
            // names becomes `<name>-ssh`, since host names are unique), a live page is a document kind, and a note can
            // anchor to a DOM element. SQLite cannot widen a CHECK in place, so each table is rebuilt in GRDB's
            // documented order (create, copy, drop, rename, recreate indexes) with foreign keys off for the
            // migration: host first, then document, then note, each new table referencing the final names.
            try db.execute(sql: """
                CREATE TABLE host_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL CHECK (kind IN ('local', 'ssh', 'web', 'github', 'atlassian')),
                    last_connected_at DATETIME,
                    origin TEXT NOT NULL DEFAULT 'ssh_config',
                    options_json TEXT
                );
                INSERT INTO host_new (id, name, kind, last_connected_at, origin, options_json)
                    SELECT id, name, kind, last_connected_at, origin, options_json FROM host;
                DROP TABLE host;
                ALTER TABLE host_new RENAME TO host;
                """)
            // An ssh alias that took a name the integration hosts need moves to the first free `<name>-ssh` (a
            // database may hold `web-ssh` already) and remembers its alias, which is what ssh is still given.
            try Self.moveAliasesOffVirtualNames(db, includingRenamed: false)
            try db.execute(sql: """
                INSERT INTO host (id, name, kind, last_connected_at, origin, options_json) VALUES
                    ('h_web', 'web', 'web', NULL, 'local', NULL),
                    ('h_github', 'github', 'github', NULL, 'local', NULL),
                    ('h_atlassian', 'atlassian', 'atlassian', NULL, 'local', NULL);
                CREATE TABLE document_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    host_id TEXT NOT NULL REFERENCES host(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('text', 'code', 'markdown', 'image', 'pdf', 'csv', 'file', 'web')),
                    last_hash TEXT,
                    last_mtime DATETIME,
                    last_size INTEGER,
                    UNIQUE (host_id, path)
                );
                INSERT INTO document_new (id, host_id, path, kind, last_hash, last_mtime, last_size)
                    SELECT id, host_id, path, kind, last_hash, last_mtime, last_size FROM document;
                DROP TABLE document;
                ALTER TABLE document_new RENAME TO document;
                CREATE TABLE note_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                    anchor_json TEXT NOT NULL,
                    anchor_type TEXT NOT NULL CHECK (anchor_type IN ('text', 'image', 'pdf', 'file', 'element')),
                    body TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('draft', 'sent', 'resolved', 'orphaned')),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    color TEXT NOT NULL,
                    resolve_outcome TEXT,
                    resolve_message TEXT
                );
                INSERT INTO note_new (id, document_id, anchor_json, anchor_type, body, state, created_at, updated_at, color, resolve_outcome, resolve_message)
                    SELECT id, document_id, anchor_json, anchor_type, body, state, created_at, updated_at, color, resolve_outcome, resolve_message FROM note;
                DROP TABLE note;
                ALTER TABLE note_new RENAME TO note;
                CREATE INDEX note_document_state ON note(document_id, state);
                """)
        }
        migrator.registerMigration("v5-host-alias") { db in
            // Databases migrated before v4 kept the real alias: an ssh row renamed to `github-ssh` there learns that
            // its alias is `github`, so ssh is given the name it knows.
            // A row named `<name>-ssh` from the config looks the same whether an earlier v4 renamed it or the
            // config really says `Host github-ssh`; it is tagged here and the host list clears the tag when the
            // config lists the name but not the alias.
            try Self.moveAliasesOffVirtualNames(db, includingRenamed: true)
        }
        return migrator
    }

    /// The names the integration hosts own.
    static let virtualHostNames = ["web", "github", "atlassian"]

    /// Moves ssh rows off the integration hosts' names (first free `<name>-ssh`) and records each one's real alias
    /// in its options, including rows an earlier version already renamed without recording it.
    static func moveAliasesOffVirtualNames(_ db: Database, includingRenamed: Bool) throws {
        for name in virtualHostNames {
            let sql = includingRenamed
                ? "SELECT id, name, options_json FROM host WHERE kind = 'ssh' AND (name = ? OR (name = ? AND origin = 'ssh_config'))"
                : "SELECT id, name, options_json FROM host WHERE kind = 'ssh' AND name = ?"
            let arguments: StatementArguments = includingRenamed ? [name, name + "-ssh"] : [name]
            for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
                let id: String = row["id"]
                let current: String = row["name"]
                let stored: String? = row["options_json"]
                // Options that cannot be read are left alone rather than overwritten.
                var options: HostOptions
                if let stored {
                    guard let decoded = try? JSONDecoder().decode(HostOptions.self, from: Data(stored.utf8)) else { continue }
                    options = decoded
                } else {
                    options = HostOptions()
                }
                if options.alias == nil { options.alias = name }
                let json = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
                let newName = current == name ? try NoteStore.freeName(for: name, suffix: "ssh", db) : current
                try db.execute(sql: "UPDATE host SET name = ?, options_json = ? WHERE id = ?", arguments: [newName, json, id])
            }
        }
    }
}
