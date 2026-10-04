import Core
import Foundation
import Testing
@testable import Gloss

struct AccessibilityTests {
    @Test func noteCardsReadAsOneSentence() {
        var note = Note(id: .new(), documentID: .new(), anchor: .wholeFile, body: "Guard zero minutes", state: .draft, color: .blue,
                        createdAt: Date(), updatedAt: Date())
        #expect(NoteCard.spokenSummary(note) == "Draft note, blue, \(Core.Anchor.wholeFile.summary). Guard zero minutes.")
        note.state = .resolved
        note.resolveOutcome = .needsInput
        note.resolveMessage = "Which unit, km or miles?"
        #expect(NoteCard.spokenSummary(note).hasPrefix("Needs input note, blue"))
        #expect(NoteCard.spokenSummary(note).hasSuffix("Agent asks: Which unit, km or miles?"), "a question is asked, as the bubble says")
        note.resolveOutcome = .done
        #expect(NoteCard.spokenSummary(note).hasSuffix("Agent replied: Which unit, km or miles?"))
    }

    @Test func aTextNoteSaysTheLineItIsAbout() {
        let text = "    var isSteep: Bool { true }"
        let index = LineIndex(text)
        let anchor = Core.Anchor.text(ReAnchorer.make(from: NSRange(location: 0, length: (text as NSString).length), in: text, index: index, hash: Data(text.utf8).sha256Hex))
        let note = Note(id: .new(), documentID: .new(), anchor: anchor, body: "Use 10%", state: .draft, color: .yellow,
                        createdAt: Date(), updatedAt: Date())
        #expect(NoteCard.spokenSummary(note) == "Draft note, yellow, \(anchor.summary). On: var isSteep: Bool { true }. Use 10%.")
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
