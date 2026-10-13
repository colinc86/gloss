import Foundation
import Testing
@testable import Core

/// Folding a note's events into its state, with the PM's rules (2026-10-13): anyone resolves or reopens, only the
/// owner sends or accepts, the note's author or the owner deletes.
struct GlossFoldTests {
    let owner = AuthorID.new()
    let participant = AuthorID.new()
    let stranger = AuthorID.new()
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func info() -> GlossInfo {
        GlossInfo(id: .new(), instance: .new(), createdAt: start, ownerAuthor: owner, kind: .markdown,
                  title: "README.md", source: .file(name: "README.md", git: nil),
                  current: GlossCurrent(hash: String(repeating: "a", count: 64), iteration: 0, capturedAt: start))
    }

    func note(by author: AuthorID, via: GlossVia? = nil) -> GlossNote {
        GlossNote(id: .new(), author: author, via: via, createdAt: start, updatedAt: start, iteration: 0, anchor: .wholeFile, body: "Note", color: .yellow)
    }

    func event(_ type: GlossEventType, _ note: GlossNote, by author: AuthorID, at offset: TimeInterval) -> GlossEvent {
        GlossEvent(note: note.id, author: author, type: type, at: start + offset)
    }

    @Test func aParticipantsNoteWaitsWithTheOwnerUntilSent() {
        let posted = note(by: participant)
        let state = GlossFold.fold(posted, messages: [], events: [], info: info())
        #expect(state.status == .posted && !state.isAgentVisible, "posted is not agent-sent")

        let sent = GlossFold.fold(posted, messages: [], events: [.sent(posted.id, by: owner, review: true, at: start + 5)], info: info())
        #expect(sent.status == .sent && sent.isAgentVisible && sent.sentAt == start + 5 && sent.reviewRequested)
    }

    @Test func onlyTheOwnerSendsAndAccepts() {
        let note = note(by: participant)
        let events = [
            GlossEvent.sent(note.id, by: participant, at: start + 1),
            .resolved(note.id, by: participant, at: start + 2),
            event(.accepted, note, by: participant, at: 3),
        ]
        let state = GlossFold.fold(note, messages: [], events: events, info: info())
        #expect(state.sentAt == nil, "a participant's send doesn't count")
        #expect(state.status == .resolved && state.resolution?.by == participant, "anyone may resolve, attributed")
        #expect(state.acceptedAt == nil, "a participant's acceptance is ignored")
        #expect(state.refused == [events[0].id, events[2].id])

        let accepted = GlossFold.fold(note, messages: [], events: events + [event(.accepted, note, by: owner, at: 4)], info: info())
        #expect(accepted.acceptedAt == start + 4)
    }

    @Test func acceptingCountsOnlyOnAResolvedNote() {
        let note = note(by: owner)
        let state = GlossFold.fold(note, messages: [], events: [.sent(note.id, by: owner, at: start + 1), event(.accepted, note, by: owner, at: 2)], info: info())
        #expect(state.acceptedAt == nil && state.status == .sent)
    }

    @Test func reopeningAndResendingClearTheResult() {
        let note = note(by: owner)
        var events: [GlossEvent] = [
            .sent(note.id, by: owner, review: true, at: start + 1),
            .resolved(note.id, by: owner, via: GlossVia(agent: "Claude Code"), outcome: .done, message: "Shortened it.", at: start + 2),
        ]
        var state = GlossFold.fold(note, messages: [], events: events, info: info())
        #expect(state.awaitsReview && state.resolution?.via?.agent == "Claude Code" && state.resolution?.message == "Shortened it.")

        events.append(event(.accepted, note, by: owner, at: 3))
        events.append(event(.reopened, note, by: participant, at: 4))
        state = GlossFold.fold(note, messages: [], events: events, info: info())
        #expect(state.status == .sent && state.resolution == nil && state.acceptedAt == nil, "reopened goes back to sent")

        let posted = self.note(by: participant)
        let reopened = GlossFold.fold(posted, messages: [], events: [.resolved(posted.id, by: owner, at: start + 1), event(.reopened, posted, by: owner, at: 2)], info: info())
        #expect(reopened.status == .posted, "a note never sent reopens to posted")
    }

    @Test func deletingIsTheAuthorsOrTheOwners() {
        let note = note(by: participant)
        let byStranger = GlossFold.fold(note, messages: [], events: [event(.deleted, note, by: stranger, at: 1)], info: info())
        #expect(!byStranger.trashed && byStranger.refused.count == 1)

        let byAuthor = GlossFold.fold(note, messages: [], events: [event(.deleted, note, by: participant, at: 1)], info: info())
        #expect(byAuthor.trashed && byAuthor.deletedBy == participant)

        let moderated = GlossFold.fold(note, messages: [], events: [event(.deleted, note, by: owner, at: 1)], info: info())
        #expect(moderated.trashed && moderated.deletedBy == owner)

        let restored = GlossFold.fold(note, messages: [], events: [event(.deleted, note, by: owner, at: 1), event(.restored, note, by: participant, at: 2)], info: info())
        #expect(!restored.trashed)
    }

    @Test func movesChangeTheAnchor() throws {
        let note = note(by: participant)
        let anchor = Anchor.text(TextAnchor(start: TextPosition(line: 4, col: 1), end: TextPosition(line: 4, col: 5), text: "Hey", before: "", after: ""))
        let move = try GlossEvent.moved(note.id, by: owner, to: anchor, removed: false, at: start + 1)
        let state = GlossFold.fold(note, messages: [], events: [move], info: info())
        #expect(state.anchor == anchor && !state.removed)
        let strangerMove = try GlossEvent.moved(note.id, by: stranger, to: .wholeFile, removed: true, at: start + 2)
        #expect(GlossFold.fold(note, messages: [], events: [move, strangerMove], info: info()).anchor == anchor)
    }

    @Test func concurrentEventsConvergeWhateverTheArrivalOrder() {
        let note = note(by: participant)
        let events = [
            GlossEvent.sent(note.id, by: owner, at: start + 1),
            .resolved(note.id, by: participant, at: start + 2),
            event(.reopened, note, by: owner, at: 2),
            .resolved(note.id, by: owner, via: GlossVia(agent: "Codex"), at: start + 3),
            event(.accepted, note, by: owner, at: 4),
            event(.deleted, note, by: stranger, at: 5),
        ]
        let expected = GlossFold.fold(note, messages: [], events: events, info: info())
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            #expect(GlossFold.fold(note, messages: [], events: events.shuffled(using: &generator), info: info()) == expected)
        }
        #expect(expected.status == .resolved && expected.acceptedAt == start + 4 && !expected.trashed)
    }

    @Test func threadsReadInCreationOrderAndQuestionsWait() {
        let question = note(by: owner, via: GlossVia(agent: "Claude Code"))
        #expect(GlossFold.fold(question, messages: [], events: [], info: info()).waitingOnUser, "an agent's own note is a question")

        let answer = GlossMessage(note: question.id, author: participant, kind: .comment, body: "The second one", createdAt: start + 2)
        let followUp = GlossMessage(note: question.id, author: owner, via: GlossVia(agent: "Claude Code"), kind: .question, body: "Both?", createdAt: start + 3)
        let state = GlossFold.fold(question, messages: [followUp, answer], events: [], info: info())
        #expect(state.thread.map(\.id) == [answer.id, followUp.id])
        #expect(state.waitingOnUser)
        #expect(!GlossFold.fold(question, messages: [answer], events: [], info: info()).waitingOnUser)
    }

    @Test func onlyAnOwnersResolveNamesAnAgent() {
        let note = note(by: participant)
        let claimed = GlossFold.fold(note, messages: [], events: [.resolved(note.id, by: participant, via: GlossVia(agent: "Claude Code"), at: start + 1)], info: info())
        #expect(claimed.status == .resolved && claimed.resolution?.by == participant)
        #expect(claimed.resolution?.via == nil, "agents work on the owner's Mac; a participant can't claim one")
        let real = GlossFold.fold(note, messages: [], events: [.resolved(note.id, by: owner, via: GlossVia(agent: "Codex"), at: start + 1)], info: info())
        #expect(real.resolution?.via?.agent == "Codex")
    }

    @Test func unknownEventTypesAreSkipped() {
        let note = note(by: participant)
        var future = event(.resolved, note, by: owner, at: 1)
        future.type = "pinned"
        let state = GlossFold.fold(note, messages: [], events: [future], info: info())
        #expect(state.status == .posted && state.refused.isEmpty)
    }
}
