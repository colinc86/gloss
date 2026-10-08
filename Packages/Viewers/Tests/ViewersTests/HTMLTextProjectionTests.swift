import Core
import Foundation
import Testing
@testable import Viewers

/// HTML source → page text, and page selections back to source ranges.
struct HTMLTextProjectionTests {
    static let page = """
    <!DOCTYPE html>
    <html><head><title>Trail &amp; Notes</title>
    <style>p { color: red; }</style></head>
    <body>
    <!-- a comment with <b>tags</b> -->
    <h1 class="big">Ridge <em>loop</em></h1>
    <p title="a > b">Fish &amp; chips &#38; peas &#x2014; done</p>
    <script>if (a < b) { x = "<p>"; }</script>
    </body></html>
    """

    private func sourceText(_ projection: HTMLTextProjection, _ needle: String) -> String? {
        let range = (projection.text as NSString).range(of: needle)
        guard range.location != NSNotFound, let source = projection.sourceRange(forProjected: range) else { return nil }
        return (Self.page as NSString).substring(with: source)
    }

    @Test func tagsCommentsAndDoctypeProduceNoText() {
        let projection = HTMLTextProjection(Self.page)
        #expect(!projection.text.contains("DOCTYPE") && !projection.text.contains("comment") && !projection.text.contains("class="))
        #expect(projection.text.contains("Ridge loop"), "inline tags vanish between words")
        #expect(!projection.text.contains("a > b"), "a > inside a quoted attribute does not end the tag")
    }

    @Test func entitiesDecodeAndMapBackToTheirSource() {
        let projection = HTMLTextProjection(Self.page)
        #expect(projection.text.contains("Fish & chips & peas — done"))
        #expect(sourceText(projection, "Fish & chips") == "Fish &amp; chips")
        #expect(sourceText(projection, "peas — done") == "peas &#x2014; done")
        #expect(sourceText(projection, "loop") == "loop")
        #expect(sourceText(projection, "Ridge loop") == "Ridge <em>loop", "a span across a tag covers the tag in source")
    }

    @Test func rawTextElementsKeepTheirContent() {
        let projection = HTMLTextProjection(Self.page)
        #expect(projection.text.contains("p { color: red; }"), "style text is text, as in textContent")
        #expect(projection.text.contains("if (a < b) { x = \"<p>\"; }"), "a < in a script is not a tag")
        #expect(projection.text.contains("Trail & Notes"), "title decodes entities")
    }

    @Test func sourceRangesProjectBack() throws {
        let projection = HTMLTextProjection(Self.page)
        let chips = (Self.page as NSString).range(of: "chips")
        let projected = try #require(projection.projectedRange(forSource: chips))
        #expect((projection.text as NSString).substring(with: projected) == "chips")
        let line = (Self.page as NSString).range(of: "<p title=\"a > b\">Fish &amp; chips &#38; peas &#x2014; done</p>")
        let whole = try #require(projection.projectedRange(forSource: line))
        #expect((projection.text as NSString).substring(with: whole) == "Fish & chips & peas — done", "a whole source line maps to its text")
    }

    /// A note whose text was removed keeps length 0 all the way to the DOM, so the page draws a caret, not a letter.
    @Test func aPointStaysAPoint() throws {
        let source = "<p>Fish &amp; chips</p>"
        let projection = HTMLTextProjection(source)
        let chips = (source as NSString).range(of: "chips")
        let point = try #require(projection.projectedRange(forSource: NSRange(location: chips.location, length: 0)))
        #expect(point.length == 0)
        #expect((projection.text as NSString).substring(from: point.location) == "chips")
        let alignment = projection.alignment(withDOM: projection.text)
        #expect(alignment.dom(point) == NSRange(location: point.location, length: 0))
        let end = try #require(projection.projectedRange(forSource: NSRange(location: chips.location + chips.length, length: 0)))
        #expect(alignment.dom(end) == NSRange(location: (projection.text as NSString).length, length: 0), "after the last character")
    }

    @Test func crlfCountsAsOneNewline() {
        let projection = HTMLTextProjection("<p>a\r\nb</p>")
        #expect(projection.text == "a\nb")
        #expect(projection.sourceRange(forProjected: NSRange(location: 0, length: 3)) == NSRange(location: 3, length: 4))
    }

    @Test func alignmentSkipsWhitespaceTheBrowserDropped() throws {
        let projection = HTMLTextProjection("\n\n<html><body><p>one</p>\n<p>two</p></body></html>\n")
        // The parser drops the whitespace before <html>; the DOM text starts at "one".
        let dom = "one\ntwo\n"
        let alignment = projection.alignment(withDOM: dom)
        let two = try #require(alignment.projected(NSRange(location: 4, length: 3)))
        #expect((projection.text as NSString).substring(with: two) == "two")
        let back = try #require(alignment.dom(two))
        #expect(back == NSRange(location: 4, length: 3))
    }

    @Test func viewerControllerMapsAPageSelectionToSource() throws {
        let source = TextEditorController(text: Self.page)
        let html = HTMLViewerController(source: source, documentPath: "/p/page.html") { _ in Data() }
        let projection = html.projection
        html.alignment = projection.alignment(withDOM: projection.text)
        let dom = (projection.text as NSString).range(of: "chips & peas")
        html.selection = HTMLSelection(dom: dom, text: "chips & peas", rect: nil)
        let mapping = try #require(html.renderedSelectionMapping)
        #expect((Self.page as NSString).substring(with: mapping.source) == "chips &#38; peas")
        #expect(!mapping.exact, "an entity inside makes it inexact")
        #expect(HTMLViewerController.handles(path: "/x/INDEX.HTM") && !HTMLViewerController.handles(path: "/x/a.md"))
    }

    private func mapped(_ source: String, select needle: String, dom: String? = nil) -> String? {
        let controller = HTMLViewerController(source: TextEditorController(text: source), documentPath: "/p/a.html") { _ in Data() }
        let domText = dom ?? controller.projection.text
        controller.alignment = controller.projection.alignment(withDOM: domText)
        let range = (domText as NSString).range(of: needle)
        controller.selection = HTMLSelection(dom: range, text: needle, rect: nil)
        return controller.renderedSelectionMapping.map { (source as NSString).substring(with: $0.source) }
    }

    @Test func latinAndLegacyEntitiesDecode() {
        #expect(HTMLTextProjection("<p>Caf&eacute; &Ntilde; &amp b &copy 2024</p>").text == "Café Ñ & b © 2024")
        #expect(mapped("<p>Caf&eacute; menu: the soup is hot and the tea is cold.</p>", select: "tea is cold") == "tea is cold")
        #expect(mapped("<p>a &amp b and later words</p>", select: "later words") == "later words")
    }

    @Test func unknownEntitiesDoNotShiftLaterText() {
        // The DOM decodes &bigstar; but the scan keeps it literally; later text must still map to itself.
        let source = "<p>Rated &bigstar; by readers, the tea is cold and the soup is hot.</p>"
        #expect(mapped(source, select: "the soup is hot", dom: "Rated ★ by readers, the tea is cold and the soup is hot.") == "the soup is hot")
    }

    @Test func customElementsCommentsAndUnquotedApostrophes() {
        #expect(mapped("<title-bar><b>Hi</b></title-bar><p>after text</p>", select: "after text") == "after text")
        #expect(HTMLTextProjection("<title-bar><b>Hi</b></title-bar>").text == "Hi", "a custom element is not <title>")
        #expect(mapped("<a title=it's>link</a> and more text", select: "more") == "more")
        #expect(mapped("<!--><p>one</p><!---><p>two words</p>", select: "two words") == "two words")
    }

    @Test func pagesReadOnlyInsideTheirRootAndNeverHiddenPaths() {
        #expect(HTMLViewerController.allowsResource("/proj/web/style.css", root: "/proj", local: false))
        #expect(HTMLViewerController.allowsResource("/proj/web/../images/a.png", root: "/proj", local: false))
        #expect(!HTMLViewerController.allowsResource("/proj/../etc/passwd", root: "/proj", local: false), "no escaping the root with ..")
        #expect(!HTMLViewerController.allowsResource("/Users/me/.ssh/id_ed25519", root: "/Users/me", local: false))
        #expect(!HTMLViewerController.allowsResource("/proj/.env", root: "/proj", local: false))
        #expect(!HTMLViewerController.allowsResource("/project-two/a.css", root: "/proj", local: false), "a shared prefix is not inside")
        #expect(HTMLViewerController(source: TextEditorController(text: ""), documentPath: "/p/web/a.html") { _ in Data() }.resourceRoot == "/p/web", "without a root, the document's folder")
    }
}
