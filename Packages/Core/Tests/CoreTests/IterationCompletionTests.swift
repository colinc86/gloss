import Foundation
import GRDB
import Testing
@testable import Core

struct IterationCompletionTests {
    func setUp() async throws -> (NoteStore, Document, Note, Note) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/demo.md", kind: .markdown, fingerprint: Fingerprint())
        try await store.recordIterationStart(documentID: document.id, content: Data("before".utf8))
        let a = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "A?", author: "codex")
        let b = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "B?", author: "codex")
        return (store, document, a, b)
    }

    @Test func lastResolveRecordsOneCompletionInItsTransaction() async throws {
        let (store, _, a, b) = try await setUp()
        try await store.resolve(a.id)
        #expect(try await store.pendingIterationCompletions().isEmpty)
        // A raw write exercises the trigger independently of the store's resolve entry points.
        try await store.database.queue.write { db in
            try db.execute(sql: "UPDATE note SET state = 'resolved' WHERE id = ?", arguments: [b.id.rawValue])
        }
        let pending = try await store.pendingIterationCompletions()
        #expect(pending.count == 1 && pending.first?.generation == 1)
        try await store.accept([a.id, b.id])
        #expect(try await store.pendingIterationCompletions() == pending, "acceptance is not another resolution")
    }

    @Test func concurrentFinishWritesAdvanceOnlyOnce() async throws {
        let (store, document, a, b) = try await setUp()
        async let resolveA: Void = store.resolveSent(a.id, agent: "codex")
        async let resolveB: Void = store.resolveSent(b.id, agent: "codex")
        _ = try await (resolveA, resolveB)
        let completion = try #require(try await store.pendingIterationCompletions().first)
        async let finishA = store.finishIteration(completion, content: Data("after".utf8), gitCommit: nil, enabled: true)
        async let finishB = store.finishIteration(completion, content: Data("after".utf8), gitCommit: nil, enabled: true)
        let results = try await (finishA, finishB)
        #expect(results.0 != results.1, "exactly one transaction advances")
        #expect(try await store.document(document.id)?.currentIteration == 1)
        #expect(try await store.pendingIterationCompletions().isEmpty)
        // A manual request prepared for the old round must not advance the new empty round.
        _ = try await store.startIteration(documentID: document.id, openNotes: .leave, snapshot: Data("after".utf8), expectedIteration: 0)
        #expect(try await store.document(document.id)?.currentIteration == 1)
    }

    @Test func notesCreatedDuringCompletionAreSavedAndCarriedForward() async throws {
        let (store, document, a, b) = try await setUp()
        try await store.resolve(a.id)
        try await store.resolve(b.id)
        let completion = try #require(try await store.pendingIterationCompletions().first)
        let after = completion.completedAt.addingTimeInterval(0.001)
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "new", color: .yellow, at: after)
        let question = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Next?", author: "codex", at: after)
        let copy = try await store.bringForward(a.id, anchor: .wholeFile, origin: "old", at: after)
        #expect(draft.iteration == 0 && question.iteration == 0 && copy.iteration == 0, "creation does not wait for the worker")
        #expect(try await store.finishIteration(completion, content: Data("after".utf8), gitCommit: nil, enabled: true))
        #expect(Set(try await store.notes(for: document.id).map(\.id)) == [draft.id, question.id, copy.id])
        #expect(try await store.note(question.id)?.waitingOnUser == true)
        #expect(try await store.note(a.id)?.iteration == 0)
        #expect(try await store.note(b.id)?.iteration == 0)
        #expect(try await store.pendingIterationCompletions().isEmpty)
    }

    @Test func postCompletionInsertionUsesDatabaseOrderInsteadOfItsCapturedCreationDate() async throws {
        let (store, document, a, b) = try await setUp()
        try await store.resolve(a.id)
        try await store.resolve(b.id)
        let completion = try #require(try await store.pendingIterationCompletions().first)
        // Simulates a date captured before a queued last resolve; actual insertion is after that transaction.
        let captured = completion.completedAt.addingTimeInterval(-60)
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "late", color: .yellow, at: captured)
        let question = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Late?", author: "codex", at: captured)
        let copy = try await store.bringForward(a.id, anchor: .wholeFile, origin: "late", at: captured)
        #expect(try await store.finishIteration(completion, content: Data("after".utf8), gitCommit: nil, enabled: true))
        #expect(Set(try await store.notes(for: document.id).map(\.id)) == [draft.id, question.id, copy.id])
        #expect(draft.createdAt < completion.completedAt, "user-facing creation date is preserved")
    }

    @Test func trashingTheLastOpenNoteCompletesOnlyANonemptyLiveRound() async throws {
        let (store, document, a, b) = try await setUp()
        try await store.resolve(a.id)
        try await store.trashNotes([b.id])
        let completion = try #require(try await store.pendingIterationCompletions().first)
        #expect(completion.number == 0 && completion.generation == 1)
        #expect(try await store.finishIteration(completion, content: Data("after".utf8), gitCommit: nil, enabled: true))
        #expect(try await store.document(document.id)?.currentIteration == 1)
        #expect(try await store.note(b.id) == nil)
        let only = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "only", color: .yellow)
        try await store.trashNotes([only.id])
        #expect(try await store.pendingIterationCompletions().isEmpty, "emptying a round is not completion")
    }

    @Test func aHandledFailureCannotConsumeANewerCompletion() async throws {
        let (store, document, a, b) = try await setUp()
        try await store.resolve(a.id)
        try await store.resolve(b.id)
        let first = try #require(try await store.pendingIterationCompletions().first)
        try await store.addFollowUp(a.id, body: "More")
        try await store.resolve(a.id)
        let second = try #require(try await store.pendingIterationCompletions().first)
        #expect(second.generation == first.generation + 1)
        try await store.handleIterationCompletion(first)
        #expect(try await store.pendingIterationCompletions() == [second])
        try await store.handleIterationCompletion(second)
        #expect(try await store.pendingIterationCompletions().isEmpty)
        #expect(try await store.document(document.id)?.currentIteration == 0)
    }

    @Test func unchangedOrDisabledCompletionIsConsumed() async throws {
        for enabled in [true, false] {
            let (store, document, a, b) = try await setUp()
            try await store.resolve(a.id)
            try await store.resolve(b.id)
            let completion = try #require(try await store.pendingIterationCompletions().first)
            let content = Data((enabled ? "before" : "after").utf8)
            #expect(try await !store.finishIteration(completion, content: content, gitCommit: nil, enabled: enabled))
            #expect(try await store.document(document.id)?.currentIteration == 0)
            #expect(try await store.pendingIterationCompletions().isEmpty)
            #expect(try await !store.finishIteration(completion, content: Data("later".utf8), gitCommit: nil, enabled: true))
        }
    }

    @Test func aNewRoundUsesItsStartingHashAndCarriesReviewWithoutRetriggering() async throws {
        let (store, document, a, b) = try await setUp()
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [a.id, b.id], outcome: .delivered, review: true)
        try await store.resolveSent(a.id, agent: "codex")
        try await store.resolveSent(b.id, agent: "codex")
        let completion = try #require(try await store.pendingIterationCompletions().first)
        #expect(try await store.finishIteration(completion, content: Data("after".utf8), gitCommit: nil, enabled: true))
        #expect(try await store.notes(for: document.id).allSatisfy { $0.iteration == 1 && $0.awaitsReview })
        #expect(try await store.pendingIterationCompletions().isEmpty)
        let fresh = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Fresh?", author: "codex")
        try await store.resolveSent(fresh.id, agent: "codex")
        let next = try #require(try await store.pendingIterationCompletions().first)
        #expect(next.number == 1 && next.startHash == Data("after".utf8).sha256Hex)
        #expect(try await !store.finishIteration(next, content: Data("after".utf8), gitCommit: nil, enabled: true))
        #expect(try await store.document(document.id)?.currentIteration == 1)
    }

    @Test func migrationRecoversAKnownStartingHashWithoutInventingIterationZero() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v14-review")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO document (id, host_id, path, kind, current_iteration)
                    SELECT 'd_demo', id, '/demo.md', 'markdown', 1 FROM host WHERE name = 'local';
                INSERT INTO iteration (document_id, number, started_at, snapshot_hash) VALUES ('d_demo', 0, '2026-10-12 10:00:00', 'known');
                INSERT INTO iteration (document_id, number, started_at) VALUES ('d_demo', 1, '2026-10-12 10:01:00');
                """)
        }
        try Schema.migrator.migrate(queue)
        try queue.read { (db: Database) throws in
            #expect(try String.fetchOne(db, sql: "SELECT start_hash FROM iteration WHERE number = 0") == nil)
            #expect(try String.fetchOne(db, sql: "SELECT start_hash FROM iteration WHERE number = 1") == "known")
        }
    }
}
