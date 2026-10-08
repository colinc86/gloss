import Core
import Foundation
import Testing
@testable import Gloss

struct AccessibilityTests {
    @Test func noteCardsReadAsOneSentence() {
        var note = Note(id: .new(), documentID: .new(), anchor: .wholeFile, body: "Guard zero minutes", state: .draft, color: .blue,
                        createdAt: Date(), updatedAt: Date())
        #expect(NoteCard.spokenSummary(note) == "Draft note, blue, \(Core.Anchor.wholeFile.summary). Guard zero minutes.")
        note.state = .sent
        note.waitingOnUser = true
        let question = NoteThread.Turn(speaker: .agent, text: "Which unit, km or miles?", asks: true)
        #expect(NoteCard.spokenSummary(note, latest: question).hasPrefix("Your turn note, blue"))
        #expect(NoteCard.spokenSummary(note, latest: question).hasSuffix("Agent: Which unit, km or miles?, waiting for your answer."), "who spoke, the words, and that it waits")
        note.waitingOnUser = false
        let reply = NoteThread.Turn(speaker: .agent, text: "Which unit, km or miles?")
        #expect(NoteCard.spokenSummary(note, latest: reply).hasSuffix("Agent: Which unit, km or miles?"))
        let followUp = NoteThread.Turn(speaker: .user, text: "Miles, please", unsent: true)
        #expect(NoteCard.spokenSummary(note, latest: followUp).hasSuffix("You, not sent: Miles, please."))
        note.state = .resolved
        note.resolveMessage = "Switched to km."
        #expect(NoteCard.spokenSummary(note).hasSuffix("Agent: Switched to km."), "a resolved note's reply, before its thread loads")
    }

    @Test func aTextNoteSaysTheLineItIsAbout() {
        let text = "    var isSteep: Bool { true }"
        let index = LineIndex(text)
        let anchor = Core.Anchor.text(ReAnchorer.make(from: NSRange(location: 0, length: (text as NSString).length), in: text, index: index, hash: Data(text.utf8).sha256Hex))
        let note = Note(id: .new(), documentID: .new(), anchor: anchor, body: "Use 10%", state: .draft, color: .yellow,
                        createdAt: Date(), updatedAt: Date())
        #expect(NoteCard.spokenSummary(note) == "Draft note, yellow, \(anchor.summary). On: var isSteep: Bool { true }. Use 10%.")
        var removed = note
        removed.anchor = .text(TextAnchor(start: .init(line: 1, col: 5), end: .init(line: 1, col: 5), text: "", before: "", after: ""))
        #expect(NoteCard.spokenSummary(removed).contains("Its text was removed."), "a removal point says so instead of quoting nothing")
    }

    @Test func treeRowsSayWhatTheirMarksShow() {
        #expect(FileCellView.spokenLabel(name: "README.md", isDirectory: false, mark: nil, folderCount: 0, holdsActive: false) == "README.md")
        let mark = NoteMark(count: 2, colors: [.yellow], needsAttention: true)
        #expect(FileCellView.spokenLabel(name: "pace.py", isDirectory: false, mark: mark, folderCount: 0, holdsActive: false)
            == "pace.py, 2 open notes, needs attention")
        #expect(FileCellView.spokenLabel(name: "src", isDirectory: true, mark: nil, folderCount: 1, holdsActive: true)
            == "src, 1 open note inside, contains the open file")
    }
}
