import AppKit
import Core
import Foundation
import GRDB
import Dispatch
import Synchronization
import Testing
@testable import Gloss

@MainActor
final class RefinementFixture {
    let store: NoteStore
    let transport = FakeTransport()
    let sender: SendCoordinator
    let panel: NotesPanelModel
    let model: RefinementModel
    let session: DocumentSession
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-refinement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("PLAN.md").path
        try "# Plan\nDetails to clarify\n".write(toFile: path, atomically: true, encoding: .utf8)
        store = NoteStore(database: try AppDatabase.inMemory())
        sender = SendCoordinator(noteStore: store, transports: [transport], stagers: [:])
        panel = NotesPanelModel(noteStore: store)
        model = RefinementModel(store: store, sender: sender, panel: panel)
        session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store)
    }
    func open() async {
        panel.start(); model.startObserving()
        await session.open(); await sender.refreshTargets(); sender.rememberTarget(FakeTransport.target)
    }
    func close() { session.close(); panel.stop(); model.stop(); try? FileManager.default.removeItem(at: directory) }
    var document: Core.Document { session.document! }
    func begin(review: Bool = false) async throws -> Refinement {
        await model.begin(session, review: review)
        return try #require(try await store.refinement(for: document.id))
    }
    func question(_ text: String = "Which?", choices: QuestionChoices? = nil) async throws -> Note {
        try await store.askUser(documentID: document.id, anchor: .wholeFile, question: text, author: "agent", choices: choices)
    }
    func wait(_ predicate: () -> Bool) async {
        for _ in 0..<100 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(20)) }
        Issue.record("Observation did not settle")
    }
}

@MainActor struct RefinementModelTests {
    @Test func startingTwiceDoesNotSendTwice() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        async let a: Void = f.model.begin(f.session, review: false)
        async let b: Void = f.model.begin(f.session, review: false)
        _ = await (a, b)
        #expect(f.transport.delivered.count == 1)
        #expect(try await f.store.notes(for: f.document.id).count == 1)
    }
    @Test func entryNeedsAnAgentButNotDrafts() async throws {
        let f = try RefinementFixture(); await f.session.open(); defer { f.close() }
        #expect(!f.model.canStart(f.session))
        await f.sender.refreshTargets(); f.sender.rememberTarget(FakeTransport.target)
        #expect(f.model.canStart(f.session))
        #expect(try await f.store.notes(for: f.document.id).isEmpty)
    }
    @Test func roundOneStartsOnInitialDelivery() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin()
        #expect(state.status == .active && state.round == 1 && !state.hasAnswers)
    }
    @Test func noWaitingQuestionsDoesNotImplicitlyFinish() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin()
        try await f.store.resolve(try #require(state.requestNoteID))
        await f.model.refresh(f.document.id)
        #expect(f.model.state(for: f.document.id)?.status == .active)
    }
    @Test func aFinishDisplaysSummaryAndRemovesFutureDirectives() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin()
        try await f.store.finishRefinement(documentID: f.document.id, generation: state.generation, summary: "Examples clarified")
        await f.model.refresh(f.document.id)
        let completed = try #require(f.model.state(for: f.document.id))
        #expect(f.model.detail(completed) == "Examples clarified")
        #expect(try await f.sender.preview(noteIDs: [try #require(state.requestNoteID)], review: false).text.contains("Refinement:") == false)
    }
    @Test func exitWhileSendingIsImmediateAndKeepsOrdinaryWork() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        f.transport.whileDelivering = {
            #expect(f.model.preparing.contains(f.document.id), "admission stays owned until the entire initial operation finishes")
            if let state = f.model.state(for: f.document.id) { f.model.end(state) }
            #expect(f.model.state(for: f.document.id) == nil)
        }
        let state = try await f.begin()
        #expect(state.status == .ended)
        #expect(f.transport.delivered[0].0.text.contains("Refinement:"), "already handed over cannot be retracted")
        #expect(try await f.store.notes(for: f.document.id).count == 1)
    }
    @Test func restartNeverResendsTheRequest() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        _ = try await f.begin()
        let restored = RefinementModel(store: f.store, sender: f.sender, panel: f.panel)
        restored.startObserving(); defer { restored.stop() }
        await f.wait { restored.state(for: f.document.id) != nil }
        #expect(restored.state(for: f.document.id)?.status == .active)
        #expect(f.transport.delivered.count == 1)
    }
    @Test func partialAnswersKeepTheRemainingUserTurnVisible() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin()
        let first = try await f.question("One?"); _ = try await f.question("Two?")
        try await f.store.addFollowUp(first.id, body: "Yes")
        await f.wait { f.model.questions(in: f.document.id).count == 2 && f.model.readyAnswers(in: f.document.id).count == 1 }
        await f.model.sendAnswers(state, review: false)
        await f.wait { f.model.questions(in: f.document.id).count == 1 }
        #expect(f.model.detail(try #require(f.model.state(for: f.document.id))).contains("1 question for you"))
    }
    @Test func uncommittedAnswerFieldsAreStagedBeforeRoundSend() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin()
        let q = try await f.question()
        let unrelated = try await f.store.createNote(documentID: f.document.id, anchor: .wholeFile, body: "unrelated", color: .blue)
        f.panel.followUpText[q.id] = "My answer"
        await f.wait { f.model.readyAnswers(in: f.document.id).count == 1 }
        f.panel.searchText = "hide every question"; f.panel.filter = .drafts
        #expect(f.model.questions(in: f.document.id).count == 1)
        await f.model.sendAnswers(state, review: false)
        #expect(f.transport.delivered.last?.0.noteIDs == [q.id])
        #expect(f.transport.delivered.last?.0.text.contains("My answer") == true)
        #expect(try await f.store.note(unrelated.id)?.state == .draft)
        #expect(f.panel.followUpText[q.id] == nil)
    }
    @Test func aStagingFailureKeepsTheInputAndCancelsDelivery() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin(); let q = try await f.question()
        f.panel.followUpText[q.id] = "Keep this input"
        await f.wait { f.model.readyAnswers(in: f.document.id).count == 1 }
        try await f.store.database.queue.write { db in try db.execute(sql: "CREATE TRIGGER reject_answer BEFORE INSERT ON note_message WHEN NEW.author = 'user' BEGIN SELECT RAISE(ABORT, 'test staging failure'); END") }
        await f.model.sendAnswers(state, review: false)
        #expect(f.panel.followUpText[q.id] == "Keep this input")
        #expect(f.transport.delivered.count == 1)
    }
    @Test func entryCapturesTheIterationBaselineBeforeCreatingItsRequest() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let settings = SettingsStore(noteStore: f.store)
        let iterations = IterationsModel(noteStore: f.store, settings: settings)
        iterations.fileSystem = { _ in LocalFileSystem(deleteBehavior: .permanent) }
        f.model.prepareDocument = { await iterations.prepareForNote($0) }
        _ = try await f.begin()
        let documentID = f.document.id
        let hash = try await f.store.database.queue.read { db in try String.fetchOne(db, sql: "SELECT start_hash FROM iteration WHERE document_id = ?", arguments: [documentID.rawValue]) }
        #expect(hash != nil)
    }
    @Test func endingDuringBaselinePreparationCreatesNoRequest() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        f.model.prepareDocument = { id in f.model.cancelPreparation(id) }
        await f.model.begin(f.session, review: false)
        #expect(try await f.store.notes(for: f.document.id).isEmpty && f.transport.delivered.isEmpty)
    }
}

@MainActor extension NotesPanelModelTests {
    @Test func theUnansweredQuestionStaysVisibleAfterAStatusReply() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let q = try await f.question("Question", choices: QuestionChoices(["A", "B"]))
        try await f.store.agentReply(q.id, body: "Still working", asks: false, agent: "agent")
        let question = NoteMessage.unansweredQuestion(in: try await f.store.messages(for: q.id))
        #expect(question?.body == "Question" && question?.choices?.options == ["A", "B"])
    }
    @Test func anIncomingQuestionDoesNotReplaceTypedText() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let q = try await f.question(choices: QuestionChoices(["A", "B"]))
        f.panel.followUpText[q.id] = "Still typing"
        try await f.store.agentReply(q.id, body: "Follow-up?", asks: true, agent: "agent")
        await f.wait { f.panel.messages(for: q.id).count == 2 }
        #expect(f.panel.followUpText[q.id] == "Still typing")
    }
    @Test func choiceControlsAlwaysAllowFreeform() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let q = try await f.question(choices: QuestionChoices(["A", "B"]))
        let message = try #require(try await f.store.messages(for: q.id).first)
        await f.panel.selectChoices([1], question: message.id)
        #expect(await f.panel.addFollowUp(to: q.id, "Because…"))
        #expect(try await f.store.messages(for: q.id).filter { !$0.isSent }.map(\.body) == ["B", "Because…"])
    }
    @Test func deletingAndUndoingChoiceAnswersRestoresSelectionAndCustomStatus() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let q = try await f.question(choices: QuestionChoices(["A", "B"]))
        let question = try #require(try await f.store.messages(for: q.id).first)
        await f.panel.selectChoices([0], question: question.id)
        await f.wait { f.panel.messages(for: q.id).count == 2 }
        let draft = try #require(f.panel.messages(for: q.id).last)
        await f.panel.deleteFollowUp(draft.id)
        #expect(f.panel.selectedChoices(for: question, editable: true).isEmpty)
        #expect(await f.panel.restoreFollowUp(draft))
        await f.wait { f.panel.messages(for: q.id).count == 2 }
        let restored = try #require(f.panel.messages(for: q.id).last)
        #expect(await f.panel.updateFollowUp(restored.id, "Custom answer"))
        await f.wait { f.panel.messages(for: q.id).last?.customAnswer == true }
        let custom = try #require(f.panel.messages(for: q.id).last)
        await f.panel.deleteFollowUp(custom.id)
        #expect(await f.panel.restoreFollowUp(custom))
        let again = try #require(try await f.store.messages(for: q.id).last)
        #expect(again.customAnswer && again.inReplyTo == question.id && again.body == "Custom answer")
    }
}

@MainActor extension CompactLayoutTests {
    @Test func anAgentQuestionHasATraySummaryWithoutAUserComment() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let q = try await f.question("First line\nSecond line")
        #expect(NotesTray.summary(q, messages: try await f.store.messages(for: q.id)) == "First line")
    }
    @Test func answeringFromTheTrayUsesTheSameChoiceDraft() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let q = try await f.question(choices: QuestionChoices(["A", "B"]))
        let question = try #require(try await f.store.messages(for: q.id).first)
        await f.panel.selectChoices([0], question: question.id)
        f.panel.followUpText[q.id] = "Explanation"
        await f.wait { f.panel.messages(for: q.id).count == 2 }
        #expect(f.panel.selectedChoices(for: question, editable: true) == [0])
        #expect(f.panel.followUpText[q.id] == "Explanation")
        #expect(f.transport.delivered.isEmpty)
    }
}

@MainActor extension AccessibilityTests {
    @Test func theRefinementNoticeSpeaksRoundAndWhoseTurnItIs() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let r = try await f.begin(); _ = try await f.question()
        await f.wait { f.model.questions(in: f.document.id).count == 1 }
        #expect(f.model.detail(r) == "Round 1 · 1 question for you")
    }
    @Test func aStagedChoiceAnswerIsSpokenAsNotSent() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let q = try await f.question(choices: QuestionChoices(["A", "B"]))
        let question = try #require(try await f.store.messages(for: q.id).first)
        await f.panel.selectChoices([0], question: question.id)
        await f.wait { f.panel.messages(for: q.id).count == 2 }
        #expect(f.panel.choiceAnswerSummary(for: q.id).contains("not sent"))
    }
}

@MainActor extension RefinementModelTests {
    @Test func currentUncommittedAnswersBlockFinishButHistoricalFieldsDoNot() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        _ = try await f.begin(); let q = try await f.question()
        f.panel.followUpText[q.id] = "Unsent field"
        await f.wait { f.model.questions(in: f.document.id).count == 1 }
        #expect(throws: RefinementError.pendingAnswers) { try f.model.validateFinish(f.document.id) }
        _ = try await f.store.startIteration(documentID: f.document.id, openNotes: .leave, snapshot: nil)
        await f.wait { f.model.questions(in: f.document.id).isEmpty }
        try f.model.validateFinish(f.document.id)
    }
    @Test func simultaneousEntryOnTwoDocumentsRemainsRetryable() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let path = f.directory.appendingPathComponent("OTHER.md").path
        try "Other".write(toFile: path, atomically: true, encoding: .utf8)
        let other = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: f.store)
        await other.open(); defer { other.close() }
        f.transport.whileDelivering = { try? await Task.sleep(for: .milliseconds(100)) }
        async let first: Void = f.model.begin(f.session, review: false)
        async let second: Void = f.model.begin(other, review: false)
        _ = await (first, second)
        let states = try await f.store.refinements()
        #expect(states.count == 2)
        #expect(states.allSatisfy { $0.status == .active || $0.error != nil })
        for state in states where state.status == .starting {
            await f.model.retry(state, review: false, session: state.documentID == f.document.id ? f.session : other)
        }
        #expect(try await f.store.refinements().allSatisfy { $0.status == .active })
        #expect(f.transport.delivered.count == 2)
    }
}

private struct CancellingRequestStager: AttachmentStager {
    let cancel: @MainActor @Sendable () -> Void
    func stage(_ files: [LocalAttachment], for target: AgentTarget, sendID: SendID) async throws -> StagingResult {
        await cancel()
        return .empty
    }
}

@MainActor extension RefinementModelTests {
    @Test func endingAfterRequestCreationBeforeHandoffRemovesTheRequestAndMode() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let unrelated = try await f.store.createNote(documentID: f.document.id, anchor: .wholeFile, body: "Unrelated draft", color: .blue)
        f.sender.register(stager: CancellingRequestStager(cancel: {
            if let state = f.model.state(for: f.document.id) { f.model.end(state) }
        }), for: .local)
        await f.model.begin(f.session, review: false)
        #expect(f.transport.delivered.isEmpty)
        #expect(try await f.store.refinement(for: f.document.id) == nil)
        #expect(try await f.store.notes(for: f.document.id) == [unrelated])
    }
}


@MainActor extension RefinementModelTests {
    @Test func aSendStartingWhileAnswersStageReportsBusyAndKeepsTheAnswerUnsent() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin(); let q = try await f.question()
        let unrelated = try await f.store.createNote(documentID: f.document.id, anchor: .wholeFile, body: "Other send", color: .blue)
        f.panel.followUpText[q.id] = "Staged answer"
        await f.wait { f.model.readyAnswers(in: f.document.id).count == 1 }
        let staging = Mutex(false)
        let resumeStaging = DispatchSemaphore(value: 0)
        try await f.store.database.queue.write { db in
            db.add(function: DatabaseFunction("hold_staging", argumentCount: 0) { _ in
                staging.withLock { $0 = true }
                guard resumeStaging.wait(timeout: .now() + 5) == .success else { throw DatabaseError(message: "staging gate timed out") }
                return 0
            })
            try db.execute(sql: "CREATE TRIGGER hold_answer BEFORE INSERT ON note_message WHEN NEW.author = 'user' BEGIN SELECT hold_staging(); END")
        }
        var releaseDelivery: CheckedContinuation<Void, Never>?
        f.transport.whileDelivering = { await withCheckedContinuation { releaseDelivery = $0 } }
        defer { resumeStaging.signal(); releaseDelivery?.resume() }
        let answers = Task { await f.model.sendAnswers(state, review: false) }
        await f.wait { staging.withLock { $0 } }
        let other = Task { await f.sender.send(noteIDs: [unrelated.id], to: FakeTransport.target) }
        await f.wait { f.sender.isSending }
        resumeStaging.signal()
        await answers.value
        #expect(f.model.errors[f.document.id] == "Another send is in progress. Retry when it finishes.")
        #expect(try await f.store.note(q.id)?.hasUnsentFollowUps == true)
        await f.wait { releaseDelivery != nil }
        let release = releaseDelivery; releaseDelivery = nil; release?.resume()
        await other.value
        #expect(f.transport.delivered.last?.0.noteIDs == [unrelated.id])
    }
}


@MainActor extension RefinementModelTests {
    @Test func aCompletedRunStillAllowsCancellingTheNextPreparation() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        let state = try await f.begin()
        try await f.store.finishRefinement(documentID: f.document.id, generation: state.generation, summary: "Previous summary")
        await f.model.refresh(f.document.id)
        let before = try await f.store.notes(for: f.document.id)
        var offeredCancellation = false
        f.model.prepareDocument = { id in
            offeredCancellation = f.model.isPreparing(id)
            #expect(f.model.state(for: id)?.status == .completed)
            f.model.cancelPreparation(id)
        }
        await f.model.begin(f.session, review: false)
        #expect(offeredCancellation)
        #expect(try await f.store.notes(for: f.document.id) == before)
        #expect(try await f.store.refinement(for: f.document.id)?.summary == "Previous summary")
        #expect(f.transport.delivered.count == 1)
    }
}
