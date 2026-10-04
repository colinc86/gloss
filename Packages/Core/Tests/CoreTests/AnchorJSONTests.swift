import Foundation
import Testing
@testable import Core

struct AnchorJSONTests {
    @Test func textAnchorMatchesTheDocShape() throws {
        let anchor = Anchor.text(TextAnchor(
            start: TextPosition(line: 40, col: 1), end: TextPosition(line: 52, col: 8),
            text: "## Auth flow", before: "a\nb", after: "c", hash: "abc"
        ))
        #expect(try anchor.encodedJSON() == ###"{"after":"c","before":"a\nb","end":{"col":8,"line":52},"hash":"abc","start":{"col":1,"line":40},"text":"## Auth flow"}"###)
        #expect(anchor.type == .text)
    }

    @Test func imageAnchorMatchesTheDocShape() throws {
        let anchor = Anchor.image(ImageAnchor(x: 1204, y: 312, w: 640, h: 220, imageW: 2880, imageH: 1800))
        #expect(try anchor.encodedJSON() == #"{"h":220,"imageH":1800,"imageW":2880,"w":640,"x":1204,"y":312}"#)
    }

    @Test func pdfAnchorMatchesTheDocShape() throws {
        let anchor = Anchor.pdf(PDFAnchor(page: 2, bounds: PDFBounds(x: 10, y: 20, w: 30, h: 40), text: "hello", pageCount: 9))
        #expect(try anchor.encodedJSON() == #"{"bounds":{"h":40,"w":30,"x":10,"y":20},"page":2,"pageCount":9,"text":"hello"}"#)
    }

    @Test func elementAnchorMatchesTheDocShape() throws {
        let anchor = Anchor.element(ElementAnchor(
            selector: "#toolbar > button:nth-of-type(2)", tag: "BUTTON", text: "  Save\n  now ", html: "<button class=\"primary\">Save</button>",
            rect: ElementRect(x: 120, y: 480, w: 96, h: 32), line: 42, hash: "h"
        ))
        #expect(try anchor.encodedJSON() == ###"{"hash":"h","html":"<button class=\"primary\">Save</button>","line":42,"rect":{"h":32,"w":96,"x":120,"y":480},"selector":"#toolbar > button:nth-of-type(2)","tag":"button","text":"Save now"}"###)
        #expect(anchor.type == .element)
        #expect(anchor.summary == "Element button:nth-of-type(2)")
        #expect(Anchor.element(ElementAnchor(selector: "#save", tag: "a", text: "", html: "", rect: .init(x: 0, y: 0, w: 1, h: 1))).summary == "Element #save")
        #expect(anchor.sortKey == Anchor.SortKey(primary: 480, secondary: 120))
    }

    @Test func elementAnchorCapsTextAndHTML() {
        let anchor = ElementAnchor(selector: "p", tag: "p", text: String(repeating: "a ", count: 600), html: String(repeating: "<i>", count: 2000), rect: .init(x: 0, y: 0, w: 0, h: 0))
        #expect(anchor.text.count == ElementAnchor.textLimit)
        #expect(anchor.text.hasSuffix("…"))
        #expect(anchor.html.count == ElementAnchor.htmlLimit)
        #expect(anchor.html.hasSuffix("…"))
    }

    @Test func wholeFileIsEmptyObject() throws {
        #expect(try Anchor.wholeFile.encodedJSON() == "{}")
        #expect(try Anchor(type: .file, json: "{}") == .wholeFile)
    }

    @Test func decodesRowsWrittenWithoutHash() throws {
        let anchor = try Anchor(type: .text, json: #"{"start":{"line":1,"col":1},"end":{"line":1,"col":5},"text":"abcd","before":"","after":""}"#)
        guard case .text(let text) = anchor else { Issue.record("expected text"); return }
        #expect(text.hash == nil)
        #expect(text.text == "abcd")
        let image = try Anchor(type: .image, json: #"{"x":1,"y":2,"w":3,"h":4,"imageW":5,"imageH":6}"#)
        guard case .image(let imageAnchor) = image else { Issue.record("expected image"); return }
        #expect(imageAnchor.hash == nil)
    }

    @Test func roundTripsThroughCodable() throws {
        let anchors: [Anchor] = [
            .text(TextAnchor(start: .init(line: 1, col: 1), end: .init(line: 2, col: 3), text: "x\ny", before: "", after: "z")),
            .image(ImageAnchor(x: 0, y: 0, w: 1, h: 1, imageW: 2, imageH: 2, hash: "h")),
            .pdf(PDFAnchor(page: 0, bounds: nil, text: nil, pageCount: 1)),
            .wholeFile,
            .element(ElementAnchor(selector: "main > p:nth-of-type(3)", tag: "p", text: "Hi", html: "<p>Hi</p>", rect: .init(x: 1.5, y: 2, w: 3, h: 4))),
        ]
        let data = try JSONEncoder().encode(anchors)
        #expect(try JSONDecoder().decode([Anchor].self, from: data) == anchors)
    }

    @Test func summariesAndSortKeys() {
        #expect(Anchor.text(TextAnchor(start: .init(line: 3, col: 1), end: .init(line: 3, col: 9), text: "", before: "", after: "")).summary == "Line 3")
        #expect(Anchor.text(TextAnchor(start: .init(line: 3, col: 1), end: .init(line: 5, col: 9), text: "", before: "", after: "")).summary == "Lines 3-5")
        #expect(Anchor.pdf(PDFAnchor(page: 2, bounds: nil, text: nil, pageCount: 3)).summary == "Page 3")
        #expect(Anchor.wholeFile.summary == "Whole file")
        #expect(Anchor.wholeFile.sortKey > Anchor.text(TextAnchor(start: .init(line: 999, col: 1), end: .init(line: 999, col: 1), text: "", before: "", after: "")).sortKey)
    }
}
