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
