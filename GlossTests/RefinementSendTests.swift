import Core
import Foundation
import Testing
@testable import Gloss

@MainActor extension SendCoordinatorTests {
    @Test func refiningWithZeroExistingNotesSendsOnlyTheDocumentRequest() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let r = try await f.begin(review: true)
        #expect(f.transport.delivered[0].0.noteIDs == [r.requestNoteID!])
        #expect(f.transport.delivered[0].0.text.contains(Refinement.request))
        #expect(f.transport.delivered[0].0.text.contains("Whole file"))
        #expect(f.transport.delivered[0].0.text.hasSuffix(PacketBuilder.reviewSentence))
    }
    @Test func anInitialFailureKeepsOneRetryableRequest() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        f.transport.shouldFail = true
        let failed = try await f.begin()
        #expect(failed.status == .starting && failed.error != nil)
        f.transport.shouldFail = false
        await f.model.retry(failed, review: false, session: f.session)
        #expect(try await f.store.notes(for: f.document.id).count == 1)
        #expect(f.transport.delivered.count == 1 && f.transport.delivered[0].0.noteIDs == [failed.requestNoteID!])
    }
    @Test func everySendFromTheActiveDocumentCarriesItsDirective() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        _ = try await f.begin()
        let extra = try await f.store.createNote(documentID: f.document.id, anchor: .wholeFile, body: "more", color: .green)
        await f.sender.send(noteIDs: [extra.id], to: FakeTransport.target)
        #expect(f.transport.delivered.last?.0.text.contains("Refinement:") == true)
    }
    @Test func endingDuringPreparationRemovesTheUndeliveredDirective() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin()
        let extra = try await f.store.createNote(documentID: f.document.id, anchor: .wholeFile, body: "more", color: .green)
        var validations = 0
        await f.sender.send(noteIDs: [extra.id], to: FakeTransport.target, validate: {
            validations += 1
            if validations == 2 { f.model.end(state) }
            return nil
        })
        #expect(f.transport.delivered.last?.0.text.contains("Refinement:") == false)
    }
    @Test func retryAfterExitIsAnOrdinarySend() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        f.transport.shouldFail = true; let state = try await f.begin()
        f.model.end(state); f.transport.shouldFail = false
        await f.sender.retry()
        #expect(f.transport.delivered.last?.0.text.contains("Refinement:") == false)
        #expect(try await f.store.refinement(for: f.document.id)?.status == .ended)
    }
    @Test func previewAndCopyDescribeRefinementWithoutMutatingState() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin()
        let q = try await f.question(choices: QuestionChoices(["A", "B"]))
        let before = try await f.store.messages(for: q.id)
        let preview = try await f.sender.preview(noteIDs: [q.id], review: true, composing: [q.id: "Private answer"])
        #expect(preview.text.contains("Private answer") && preview.text.contains("Choice 1: \"A\""))
        var copied = ""; f.sender.writeClipboard = { copied = $0 }; await f.sender.copy(noteIDs: [q.id])
        #expect(copied.contains("Refinement:") && !copied.contains("Private answer"))
        #expect(try await f.store.messages(for: q.id) == before)
        #expect(try await f.store.refinement(for: f.document.id) == state)
    }
    @Test func anEditDuringAnswerDeliveryStaysUnsent() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        _ = try await f.begin(); let q = try await f.question(choices: QuestionChoices(["A", "B"]))
        let question = try #require(try await f.store.messages(for: q.id).first)
        try await f.store.setChoiceSelection(questionID: question.id, indexes: [0])
        let answer = try #require(try await f.store.messages(for: q.id).last)
        f.transport.whileDelivering = { try? await f.store.updateFollowUp(answer.id, body: "Edited while sending") }
        await f.sender.send(noteIDs: [q.id], to: FakeTransport.target)
        #expect(f.transport.delivered.last?.0.text.contains("User replied: \"A\"") == true)
        #expect(try await f.store.messages(for: q.id).last?.isSent == false)
        #expect(try await f.store.note(q.id)?.waitingOnUser == false, "the carried question was delivered, while the edited answer remains unsent")
    }
    @Test func aNewQuestionDuringAnswerDeliveryRemainsWaiting() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        _ = try await f.begin(); let q = try await f.question("First?", choices: QuestionChoices(["A", "B"]))
        let first = try #require(try await f.store.messages(for: q.id).first)
        try await f.store.setChoiceSelection(questionID: first.id, indexes: [0])
        f.transport.whileDelivering = { try? await f.store.agentReply(q.id, body: "Second?", asks: true, agent: "agent", choices: QuestionChoices(["X", "Y"])) }
        await f.sender.send(noteIDs: [q.id], to: FakeTransport.target)
        #expect(try await f.store.note(q.id)?.waitingOnUser == true)
        let latest = try #require(NoteMessage.unansweredQuestion(in: try await f.store.messages(for: q.id)))
        #expect(latest.body == "Second?")
        try await f.store.setChoiceSelection(questionID: latest.id, indexes: [1])
        #expect(try await f.store.messages(for: q.id).last?.body == "Y")
    }
}

@MainActor extension SendCoordinatorTests {
    @Test func aFollowUpWrittenBeforeACarriedQuestionClearsWaitingAfterSend() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin()
        let id = try #require(state.requestNoteID)
        try await f.store.addFollowUp(id, body: "Earlier unsent follow-up")
        try await f.store.agentReply(id, body: "Later question", asks: true, agent: "agent")
        await f.sender.send(noteIDs: [id], to: FakeTransport.target)
        let text = try #require(f.transport.delivered.last?.0.text)
        #expect(text.contains("Agent (agent) asked: \"Later question\"\nUser replied: \"Earlier unsent follow-up\""))
        #expect(try await f.store.note(id)?.waitingOnUser == false)
        #expect(try await f.store.note(id)?.hasUnsentFollowUps == false)
    }
    @Test func getNoteAndCopyKeepTheirGoldenBytesWithoutReviewInstructions() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let note = try await f.store.createNote(documentID: f.document.id, anchor: .wholeFile, body: "Review this", color: .yellow)
        await f.sender.send(noteIDs: [note.id], to: FakeTransport.target, review: true)
        let expected = "File: \(f.document.path)\nSource: markdown\n\nNote: \(note.id.rawValue)\nWhole file\nUser comment: \"Review this\"\n\n" + PacketBuilder.closingLine(count: 1)
        #expect(try await f.sender.packet(noteIDs: [note.id], wholeThread: true).text == expected)
        var copied = ""; f.sender.writeClipboard = { copied = $0 }
        await f.sender.copy(noteIDs: [note.id])
        #expect(copied == expected)
        #expect(try await f.sender.preview(noteIDs: [note.id], review: false).text.hasSuffix(PacketBuilder.reviewSentence))
    }
}
