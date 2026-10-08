import Foundation
import Testing
@testable import Core

struct AnchorRelocatorTests {
    let content = """
        # Alerts
        Send one alert a minute.
        Severe alerts go out at once.

        ## Limits
        Severe alerts go out at once.
        Done.
        """

    @Test func findsTheTextOnTheGivenLines() throws {
        let anchor = try AnchorRelocator.text(in: content, hash: "h", line: 2, endLine: 3, text: "one alert a minute")
        #expect(anchor.start == TextPosition(line: 2, col: 6) && anchor.end == TextPosition(line: 2, col: 24))
        #expect(anchor.text == "one alert a minute" && anchor.hash == "h")
        #expect(anchor.before == "# Alerts" && anchor.after == "Severe alerts go out at once.\n\n## Limits", "context comes from the file")
    }

    @Test func findsTheNearestOccurrenceWhenTheLinesAreOff() throws {
        // On lines 3 and 6; the agent says 7.
        let near = try AnchorRelocator.text(in: content, hash: nil, line: 7, endLine: 7, text: "Severe alerts go out at once.")
        #expect(near.start.line == 6)
        let other = try AnchorRelocator.text(in: content, hash: nil, line: 1, endLine: 1, text: "Severe alerts go out at once.\n")
        #expect(other.start.line == 3 && other.end.line == 3, "nearest to the line given, trailing newline ignored")
        let both = try AnchorRelocator.text(in: content, hash: nil, line: 5, endLine: 6, text: "## Limits\nSevere alerts")
        #expect(both.start == TextPosition(line: 5, col: 1) && both.end == TextPosition(line: 6, col: 14))
    }

    @Test func textThatIsNotThereSaysWhatWasSearched() throws {
        #expect(throws: RelocationError.notFound(text: "Two alerts", lines: 1...7)) {
            try AnchorRelocator.text(in: content, hash: nil, line: 2, endLine: 2, text: "Two alerts")
        }
        let far = String(repeating: "filler\n", count: 120) + "needle\n"
        #expect(throws: RelocationError.notFound(text: "needle", lines: 1...51)) {
            try AnchorRelocator.text(in: far, hash: nil, line: 1, endLine: 1, text: "needle")
        }
        #expect(RelocationError.notFound(text: "Two alerts", lines: 1...7).localizedDescription.contains("\"Two alerts\""))
        #expect(throws: RelocationError.emptyText) { try AnchorRelocator.text(in: content, hash: nil, line: 1, endLine: 1, text: "\n") }
        #expect(throws: RelocationError.lineOutOfRange(line: 40, lineCount: 7)) { try AnchorRelocator.text(in: content, hash: nil, line: 40, endLine: 40, text: "Done.") }
    }

    @Test func crlfAndUTF16Columns() throws {
        let crlf = "first\r\nnaïve 👋 café\r\nlast"
        let anchor = try AnchorRelocator.text(in: crlf, hash: nil, line: 2, endLine: 2, text: "café")
        // "naïve 👋 " is 9 UTF-16 units (the emoji is two).
        #expect(anchor.start == TextPosition(line: 2, col: 10) && anchor.end == TextPosition(line: 2, col: 14))
        let lines = try AnchorRelocator.text(in: crlf, hash: nil, line: 1, endLine: 2, text: "first\r\nnaïve")
        #expect(lines.text == "first\nnaïve" && lines.end == TextPosition(line: 2, col: 6))
    }

    /// The agent says which line the text was on; the point is the start of what now sits there, never the end of
    /// a heading above it.
    @Test func aRemovalLandsAtTheStartOfTheLineTheAgentGave() throws {
        let after = "# Title\n\n## Caching\n\nForecasts are fetched each hour.\nlast"
        let point = try AnchorRelocator.removed(in: after, hash: "h2", line: 5)
        #expect(point.start == TextPosition(line: 5, col: 1) && point.end == point.start && point.text.isEmpty && point.hash == "h2")
        #expect(try AnchorRelocator.removed(in: after, hash: nil, line: 4).start == TextPosition(line: 5, col: 1), "a blank line gives way to the paragraph after it")
        #expect(try AnchorRelocator.removed(in: after, hash: nil, line: 1).start == TextPosition(line: 1, col: 1))
        #expect(try AnchorRelocator.removed(in: after, hash: nil, line: 7).start == TextPosition(line: 6, col: 5), "past the last line: the end of the file")
        #expect(throws: RelocationError.lineOutOfRange(line: 8, lineCount: 6)) { try AnchorRelocator.removed(in: after, hash: nil, line: 8) }
    }

    @Test func onlyTextAndElementsMove() throws {
        let element = ElementAnchor(selector: "#save", tag: "button", text: "Save", html: "<button id=save>Save</button>", rect: .init(x: 0, y: 0, w: 1, h: 1), hash: "old")
        let moved = try AnchorRelocator.relocate(.element(element), to: .element(selector: " #toolbar > button:nth-of-type(2) "), content: "", hash: nil)
        guard case .element(let next) = moved.anchor else { Issue.record("expected an element"); return }
        #expect(next.selector == "#toolbar > button:nth-of-type(2)" && next.hash == nil && next.text == "Save" && !moved.removed)
        #expect(throws: RelocationError.invalidSelector) { try AnchorRelocator.relocate(.element(element), to: .element(selector: "  "), content: "", hash: nil) }
        #expect(throws: RelocationError.wrongKind(.element)) { try AnchorRelocator.relocate(.element(element), to: .removed(line: 1), content: "", hash: nil) }
        let textAnchor = Anchor.text(try AnchorRelocator.text(in: content, hash: nil, line: 1, endLine: 1, text: "# Alerts"))
        #expect(throws: RelocationError.wrongKind(.text)) { try AnchorRelocator.relocate(textAnchor, to: .element(selector: "#x"), content: content, hash: nil) }
        let removal = try AnchorRelocator.relocate(textAnchor, to: .removed(line: 1), content: content, hash: nil)
        #expect(removal.removed)
        let image = Anchor.image(ImageAnchor(x: 0, y: 0, w: 1, h: 1, imageW: 2, imageH: 2))
        #expect(throws: RelocationError.notMovable(.image)) { try AnchorRelocator.relocate(image, to: .removed(line: 1), content: "", hash: nil) }
        #expect(throws: RelocationError.notMovable(.file)) { try AnchorRelocator.relocate(.wholeFile, to: .text(line: 1, endLine: 1, text: "x"), content: "x", hash: nil) }
        #expect(throws: RelocationError.notMovable(.pdf)) {
            try AnchorRelocator.relocate(.pdf(PDFAnchor(page: 0, bounds: nil, text: nil, pageCount: 1)), to: .removed(line: 1), content: "", hash: nil)
        }
    }
}

struct ReAnchorRemovalTests {
    func anchor(line: Int, in content: String) -> TextAnchor {
        let index = LineIndex(content)
        return ReAnchorer.make(from: index.contentRange(ofLine: line), in: content, index: index, hash: "old")
    }

    @Test func removedLinesLeaveAPointWhereTheyWere() {
        let old = "one\ntwo\nthree\nTARGET LINE\nfour\nfive"
        let note = anchor(line: 4, in: old)
        let result = ReAnchorer.text(note, in: "one\ntwo\nthree\nfour\nfive", newHash: "new")
        guard case .removed(.text(let point)) = result else { Issue.record("expected a removal, got \(result)"); return }
        #expect(point.start == TextPosition(line: 4, col: 1) && point.end == point.start && point.text.isEmpty && point.hash == "new",
                "the start of what now sits where the text was")
        // Only blank lines left between the neighbours is a removal too, at the start of the line after them, not the
        // end of the line (a heading, say) above.
        guard case .removed(.text(let gap)) = ReAnchorer.text(note, in: "one\ntwo\nthree\n\n  \nfour\nfive", newHash: "new") else { Issue.record("expected a removal"); return }
        #expect(gap.start == TextPosition(line: 6, col: 1))
    }

    @Test func removalsAtTheEdgesOfTheFile() {
        let first = anchor(line: 1, in: "TARGET\na\nb")
        guard case .removed(.text(let top)) = ReAnchorer.text(first, in: "a\nb", newHash: "n") else { Issue.record("expected a removal at the top"); return }
        #expect(top.start == TextPosition(line: 1, col: 1))
        let last = anchor(line: 3, in: "a\nb\nTARGET")
        guard case .removed(.text(let bottom)) = ReAnchorer.text(last, in: "a\nb", newHash: "n") else { Issue.record("expected a removal at the end"); return }
        #expect(bottom.start == TextPosition(line: 2, col: 2))
    }

    @Test func anEditThatIsNotARemovalReanchorsAsBefore() {
        let old = "one\ntwo\nthree\nlet x = compute(1)\nfour\nfive"
        let note = anchor(line: 4, in: old)
        let result = ReAnchorer.text(note, in: "one\ntwo\nthree\nlet x = compute(2)\nfour\nfive", newHash: "new")
        guard case .movedNeedsReview(.text(let moved)) = result else { Issue.record("expected a flagged move, got \(result)"); return }
        #expect(moved.start.line == 4 && moved.text == "let x = compute(2)")
        // Text that moved is found, not reported removed.
        guard case .moved(.text(let found)) = ReAnchorer.text(note, in: "let x = compute(1)\none\ntwo\nthree\nfour\nfive", newHash: "new") else { Issue.record("expected a move"); return }
        #expect(found.start.line == 1)
        // A blank selection is never a removal.
        let blank = anchor(line: 2, in: "a\n\nb")
        if case .removed = ReAnchorer.text(blank, in: "a\nb", newHash: "n") { Issue.record("a blank line is not removed text") }
    }

    @Test func aPointFollowsItsContext() {
        let content = "one\ntwo\nthree\nfour\nfive"
        let index = LineIndex(content)
        let point = ReAnchorer.make(from: NSRange(location: index.utf16Offset(for: TextPosition(line: 3, col: 6)), length: 0), in: content, index: index, hash: "old")
        #expect(ReAnchorer.text(point, in: content, newHash: "old") == .unchanged)
        let result = ReAnchorer.text(point, in: "zero\none\ntwo\nthree\nfour\nfive", newHash: "new")
        guard case .moved(.text(let moved)) = result else { Issue.record("expected a move, got \(result)"); return }
        #expect(moved.start == TextPosition(line: 4, col: 6) && moved.end == moved.start && moved.text.isEmpty, "still a point, never widened to its line")
        if case .removed = ReAnchorer.text(point, in: "one\ntwo\nfour\nfive", newHash: "new") { Issue.record("a point is never removed again") }
    }
}
