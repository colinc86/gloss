import Core
import Testing
@testable import Gloss

/// How a card reads a note's body as a conversation: the comment, the exchanges, and the latest turn.
struct NoteThreadTests {
    @Test func aCommentWithNoExchangeHasNoTurns() {
        let thread = NoteThread(body: "Tighten this\nand this")
        #expect(thread.comment == "Tighten this\nand this")
        #expect(thread.turns.isEmpty)
        #expect(thread.latest == nil)
        #expect(thread.earlier.isEmpty)
    }

    @Test func oneAnsweredQuestionEndsWithTheAnswer() {
        let thread = NoteThread(body: NoteStore.body("Expand this", answering: "Which section?", with: "Install"))
        #expect(thread.comment == "Expand this")
        #expect(thread.turns == [.init(speaker: .agent, text: "Which section?"), .init(speaker: .user, text: "Install")])
        #expect(thread.latest == .init(speaker: .user, text: "Install"))
        #expect(thread.earlier == [.init(speaker: .agent, text: "Which section?")])
    }

    @Test func severalRoundsKeepTheirOrder() {
        let once = NoteStore.body("Expand this", answering: "Which section?", with: "Install")
        let twice = NoteStore.body(once, answering: "Mac or Linux?", with: "Both")
        let thread = NoteThread(body: twice)
        #expect(thread.comment == "Expand this")
        #expect(thread.turns.map(\.text) == ["Which section?", "Install", "Mac or Linux?", "Both"])
        #expect(thread.turns.map(\.speaker) == [.agent, .user, .agent, .user])
        #expect(thread.latest?.text == "Both")
    }

    @Test func anAnswerWithNoQuestionIsTheUsersTurn() {
        let thread = NoteThread(body: NoteStore.body("Expand this", answering: nil, with: "The install steps"))
        #expect(thread.turns == [.init(speaker: .user, text: "The install steps")])
        #expect(thread.earlier.isEmpty)
    }

    @Test func aPendingMessageFromTheAgentIsTheLatestTurn() {
        let body = NoteStore.body("Expand this", answering: "Which section?", with: "Install")
        let thread = NoteThread(body: body, resolveMessage: "  Done, both platforms.\n")
        #expect(thread.latest == .init(speaker: .agent, text: "Done, both platforms."))
        #expect(thread.earlier.map(\.text) == ["Which section?", "Install"])
        // An agent's own question has no comment above it.
        let asked = NoteThread(body: "", resolveMessage: "Shorter, or plainer?")
        #expect(asked.comment.isEmpty)
        #expect(asked.turns == [.init(speaker: .agent, text: "Shorter, or plainer?")])
        #expect(NoteThread(body: "Fix", resolveMessage: "  ").turns.isEmpty)
    }

    @Test func aCommentLineThatBeginsWithALabelIsTheComment() {
        let thread = NoteThread(body: "Two options:\nAnswer: keep it\nAgent asked: nothing")
        #expect(thread.comment == "Two options:\nAnswer: keep it\nAgent asked: nothing")
        #expect(thread.turns.isEmpty)
        let crlf = NoteThread(body: "Expand this\r\n\r\nAgent asked: Which?\r\nAnswer: Install")
        #expect(crlf.turns.map(\.text) == ["Which?", "Install"])
    }

    @Test func labelsInsideALineAreTheComment() {
        let thread = NoteThread(body: "Say \"Answer: yes\" here\nand not Agent asked: there")
        #expect(thread.comment == "Say \"Answer: yes\" here\nand not Agent asked: there")
        #expect(thread.turns.isEmpty)
    }
}
