import Foundation
import GRDB
import Testing
@testable import Core

/// Recently Deleted (issue #15): a deleted note keeps its row until it is restored, deleted for good, or purged.
struct NoteTrashTests {
    func makeStore() throws -> NoteStore {
        NoteStore(database: try AppDatabase.inMemory())
    }

    func makeDocument(_ store: NoteStore, path: String = "/tmp/proj/a.md") async throws -> Document {
        try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint(mtime: Date(timeIntervalSince1970: 1), size: 1, hash: "h"))
    }

    @Test func aTrashedNoteIsLeftOutOfEveryRead() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let kept = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "kept", color: .blue)
        let gone = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "gone", color: .pink)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [kept.id, gone.id], outcome: .delivered)
        let question = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Which?", author: "claude")
        var notes = store.observeNotes(for: document.id).makeAsyncIterator()
        var documents = store.observeDocumentsWithNotes().makeAsyncIterator()
        #expect(try await notes.next()?.count == 3)
        #expect(try await documents.next()?.first?.notes.count == 3)

        try await store.trashNotes([gone.id, question.id])
        #expect(try await notes.next()?.map(\.id) == [kept.id], "the document's observer drops it")
        #expect(try await documents.next()?.first?.notes.map(\.id) == [kept.id], "the panel's observer drops it")
        #expect(try await store.note(gone.id) == nil)
        #expect(try await store.notes(for: document.id).map(\.id) == [kept.id])
        #expect(try await store.documentsWithNotes().flatMap(\.notes).map(\.id) == [kept.id])
        #expect(try await store.pendingNotes().map(\.note.id) == [kept.id])
        #expect(try await store.sharedNoteIDs() == [kept.id])
        #expect(try await store.isTrashed(gone.id))
        #expect(try await store.isTrashed(kept.id) == false)

        // An agent can't write to it; it is told the note was deleted.
        await #expect(throws: NoteStoreError.noteDeleted(gone.id)) { try await store.resolveSent(gone.id) }
        await #expect(throws: NoteStoreError.noteDeleted(question.id)) { try await store.agentReply(question.id, body: "More?", asks: true, agent: "claude") }
        #expect(NoteStoreError.noteDeleted(gone.id).localizedDescription == "Note \(gone.id.rawValue) was deleted by the user.")

        // Trashing every note leaves the document out of the panel, but not out of what keeps its host and path.
        try await store.trashNotes([kept.id])
        #expect(try await store.documentsWithNotes().isEmpty)
        #expect(try await store.documentsWithAnyNotes().map(\.id) == [document.id])
        #expect(try await store.wasShared(gone.id), "it was delivered before it was deleted")
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "draft", color: .yellow)
        #expect(try await store.wasShared(draft.id) == false)
    }

    @Test func untrashingBringsTheNoteBackWithItsThread() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let note = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Which one?", author: "claude")
        try await store.addFollowUp(note.id, body: "The first.")
        _ = try await store.addAttachment(noteID: note.id, kind: .crop, localPath: "/tmp/crop.png", width: 4, height: 4)
        let before = try #require(try await store.note(note.id))
        let thread = try await store.messages(for: note.id)

        try await store.trashNotes([note.id], at: Date(timeIntervalSince1970: 1_000))
        let trashed = try await store.trashedNotes(underRoot: "/tmp/proj", hostID: .local)
        #expect(trashed.map(\.id) == [note.id])
        #expect(trashed.first?.deletedAt == Date(timeIntervalSince1970: 1_000))
        #expect(trashed.first?.document.path == "/tmp/proj/a.md")

        #expect(try await store.untrashNotes([note.id]) == [note.id])
        #expect(try await store.untrashNotes([note.id]).isEmpty, "already back")
        #expect(try await store.note(note.id) == before, "back as it was, still waiting on the user")
        #expect(try await store.messages(for: note.id) == thread)
        #expect(try await store.attachments(for: note.id).count == 1)
        #expect(try await store.trashedNotes(underRoot: "/tmp/proj", hostID: .local).isEmpty)
    }

    @Test func recentlyDeletedIsScopedToTheRoot() async throws {
        let store = try makeStore()
        let inside = try await makeDocument(store, path: "/tmp/proj/sub/b.md")
        let sibling = try await makeDocument(store, path: "/tmp/project/c.md")
        let box = try await store.saveHost(id: nil, name: "box", options: HostOptions(hostName: "box.example"))
        let remote = try await store.upsertDocument(hostID: box.id, path: "/tmp/proj/d.md", kind: .markdown, fingerprint: Fingerprint())
        var ids: [NoteID] = []
        for document in [inside, sibling, remote] {
            ids.append(try await store.createNote(documentID: document.id, anchor: .wholeFile, body: document.path, color: .yellow).id)
        }
        try await store.trashNotes(ids)
        #expect(try await store.trashedNotes(underRoot: "/tmp/proj", hostID: .local).map(\.id) == [ids[0]], "not a sibling folder, not another host")
        #expect(try await store.trashedNotes(underRoot: "/tmp/proj/sub/b.md", hostID: .local).map(\.id) == [ids[0]])
        #expect(try await store.trashedNotes(underRoot: "/", hostID: .local).count == 2)
        #expect(try await store.trashedNotes(underRoot: "/tmp/proj", hostID: box.id).map(\.id) == [ids[2]])

        var observed = store.observeTrashedNotes(underRoot: "/tmp/proj", hostID: .local).makeAsyncIterator()
        #expect(try await observed.next()?.count == 1)
        try await store.deleteForever([ids[0]])
        #expect(try await observed.next()?.isEmpty == true)
        #expect(try await store.isTrashed(ids[0]) == false)
    }

    @Test func purgeRemovesOnlyExpiredNotes() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let old = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "old", color: .yellow)
        let young = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "young", color: .yellow)
        let live = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "live", color: .yellow)
        _ = try await store.addAttachment(noteID: old.id, kind: .crop, localPath: "/tmp/old.png", width: 1, height: 1)
        try await store.trashNotes([old.id], at: Date(timeIntervalSince1970: 100))
        try await store.trashNotes([young.id], at: Date(timeIntervalSince1970: 300))

        #expect(try await store.purgeTrash(olderThan: Date(timeIntervalSince1970: 200)) == 1)
        #expect(try await store.isTrashed(old.id) == false)
        #expect(try await store.isTrashed(young.id))
        #expect(try await store.allAttachmentPaths().isEmpty, "a purged note's attachment row goes with it")
        #expect(try await store.note(live.id) != nil)
        #expect(try await store.trashedNotes(underRoot: "/tmp", hostID: .local).map(\.id) == [young.id])
    }

    @Test func theMigrationKeepsEveryNoteLive() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v11-note-threads")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO document (id, host_id, path, kind) VALUES ('d_1', 'h_local', '/tmp/a.md', 'markdown')")
            try db.execute(sql: """
                INSERT INTO note (id, document_id, anchor_json, anchor_type, body, state, created_at, updated_at, color)
                VALUES ('n_1', 'd_1', '{}', 'file', 'Keep me', 'sent', '2026-10-01 10:00:00.000', '2026-10-01 10:00:00.000', 'yellow')
                """)
            try db.execute(sql: "INSERT INTO note_message (id, note_id, author, kind, body, created_at, sent_at) VALUES ('m_1', 'n_1', 'user', 'comment', 'More', '2026-10-01 10:00:00.000', NULL)")
        }
        try Schema.migrator.migrate(queue)
        try queue.read { db in
            let record = try #require(try NoteRecord.fetchOne(db, key: "n_1"))
            #expect(record.deletedAt == nil && record.body == "Keep me")
            #expect(try NoteMessageRecord.fetchCount(db) == 1)
        }
    }
}
