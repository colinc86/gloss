import Foundation
import GRDB

/// Database schema. Every change is a new migration appended to `migrator`; `v1` is never edited.
public enum Schema {
    public static let tableNames = [
        "host", "root", "document", "note", "attachment", "send", "send_note", "staged_file", "target", "setting", "web_page", "note_message",
        "iteration", "snapshot", "refinement", "collaboration_document", "collaboration_review", "collaboration_seen", "collaboration_note_map", "collaboration_message_map", "agent_note_snapshot",
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
        migrator.registerMigration("v6-orphan-state") { db in
            // The state a note had when it lost its place, so finding it again puts it back as it was (a sent note
            // stays sent) instead of always making it a draft.
            try db.execute(sql: "ALTER TABLE note ADD COLUMN previous_state TEXT")
        }
        migrator.registerMigration("v7-note-author") { db in
            // Who wrote the note: NULL for the user, the agent's name for a question an agent asked (issue #4).
            try db.execute(sql: "ALTER TABLE note ADD COLUMN author TEXT")
        }
        migrator.registerMigration("v8-embedded-image-anchors") { db in
            // A note can anchor to a picture embedded in a document (#2 follow-up: a region of a ticket's screenshot).
            // SQLite cannot widen a CHECK in place, so the note table is rebuilt as v4 did, every column kept.
            try db.execute(sql: """
                CREATE TABLE note_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                    anchor_json TEXT NOT NULL,
                    anchor_type TEXT NOT NULL CHECK (anchor_type IN ('text', 'image', 'pdf', 'file', 'element', 'embedded-image')),
                    body TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('draft', 'sent', 'resolved', 'orphaned')),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    color TEXT NOT NULL,
                    resolve_outcome TEXT,
                    resolve_message TEXT,
                    previous_state TEXT,
                    author TEXT
                );
                INSERT INTO note_new (id, document_id, anchor_json, anchor_type, body, state, created_at, updated_at, color, resolve_outcome, resolve_message, previous_state, author)
                    SELECT id, document_id, anchor_json, anchor_type, body, state, created_at, updated_at, color, resolve_outcome, resolve_message, previous_state, author FROM note;
                DROP TABLE note;
                ALTER TABLE note_new RENAME TO note;
                CREATE INDEX note_document_state ON note(document_id, state);
                """)
        }
        migrator.registerMigration("v9-resolve-agent") { db in
            // The agent that resolved the note through MCP, by the name its client gave: a note sent by clipboard
            // has no agent of its own to name the reply after.
            try db.execute(sql: "ALTER TABLE note ADD COLUMN resolve_agent TEXT")
        }
        migrator.registerMigration("v10-web-pages") { db in
            // Pages visited, for the explorer's Web section and Open Quickly: by URL and the host it was reached
            // on (`h_web`, or an ssh host whose loopback it is), so the same localhost on two machines is two pages.
            try db.execute(sql: """
                CREATE TABLE web_page (
                    url TEXT NOT NULL,
                    host_id TEXT NOT NULL REFERENCES host(id) ON DELETE CASCADE,
                    title TEXT,
                    last_visited_at DATETIME NOT NULL,
                    pinned BOOLEAN NOT NULL DEFAULT 0,
                    PRIMARY KEY (url, host_id)
                );
                CREATE INDEX web_page_recent ON web_page(pinned, last_visited_at);
                """)
        }
        migrator.registerMigration("v11-note-threads") { db in
            // A note becomes a thread: its comment stays in `body`, and every later turn (the user's follow-ups, an
            // agent's replies and questions, moves) is a message. An agent's question no longer resolves the note;
            // it leaves it open and waiting on the user. `original_anchor_*` is where the note was before it first moved.
            try db.execute(sql: """
                CREATE TABLE note_message (
                    id TEXT PRIMARY KEY NOT NULL,
                    note_id TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    author TEXT,
                    kind TEXT NOT NULL CHECK (kind IN ('comment', 'question', 'reply', 'moved')),
                    body TEXT NOT NULL,
                    meta_json TEXT,
                    created_at DATETIME NOT NULL,
                    sent_at DATETIME
                );
                CREATE INDEX note_message_note ON note_message(note_id);
                ALTER TABLE note ADD COLUMN waiting_on_user INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE note ADD COLUMN original_anchor_json TEXT;
                ALTER TABLE note ADD COLUMN original_anchor_type TEXT;
                """)
            try Self.splitLegacyThreads(db)
        }
        migrator.registerMigration("v12-note-trash") { db in
            // Deleting a note puts it in Recently Deleted (issue #15): the row stays, with its thread, attachments and
            // sends, until it is restored, deleted for good, or purged after the retention the user picked.
            try db.execute(sql: "ALTER TABLE note ADD COLUMN deleted_at DATETIME")
            try db.execute(sql: "CREATE INDEX note_deleted_at ON note(deleted_at)")
        }
        migrator.registerMigration("v13-iterations") { db in
            // Iterations (issue #18): numbered rounds of notes on one document, from 0. Ending one keeps the content
            // its notes were taken on as a snapshot, de-duplicated by hash and zlib-compressed, so an unchanged file
            // costs nothing. Every note so far is in iteration 0, which starts with the document's first note.
            try db.execute(sql: """
                ALTER TABLE document ADD COLUMN current_iteration INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE note ADD COLUMN iteration INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX note_document_iteration ON note(document_id, iteration);
                CREATE TABLE snapshot (
                    hash TEXT PRIMARY KEY NOT NULL,
                    data BLOB NOT NULL,
                    size INTEGER NOT NULL,
                    created_at DATETIME NOT NULL
                );
                CREATE TABLE iteration (
                    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                    number INTEGER NOT NULL,
                    name TEXT,
                    started_at DATETIME NOT NULL,
                    ended_at DATETIME,
                    snapshot_hash TEXT,
                    git_commit TEXT,
                    PRIMARY KEY (document_id, number)
                );
                INSERT INTO iteration (document_id, number, started_at)
                    SELECT document_id, 0, MIN(created_at) FROM note GROUP BY document_id;
                """)
        }
        migrator.registerMigration("v14-review") { db in
            // Review (2026-10-10): a send can ask the user to review what the agent did; its notes, once resolved,
            // wait for the user to accept them. Accepting is the user's own stamp, apart from the agent's resolve.
            try db.execute(sql: """
                ALTER TABLE send ADD COLUMN review INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE note ADD COLUMN review_requested INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE note ADD COLUMN accepted_at DATETIME;
                """)
        }
        migrator.registerMigration("v15-iteration-completion") { db in
            // Completion is recorded in the same transaction as the last resolve, including writes outside the UI.
            try db.execute(sql: """
                ALTER TABLE iteration ADD COLUMN start_hash TEXT;
                ALTER TABLE iteration ADD COLUMN completion_generation INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE iteration ADD COLUMN handled_generation INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE iteration ADD COLUMN completed_at DATETIME;
                ALTER TABLE note ADD COLUMN iteration_joined_at DATETIME;
                UPDATE note SET iteration_joined_at = created_at;
                CREATE TRIGGER note_iteration_joined AFTER INSERT ON note
                BEGIN
                    UPDATE note SET iteration_joined_at = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id = NEW.id;
                END;
                UPDATE iteration SET start_hash = (SELECT previous.snapshot_hash FROM iteration AS previous
                    WHERE previous.document_id = iteration.document_id AND previous.number = iteration.number - 1);
                CREATE TRIGGER iteration_last_resolve AFTER UPDATE OF state ON note
                WHEN OLD.state != 'resolved' AND NEW.state = 'resolved' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NULL
                    AND OLD.iteration = NEW.iteration
                    AND NEW.iteration = (SELECT current_iteration FROM document WHERE id = NEW.document_id)
                    AND NOT EXISTS (SELECT 1 FROM note WHERE document_id = NEW.document_id
                        AND iteration = NEW.iteration AND deleted_at IS NULL AND state != 'resolved')
                BEGIN
                    UPDATE iteration SET completion_generation = completion_generation + 1, completed_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
                        WHERE document_id = NEW.document_id AND number = NEW.iteration;
                END;
                CREATE TRIGGER iteration_last_trash AFTER UPDATE OF deleted_at ON note
                WHEN OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND OLD.state != 'resolved'
                    AND NEW.iteration = (SELECT current_iteration FROM document WHERE id = NEW.document_id)
                    AND EXISTS (SELECT 1 FROM note WHERE document_id = NEW.document_id
                        AND iteration = NEW.iteration AND deleted_at IS NULL)
                    AND NOT EXISTS (SELECT 1 FROM note WHERE document_id = NEW.document_id
                        AND iteration = NEW.iteration AND deleted_at IS NULL AND state != 'resolved')
                BEGIN
                    UPDATE iteration SET completion_generation = completion_generation + 1, completed_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
                        WHERE document_id = NEW.document_id AND number = NEW.iteration;
                END;
                """)
        }
        migrator.registerMigration("v16-refinement") { db in
            try db.execute(sql: """
                ALTER TABLE note_message ADD COLUMN choices_json TEXT;
                ALTER TABLE note_message ADD COLUMN in_reply_to TEXT REFERENCES note_message(id) ON DELETE SET NULL;
                ALTER TABLE note_message ADD COLUMN selected_options_json TEXT;
                ALTER TABLE note_message ADD COLUMN custom_answer INTEGER NOT NULL DEFAULT 0;
                CREATE UNIQUE INDEX choice_answer_draft ON note_message(in_reply_to)
                    WHERE sent_at IS NULL AND custom_answer = 0 AND selected_options_json IS NOT NULL;
                CREATE TABLE refinement (
                    document_id TEXT PRIMARY KEY NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                    generation TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('starting', 'active', 'completed', 'ended')),
                    round INTEGER NOT NULL DEFAULT 1,
                    request_note_id TEXT REFERENCES note(id) ON DELETE SET NULL,
                    target_json TEXT NOT NULL,
                    started_at DATETIME NOT NULL,
                    completed_at DATETIME,
                    summary TEXT,
                    error TEXT,
                    awaiting_next_round INTEGER NOT NULL DEFAULT 0,
                    has_answers INTEGER NOT NULL DEFAULT 0,
                    dismissed INTEGER NOT NULL DEFAULT 0
                );
                """)
        }
        migrator.registerMigration("v17-collaboration") { db in
            try db.execute(sql: """
                CREATE TABLE host_new (
                    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL CHECK (kind IN ('local','ssh','web','github','atlassian','gloss')),
                    last_connected_at DATETIME, origin TEXT NOT NULL DEFAULT 'ssh_config', options_json TEXT
                );
                INSERT INTO host_new SELECT * FROM host;
                DROP TABLE host;
                ALTER TABLE host_new RENAME TO host;
                """)
            try Self.moveAliasesOffVirtualNames(db,includingRenamed: false,names: ["gloss"])
            try db.execute(sql: """
                INSERT INTO host (id,name,kind,origin) VALUES ('h_gloss','gloss','gloss','local');
                ALTER TABLE note ADD COLUMN resolved_at DATETIME;
                ALTER TABLE note ADD COLUMN contributor_id TEXT;
                ALTER TABLE note ADD COLUMN contributor_name TEXT;
                ALTER TABLE note ADD COLUMN published_at DATETIME;
                ALTER TABLE note ADD COLUMN posted_to_owner INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE note ADD COLUMN published_body TEXT;
                ALTER TABLE note ADD COLUMN published_color TEXT;
                ALTER TABLE note ADD COLUMN collaboration_event_id TEXT;
                ALTER TABLE note ADD COLUMN collaboration_move_id TEXT;
                ALTER TABLE note ADD COLUMN collaboration_move_at DATETIME;
                ALTER TABLE note ADD COLUMN local_state_at DATETIME;
                CREATE TABLE agent_note_snapshot (
                    note_id TEXT PRIMARY KEY NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    note_json TEXT NOT NULL, attachments_json TEXT NOT NULL
                );
                CREATE TABLE collaboration_document (
                    instance TEXT PRIMARY KEY NOT NULL,
                    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE
                );
                CREATE TABLE collaboration_review (
                    instance TEXT PRIMARY KEY NOT NULL,
                    url TEXT NOT NULL,
                    document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                    title TEXT NOT NULL, owner_author TEXT NOT NULL,
                    is_owner INTEGER NOT NULL, is_copy INTEGER NOT NULL,
                    UNIQUE(document_id)
                );
                ALTER TABLE note_message ADD COLUMN contributor_id TEXT;
                ALTER TABLE note_message ADD COLUMN contributor_name TEXT;
                ALTER TABLE note_message ADD COLUMN agent_sent_at DATETIME;
                UPDATE note_message SET agent_sent_at=sent_at WHERE author='user' AND sent_at IS NOT NULL;
                CREATE TABLE collaboration_note_map (
                    instance TEXT NOT NULL REFERENCES collaboration_document(instance) ON DELETE CASCADE,
                    remote_id TEXT NOT NULL, local_id TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    PRIMARY KEY(instance,remote_id), UNIQUE(instance,local_id)
                );
                CREATE TABLE collaboration_message_map (
                    instance TEXT NOT NULL REFERENCES collaboration_document(instance) ON DELETE CASCADE,
                    remote_id TEXT NOT NULL, local_id TEXT NOT NULL REFERENCES note_message(id) ON DELETE CASCADE,
                    PRIMARY KEY(instance,remote_id), UNIQUE(instance,local_id)
                );
                CREATE TABLE collaboration_seen (
                    instance TEXT NOT NULL REFERENCES collaboration_review(instance) ON DELETE CASCADE,
                    record_id TEXT NOT NULL, PRIMARY KEY(instance,record_id)
                );
                """)
        }
        return migrator
    }

    /// Moves the exchanges folded into note bodies into messages, and turns questions stored as `resolved` +
    /// `needs_input` into open notes waiting on the user.
    static func splitLegacyThreads(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, body, state, previous_state, author, resolve_outcome, resolve_message, resolve_agent, updated_at
            FROM note WHERE body LIKE '%' || ? || '%' OR body LIKE '%' || ? || '%' OR resolve_message IS NOT NULL
            """, arguments: [LegacyThread.askedLabel, LegacyThread.answerLabel])
        for row in rows {
            let id: String = row["id"]
            let body: String = row["body"]
            var state: String = row["state"]
            var previousState: String? = row["previous_state"]
            let noteAuthor: String? = row["author"]
            let outcome: String? = row["resolve_outcome"]
            let resolveMessage: String? = row["resolve_message"]
            let resolveAgent: String? = row["resolve_agent"]
            // The stored value as it is, so the messages' times read back exactly as the note's.
            let updatedAt: DatabaseValue = row["updated_at"]
            let thread = LegacyThread(body: body)
            func insert(author: String?, kind: MessageKind, body: String, sent: Bool) throws {
                try db.execute(sql: "INSERT INTO note_message (id, note_id, author, kind, body, meta_json, created_at, sent_at) VALUES (?, ?, ?, ?, ?, NULL, ?, ?)",
                               arguments: [MessageID.new().rawValue, id, author, kind.rawValue, body, updatedAt, sent ? updatedAt : DatabaseValue.null])
            }
            // A draft whose last turn is the user's answer hadn't sent that answer: the answer becomes the unsent
            // follow-up of a sent note, which is how an answer waits to be sent now. Only for a note an agent had (it
            // asked, or the note was delivered): a never-sent draft whose comment happens to read "Answer:" stays a draft.
            let isDraft = state == "draft" || (state == "orphaned" && previousState == "draft")
            let shared = try noteAuthor != nil || (Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM send_note JOIN send ON send.id = send_note.send_id
                               WHERE send_note.note_id = ? AND send.outcome = 'delivered')
                """, arguments: [id]) ?? false)
            let answerUnsent = isDraft && shared && thread.turns.last?.isAgent == false
            if answerUnsent {
                if state == "draft" { state = "sent" } else { previousState = "sent" }
            }
            for (offset, turn) in thread.turns.enumerated() {
                let sent = !(answerUnsent && offset == thread.turns.count - 1)
                try insert(author: turn.isAgent ? (noteAuthor ?? MessageAuthor.unnamedAgent) : MessageAuthor.userValue,
                           kind: turn.isAgent ? .question : .comment, body: turn.text, sent: sent)
            }
            var waiting = false
            var clearResolve = false
            let message = resolveMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if state == "resolved", outcome == ResolveOutcome.needsInput.rawValue {
                // A question: open again, waiting on the user. A question on a note whose text had gone stays an orphan.
                if !message.isEmpty {
                    try insert(author: resolveAgent ?? noteAuthor ?? MessageAuthor.unnamedAgent, kind: .question, body: message, sent: true)
                }
                if previousState == "orphaned" {
                    state = "orphaned"
                    previousState = "sent"
                } else {
                    state = "sent"
                    previousState = nil
                }
                waiting = true
                clearResolve = true
            } else if state == "resolved", !message.isEmpty {
                // The resolve message stays on the note (its contract), and is also the thread's last turn.
                try insert(author: resolveAgent ?? MessageAuthor.unnamedAgent, kind: .reply, body: message, sent: true)
            }
            try db.execute(sql: """
                UPDATE note SET body = ?, state = ?, previous_state = ?, waiting_on_user = ?,
                    resolve_outcome = CASE WHEN ? THEN NULL ELSE resolve_outcome END,
                    resolve_message = CASE WHEN ? THEN NULL ELSE resolve_message END,
                    resolve_agent = CASE WHEN ? THEN NULL ELSE resolve_agent END
                WHERE id = ?
                """, arguments: [thread.turns.isEmpty ? body : thread.comment, state, previousState, waiting, clearResolve, clearResolve, clearResolve, id])
        }
    }

    /// The names the integration hosts own.
    static let virtualHostNames = ["web", "github", "atlassian", "gloss"]

    /// Moves ssh rows off the integration hosts' names (first free `<name>-ssh`) and records each one's real alias
    /// in its options, including rows an earlier version already renamed without recording it.
    static func moveAliasesOffVirtualNames(_ db: Database, includingRenamed: Bool, names: [String] = ["web", "github", "atlassian"]) throws {
        for name in names {
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
