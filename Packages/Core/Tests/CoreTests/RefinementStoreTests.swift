import Foundation
import GRDB
import Testing
@testable import Core

struct RefinementStoreTests {
    func fixture() async throws -> (NoteStore, Document) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let doc = try await store.upsertDocument(hostID: .local, path: "/tmp/refinement.md", kind: .markdown, fingerprint: Fingerprint())
        return (store, doc)
    }
    func activate(_ store: NoteStore, _ doc: Document, generation: String = "rf_test", review: Bool = false) async throws -> Refinement {
        let state = try await store.beginRefinement(documentID: doc.id, generation: generation, targetJSON: "{}")
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "request", noteIDs: [try #require(state.requestNoteID)], outcome: .delivered, review: review)
        return try #require(try await store.refinement(for: doc.id))
    }
    @Test func severalDocumentsHaveIndependentActiveRefinements() async throws {
        let (store, doc) = try await fixture()
        let other = try await store.upsertDocument(hostID: .local, path: "/tmp/other.md", kind: .markdown, fingerprint: Fingerprint())
        _ = try await activate(store, doc)
        _ = try await activate(store, other, generation: "rf_other")
        #expect(try await store.refinements().filter(\.emitsDirective).count == 2)
        let again = try await store.beginRefinement(documentID: doc.id, generation: "rf_duplicate", targetJSON: "{}")
        #expect(again.generation == "rf_test")
        #expect(try await store.notes(for: doc.id).count == 1)
    }
    @Test func anActivationAndCompletionSurviveReopeningTheStore() async throws {
        let (store, doc) = try await fixture()
        _ = try await activate(store, doc)
        try await store.finishRefinement(documentID: doc.id, generation: "rf_test", summary: "Updated examples.")
        let reopened = NoteStore(database: store.database)
        #expect(try await reopened.refinement(for: doc.id)?.summary == "Updated examples.")
        #expect(try await reopened.refinement(for: doc.id)?.status == .completed)
    }
    @Test func endingRefinementLeavesEveryNoteAndMessageUnchanged() async throws {
        let (store, doc) = try await fixture()
        _ = try await activate(store, doc)
        let question = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Which?", author: "agent", choices: QuestionChoices(["A", "B"]))
        try await store.setChoiceSelection(questionID: try #require(try await store.messages(for: question.id).first?.id), indexes: [1])
        let before = try await store.notes(for: doc.id)
        let messages = try await store.messages(for: question.id)
        try await store.endRefinement(documentID: doc.id)
        #expect(try await store.notes(for: doc.id) == before)
        #expect(try await store.messages(for: question.id) == messages)
        #expect(try await store.refinement(for: doc.id)?.status == .ended)
    }
    @Test func aStaleFinishCannotEndANewActivation() async throws {
        let (store, doc) = try await fixture()
        _ = try await activate(store, doc)
        try await store.endRefinement(documentID: doc.id)
        _ = try await activate(store, doc, generation: "rf_new")
        await #expect(throws: RefinementError.staleGeneration) { try await store.finishRefinement(documentID: doc.id, generation: "rf_test", summary: "old") }
        try await store.endRefinement(documentID: doc.id, generation: "rf_test")
        #expect(try await store.refinement(for: doc.id)?.status == .active)
    }
    @Test func finishingIsIdempotentAndDoesNotAcceptReview() async throws {
        let (store, doc) = try await fixture()
        let state = try await activate(store, doc, review: true)
        try await store.resolveSent(try #require(state.requestNoteID), message: "Updated it.")
        try await store.finishRefinement(documentID: doc.id, generation: state.generation, summary: "First summary")
        let completed = try await store.refinement(for: doc.id)
        try await store.finishRefinement(documentID: doc.id, generation: state.generation, summary: "Second summary")
        #expect(try await store.refinement(for: doc.id) == completed)
        #expect(try await store.note(try #require(state.requestNoteID))?.awaitsReview == true)
    }
    @Test func historicalQuestionsDoNotBlockFinishing() async throws {
        let (store, doc) = try await fixture()
        _ = try await activate(store, doc)
        _ = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Old question", author: "agent")
        _ = try await store.startIteration(documentID: doc.id, openNotes: .leave, snapshot: nil)
        try await store.finishRefinement(documentID: doc.id, generation: "rf_test", summary: "Current work complete")
        #expect(try await store.refinement(for: doc.id)?.status == .completed)
    }
    @Test func migrationLeavesExistingDocumentsInactive() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v15-iteration-completion")
        try queue.write { db in try db.execute(sql: "INSERT INTO document(id,host_id,path,kind) VALUES ('d_old','h_local','/tmp/old.md','markdown')") }
        try Schema.migrator.migrate(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM refinement") } == 0)
    }
    @Test func aFailedOrUnrelatedSendDoesNotAdvanceTheRound() async throws {
        let (store, doc) = try await fixture()
        _ = try await activate(store, doc)
        let question = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Which?", author: "agent")
        try await store.addFollowUp(question.id, body: "A")
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "answer", noteIDs: [question.id], outcome: .failed("offline"))
        let other = try await store.createNote(documentID: doc.id, anchor: .wholeFile, body: "unrelated", color: .blue)
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "other", noteIDs: [other.id], outcome: .delivered)
        _ = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Also?", author: "agent")
        #expect(try await store.refinement(for: doc.id)?.round == 1)
    }
    @Test func theFirstQuestionAfterDeliveredAnswersStartsTheNextRoundOnce() async throws {
        let (store, doc) = try await fixture()
        _ = try await activate(store, doc)
        let q = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "One?", author: "agent")
        _ = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Two?", author: "agent")
        try await store.addFollowUp(q.id, body: "Yes")
        #expect(try await store.refinement(for: doc.id)?.round == 1)
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "answer", noteIDs: [q.id], outcome: .delivered)
        #expect(try await store.refinement(for: doc.id)?.round == 1)
        _ = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Three?", author: "agent")
        _ = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Four?", author: "agent")
        #expect(try await store.refinement(for: doc.id)?.round == 2)
        #expect(try await store.notes(for: doc.id).filter(\.waitingOnUser).count == 3)
    }
}

extension RefinementStoreTests {
    @Test func renamingKeepsTheDocumentRefinement() async throws {
        let (store, doc) = try await fixture()
        let active = try await activate(store, doc)
        let move = DocumentRelocation(hostID: .local, from: doc.path, to: "/tmp/renamed.md", directory: false)
        try await store.applyRelocation(move)
        #expect(try await store.refinement(for: doc.id) == active)
        #expect(try await store.document(doc.id)?.path == "/tmp/renamed.md")
    }
    @Test func mergingDocumentRowsPreservesTheActivationAndRefusesAConflict() async throws {
        let (store, doc) = try await fixture()
        let target = try await store.upsertDocument(hostID: .local, path: "/tmp/target.md", kind: .markdown, fingerprint: Fingerprint())
        _ = try await activate(store, doc)
        try await store.relocateDocument(hostID: .local, from: doc.path, to: target.path)
        #expect(try await store.refinement(for: target.id)?.generation == "rf_test")
        let fresh = try await store.upsertDocument(hostID: .local, path: "/tmp/fresh.md", kind: .markdown, fingerprint: Fingerprint())
        _ = try await activate(store, fresh, generation: "rf_fresh")
        await #expect(throws: (any Error).self) { try await store.relocateDocument(hostID: .local, from: fresh.path, to: target.path) }
        #expect(try await store.refinement(for: fresh.id)?.generation == "rf_fresh")
    }
}

extension RefinementStoreTests {
    @Test func cancellingPreparationDeletesOnlyItsNeverSentRequestAndMode() async throws {
        let (store, doc) = try await fixture()
        let unrelated = try await store.createNote(documentID: doc.id, anchor: .wholeFile, body: "Keep me", color: .blue)
        let state = try await store.beginRefinement(documentID: doc.id, generation: "rf_cancel", targetJSON: "{}")
        #expect(try await store.cancelRefinement(documentID: doc.id, generation: "rf_old") == false)
        #expect(try await store.refinement(for: doc.id) == state)
        #expect(try await store.cancelRefinement(documentID: doc.id, generation: state.generation))
        #expect(try await store.note(try #require(state.requestNoteID)) == nil)
        #expect(try await store.refinement(for: doc.id) == nil)
        #expect(try await store.note(unrelated.id) == unrelated)
    }
    @Test func cancellationNeverDeletesARequestThatWasDelivered() async throws {
        let (store, doc) = try await fixture()
        let state = try await activate(store, doc)
        #expect(try await store.cancelRefinement(documentID: doc.id, generation: state.generation) == false)
        #expect(try await store.note(try #require(state.requestNoteID)) != nil)
        #expect(try await store.refinement(for: doc.id) == state)
    }
    @Test func concurrentQuestionsAfterAnswersAdvanceTheRoundExactlyOnce() async throws {
        let (store, doc) = try await fixture()
        _ = try await activate(store, doc)
        let q = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "First?", author: "agent")
        let message = try #require(try await store.messages(for: q.id).first)
        try await store.addFollowUp(q.id, body: "Answer")
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "answer", noteIDs: [q.id], outcome: .delivered, carriedQuestions: [message.id])
        async let a = store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Second?", author: "agent")
        async let b = store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Third?", author: "agent")
        _ = try await (a, b)
        #expect(try await store.refinement(for: doc.id)?.round == 2)
        #expect(try await store.refinement(for: doc.id)?.awaitingNextRound == false)
    }
}

extension RefinementStoreTests {
    @Test func cancellationKeepsTheRequestAfterAFailedHandoff() async throws {
        let (store, doc) = try await fixture()
        let state = try await store.beginRefinement(documentID: doc.id, generation: "rf_failure", targetJSON: "{}")
        let request = try #require(state.requestNoteID)
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "request", noteIDs: [request], outcome: .failed("offline"))
        #expect(try await store.cancelRefinement(documentID: doc.id, generation: state.generation) == false)
        #expect(try await store.note(request) != nil)
        #expect(try await store.refinement(for: doc.id) == state)
    }
}
