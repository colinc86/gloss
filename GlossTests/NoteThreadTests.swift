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
        #expect(thread.turns[0].agent == nil, "an agent that gave no name is just the agent")
        #expect(thread.latest?.unsent == true)
    }
}
