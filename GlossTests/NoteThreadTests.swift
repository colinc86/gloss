import Core
import Foundation
import Testing
@testable import Gloss

/// How a card reads a note as a conversation: the comment, its messages as turns, and the latest turn.
struct NoteThreadTests {
    private let noteID = NoteID.new()

    private func message(_ author: MessageAuthor, _ kind: MessageKind, _ body: String, sent: Bool = true) -> NoteMessage {
        NoteMessage(id: .new(), noteID: noteID, author: author, kind: kind, body: body, createdAt: Date(), sentAt: sent ? Date() : nil)
    }

    @Test func aCommentWithNoMessagesHasNoTurns() {
        let thread = NoteThread(comment: "Tighten this\nand this\n", messages: [])
        #expect(thread.comment == "Tighten this\nand this")
        #expect(thread.turns.isEmpty && thread.latest == nil)
    }

    @Test func messagesBecomeTurnsWithTheLatestLast() {
        let thread = NoteThread(comment: "Expand this", messages: [
            message(.agent("claude"), .question, "Which section?"),
            message(.user, .comment, " Install \n"),
            message(.agent("claude"), .reply, "Expanded it."),
        ])
        #expect(thread.turns.map(\.speaker) == [.agent, .user, .agent])
        #expect(thread.turns.map(\.text) == ["Which section?", "Install", "Expanded it."])
        #expect(thread.turns[0].asks && !thread.turns[2].asks && thread.turns[0].agent == "claude")
        #expect(thread.latest?.text == "Expanded it." && thread.earlier.count == 2)
    }

    @Test func movesAndUnnamedAgentsReadQuietly() {
        let point = Anchor.text(TextAnchor(start: .init(line: 1, col: 1), end: .init(line: 1, col: 1), text: "", before: "", after: ""))
        var moved = message(.app, .moved, "")
        moved.move = NoteMove(from: .wholeFile, to: point, removed: true)
        let thread = NoteThread(comment: "", messages: [
            moved,
            message(.agent(MessageAuthor.unnamedAgent), .question, "Shorter, or plainer?"),
            message(.user, .comment, "Plainer", sent: false),
        ])
        #expect(thread.turns.count == 2, "moves are not turns")
        #expect(thread.entries.count == 3 && thread.latestMove?.title == "Removed", "a removal Gloss found names no agent")
        #expect(thread.unsent.map(\.text) == ["Plainer"])
        #expect(thread.turns[0].agent == nil, "an agent that gave no name is just the agent")
        #expect(thread.latest?.unsent == true)
    }

    @Test func aMoveNamesWhoMovedItAndKeepsTheOldText() {
        let index = LineIndex("let a = 1\nlet b = 2")
        let old = Anchor.text(ReAnchorer.make(from: index.contentRange(ofLine: 2), in: "let a = 1\nlet b = 2", index: index, hash: nil))
        let point = Anchor.text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 1), text: "", before: "let a = 1", after: ""))
        var moved = message(.agent("codex"), .moved, "")
        moved.move = NoteMove(from: old, to: point, removed: true)
        var unnamed = message(.agent(MessageAuthor.unnamedAgent), .moved, "")
        unnamed.move = NoteMove(from: point, to: old, removed: false)
        let thread = NoteThread(comment: "Inline b", messages: [moved, message(.agent("codex"), .reply, "Inlined it."), unnamed])
        guard case .move(let first) = thread.entries[0] else { Issue.record("a move first"); return }
        #expect(first.title == "Removed by Codex" && first.oldExcerpt == "let b = 2" && first.removed)
        #expect(thread.latestMove?.title == "Edited by the agent")
        #expect(point.isRemovalPoint && !old.isRemovalPoint)
    }

    /// A click opens a card while it is selected; the toggle closes it then, or opens it to stay open.
    @Test func selectingOpensACardAndTheTogglePinsOrClosesIt() {
        var opening = CardOpening()
        #expect(!opening.isOpen(selected: false) && opening.isOpen(selected: true), "selected is open")
        opening.toggle(selected: true)
        #expect(!opening.isOpen(selected: true), "the toggle closes a selected card")
        opening.deselected()
        #expect(opening.isOpen(selected: true), "selected again, it opens again")
        opening.toggle(selected: false)
        #expect(opening.isOpen(selected: false), "opened by the toggle without selecting")
        opening.deselected()
        #expect(opening.isOpen(selected: false), "what the toggle opened stays open after deselecting")
        opening.toggle(selected: true)
        opening.deselected()
        #expect(!opening.isOpen(selected: false))
    }
}
