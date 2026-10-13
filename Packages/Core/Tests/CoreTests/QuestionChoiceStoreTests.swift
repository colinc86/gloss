import Foundation
import Testing
@testable import Core

struct QuestionChoiceStoreTests {
    func fixture(multi: Bool = false) async throws -> (NoteStore, Note, NoteMessage) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let doc = try await store.upsertDocument(hostID: .local, path: "/tmp/choices.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.askUser(documentID: doc.id, anchor: .wholeFile, question: "Which?", author: "agent", choices: QuestionChoices([" A ", "B", "C"], multi: multi))
        return (store, note, try #require(try await store.messages(for: note.id).first))
    }
    @Test func singleChoiceReplacesTheStagedSelection() async throws {
        let (store, note, question) = try await fixture()
        try await store.setChoiceSelection(questionID: question.id, indexes: [0])
        try await store.setChoiceSelection(questionID: question.id, indexes: [1])
        let drafts = try await store.messages(for: note.id).filter { !$0.isSent }
        #expect(drafts.count == 1 && drafts[0].body == "B" && drafts[0].inReplyTo == question.id)
        #expect(try await store.sends(for: note.id).isEmpty)
    }
    @Test func multipleChoicesStageOneAnswerInOptionOrder() async throws {
        let (store, note, question) = try await fixture(multi: true)
        try await store.setChoiceSelection(questionID: question.id, indexes: [2, 0, 2])
        let draft = try #require(try await store.messages(for: note.id).last)
        #expect(draft.body == "A\nC" && draft.selectedOptions == [0, 2] && !draft.isSent)
    }
    @Test func aCustomAnswerIsNeverOverwrittenByChoiceChanges() async throws {
        let (store, note, question) = try await fixture()
        try await store.addFollowUp(note.id, body: "unrelated freeform")
        try await store.setChoiceSelection(questionID: question.id, indexes: [0])
        let draft = try #require(try await store.messages(for: note.id).last)
        try await store.updateFollowUp(draft.id, body: "A, because…")
        try await store.setChoiceSelection(questionID: question.id, indexes: [1])
        let messages = try await store.messages(for: note.id)
        #expect(messages.map(\.body) == ["Which?", "unrelated freeform", "A, because…", "B"])
        #expect(messages[2].customAnswer && messages[2].selectedOptions == nil)
    }
    @Test func clearingTheLastChoiceRemovesOnlyTheGeneratedDraft() async throws {
        let (store, note, question) = try await fixture()
        try await store.addFollowUp(note.id, body: "Explanation")
        try await store.setChoiceSelection(questionID: question.id, indexes: [0])
        try await store.setChoiceSelection(questionID: question.id, indexes: [])
        #expect(try await store.messages(for: note.id).map(\.body) == ["Which?", "Explanation"])
    }
    @Test func sentAnswersAndOlderChoicesRemainImmutable() async throws {
        let (store, note, question) = try await fixture()
        try await store.setChoiceSelection(questionID: question.id, indexes: [0])
        _ = try await store.recordSend(transport: "fake", targetJSON: "{}", packetText: "answer", noteIDs: [note.id], outcome: .delivered)
        await #expect(throws: RefinementError.questionClosed) { try await store.setChoiceSelection(questionID: question.id, indexes: [1]) }
        try await store.agentReply(note.id, body: "Next?", asks: true, agent: "agent", choices: QuestionChoices(["X", "Y"], multi: true))
        let messages = try await store.messages(for: note.id)
        #expect(messages[0].choices == question.choices && messages[1].body == "A" && messages[1].isSent)
        #expect(messages.last?.choices?.options == ["X", "Y"])
        #expect(!messages.contains { !$0.isSent })
    }
    @Test func choiceDraftsSurviveRestart() async throws {
        let (store, note, question) = try await fixture()
        try await store.setChoiceSelection(questionID: question.id, indexes: [2])
        let reopened = NoteStore(database: store.database)
        #expect(try await reopened.messages(for: note.id).last?.selectedOptions == [2])
    }
    @Test func questionOptionsBelongToEachMessage() async throws {
        let (store, note, first) = try await fixture()
        try await store.agentReply(note.id, body: "Status", asks: false, agent: "agent")
        #expect(NoteMessage.unansweredQuestion(in: try await store.messages(for: note.id))?.id == first.id)
        try await store.agentReply(note.id, body: "New?", asks: true, agent: "agent", choices: QuestionChoices(["X", "Y"]))
        await #expect(throws: RefinementError.questionClosed) { try await store.setChoiceSelection(questionID: first.id, indexes: [0]) }
        #expect(try await store.messages(for: note.id).first?.choices == first.choices)
    }
    @Test func legacyMessagesRemainFreeform() async throws {
        let (store, note, _) = try await fixture()
        try await store.agentReply(note.id, body: "Freeform?", asks: true, agent: "agent")
        #expect(try await store.messages(for: note.id).last?.choices == nil)
    }
    @Test func invalidChoicesAndSelectionsWriteNothing() async throws {
        #expect(throws: RefinementError.invalidChoices) { try QuestionChoices([" A", "A "]) }
        #expect(throws: RefinementError.invalidChoices) { try QuestionChoices(["A", " "]) }
        #expect(throws: RefinementError.invalidChoices) { try QuestionChoices([String(repeating: "x", count: 201), "B"]) }
        let (store, note, question) = try await fixture()
        await #expect(throws: RefinementError.invalidSelection) { try await store.setChoiceSelection(questionID: question.id, indexes: [0, 1]) }
        #expect(try await store.messages(for: note.id).count == 1)
    }
}
