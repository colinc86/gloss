import Foundation
import Testing
@testable import Core

struct NoteThreadStoreTests {
    let store: NoteStore
    let document: Document

    init() async throws {
        store = NoteStore(database: try AppDatabase.inMemory())
        document = try await store.upsertDocument(hostID: .local, path: "/tmp/proj/notes.md", kind: .markdown, fingerprint: Fingerprint())
    }

    func text(_ line: Int, _ text: String) -> Anchor {
        .text(TextAnchor(start: .init(line: line, col: 1), end: .init(line: line, col: text.utf16.count + 1), text: text, before: "", after: ""))
    }

    /// A note the user sent.
    func sentNote(_ body: String = "Tighten this", line: Int = 3) async throws -> Note {
        let note = try await store.createNote(documentID: document.id, anchor: text(line, "old line"), body: body, color: .blue)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        return try #require(try await store.note(note.id))
    }

    /// The notes panel reads every thread through one observation, by note and oldest first.
    @Test func everyThreadIsObservedAtOnce() async throws {
        let first = try await sentNote("one", line: 1)
        let second = try await sentNote("two", line: 2)
        _ = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "no thread", color: .blue)
        try await store.agentReply(first.id, body: "Done?", asks: true, agent: "claude")
        try await store.addFollowUp(first.id, body: "Yes")
        try await store.agentReply(second.id, body: "Done.", asks: false, agent: "codex")
        let all = store.allMessagesNow()
        #expect(Set(all.keys) == [first.id, second.id], "notes without messages are absent")
        #expect(all[first.id]?.map(\.body) == ["Done?", "Yes"] && all[second.id]?.map(\.body) == ["Done."])
        var iterator = store.observeAllMessages().makeAsyncIterator()
        #expect(try await iterator.next() == all)
        try await store.addFollowUp(second.id, body: "Thanks")
        #expect(try await iterator.next()?[second.id]?.last?.body == "Thanks")
    }

    /// Gloss re-anchors a note on rewritten words before the agent says where its change is: Gloss's move is
    /// recorded and keeps the words the note was made on, and the agent's move then takes it over as one line.
    @Test func aReanchorOnChangedWordsIsAMoveTheAgentTakesOver() async throws {
        let note = try await sentNote()
        // The same words a line lower: the note only follows them.
        try await store.applyReanchor(note.id, to: text(4, "old line"))
        var current = try #require(try await store.note(note.id))
        #expect(current.anchor == text(4, "old line") && current.originalAnchor == nil)
        #expect(try await store.messages(for: note.id).isEmpty)
        // Rewritten words: a move Gloss records, remembering where the note was made.
        try await store.applyReanchor(note.id, to: text(4, "new line"))
        current = try #require(try await store.note(note.id))
        #expect(current.originalAnchor == text(4, "old line"))
        var messages = try await store.messages(for: note.id)
        #expect(messages.count == 1 && messages[0].author == .app && messages[0].move == NoteMove(from: text(4, "old line"), to: text(4, "new line"), removed: false))
        // The agent says where: one move, by the agent, from where the note was before either.
        try await store.agentReply(note.id, body: "Rewrote it.", asks: false, agent: "claude",
                                   relocation: NoteRelocation(anchor: text(5, "newer line"), removed: false))
        messages = try await store.messages(for: note.id)
        #expect(messages.map(\.kind) == [.moved, .reply])
        #expect(messages[0].author == .agent("claude") && messages[0].move == NoteMove(from: text(4, "old line"), to: text(5, "newer line"), removed: false))
        current = try #require(try await store.note(note.id))
        #expect(current.anchor == text(5, "newer line") && current.originalAnchor == text(4, "old line"))
        try await store.restoreOriginalPlace(note.id)
        #expect(try await store.note(note.id)?.anchor == text(4, "old line"), "back to the words it was made on")
    }

    /// Gloss found the text removed, then the agent says it removed it: one line, the agent's.
    @Test func anAgentsRemovalTakesOverTheOneGlossFound() async throws {
        let note = try await sentNote()
        let point = Anchor.text(TextAnchor(start: .init(line: 3, col: 1), end: .init(line: 3, col: 1), text: "", before: "", after: ""))
        try await store.applyRelocation(note.id, to: point, removed: true, author: nil)
        try await store.agentReply(note.id, body: "Removed it.", asks: false, agent: "codex", relocation: NoteRelocation(anchor: point, removed: true))
        let moves = try await store.messages(for: note.id).filter { $0.kind == .moved }
        #expect(moves.count == 1 && moves[0].author == .agent("codex") && moves[0].move?.removed == true)
        #expect(moves[0].move?.from == text(3, "old line"))
        // Not after something else was said: an agent's later move is its own.
        try await store.agentReply(note.id, body: "Put it back.", asks: false, agent: "codex", relocation: NoteRelocation(anchor: text(3, "old line"), removed: false))
        #expect(try await store.messages(for: note.id).filter { $0.kind == .moved }.count == 2)
    }

    /// Only a Gloss move made after the agent last had the note is the agent's to take over: the user's own deletion
    /// before sending stays Gloss's line.
    @Test func aGlossMoveFromBeforeTheSendStaysGlosss() async throws {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let note = try await store.createNote(documentID: document.id, anchor: text(3, "old line"), body: "b", color: .blue, at: start)
        let point = Anchor.text(TextAnchor(start: .init(line: 3, col: 1), end: .init(line: 3, col: 1), text: "", before: "", after: ""))
        try await store.applyRelocation(note.id, to: point, removed: true, author: nil, at: start.addingTimeInterval(10))
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered,
                                       at: start.addingTimeInterval(20))
        try await store.agentReply(note.id, body: "Moved it.", asks: false, agent: "claude",
                                   relocation: NoteRelocation(anchor: text(4, "new line"), removed: false), at: start.addingTimeInterval(30))
        let moves = try await store.messages(for: note.id).filter { $0.kind == .moved }
        #expect(moves.map(\.author) == [.app, .agent("claude")], "the user's deletion isn't credited to the agent")
    }

    /// Two reloads in a row make one Gloss move, from where the note was to where it is now.
    @Test func glossMovesInARowAreOne() async throws {
        let note = try await sentNote()
        try await store.applyReanchor(note.id, to: text(4, "first rewrite"))
        try await store.applyReanchor(note.id, to: text(5, "second rewrite"))
        let moves = try await store.messages(for: note.id).filter { $0.kind == .moved }
        #expect(moves.count == 1 && moves[0].author == .app)
        #expect(moves[0].move == NoteMove(from: text(3, "old line"), to: text(5, "second rewrite"), removed: false))
        #expect(try await store.note(note.id)?.originalAnchor == text(3, "old line"))
    }

    /// An agent putting a note back where it was before Gloss's move leaves no move, and nothing to restore.
    @Test func aMoveBackToWhereItWasIsNoMove() async throws {
        let note = try await sentNote()
        try await store.applyReanchor(note.id, to: text(4, "rewritten"))
        try await store.agentReply(note.id, body: "Reverted.", asks: false, agent: "claude", relocation: NoteRelocation(anchor: text(3, "old line"), removed: false))
        let current = try #require(try await store.note(note.id))
        #expect(current.anchor == text(3, "old line") && current.originalAnchor == nil)
        #expect(try await store.messages(for: note.id).map(\.kind) == [.reply])
    }

    /// A CRLF file's lines end differently from the text Gloss looks for; the same words are no change.
    @Test func lineEndingsAloneAreNotChangedWords() async throws {
        let crlf = Anchor.text(TextAnchor(start: .init(line: 3, col: 1), end: .init(line: 4, col: 4), text: "one\r\ntwo", before: "", after: ""))
        let lf = Anchor.text(TextAnchor(start: .init(line: 5, col: 1), end: .init(line: 6, col: 4), text: "one\ntwo", before: "", after: ""))
        let note = try await store.createNote(documentID: document.id, anchor: crlf, body: "b", color: .blue)
        try await store.applyReanchor(note.id, to: lf)
        let current = try #require(try await store.note(note.id))
        #expect(current.anchor == lf && current.originalAnchor == nil)
        #expect(try await store.messages(for: note.id).isEmpty)
    }

    /// An orphan found again on changed words has its place back, and the move is recorded.
    @Test func anOrphanFoundOnChangedWordsIsAMove() async throws {
        let note = try await sentNote()
        try await store.markOrphaned(note.id)
        try await store.applyReanchor(note.id, to: text(6, "rewritten"))
        let current = try #require(try await store.note(note.id))
        #expect(current.state == .sent && current.anchor == text(6, "rewritten") && current.originalAnchor == text(3, "old line"))
        #expect(try await store.messages(for: note.id).map(\.author) == [.app])
    }

    @Test func aReplyAndAQuestionKeepTheNoteOpen() async throws {
        let note = try await sentNote()
        try await store.agentReply(note.id, body: "Shortened the intro.", asks: false, agent: "claude")
        var current = try #require(try await store.note(note.id))
        #expect(current.state == .sent && !current.waitingOnUser)
        try await store.agentReply(note.id, body: "Only the intro, or the whole page?", asks: true, agent: "claude")
        current = try #require(try await store.note(note.id))
        #expect(current.state == .sent && current.waitingOnUser && current.needsAttention)
        let messages = try await store.messages(for: note.id)
        #expect(messages.map(\.kind) == [.reply, .question])
        #expect(messages.allSatisfy { $0.isSent && $0.author == .agent("claude") })
        // An agent with no name is still an agent; a status reply doesn't take back its open question.
        try await store.agentReply(note.id, body: "Also fixed a typo.", asks: false, agent: nil)
        #expect(try await store.messages(for: note.id).last?.author == .agent(MessageAuthor.unnamedAgent))
        #expect(try await store.note(note.id)?.waitingOnUser == true, "still waiting on the user's answer")
        // Only the user's answer, sent, ends the wait.
        try await store.addFollowUp(note.id, body: "The whole page.")
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        #expect(try await store.note(note.id)?.waitingOnUser == false)
        try await store.agentReply(note.id, body: "On it.", asks: false, agent: "claude")
        #expect(try await store.note(note.id)?.waitingOnUser == false, "a reply that doesn't ask leaves it the agent's turn")
    }

    @Test func anAgentCannotWriteToADraftOrAClosedNote() async throws {
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "mine", color: .blue)
        await #expect(throws: NoteStoreError.illegalTransition(from: .draft, to: .resolved)) {
            try await store.agentReply(draft.id, body: "hi", asks: false, agent: "claude")
        }
        let note = try await sentNote()
        try await store.resolveSent(note.id, outcome: .done, message: "Done.", agent: "claude")
        await #expect(throws: NoteStoreError.noteClosed) {
            try await store.agentReply(note.id, body: "One more thing", asks: true, agent: "claude")
        }
        #expect(NoteStoreError.noteClosed.localizedDescription == "The note is resolved; the user reopens it with a follow-up.")
        #expect(try await store.messages(for: draft.id).isEmpty)
    }

    @Test func resolvingAddsTheMessageAsAReply() async throws {
        let note = try await sentNote()
        try await store.resolveSent(note.id, outcome: .done, message: "Tightened.", agent: "codex")
        let resolved = try #require(try await store.note(note.id))
        #expect(resolved.state == .resolved && resolved.resolveMessage == "Tightened." && resolved.resolveAgent == "codex")
        let messages = try await store.messages(for: note.id)
        #expect(messages.map(\.kind) == [.reply] && messages.first?.body == "Tightened." && messages.first?.author == .agent("codex"))
        // Without a message, nothing is added.
        let quiet = try await sentNote("Quiet")
        try await store.resolveSent(quiet.id, agent: "codex")
        #expect(try await store.messages(for: quiet.id).isEmpty)
    }

    @Test func aFollowUpOnAResolvedNoteReopensIt() async throws {
        let note = try await sentNote()
        try await store.resolveSent(note.id, outcome: .done, message: "Done.", agent: "claude")
        let followUp = try await store.addFollowUp(note.id, body: "The second paragraph too, please.")
        #expect(followUp.kind == .comment && followUp.author == .user && !followUp.isSent)
        let reopened = try #require(try await store.note(note.id))
        #expect(reopened.state == .sent && reopened.hasUnsentFollowUps)
        #expect(reopened.resolveOutcome == nil && reopened.resolveMessage == nil && reopened.resolveAgent == nil)
        #expect(!reopened.needsAttention, "the user's own turn is a draft to send, not an alarm")
        // Sending it carries the follow-up.
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        #expect(try await store.messages(for: note.id).allSatisfy(\.isSent))
        #expect(try await store.note(note.id)?.hasUnsentFollowUps == false)
    }

    @Test func aFollowUpOnADraftResolvedByHandKeepsItADraft() async throws {
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "mine", color: .blue)
        try await store.resolve(draft.id)
        try await store.addFollowUp(draft.id, body: "Not done after all")
        #expect(try await store.note(draft.id)?.state == .draft, "never sent, so never an agent's")
        #expect(try await store.pendingNotes(states: [.sent]).isEmpty)
    }

    @Test func onlyAgentsQuestionsCountTowardsTheCap() async throws {
        // The user's own notes waiting on an answer don't use up the agents' allowance.
        for n in 0..<NoteStore.agentQuestionLimit {
            let note = try await sentNote("Note \(n)", line: n + 1)
            try await store.agentReply(note.id, body: "Which?", asks: true, agent: "claude")
        }
        _ = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Still room?", author: "claude")
    }

    @Test func aFollowUpOnAResolvedOrphanKeepsItAnOrphan() async throws {
        let note = try await sentNote()
        try await store.markOrphaned(note.id)
        try await store.resolveSent(note.id, outcome: .done, message: "Removed it.", agent: "claude")
        try await store.addFollowUp(note.id, body: "Put the heading back?")
        let reopened = try #require(try await store.note(note.id))
        #expect(reopened.state == .orphaned)
        // Its agent may answer: it was sent when its text went.
        try await store.agentReply(note.id, body: "Which heading?", asks: true, agent: "claude")
        #expect(try await store.note(note.id)?.waitingOnUser == true)
    }

    @Test func aReplyArrivesWhileTheUserHasADraftFollowUp() async throws {
        let note = try await sentNote()
        try await store.agentReply(note.id, body: "Which section?", asks: true, agent: "claude")
        try await store.addFollowUp(note.id, body: "The install")
        #expect(try await store.note(note.id)?.waitingOnUser == true, "waiting until the answer is sent")
        try await store.agentReply(note.id, body: "Or should I do all of them?", asks: true, agent: "claude")
        let messages = try await store.messages(for: note.id)
        #expect(messages.map(\.kind) == [.question, .comment, .question])
        #expect(messages[1].sentAt == nil, "the draft follow-up stays the user's")
        let current = try #require(try await store.note(note.id))
        #expect(current.hasUnsentFollowUps && current.waitingOnUser)
    }

    @Test func resolvingIsRefusedWhileAFollowUpIsUnsent() async throws {
        let note = try await sentNote()
        try await store.agentReply(note.id, body: "Which section?", asks: true, agent: "claude")
        try await store.addFollowUp(note.id, body: "The install")
        await #expect(throws: NoteStoreError.unsentFollowUp) { try await store.resolveSent(note.id, message: "Done.", agent: "claude") }
        #expect(NoteStoreError.unsentFollowUp.localizedDescription.contains("follow-up"))
        #expect(try await store.note(note.id)?.state == .sent)
        #expect(try await store.messages(for: note.id).count == 2, "a refused resolve writes nothing")
        // Once sent, the agent can finish.
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        try await store.resolveSent(note.id, message: "Done.", agent: "claude")
        #expect(try await store.note(note.id)?.state == .resolved)
    }

    @Test func onlyUnsentFollowUpsCanBeChanged() async throws {
        let note = try await sentNote()
        let first = try await store.addFollowUp(note.id, body: "Typo")
        try await store.updateFollowUp(first.id, body: "Fixed typo")
        #expect(try await store.messages(for: note.id).map(\.body) == ["Fixed typo"])
        let second = try await store.addFollowUp(note.id, body: "Never mind")
        try await store.deleteFollowUp(second.id)
        #expect(try await store.messages(for: note.id).map(\.id) == [first.id])
        // A failed delivery stamps nothing.
        _ = try await store.recordSend(transport: "tmux", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .failed("no pane"))
        #expect(try await store.messages(for: note.id).first?.isSent == false)
        _ = try await store.recordSend(transport: "tmux", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        await #expect(throws: NoteStoreError.messageAlreadySent(first.id)) { try await store.updateFollowUp(first.id, body: "Again") }
        await #expect(throws: NoteStoreError.messageAlreadySent(first.id)) { try await store.deleteFollowUp(first.id) }
        let missing = MessageID.new()
        await #expect(throws: NoteStoreError.messageNotFound(missing)) { try await store.deleteFollowUp(missing) }
    }

    @Test func notesListedWithTheirFollowUpState() async throws {
        let note = try await sentNote()
        let other = try await sentNote("Other", line: 9)
        try await store.addFollowUp(note.id, body: "And this")
        let listed = try await store.notes(for: document.id)
        #expect(listed.first { $0.id == note.id }?.hasUnsentFollowUps == true)
        #expect(listed.first { $0.id == other.id }?.hasUnsentFollowUps == false)
        #expect(try await store.pendingNotes(states: [.sent]).first { $0.note.id == note.id }?.note.hasUnsentFollowUps == true)
        #expect(try await store.documentsWithNotes().flatMap(\.notes).filter(\.hasUnsentFollowUps).map(\.id) == [note.id])
    }

    @Test func aRelocationMovesTheNoteAndRemembersWhereItWas() async throws {
        let note = try await sentNote()
        let first = text(5, "new line")
        try await store.applyRelocation(note.id, to: first, removed: false, author: "claude")
        var moved = try #require(try await store.note(note.id))
        #expect(moved.anchor == first && moved.originalAnchor == note.anchor)
        let second = text(7, "newer line")
        try await store.applyRelocation(note.id, to: second, removed: false, author: "claude")
        moved = try #require(try await store.note(note.id))
        #expect(moved.anchor == second && moved.originalAnchor == note.anchor, "the original place is the one before the first move")
        let messages = try await store.messages(for: note.id)
        #expect(messages.map(\.kind) == [.moved, .moved])
        #expect(messages[0].move == NoteMove(from: note.anchor, to: first, removed: false) && messages[0].author == .agent("claude"))
        #expect(messages[1].move?.from == first)
        // Moving to where it already is says nothing.
        try await store.applyRelocation(note.id, to: second, removed: false, author: "claude")
        #expect(try await store.messages(for: note.id).count == 2)

        try await store.restoreOriginalPlace(note.id)
        let restored = try #require(try await store.note(note.id))
        #expect(restored.anchor == note.anchor && restored.originalAnchor == nil)
        #expect(try await store.messages(for: note.id).last?.move == NoteMove(from: second, to: note.anchor, removed: false))
        #expect(try await store.messages(for: note.id).last?.author == .user)
        await #expect(throws: NoteStoreError.noOriginalPlace(note.id)) { try await store.restoreOriginalPlace(note.id) }
    }

    @Test func aRemovalFoundByGlossRecoversAnOrphanAndNamesNoAgent() async throws {
        let note = try await sentNote()
        try await store.markOrphaned(note.id)
        let point = Anchor.text(TextAnchor(start: .init(line: 2, col: 5), end: .init(line: 2, col: 5), text: "", before: "", after: ""))
        try await store.applyRelocation(note.id, to: point, removed: true, author: nil)
        let recovered = try #require(try await store.note(note.id))
        #expect(recovered.state == .sent && recovered.anchor == point, "back to the state it had, at the point")
        let message = try #require(try await store.messages(for: note.id).last)
        #expect(message.author == .app && message.move?.removed == true && message.isSent)
    }

    @Test func anAgentsReplyCanMoveTheNoteInTheSameWrite() async throws {
        let note = try await sentNote()
        let moved = text(4, "rewritten")
        try await store.resolveSent(note.id, outcome: .done, message: "Rewrote it.", agent: "claude", relocation: NoteRelocation(anchor: moved, removed: false))
        let resolved = try #require(try await store.note(note.id))
        #expect(resolved.state == .resolved && resolved.anchor == moved && resolved.originalAnchor == note.anchor)
        #expect(try await store.messages(for: note.id).map(\.kind) == [.moved, .reply])

        let other = try await sentNote("Other", line: 8)
        try await store.markOrphaned(other.id)
        try await store.agentReply(other.id, body: "Moved it to line 2.", asks: false, agent: "codex", relocation: NoteRelocation(anchor: text(2, "x"), removed: false))
        #expect(try await store.note(other.id)?.state == .sent, "an orphan the agent places is found again")
    }

    @Test func aUserResolvedNoteWithAFollowUpIsReopenedBySending() async throws {
        let note = try await sentNote()
        try await store.addFollowUp(note.id, body: "One more")
        try await store.resolve(note.id)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        let sent = try #require(try await store.note(note.id))
        #expect(sent.state == .sent && !sent.hasUnsentFollowUps)
    }
}
