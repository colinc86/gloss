import Core
import Foundation
import Testing
@testable import Viewers

struct MinimapTests {
    @Test func marksSitAtTheirLinesAndOpenWorkDrawsOnTop() {
        let text = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let index = LineIndex(text)
        let draft = NoteID.new(), resolved = NoteID.new(), sent = NoteID.new()
        let lineTen = index.contentRange(ofLine: 10)
        let linesFiftyToSixty = NSRange(location: index.contentRange(ofLine: 50).location,
                                        length: NSMaxRange(index.contentRange(ofLine: 60)) - index.contentRange(ofLine: 50).location)
        let marks = MinimapView.marks(for: [
            TextHighlight(id: draft, range: lineTen, color: .yellow, state: .draft),
            TextHighlight(id: resolved, range: linesFiftyToSixty, color: .green, state: .resolved),
            TextHighlight(id: sent, range: index.contentRange(ofLine: 90), color: .blue, state: .sent),
        ], lineIndex: index)
        #expect(marks.map(\.noteID) == [resolved, sent, draft], "settled first, drafts drawn last so they stay on top")
        #expect(marks.first { $0.noteID == draft }?.lines == 10...10)
        #expect(marks.first { $0.noteID == resolved }?.lines == 50...60, "a multi-line note spans its lines")
    }

    /// Replaced text has no place to mark, as in the gutter; removed text is an outlined tick where it was.
    @Test func invalidatedNotesLeaveTheMinimapAndPointsAreMarked() {
        let index = LineIndex((1...10).map { "line \($0)" }.joined(separator: "\n"))
        let replaced = NoteID.new(), removed = NoteID.new()
        let marks = MinimapView.marks(for: [
            TextHighlight(id: replaced, range: NSRange(location: 3, length: 0), color: .yellow, state: .draft, isInvalidated: true),
            TextHighlight(id: removed, range: NSRange(location: index.contentRange(ofLine: 5).location, length: 0), color: .blue, state: .sent),
        ], lineIndex: index)
        #expect(marks.map(\.noteID) == [removed])
        #expect(marks[0].isPoint && marks[0].line == 5)
    }

    /// The old ruler stretched a five-line file over the pane, so one line's note was a fifth of the window tall.
    @Test func aShortFileIsAShortPicture() {
        let layout = MinimapView.Layout(lineCount: 5, viewHeight: 600, scrollFraction: 0, visibleLines: nil)
        #expect(layout.contentHeight == 10)
        #expect(layout.offset == 0)
        let note = layout.rect(forLines: 3...3)
        #expect(note.y == 4 && note.height == 2)
        #expect(layout.slider == nil, "no slider while the whole file shows")
        #expect(layout.shownLines == 1...5)
        #expect(layout.line(atY: 500) == 5, "a click below the picture lands on the last line")
    }

    @Test func aLongFileScrollsWithTheEditor() {
        // 1,000 lines are 2,000 pt of picture in a 500 pt view: 1,500 pt to travel.
        var layout = MinimapView.Layout(lineCount: 1000, viewHeight: 500, scrollFraction: 0, visibleLines: 1...40)
        #expect(layout.offset == 0)
        #expect(layout.slider?.y == 0 && layout.slider?.height == 80)
        layout.scrollFraction = 1
        layout.visibleLines = 961...1000
        #expect(layout.offset == 1500)
        #expect(layout.slider?.y == 420, "the slider ends at the bottom of the view")
        #expect(layout.top(ofLine: 1000) == 498)
        layout.scrollFraction = 0.5
        #expect(layout.offset == 750)
        #expect(layout.line(atY: 0) == 376)
        #expect(layout.shownLines == 376...625)
        #expect(layout.sliderTravel == 420)
    }

    /// Wrapped lines make the editor's pixel scroll disagree with a picture of source lines; the fraction comes from
    /// the top line on screen instead, so the slider sits over exactly the lines shown however tall they wrap.
    @Test func theSliderFollowsSourceLinesNotPixels() {
        let fraction = MinimapView.Layout.fraction(firstLine: 101, visibleCount: 12, lineCount: 1000)
        let layout = MinimapView.Layout(lineCount: 1000, viewHeight: 800, scrollFraction: fraction, visibleLines: 101...112)
        let slider = try! #require(layout.slider)
        #expect(abs(slider.y - layout.top(ofLine: 101)) < 0.001)
        #expect(slider.height == 24)
        #expect(MinimapView.Layout.firstLine(forFraction: fraction, visibleCount: 12, lineCount: 1000) == 101)
        #expect(MinimapView.Layout.fraction(firstLine: 1, visibleCount: 40, lineCount: 30) == 0, "nothing to scroll")
    }

    @Test func runsSplitOnWhitespaceTabsAndColour() {
        func runs(_ line: String, max: Int = 100, key: (Int) -> Int = { _ in 0 }) -> [MinimapView.Run<Int>] {
            MinimapView.runs(in: Array(line.utf16), tabWidth: 4, maxColumns: max, key: key)
        }
        #expect(runs("let x = 1").map { [$0.column, $0.length] } == [[0, 3], [4, 1], [6, 1], [8, 1]])
        #expect(runs("\tfoo").map(\.column) == [4], "a tab advances to the next stop")
        #expect(runs("ab\tc").map(\.column) == [0, 4])
        #expect(runs("").isEmpty)
        #expect(runs("    ").isEmpty)
        #expect(runs("abcdefghij", max: 4).map(\.length) == [4], "nothing past the last column")
        // `let` and `x` in different captures: the run breaks where the colour changes.
        #expect(runs("letx", key: { $0 < 3 ? 1 : 2 }).map { [$0.column, $0.length, $0.key] } == [[0, 3, 1], [3, 1, 2]])
        #expect(runs("a😀b").map(\.length) == [3], "a surrogate pair is one column")
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

    @Test func hunkMarksSitAtTheirLinesWithDeletionsAsPoints() {
        let marks = MinimapView.hunkMarks(for: LineChanges(added: [41...50, 10...10], deletions: [75]))
        #expect(marks.map(\.lines) == [10...10, 41...50, 75...75])
        #expect(marks[2].isDeletion)
    }
}
