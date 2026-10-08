import Foundation
import GRDB
import Testing
@testable import Core

/// `v11-note-threads` moves the exchanges folded into note bodies into messages, by the rules the card read them with.
struct ThreadMigrationTests {
    /// A database at v10 with one document, the given notes inserted, then migrated to the latest schema.
    /// `delivered` notes were sent to an agent once.
    func migrated(_ notes: [(id: String, body: String, state: String, outcome: String?, message: String?, author: String?, agent: String?, previous: String?)],
                  delivered: [String] = []) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v10-web-pages")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO document (id, host_id, path, kind) VALUES ('d_1', 'h_local', '/tmp/a.md', 'markdown')")
            for note in notes {
                try db.execute(sql: """
                    INSERT INTO note (id, document_id, anchor_json, anchor_type, body, state, created_at, updated_at, color, resolve_outcome, resolve_message, previous_state, author, resolve_agent)
                    VALUES (?, 'd_1', '{}', 'file', ?, ?, '2026-10-01 10:00:00.000', '2026-10-02 11:00:00.000', 'yellow', ?, ?, ?, ?, ?)
                    """, arguments: [note.id, note.body, note.state, note.outcome, note.message, note.previous, note.author, note.agent])
            }
            try db.execute(sql: "INSERT INTO send (id, target_json, transport, packet_text, sent_at, outcome) VALUES ('s_1', '{}', 'clipboard', 'p', '2026-10-01 10:30:00.000', 'delivered')")
            for id in delivered { try db.execute(sql: "INSERT INTO send_note (send_id, note_id) VALUES ('s_1', ?)", arguments: [id]) }
        }
        try Schema.migrator.migrate(queue)
        return queue
    }

    func note(_ queue: DatabaseQueue, _ id: String) throws -> Note {
        try queue.read { db in try Note(record: try #require(try NoteRecord.fetchOne(db, key: id)), db) }
    }

    func messages(_ queue: DatabaseQueue, _ id: String) throws -> [NoteMessage] {
        try queue.read { db in try NoteStore.messages(NoteID(rawValue: id), db) }
    }

    @Test func aPlainNoteIsLeftAsItIs() throws {
        let queue = try migrated([("n_1", "Tighten this\nAnswer: inside the comment", "sent", nil, nil, nil, nil, nil)])
        let note = try note(queue, "n_1")
        #expect(note.body == "Tighten this\nAnswer: inside the comment" && note.state == .sent && !note.waitingOnUser)
        #expect(try messages(queue, "n_1").isEmpty)
    }

    @Test func answeredRoundsBecomeMessages() throws {
        let once = "Expand this\n\nAgent asked: Which section?\nAnswer: Install"
        let twice = once + "\n\nAgent asked: Mac or Linux?\nAnswer: Both\nand Windows"
        let queue = try migrated([
            ("n_1", once, "sent", nil, nil, nil, nil, nil),
            ("n_2", twice, "sent", nil, nil, nil, nil, nil),
            ("n_3", "Expand this\n\nAnswer: The install steps", "sent", nil, nil, nil, nil, nil),
            ("n_4", "Expand this\r\n\r\nAgent asked: Which?\r\nAnswer: Install", "sent", nil, nil, nil, nil, nil),
        ])
        #expect(try note(queue, "n_1").body == "Expand this")
        let first = try messages(queue, "n_1")
        #expect(first.map(\.kind) == [.question, .comment] && first.map(\.body) == ["Which section?", "Install"])
        #expect(first.map(\.author) == [.agent(MessageAuthor.unnamedAgent), .user])
        #expect(first.allSatisfy { $0.sentAt == $0.createdAt && $0.isSent }, "sent when the note was last changed")
        #expect(try messages(queue, "n_2").map(\.body) == ["Which section?", "Install", "Mac or Linux?", "Both\nand Windows"])
        #expect(try messages(queue, "n_3").map(\.kind) == [.comment], "an answer with no question recorded")
        #expect(try messages(queue, "n_4").map(\.body) == ["Which?", "Install"])
        #expect(try note(queue, "n_4").body == "Expand this")
    }

    @Test func anAnswerNotYetSentStaysUnsent() throws {
        let body = "Expand this\n\nAgent asked: Which section?\nAnswer: Install"
        let queue = try migrated([("n_1", body, "draft", nil, nil, nil, nil, nil), ("n_2", body, "draft", nil, nil, nil, nil, nil)], delivered: ["n_1"])
        let note = try note(queue, "n_1")
        #expect(note.state == .sent && note.hasUnsentFollowUps, "a sent note with its answer waiting to go")
        #expect(try messages(queue, "n_1").map(\.isSent) == [true, false])
        // Never given to an agent: whatever its comment reads like, it stays the user's draft.
        let draft = try self.note(queue, "n_2")
        #expect(draft.state == .draft && !draft.hasUnsentFollowUps)
    }

    @Test func aPendingQuestionWaitsOnTheUser() throws {
        let queue = try migrated([
            ("n_1", "Tighten this", "resolved", "needs_input", "Shorter, or plainer?", nil, "codex", nil),
            ("n_2", "Gone", "resolved", "needs_input", "Put it back?", nil, nil, "orphaned"),
        ])
        let note = try note(queue, "n_1")
        #expect(note.state == .sent && note.waitingOnUser && note.needsAttention)
        #expect(note.resolveOutcome == nil && note.resolveMessage == nil && note.resolveAgent == nil)
        let question = try #require(try messages(queue, "n_1").first)
        #expect(question.kind == .question && question.body == "Shorter, or plainer?" && question.author == .agent("codex"))
        let orphan = try self.note(queue, "n_2")
        #expect(orphan.state == .orphaned && orphan.waitingOnUser, "its text is still gone")
        #expect(try queue.read { db in try String.fetchOne(db, sql: "SELECT previous_state FROM note WHERE id = 'n_2'") } == "sent")
    }

    @Test func anAskUserNoteKeepsItsAgent() throws {
        let queue = try migrated([
            ("n_1", "", "resolved", "needs_input", "Is the TTL right?", "claude", nil, nil),
            ("n_2", "\n\nAgent asked: Is the TTL right?\nAnswer: Yes", "draft", nil, nil, "claude", nil, nil),
        ])
        let asked = try note(queue, "n_1")
        #expect(asked.body.isEmpty && asked.author == "claude" && asked.waitingOnUser && asked.state == .sent)
        #expect(try messages(queue, "n_1").map(\.author) == [.agent("claude")])
        let answered = try note(queue, "n_2")
        #expect(answered.body.isEmpty && answered.state == .sent && answered.hasUnsentFollowUps)
        #expect(try messages(queue, "n_2").map(\.author) == [.agent("claude"), .user])
    }

    @Test func aResolvedReplyIsKeptAndShownInTheThread() throws {
        let queue = try migrated([("n_1", "Expand this\n\nAgent asked: Which?\nAnswer: Install", "resolved", "done", "Expanded the install steps.", nil, "claude", nil)])
        let note = try note(queue, "n_1")
        #expect(note.state == .resolved && note.resolveOutcome == .done && note.resolveMessage == "Expanded the install steps.")
        let thread = try messages(queue, "n_1")
        #expect(thread.map(\.kind) == [.question, .comment, .reply])
        #expect(thread.last?.author == .agent("claude") && thread.last?.body == "Expanded the install steps.")
    }
}
