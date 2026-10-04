import AppKit
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
        #expect(output.text.string.contains("1.\tfirst"))
        #expect(output.text.string.contains("•\titem two"))
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

    // MARK: Layout

    private func decoration(_ output: MarkdownRenderer.Output, at needle: String) -> MarkdownBlockDecoration? {
        let location = (output.text.string as NSString).range(of: needle).location
        return output.text.attribute(MarkdownRenderer.blockKey, at: location, effectiveRange: nil) as? MarkdownBlockDecoration
    }

    private func paragraph(_ output: MarkdownRenderer.Output, at needle: String) -> NSParagraphStyle? {
        let location = (output.text.string as NSString).range(of: needle).location
        return output.text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
    }

    @Test func fencedCodeIsOneColouredParagraphWithExactLines() {
        let source = "Intro\n\n```swift\nlet a = \"x\"\nfunc f() {}\n```\n"
        let output = MarkdownRenderer.render(source)
        let text = output.text.string as NSString
        #expect(text.contains("let a = \"x\"\u{2028}func f() {}"), "code lines share one paragraph")
        #expect(decoration(output, at: "func f")?.kind == .codeBlock)
        let keyword = text.range(of: "let")
        let color = output.text.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor
        #expect(color == SyntaxTheme.color(forCapture: "keyword"), "fenced swift is syntax-coloured")
        let f = output.map.sourceRange(forRendered: text.range(of: "func f() {}"))!
        #expect(f.exact && (source as NSString).substring(with: f.source) == "func f() {}")
        #expect(RenderedTextView.plainText(output.text.string).contains("let a = \"x\"\nfunc f() {}"), "copy turns separators into newlines")
    }

    @Test func fenceInfoStringsMapToGrammars() {
        #expect(MarkdownRenderer.grammarName(forFence: "swift") == "swift")
        #expect(MarkdownRenderer.grammarName(forFence: "sh") == "bash")
        #expect(MarkdownRenderer.grammarName(forFence: "shell") == "bash")
        #expect(MarkdownRenderer.grammarName(forFence: "TS") == "typescript")
        #expect(MarkdownRenderer.grammarName(forFence: "py {.numberLines}") == "python")
        #expect(MarkdownRenderer.grammarName(forFence: "brainfuck") == nil)
        #expect(MarkdownRenderer.grammarName(forFence: nil) == nil)
    }

    @Test func listItemsHangTheirMarker() {
        let output = MarkdownRenderer.render("- a long item\n  - nested\n")
        let outer = paragraph(output, at: "a long item")!
        #expect(outer.firstLineHeadIndent == 0 && outer.headIndent == 20, "wrapped lines align with the text, not the bullet")
        #expect(outer.tabStops.first?.location == 20)
        let nested = paragraph(output, at: "nested")!
        #expect(nested.firstLineHeadIndent == 20 && nested.headIndent == 40)
        #expect(output.text.string.contains("◦\tnested"), "nested bullets differ")
        #expect(nested.paragraphSpacingBefore == 4, "tight lists stay tight")
    }

    @Test func aRightAlignedFirstColumnStillTabsToItsStop() {
        let output = MarkdownRenderer.render("| n | name |\n| --: | :-- |\n| 12 | alpha |\n")
        #expect(output.text.string.contains("\t12\talpha"))
        #expect(paragraph(output, at: "alpha")?.firstLineHeadIndent == 0)
    }

    @Test func tableCellsAreExactAndAlignedByTabStops() {
        let source = "| name | n |\n| :-- | --: |\n| alpha | 1 |\n| b | 200 |\n"
        let output = MarkdownRenderer.render(source)
        // A left-aligned first column starts at the row's first-line indent: a leading tab drew a sliver in TextKit.
        #expect(output.text.string.contains("\nalpha\t1"))
        #expect(paragraph(output, at: "alpha")?.firstLineHeadIndent == MarkdownRenderer.tableCellPadding)
        for needle in ["alpha", "200"] {
            let mapping = output.map.sourceRange(forRendered: (output.text.string as NSString).range(of: needle))!
            #expect(mapping.exact && (source as NSString).substring(with: mapping.source) == needle)
        }
        let row = paragraph(output, at: "alpha")!
        #expect(row.tabStops.count == 2)
        #expect(row.tabStops.last?.alignment == .right, "column alignment carries over")
        guard case .tableRow(let header, let width)? = decoration(output, at: "name")?.kind else { Issue.record("no header decoration"); return }
        #expect(header && width > 0)
        guard case .tableRow(false, _)? = decoration(output, at: "alpha")?.kind else { Issue.record("no row decoration"); return }
    }

    @Test func quotesRulesAndHeadingsCarryDecorations() {
        let output = MarkdownRenderer.render("# Title\n\n> one\n>\n> two\n\n---\n\nafter\n")
        #expect(decoration(output, at: "Title")?.kind == .heading(level: 1))
        let one = decoration(output, at: "one")!
        let two = decoration(output, at: "two")!
        #expect(one.quoteBars.count == 1 && !one.quoteBars[0].continuesFromAbove)
        #expect(two.quoteBars.count == 1 && two.quoteBars[0].continuesFromAbove, "the bar joins paragraphs of one quote")
        #expect(output.text.string.contains("\u{00A0}") && !output.text.string.contains("───"), "rules are drawn, not typed")
        #expect(decoration(output, at: "after")?.quoteBars.isEmpty == true)
        #expect(paragraph(output, at: "Title")?.paragraphSpacingBefore == 0, "no gap above the first block")
        #expect((paragraph(output, at: "after")?.paragraphSpacingBefore ?? 0) > 0)
    }

    @Test func generatedTextNeverMapsToSource() {
        let source = "- [ ] task\n- [x] done\n\n1. one\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n```\nx\ny\n```\n\n![alt](missing.png)\n"
        let output = MarkdownRenderer.render(source, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        let text = output.text.string as NSString
        for span in output.map.spans {
            let rendered = text.substring(with: span.rendered)
            #expect(!rendered.contains("\t") && !rendered.contains("\u{2028}") && !rendered.contains("☐"), "span \(span) covers generated text")
        }
        #expect(text.contains("☐\ttask") && text.contains("☑\tdone"))
        let alt = output.map.sourceRange(forRendered: text.range(of: "alt"))!
        #expect((source as NSString).substring(with: alt.source) == "![alt](missing.png)", "a missing image maps to its markdown")
    }

    @Test func localImagesBecomeAttachments() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gloss-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: folder.appending(path: "pic one.png"))
        let source = "Look: ![red](pic%20one.png)\n"
        let local = MarkdownRenderer.render(source, baseURL: folder)
        let location = (local.text.string as NSString).range(of: "\u{FFFC}").location
        let attachment = local.text.attribute(.attachment, at: location, effectiveRange: nil) as? FittedImageAttachment
        #expect(attachment?.naturalSize == CGSize(width: 40, height: 20))
        #expect(FittedImageAttachment.fitted(CGSize(width: 800, height: 400), width: 400).size == CGSize(width: 400, height: 200), "shrinks to the pane")
        #expect(FittedImageAttachment.fitted(CGSize(width: 40, height: 20), width: 400).size == CGSize(width: 40, height: 20), "never enlarges")
        #expect(FittedImageAttachment.fitted(CGSize(width: 1600, height: 1600), width: 760).size == CGSize(width: 480, height: 480), "tall images cap their height")
        let mapping = local.map.sourceRange(forRendered: NSRange(location: location, length: 1))!
        #expect((source as NSString).substring(with: mapping.source) == "![red](pic%20one.png)")
        let remote = MarkdownRenderer.render(source)
        #expect(remote.text.string.contains("red"), "without a base URL the alt text stands in")
    }

    @Test func codeInsideContainersMapsToItsOwnLines() {
        for source in ["> ```\n> code line\n> last\n> ```\n", "- ```swift\n  code line\n  last\n  ```\n"] {
            let output = MarkdownRenderer.render(source)
            let text = output.text.string as NSString
            for needle in ["code line", "last"] {
                let mapping = output.map.sourceRange(forRendered: text.range(of: needle))!
                #expect(mapping.exact && (source as NSString).substring(with: mapping.source) == needle, "\(needle) in \(source)")
            }
            #expect(decoration(output, at: "code line")?.kind == .codeBlock, "the code keeps its fill in \(source)")
        }
    }

    @Test func multiLineHTMLStaysLinePrecise() {
        let source = "<div>\n<p>hi</p>\n</div>\n"
        let output = MarkdownRenderer.render(source)
        let mapping = output.map.sourceRange(forRendered: (output.text.string as NSString).range(of: "<p>hi</p>"))!
        #expect(mapping.exact && (source as NSString).substring(with: mapping.source) == "<p>hi</p>")
    }

    @Test func listItemsOpeningWithNestedListsKeepBothMarkers() {
        let output = MarkdownRenderer.render("- - a\n- b\n-\n")
        let text = output.text.string
        #expect(text.contains("•\t◦\ta"))
        #expect(text.contains("•\tb"))
        #expect(text.hasSuffix("•\t"), "an empty item still shows its marker")
    }

    @Test func tablesTooWideForAlignedColumnsFlowInstead() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        let output = MarkdownRenderer.render("| a | b |\n| - | - |\n| \(long) | x |\n")
        #expect(paragraph(output, at: "word")?.tabStops.isEmpty == true, "no stops that a wrapped cell would overprint")
        let narrow = MarkdownRenderer.render("| a | b |\n| - | - |\n| 1 | 2 |\n")
        #expect(paragraph(narrow, at: "1")?.tabStops.count == 2)
    }
}

struct ReadingSummaryTests {
    @Test func countsWordsAndRoundsReadingTime() {
        #expect(MarkdownViewerController.readingSummary(for: "One word") == "2 words · 1 min read")
        #expect(MarkdownViewerController.readingSummary(for: "solo") == "1 word · 1 min read")
        let long = Array(repeating: "word", count: 700).joined(separator: " ")
        #expect(MarkdownViewerController.readingSummary(for: long) == "700 words · 3 min read")
    }
}
