import Foundation
import Testing
@testable import Core

struct ReAnchorerTests {
    let original = """
    # Plan
    intro line
    before two
    before one
    ## Auth flow
    The client refreshes tokens every 5 minutes.
    after one
    after two
    tail
    """

    var anchor: TextAnchor {
        let index = LineIndex(original)
        let range = NSRange(location: index.lineStarts[4], length: index.contentRange(ofLine: 6).location + index.contentRange(ofLine: 6).length - index.lineStarts[4])
        return ReAnchorer.make(from: range, in: original, index: index, hash: "old")
    }

    @Test func makeBuildsContextAndPositions() {
        let made = anchor
        #expect(made.start == TextPosition(line: 5, col: 1))
        #expect(made.end == TextPosition(line: 6, col: 45))
        #expect(made.text == "## Auth flow\nThe client refreshes tokens every 5 minutes.")
        #expect(made.before == "intro line\nbefore two\nbefore one")
        #expect(made.after == "after one\nafter two\ntail")
    }

    @Test func unchangedWhenHashMatches() {
        #expect(ReAnchorer.text(anchor, in: "anything", newHash: "old") == .unchanged)
    }

    @Test func exactMatchMovesDown() {
        let edited = "new line\nanother\n" + original
        guard case .moved(.text(let moved)) = ReAnchorer.text(anchor, in: edited, newHash: "new") else { Issue.record("expected moved"); return }
        #expect(moved.start.line == 7)
        #expect(moved.end.line == 8)
        #expect(moved.text == anchor.text)
        #expect(moved.hash == "new")
        #expect(moved.before == "intro line\nbefore two\nbefore one")
    }

    @Test func exactMatchMovesUpAndHandlesCRLF() {
        let edited = original.replacingOccurrences(of: "intro line\nbefore two\n", with: "").replacingOccurrences(of: "\n", with: "\r\n")
        guard case .moved(.text(let moved)) = ReAnchorer.text(anchor, in: edited, newHash: "new") else { Issue.record("expected moved"); return }
        #expect(moved.start.line == 3)
        #expect(moved.end.line == 4)
    }

    @Test func duplicateTextPicksTheNearest() {
        let far = Array(repeating: "filler", count: 300).joined(separator: "\n")
        let edited = original + "\n" + far + "\n" + anchor.text + "\n"
        guard case .moved(.text(let moved)) = ReAnchorer.text(anchor, in: edited, newHash: "new") else { Issue.record("expected moved"); return }
        #expect(moved.start.line == 5)
    }

    @Test func fuzzyMatchOnContextWhenTextRewritten() {
        let edited = original.replacingOccurrences(of: "The client refreshes tokens every 5 minutes.", with: "The client refreshes tokens every 15 minutes.")
        guard case .moved(.text(let moved)) = ReAnchorer.text(anchor, in: edited, newHash: "new") else { Issue.record("expected moved"); return }
        #expect(moved.start.line == 5)
        #expect(moved.end.line == 6)
        #expect(moved.text == "## Auth flow\nThe client refreshes tokens every 15 minutes.")
    }

    @Test func heavilyRewrittenSpanNeedsReview() {
        let edited = original.replacingOccurrences(of: "## Auth flow\nThe client refreshes tokens every 5 minutes.", with: "## Auth flow\nTokens: 15 minute TTL.\nSee api.md.\nAnd more.")
        let result = ReAnchorer.text(anchor, in: edited, newHash: "new")
        guard case .movedNeedsReview(.text(let moved)) = result else { Issue.record("expected review, got \(result)"); return }
        #expect(moved.start.line == 5)
        #expect(moved.end.line == 8)
    }

    @Test func contextGapIsAddedBackForHeadingsAfterBlankLines() {
        let doc = "# Plan\n\n## Auth flow\nThe client refreshes tokens every 5 minutes.\n\n## Next\nmore\n"
        let index = LineIndex(doc)
        let range = NSRange(location: index.lineStarts[2], length: index.contentRange(ofLine: 4).location + index.contentRange(ofLine: 4).length - index.lineStarts[2])
        let made = ReAnchorer.make(from: range, in: doc, index: index, hash: "old")
        #expect(made.before == "# Plan\n")
        #expect(made.after == "\n## Next\nmore")
        let edited = "# Plan\n\n## Auth flow\nTokens now live 15 minutes and refresh lazily.\n\n## Later\nmore\n"
        // Half the lines changed and only the heading context survived, so a review flag is expected; the span must still be right.
        let moved: TextAnchor
        switch ReAnchorer.text(made, in: edited, newHash: "new") {
        case .moved(.text(let anchor)), .movedNeedsReview(.text(let anchor)): moved = anchor
        default: Issue.record("expected a relocated anchor"); return
        }
        #expect(moved.start.line == 3)
        #expect(moved.end.line == 4)
        #expect(moved.text == "## Auth flow\nTokens now live 15 minutes and refresh lazily.")
    }

    @Test func wholeLineSelectionEndsOnTheSelectedLine() {
        let doc = "one\ntwo\nthree\nfour\n"
        let index = LineIndex(doc)
        // Selecting lines 2 and 3 in NSTextView gives a range ending at the start of line 4.
        let range = NSRange(location: index.lineStarts[1], length: index.lineStarts[3] - index.lineStarts[1])
        let made = ReAnchorer.make(from: range, in: doc, index: index, hash: nil)
        #expect(made.start == TextPosition(line: 2, col: 1))
        #expect(made.end == TextPosition(line: 3, col: 6))
        #expect(made.text == "two\nthree")
        #expect(made.after == "four\n")
        #expect(ExcerptExtractor.lines(for: made, in: doc) == ["two", "three"])
    }

    @Test func farAwayContextIsNotTrusted() {
        let filler = Array(repeating: "x", count: 1000)
        let doc = (["intro line", "before two", "before one"] + filler + ["after one", "after two"]).joined(separator: "\n")
        let result = ReAnchorer.text(anchor, in: doc, newHash: "new")
        #expect(result == .orphaned, "a 1000-line bracketed span is not a plausible re-anchor")
    }

    @Test func orphanedWhenNothingMatches() {
        #expect(ReAnchorer.text(anchor, in: "completely\ndifferent\nfile", newHash: "new") == .orphaned)
    }

    @Test func imageRules() {
        let image = ImageAnchor(x: 100, y: 50, w: 200, h: 100, imageW: 1000, imageH: 500, hash: "a")
        #expect(ReAnchorer.image(image, newWidth: 1000, newHeight: 500, newHash: "a") == .unchanged)
        guard case .movedNeedsReview(.image(let same)) = ReAnchorer.image(image, newWidth: 1000, newHeight: 500, newHash: "b") else { Issue.record("expected review"); return }
        #expect(same.x == 100 && same.hash == "b")
        guard case .movedNeedsReview(.image(let scaled)) = ReAnchorer.image(image, newWidth: 2000, newHeight: 1000, newHash: "c") else { Issue.record("expected review"); return }
        #expect(scaled.x == 200 && scaled.y == 100 && scaled.w == 400 && scaled.h == 200)
        #expect(scaled.imageW == 2000 && scaled.imageH == 1000)
    }

    struct FakePDF: PDFTextSource {
        var pages: [String]
        var pageCount: Int { pages.count }
        func text(ofPage page: Int) -> String? { pages.indices.contains(page) ? pages[page] : nil }
        func find(_ text: String) -> [(page: Int, bounds: PDFBounds)] {
            pages.enumerated().filter { $0.element.contains(text) }.map { ($0.offset, PDFBounds(x: 1, y: 2, w: 3, h: 4)) }
        }
    }

    @Test func pdfRules() {
        let pdf = PDFAnchor(page: 1, bounds: PDFBounds(x: 0, y: 0, w: 10, h: 10), text: "Section 4", pageCount: 3)
        #expect(ReAnchorer.pdf(pdf, in: FakePDF(pages: ["a", "Section 4 here", "c"])) == .unchanged)
        guard case .movedNeedsReview(.pdf(let countChanged)) = ReAnchorer.pdf(pdf, in: FakePDF(pages: ["a", "Section 4 here", "c", "d"])) else { Issue.record("expected review"); return }
        #expect(countChanged.pageCount == 4 && countChanged.page == 1)
        guard case .moved(.pdf(let moved)) = ReAnchorer.pdf(pdf, in: FakePDF(pages: ["new", "a", "Section 4 here"])) else { Issue.record("expected moved"); return }
        #expect(moved.page == 2)
        #expect(moved.bounds == PDFBounds(x: 1, y: 2, w: 3, h: 4))
        #expect(ReAnchorer.pdf(pdf, in: FakePDF(pages: ["x", "y"])) == .orphaned)
        let regionOnly = PDFAnchor(page: 5, bounds: PDFBounds(x: 0, y: 0, w: 1, h: 1), text: nil, pageCount: 6)
        #expect(ReAnchorer.pdf(regionOnly, in: FakePDF(pages: ["a"])) == .orphaned)
        #expect(ReAnchorer.pdf(regionOnly, in: FakePDF(pages: Array(repeating: "", count: 6))) == .unchanged)
    }

    @Test func elementRules() {
        let anchor = ElementAnchor(selector: "#toolbar > button:nth-of-type(2)", tag: "button", text: "Save", html: "<button>Save</button>", rect: .init(x: 100, y: 100, w: 50, h: 20), line: 7, hash: "old")
        func candidate(_ selector: String, tag: String = "button", text: String = "Save", x: Double = 100, y: Double = 100) -> ElementCandidate {
            ElementCandidate(selector: selector, tag: tag, text: text, html: "<\(tag)>\(text)</\(tag)>", rect: .init(x: x, y: y, w: 50, h: 20))
        }

        #expect(ReAnchorer.element(anchor, resolution: .init(), newHash: "old") == .unchanged)

        // Same selector and text: kept, with the new rect, html and hash; the line is refreshed when the caller knows it.
        guard case .moved(.element(let moved)) = ReAnchorer.element(anchor, resolution: .init(bySelector: candidate("#toolbar > button:nth-of-type(2)", y: 140)), newHash: "new", line: 9) else {
            Issue.record("expected moved"); return
        }
        #expect(moved.rect.y == 140 && moved.hash == "new" && moved.line == 9 && moved.selector == anchor.selector)

        // Same selector, different text: kept but flagged, text and html refreshed.
        guard case .movedNeedsReview(.element(let retitled)) = ReAnchorer.element(anchor, resolution: .init(bySelector: candidate("#toolbar > button:nth-of-type(2)", text: "  Save  changes ")), newHash: "new") else {
            Issue.record("expected review"); return
        }
        #expect(retitled.text == "Save changes" && retitled.line == 7)

        // The selector now hits a different kind of element: fall through to text matches.
        let wrongTag = ElementResolution(bySelector: candidate("#toolbar > button:nth-of-type(2)", tag: "div", text: "Save"), byText: [candidate("#save")])
        guard case .movedNeedsReview(.element(let byText)) = ReAnchorer.element(anchor, resolution: wrongTag, newHash: "new") else {
            Issue.record("expected text match"); return
        }
        #expect(byText.selector == "#save")

        // Several text matches: the nearest to the old rect wins.
        let several = ElementResolution(byText: [candidate("#far", x: 900, y: 900), candidate("#near", x: 110, y: 105), candidate("div#wrong", tag: "div")])
        guard case .movedNeedsReview(.element(let nearest)) = ReAnchorer.element(anchor, resolution: several, newHash: "new") else {
            Issue.record("expected nearest"); return
        }
        #expect(nearest.selector == "#near")

        #expect(ReAnchorer.element(anchor, resolution: .init(byText: [candidate("div#x", tag: "div")]), newHash: "new") == .orphaned)
        #expect(ReAnchorer.element(anchor, resolution: .init(), newHash: "new") == .orphaned)
    }
}
