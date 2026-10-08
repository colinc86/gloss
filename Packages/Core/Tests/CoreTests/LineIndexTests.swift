import Foundation
import Testing
@testable import Core

struct LineIndexTests {
    @Test func handlesEveryTerminator() {
        let text = "a\r\nb\nc\rd\u{2028}e\u{85}f"
        let index = LineIndex(text)
        #expect(index.lineCount == 6)
        #expect(index.lineStarts == [0, 3, 5, 7, 9, 11])
        #expect(index.terminatorLengths == [2, 1, 1, 1, 1, 0])
        #expect(text.line(1, index: index) == "a")
        #expect(text.line(4, index: index) == "d")
        #expect(text.line(6, index: index) == "f")
        #expect(text.line(7, index: index) == nil)
    }

    @Test func trailingNewlineMakesAnEmptyLastLine() {
        let index = LineIndex("one\ntwo\n")
        #expect(index.lineCount == 3)
        #expect(index.contentRange(ofLine: 3) == NSRange(location: 8, length: 0))
        #expect(LineIndex("").lineCount == 1)
        #expect(LineIndex("").position(forUTF16Offset: 0) == TextPosition(line: 1, col: 1))
    }

    @Test func positionsRoundTripIncludingSurrogatePairs() {
        let text = "x😀y\nsecond"
        let index = LineIndex(text)
        // 😀 is two UTF-16 units, so "y" sits at offset 3 (col 4).
        #expect(index.position(forUTF16Offset: 3) == TextPosition(line: 1, col: 4))
        #expect(index.utf16Offset(for: TextPosition(line: 1, col: 4)) == 3)
        #expect(index.position(forUTF16Offset: 5) == TextPosition(line: 2, col: 1))
        #expect(index.position(forUTF16Offset: 999) == TextPosition(line: 2, col: 7))
        #expect(index.utf16Offset(for: TextPosition(line: 1, col: 99)) == 4, "clamps to the line content end")
        #expect(index.utf16Offset(for: TextPosition(line: 9, col: 1)) == 5, "clamps the line")
    }

    @Test func anchorRanges() {
        let text = "line one\nline two\nline three"
        let index = LineIndex(text)
        let anchor = TextAnchor(start: .init(line: 2, col: 6), end: .init(line: 3, col: 5), text: "", before: "", after: "")
        let range = index.range(for: anchor)
        #expect((text as NSString).substring(with: range) == "two\nline")
        let (start, end) = index.positions(for: range)
        #expect(start == anchor.start)
        #expect(end == anchor.end)
        #expect(index.range(ofLine: 1) == NSRange(location: 0, length: 9))
        #expect(index.contentRange(ofLine: 1) == NSRange(location: 0, length: 8))
    }
}

struct AnchorShifterTests {
    let anchor = NSRange(location: 10, length: 5)   // 10..<15

    @Test func editBeforeShifts() {
        #expect(AnchorShifter.apply(edit: NSRange(location: 2, length: 3), replacementLength: 0, to: anchor) == .shifted(NSRange(location: 7, length: 5)))
        #expect(AnchorShifter.apply(edit: NSRange(location: 10, length: 0), replacementLength: 4, to: anchor) == .shifted(NSRange(location: 14, length: 5)), "insertion at the start pushes the anchor")
    }

    @Test func editAfterLeavesItAlone() {
        #expect(AnchorShifter.apply(edit: NSRange(location: 15, length: 0), replacementLength: 3, to: anchor) == .unchanged(anchor), "insertion at the end is outside")
        #expect(AnchorShifter.apply(edit: NSRange(location: 20, length: 2), replacementLength: 0, to: anchor) == .unchanged(anchor))
    }

    @Test func editInsideResizes() {
        #expect(AnchorShifter.apply(edit: NSRange(location: 12, length: 0), replacementLength: 2, to: anchor) == .resized(NSRange(location: 10, length: 7)))
        #expect(AnchorShifter.apply(edit: NSRange(location: 11, length: 3), replacementLength: 0, to: anchor) == .resized(NSRange(location: 10, length: 2)))
    }

    @Test func overlapsClampToSurvivingPart() {
        // Replaces 8..<12 with 1 char: surviving 12..<15 now starts at 8 + 1.
        #expect(AnchorShifter.apply(edit: NSRange(location: 8, length: 4), replacementLength: 1, to: anchor) == .resized(NSRange(location: 9, length: 3)))
        // Replaces 13..<20: surviving head is 10..<13.
        #expect(AnchorShifter.apply(edit: NSRange(location: 13, length: 7), replacementLength: 2, to: anchor) == .resized(NSRange(location: 10, length: 3)))
    }

    @Test func coveringEditCollapsesOrInvalidates() {
        #expect(AnchorShifter.apply(edit: NSRange(location: 10, length: 5), replacementLength: 0, to: anchor) == .collapsed(NSRange(location: 10, length: 0)),
                "deleting the text leaves a point where it was")
        #expect(AnchorShifter.apply(edit: NSRange(location: 8, length: 9), replacementLength: 0, to: anchor) == .collapsed(NSRange(location: 8, length: 0)))
        #expect(AnchorShifter.apply(edit: NSRange(location: 9, length: 7), replacementLength: 9, to: anchor) == .invalidated)
        #expect(AnchorShifter.apply(edit: NSRange(location: 10, length: 5), replacementLength: 5, to: anchor) == .invalidated, "replacing the exact text is still a new text")
    }
}
