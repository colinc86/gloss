import Core
import Foundation
import Testing
@testable import Viewers

struct OverviewRulerTests {
    @Test func marksSitAtTheirLinesAndOpenWorkDrawsOnTop() {
        let text = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let index = LineIndex(text)
        let draft = NoteID.new(), resolved = NoteID.new(), sent = NoteID.new()
        let lineTen = index.contentRange(ofLine: 10)
        let linesFiftyToSixty = NSRange(location: index.contentRange(ofLine: 50).location,
                                        length: NSMaxRange(index.contentRange(ofLine: 60)) - index.contentRange(ofLine: 50).location)
        let marks = OverviewRulerView.marks(for: [
            TextHighlight(id: draft, range: lineTen, color: .yellow, state: .draft),
            TextHighlight(id: resolved, range: linesFiftyToSixty, color: .green, state: .resolved),
            TextHighlight(id: sent, range: index.contentRange(ofLine: 90), color: .blue, state: .sent),
        ], lineIndex: index)
        #expect(marks.map(\.noteID) == [resolved, sent, draft], "settled first, drafts drawn last so they stay on top")
        let ten = marks.first { $0.noteID == draft }!
        #expect(ten.line == 10)
        #expect(abs(ten.start - 0.09) < 0.0001)
        #expect(abs(ten.end - 0.10) < 0.0001)
        let span = marks.first { $0.noteID == resolved }!
        #expect(abs(span.start - 0.49) < 0.0001)
        #expect(abs(span.end - 0.60) < 0.0001, "a multi-line note spans its lines")
    }
}

struct JumpIndicatorTests {
    @Test func aLongNoteIndicatesOnlyItsFirstLine() {
        let index = LineIndex("alpha beta\ngamma delta\nepsilon")
        // From "beta" to the middle of "gamma": just "beta".
        #expect(TextEditorView.Coordinator.indicatorRange(for: NSRange(location: 6, length: 9), in: index) == NSRange(location: 6, length: 4))
        // A note within one line is shown whole.
        #expect(TextEditorView.Coordinator.indicatorRange(for: NSRange(location: 12, length: 5), in: index) == NSRange(location: 12, length: 5))
    }
}
