import Foundation
import GRDB
import Testing
@testable import Core

/// Iterations (issue #18): numbered rounds of notes on one document, backed by Gloss's own snapshots.
struct IterationStoreTests {
    func makeStore() throws -> NoteStore {
        NoteStore(database: try AppDatabase.inMemory())
    }

    func makeDocument(_ store: NoteStore, path: String = "/tmp/proj/a.md") async throws -> Document {
        try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint(mtime: Date(timeIntervalSince1970: 1), size: 1, hash: "h"))
    }

    @Test func theFirstNoteOpensIterationZero() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        #expect(try await store.iterations(for: document.id).isEmpty, "no notes, no iteration yet")
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow, at: Date(timeIntervalSince1970: 1_000))
        #expect(note.iteration == 0)
        let iterations = try await store.iterations(for: document.id)
        #expect(iterations.map(\.number) == [0] && iterations.first?.noteCount == 1)
        #expect(iterations.first?.startedAt == Date(timeIntervalSince1970: 1_000) && iterations.first?.endedAt == nil)
    }

    @Test func startingAnIterationCarriesOrLeavesOpenNotes() async throws {
        for choice in OpenNotesChoice.allCases {
            let store = try makeStore()
            let document = try await makeDocument(store)
            let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "draft", color: .yellow)
            let sent = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "sent", color: .yellow)
            let done = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "done", color: .yellow)
            let orphan = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "orphan", color: .yellow)
            _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [sent.id, done.id], outcome: .delivered)
            try await store.resolveSent(done.id)
            try await store.markOrphaned(orphan.id)
            let question = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Which?", author: "claude")

            let next = try await store.startIteration(documentID: document.id, openNotes: choice, snapshot: Data("v0".utf8), gitCommit: "abc1234def", at: Date(timeIntervalSince1970: 5_000))
            #expect(next == 1)
            #expect(try await store.document(document.id)?.currentIteration == 1)
            let current = Set(try await store.notes(for: document.id).map(\.id))
            let past = Set(try await store.notes(for: document.id, iteration: 0).map(\.id))
            if choice == .carry {
                #expect(current == [draft.id, sent.id, orphan.id, question.id], "draft, sent, orphaned and waiting notes come along")
                #expect(past == [done.id], "resolved notes stay put")
            } else {
                #expect(current.isEmpty)
                #expect(past == [draft.id, sent.id, done.id, orphan.id, question.id])
            }
            let iterations = try await store.iterations(for: document.id)
            #expect(iterations.map(\.number) == [0, 1])
            let ended = try #require(iterations.first)
            #expect(ended.endedAt == Date(timeIntervalSince1970: 5_000) && ended.gitCommit == "abc1234def" && ended.shortCommit == "abc1234")
            #expect(try await store.snapshot(hash: try #require(ended.snapshotHash)) == Data("v0".utf8))
            #expect(iterations.last?.snapshotHash == nil, "the current iteration has no snapshot yet")
            #expect(iterations.last?.gitCommit == "abc1234def", "the next iteration starts at the commit this one ended on")

            // The panel lists each document's current iteration.
            var panel = store.observeDocumentsWithNotes().makeAsyncIterator()
            #expect(try await panel.next()?.flatMap(\.notes).map(\.id).sorted { $0.rawValue < $1.rawValue } == current.sorted { $0.rawValue < $1.rawValue })
            // New notes go into the new iteration; the MCP view still sees every iteration's sent notes.
            let fresh = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "fresh", color: .blue)
            #expect(fresh.iteration == 1)
            #expect(try await store.pendingNotes(states: [.sent]).map(\.note.id).contains(sent.id))
        }
    }

    @Test func everyIterationsNotesComeNewestFirst() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let first = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "first", color: .yellow)
        _ = try await store.startIteration(documentID: document.id, openNotes: .leave, snapshot: Data("v0".utf8))
        let second = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "second", color: .yellow)
        _ = try await store.startIteration(documentID: document.id, openNotes: .leave, snapshot: Data("v1".utf8))
        let third = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "third", color: .yellow)
        let deleted = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "gone", color: .yellow)
        try await store.trashNotes([deleted.id])
        var stream = store.observeNotesInEveryIteration(for: document.id).makeAsyncIterator()
        let notes = try #require(try await stream.next())
        #expect(notes.map(\.id) == [third.id, second.id, first.id], "newest iteration first, deleted notes left out")
        #expect(notes.map(\.iteration) == [2, 1, 0])
    }

    @Test func snapshotsAreDeduplicatedCompressedAndPruned() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        _ = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        let big = Data(String(repeating: "the same line again\n", count: 2_000).utf8)
        try await store.startIteration(documentID: document.id, openNotes: .carry, snapshot: big)
        try await store.startIteration(documentID: document.id, openNotes: .carry, snapshot: big)
        try await store.startIteration(documentID: document.id, openNotes: .carry, snapshot: Data("changed".utf8))
        let rows = try await store.database.queue.read { db in try SnapshotRecord.fetchAll(db) }
        #expect(rows.count == 2, "an unchanged file costs nothing")
        let stored = try #require(rows.first { $0.size == Int64(big.count) })
        #expect(stored.data.count < big.count / 10, "compressed")
        let iterations = try await store.iterations(for: document.id)
        #expect(iterations[0].snapshotHash == iterations[1].snapshotHash)
        #expect(try await store.snapshot(hash: try #require(iterations[0].snapshotHash)) == big)

        // Current is 3; keeping the last 1 ended iteration keeps iteration 2's snapshot only.
        try await store.pruneSnapshots(keepingLast: 1)
        let pruned = try await store.iterations(for: document.id)
        #expect(pruned.map { $0.snapshotHash != nil } == [false, false, true, false])
        #expect(try await store.database.queue.read { db in try SnapshotRecord.fetchCount(db) } == 1, "the unused snapshot is gone")
        #expect(pruned[0].noteCount + pruned[1].noteCount + pruned[2].noteCount + pruned[3].noteCount == 1, "notes stay")
    }

    @Test func iterationsAreNamedAndLabelled() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        _ = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        try await store.renameIteration(documentID: document.id, number: 0, name: "  First pass ")
        #expect(try await store.iterations(for: document.id).first?.label == "First pass")
        try await store.renameIteration(documentID: document.id, number: 0, name: " ")
        #expect(try await store.iterations(for: document.id).first?.label.hasPrefix("Iteration 0 · ") == true)
    }

    @Test func bringingANoteForwardCopiesItIntoTheCurrentIteration() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let old = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "Still wrong", color: .pink)
        try await store.startIteration(documentID: document.id, openNotes: .leave, snapshot: Data("v0".utf8))
        let anchor = Anchor.text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 4), text: "two", before: "", after: "", hash: nil))
        let copy = try await store.bringForward(old.id, anchor: anchor, origin: "Brought forward from Iteration 0")
        #expect(copy.id != old.id && copy.iteration == 1 && copy.state == .draft && copy.body == "Still wrong" && copy.color == .pink && copy.anchor == anchor)
        #expect(try await store.messages(for: copy.id).map(\.author) == [.app])
        #expect(try await store.notes(for: document.id, iteration: 0).map(\.id) == [old.id], "the original stays where it was taken")
    }

    @Test func notesFollowingAMovedDocumentJoinItsCurrentIteration() async throws {
        let store = try makeStore()
        let old = try await makeDocument(store, path: "/tmp/proj/old.md")
        let new = try await makeDocument(store, path: "/tmp/proj/new.md")
        let moved = try await store.createNote(documentID: old.id, anchor: .wholeFile, body: "moved", color: .yellow)
        _ = try await store.createNote(documentID: new.id, anchor: .wholeFile, body: "there", color: .yellow)
        try await store.startIteration(documentID: new.id, openNotes: .leave, snapshot: nil)
        try await store.relocateDocument(hostID: .local, from: old.path, to: new.path)
        #expect(try await store.notes(for: new.id).map(\.id) == [moved.id], "into the current iteration, not one the row never had")
    }

    @Test func aNoteBroughtForwardWhoseTextIsGoneIsAnOrphan() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let old = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "gone", color: .yellow)
        try await store.startIteration(documentID: document.id, openNotes: .leave, snapshot: nil)
        let copy = try await store.bringForward(old.id, anchor: old.anchor, found: false, origin: "Brought forward from Iteration 0")
        #expect(copy.state == .orphaned)
        try await store.recoverOrphan(copy.id, anchor: .wholeFile)
        #expect(try await store.note(copy.id)?.state == .draft, "placed again, it is a draft")
    }

    @Test func aRestoredNoteGoesBackToItsOwnIteration() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        try await store.trashNotes([note.id])
        try await store.startIteration(documentID: document.id, openNotes: .carry, snapshot: nil)
        #expect(try await store.notes(for: document.id, iteration: 0).isEmpty, "a deleted note isn't carried along")
        try await store.untrashNotes([note.id])
        #expect(try await store.notes(for: document.id, iteration: 0).map(\.id) == [note.id])
        #expect(try await store.notes(for: document.id).isEmpty)
    }

    @Test func theMigrationPutsEveryNoteInIterationZero() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v12-note-trash")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO document (id, host_id, path, kind) VALUES ('d_1', 'h_local', '/tmp/a.md', 'markdown')")
            try db.execute(sql: "INSERT INTO document (id, host_id, path, kind) VALUES ('d_2', 'h_local', '/tmp/b.md', 'markdown')")
            for (id, created) in [("n_1", "2026-10-02 10:00:00.000"), ("n_2", "2026-10-01 09:00:00.000")] {
                try db.execute(sql: """
                    INSERT INTO note (id, document_id, anchor_json, anchor_type, body, state, created_at, updated_at, color)
                    VALUES (?, 'd_1', '{}', 'file', 'b', 'sent', ?, ?, 'yellow')
                    """, arguments: [id, created, created])
            }
        }
        try Schema.migrator.migrate(queue)
        try queue.read { db in
            #expect(try Int.fetchAll(db, sql: "SELECT iteration FROM note") == [0, 0])
            #expect(try Int.fetchAll(db, sql: "SELECT current_iteration FROM document ORDER BY id") == [0, 0])
            let rows = try IterationRecord.fetchAll(db)
            #expect(rows.count == 1 && rows.first?.documentId == "d_1" && rows.first?.number == 0, "only a document with notes has an iteration")
            #expect(rows.first?.startedAt == (try Date.fetchOne(db, sql: "SELECT MIN(created_at) FROM note")), "it starts with the first note")
        }
    }
}
