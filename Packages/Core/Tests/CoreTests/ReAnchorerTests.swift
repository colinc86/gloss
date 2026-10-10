import Foundation
import Testing
@testable import Core

struct ReAnchorerTests {
    /// Part of one line reports its columns (1-based, last one included); a whole line, however it was selected, and
    /// a selection over several lines do not.
    @Test func partialColumnsOnlyForPartOfOneLine() {
        let doc = "let value = compute()\nnext line\n"
        let index = LineIndex(doc)
        func columns(_ location: Int, _ length: Int) -> ClosedRange<Int>? {
            let anchor = ReAnchorer.make(from: NSRange(location: location, length: length), in: doc, index: index, hash: nil)
            return anchor.partialColumns(lineLength: index.contentRange(ofLine: anchor.start.line).length)
        }
        #expect(columns(4, 5) == 5...9, "\"value\"")
        #expect(columns(0, 3) == 1...3, "the start of the line")
        #expect(columns(12, 9) == 13...21, "the end of the line")
        #expect(columns(4, 1) == 5...5)
        #expect(columns(0, 21) == nil, "the whole line")
        #expect(columns(0, 22) == nil, "the whole line with its newline, as a triple click selects it")
        #expect(columns(4, 22) == nil, "into the next line")
    }

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

    /// Pages as lists of words; `find` reports every match, in page order, as PDFKit does.
    struct WordsPDF: PDFTextSource {
        var pages: [[String]]
        var pageCount: Int { pages.count }
        func text(ofPage page: Int) -> String? { pages.indices.contains(page) ? pages[page].joined(separator: " ") : nil }
        func find(_ text: String) -> [(page: Int, bounds: PDFBounds)] {
            pages.indices.flatMap { page in
                pages[page].indices.filter { pages[page][$0] == text }.map { (page, PDFBounds(x: Double($0), y: 0, w: 1, h: 1)) }
            }
        }
    }

    @Test func aPDFTextNoteKeepsWhichMatchItIsOn() throws {
        let second = PDFAnchor(page: 0, bounds: nil, text: "Revenue", pageCount: 2, occurrence: 1)
        #expect(ReAnchorer.pdf(second, in: WordsPDF(pages: [["Revenue", "up", "Revenue", "down"], ["x"]])) == .unchanged)
        guard case .movedNeedsReview(.pdf(let fewer)) = ReAnchorer.pdf(second, in: WordsPDF(pages: [["Revenue", "up"], ["x"]])) else {
            Issue.record("one match left: the note falls back to it and asks for a look"); return
        }
        #expect(fewer.page == 0 && fewer.occurrence == nil)
        guard case .movedNeedsReview(.pdf(let moved)) = ReAnchorer.pdf(second, in: WordsPDF(pages: [["x"], ["a", "Revenue", "b", "Revenue"], ["Revenue"]])) else {
            Issue.record("expected a move to the nearest page"); return
        }
        #expect(moved.page == 1 && moved.occurrence == nil, "the first match on the page it moved to")
        #expect(moved.textTop == 1, "and the top of that match, for its place on the page")
        let third = PDFAnchor(page: 0, bounds: nil, text: "Revenue", pageCount: 1)
        guard case .moved(.pdf(let only)) = ReAnchorer.pdf(third, in: WordsPDF(pages: [["x"], ["Revenue"]])) else { Issue.record("expected moved"); return }
        #expect(only.occurrence == nil)
        #expect(PDFAnchor(page: 0, bounds: nil, text: "a", pageCount: 1, occurrence: 0).occurrence == nil, "the first match is stored as before")
        let shouting = WordsPDF(pages: [["REVENUE", "up", "REVENUE", "down"], ["x"]])
        struct CaseBlind: PDFTextSource {
            var base: WordsPDF
            var pageCount: Int { base.pageCount }
            func text(ofPage page: Int) -> String? { base.text(ofPage: page) }
            func find(_ text: String) -> [(page: Int, bounds: PDFBounds)] { base.find(text.uppercased()) }
        }
        #expect(ReAnchorer.pdf(second, in: CaseBlind(base: shouting)) == .unchanged, "a change of case keeps the note on its match, as PDFKit's search ignores case")
    }

    @Test func pictureRegionsFollowThePicturesSize() {
        let region = ImageAnchor(x: 100, y: 50, w: 200, h: 100, imageW: 800, imageH: 400)
        let anchor = ElementAnchor(selector: "#hero", tag: "img", text: "", html: "<img>", rect: .init(x: 0, y: 0, w: 400, h: 200), hash: "old", region: region)
        func picture(_ w: Int?, _ h: Int?) -> ElementResolution {
            .init(bySelector: ElementCandidate(selector: "#hero", tag: "img", text: "", html: "<img>", rect: .init(x: 0, y: 10, w: 400, h: 200), imageW: w, imageH: h))
        }
        guard case .moved(.element(let same)) = ReAnchorer.element(anchor, resolution: picture(800, 400), newHash: "new") else { Issue.record("expected moved"); return }
        #expect(same.region == region, "the same picture keeps its region")
        guard case .movedNeedsReview(.element(let bigger)) = ReAnchorer.element(anchor, resolution: picture(1600, 800), newHash: "new") else { Issue.record("expected review"); return }
        #expect(bigger.region == ImageAnchor(x: 200, y: 100, w: 400, h: 200, imageW: 1600, imageH: 800), "a resized picture keeps the same part, flagged")
        // An element that isn't a picture (a region stored on a div, from a page that swapped its img for one) loses it.
        guard case .movedNeedsReview(.element(let gone)) = ReAnchorer.element(
            ElementAnchor(selector: "#hero", tag: "div", text: "", html: "<div>", rect: .init(x: 0, y: 0, w: 400, h: 200), hash: "old", region: region),
            resolution: .init(bySelector: ElementCandidate(selector: "#hero", tag: "div", text: "", html: "<div>", rect: .init(x: 0, y: 10, w: 400, h: 200))), newHash: "new"
        ) else { Issue.record("expected review"); return }
        #expect(gone.region == nil, "no longer a picture: no region")
        // A picture that can't tell its size (lazy, not loaded; an svg) keeps the region, unflagged.
        guard case .moved(.element(let unloaded)) = ReAnchorer.element(anchor, resolution: picture(nil, nil), newHash: "new") else { Issue.record("expected moved"); return }
        #expect(unloaded.region == region)
        let svg = ElementAnchor(selector: "#chart", tag: "svg", text: "", html: "<svg>", rect: .init(x: 0, y: 0, w: 400, h: 200), hash: "old", region: region)
        let relaid = ElementResolution(bySelector: ElementCandidate(selector: "#chart", tag: "svg", text: "", html: "<svg>", rect: .init(x: 0, y: 0, w: 300, h: 150)))
        guard case .moved(.element(let chart)) = ReAnchorer.element(svg, resolution: relaid, newHash: "new") else { Issue.record("expected moved"); return }
        #expect(chart.region == region, "an svg laid out at another size is the same picture")
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

        // The element's own line, when the page could map it, follows the element.
        var lower = candidate("#toolbar > button:nth-of-type(2)")
        lower.line = 28
        guard case .moved(.element(let followed)) = ReAnchorer.element(anchor, resolution: .init(bySelector: lower), newHash: "new") else {
            Issue.record("expected moved"); return
        }
        #expect(followed.line == 28, "twenty lines were added above the element")

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
