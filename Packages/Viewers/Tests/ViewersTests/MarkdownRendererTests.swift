import Core
import Foundation
import Testing
@testable import Viewers

struct MarkdownRendererTests {
    func renderedSubstring(_ output: MarkdownRenderer.Output, _ range: NSRange) -> String {
        (output.text.string as NSString).substring(with: range)
    }

    @Test func exactRunsMirrorTheirSource() {
        let source = """
        # Title

        Plain *emphasis* and **strong** with `code` and a [link](https://x.y).

        - item one
        - item two

        1. first
        2. second

        > quoted line

        ```swift
        let x = 1
        let y = 2
        ```

        | a | b |
        | - | - |
        | 1 | 2 |
        """
        let output = MarkdownRenderer.render(source)
        let sourceNS = source as NSString
        #expect(!output.map.spans.isEmpty)
        for span in output.map.spans where span.exact {
            #expect(renderedSubstring(output, span.rendered) == sourceNS.substring(with: span.source), "span \(span)")
        }
        // Every piece of source text appears in the rendered output.
        for needle in ["Title", "emphasis", "strong", "code", "link", "item one", "second", "quoted line", "let y = 2"] {
            #expect(output.text.string.contains(needle), "missing \(needle)")
        }
        #expect(output.text.string.contains("1. first"))
        #expect(output.text.string.contains("•  item two"))
    }

    @Test func selectionInsideEmphasisMapsToInnerColumns() {
        let source = "Say *hello world* now"
        let output = MarkdownRenderer.render(source)
        let rendered = (output.text.string as NSString).range(of: "lo wor")
        let mapping = output.map.sourceRange(forRendered: rendered)!
        #expect(mapping.exact)
        #expect((source as NSString).substring(with: mapping.source) == "lo wor")
    }

    @Test func entitiesFallBackToTheRun() {
        let source = "Fish &amp; chips"
        let output = MarkdownRenderer.render(source)
        #expect(output.text.string == "Fish & chips")
        let rendered = (output.text.string as NSString).range(of: "& ch")
        let mapping = output.map.sourceRange(forRendered: rendered)!
        #expect(!mapping.exact)
        #expect((source as NSString).substring(with: mapping.source) == "Fish &amp; chips")
    }

    @Test func multiByteColumnsMapCorrectly() {
        let source = "日本語 *強調* 😀 end"
        let output = MarkdownRenderer.render(source)
        let rendered = (output.text.string as NSString).range(of: "強調")
        let mapping = output.map.sourceRange(forRendered: rendered)!
        #expect(mapping.exact)
        #expect((source as NSString).substring(with: mapping.source) == "強調")
        let endRendered = (output.text.string as NSString).range(of: "end")
        let endMapping = output.map.sourceRange(forRendered: endRendered)!
        #expect((source as NSString).substring(with: endMapping.source) == "end")
    }

    @Test func sourceRangesProjectOntoRenderedText() {
        let source = "# Head\n\nOne two three.\n"
        let output = MarkdownRenderer.render(source)
        let two = (source as NSString).range(of: "two")
        let ranges = output.map.renderedRanges(forSource: two)
        #expect(ranges.count == 1)
        #expect(renderedSubstring(output, ranges[0]) == "two")
        // A whole-line source range (the heading including its marker) projects onto the heading text.
        let headingLine = NSRange(location: 0, length: 6)
        let heading = output.map.renderedRanges(forSource: headingLine)
        #expect(heading.map { renderedSubstring(output, $0) } == ["Head"])
    }

    @Test func codeBlockLinesAreLinePrecise() {
        let source = "```swift\nlet a = 1\nlet b = 2\n```\n"
        let output = MarkdownRenderer.render(source)
        let b = (output.text.string as NSString).range(of: "let b = 2")
        let mapping = output.map.sourceRange(forRendered: b)!
        #expect(mapping.exact)
        #expect((source as NSString).substring(with: mapping.source) == "let b = 2")
        let index = LineIndex(source)
        #expect(index.position(forUTF16Offset: mapping.source.location).line == 3)
    }

    @Test func selectionAcrossGeneratedTextWidensToBlocks() {
        let source = "- one\n- two\n"
        let output = MarkdownRenderer.render(source)
        let whole = NSRange(location: 0, length: output.text.length)
        let mapping = output.map.sourceRange(forRendered: whole)!
        #expect(!mapping.exact)
        #expect(mapping.source.location == 2 || mapping.source.location == 0)
        #expect(mapping.source.location + mapping.source.length >= (source as NSString).range(of: "two").location + 3)
    }

    @Test func viewerControllerMapsRenderedSelection() {
        let controller = TextEditorController(text: "Hello *big* world\n")
        let markdown = MarkdownViewerController(source: controller)
        markdown.renderedSelection = (markdown.rendered.string as NSString).range(of: "big")
        let mapping = markdown.renderedSelectionMapping!
        #expect(mapping.exact)
        #expect(("Hello *big* world\n" as NSString).substring(with: mapping.source) == "big")
        controller.highlights = [TextHighlight(id: NoteID.new(), range: mapping.source, color: .blue, state: .draft)]
        #expect(markdown.renderedHighlights().first?.range == markdown.renderedSelection)
    }
}
