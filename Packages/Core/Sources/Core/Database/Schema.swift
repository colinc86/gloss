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
        return migrator
    }
}
