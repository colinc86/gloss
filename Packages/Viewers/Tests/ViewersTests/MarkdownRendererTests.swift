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
        let source = "<table>\n<tr><td>hi</td></tr>\n</table>\n"
        let output = MarkdownRenderer.render(source)
        let mapping = output.map.sourceRange(forRendered: (output.text.string as NSString).range(of: "<tr><td>hi</td></tr>"))!
        #expect(mapping.exact && (source as NSString).substring(with: mapping.source) == "<tr><td>hi</td></tr>")
    }

    private func font(_ output: MarkdownRenderer.Output, at needle: String) -> NSFont? {
        let location = (output.text.string as NSString).range(of: needle).location
        return output.text.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func isBold(_ font: NSFont?) -> Bool {
        font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
    }

    @Test func aReadmeHeaderDrawsCenteredWithItsPicture() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gloss-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "docs/media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: folder.appending(path: "docs/media/icon.png"))
        let source = """
        <p align="center">
          <img src="docs/media/icon.png" width="128" height="128" alt="App icon">
        </p>

        <h1 align="center">Gloss</h1>

        <p align="center">
          <b>Mark up any file. Hand the notes on.</b><br>
          <a href="https://example.com/releases"><img alt="Latest release" src="https://img.example.com/release.svg"></a>
          <img alt="macOS 26" src="https://img.example.com/macos.svg">
        </p>

        Body text.
        """
        let output = MarkdownRenderer.render(source, baseURL: folder)
        let text = output.text.string as NSString
        #expect(!text.contains("<p") && !text.contains("<b>") && !text.contains("align"), "\(text)")
        let location = text.range(of: "\u{FFFC}").location
        let attachment = try #require(output.text.attribute(.attachment, at: location, effectiveRange: nil) as? FittedImageAttachment)
        #expect(attachment.source == "docs/media/icon.png" && attachment.naturalSize == CGSize(width: 128, height: 128))
        #expect((output.text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .center)
        let mapping = try #require(output.map.sourceRange(forRendered: NSRange(location: location, length: 1)))
        #expect((source as NSString).substring(with: mapping.source) == "<img src=\"docs/media/icon.png\" width=\"128\" height=\"128\" alt=\"App icon\">")
        #expect(font(output, at: "Gloss") == MarkdownRenderer.headingFont(level: 1))
        #expect(paragraph(output, at: "Gloss")?.alignment == .center && decoration(output, at: "Gloss")?.kind == .heading(level: 1))
        #expect(isBold(font(output, at: "Mark up")))
        #expect(text.contains("Hand the notes on.\u{2028}"), "<br> breaks the line")
        #expect(text.contains("Latest release") && text.contains("macOS 26"), "remote badges show their alt text")
        let badge = text.range(of: "Latest release").location
        #expect(output.text.attribute(.link, at: badge, effectiveRange: nil) as? String == "https://example.com/releases")
        #expect(paragraph(output, at: "Body text")?.alignment == .natural, "alignment ends with its element")
    }

    @Test func detailsDrawTheirSummaryAndStayOpen() {
        let source = "<details>\n<summary>More options</summary>\n\nHidden **text**.\n\n</details>\n"
        let output = MarkdownRenderer.render(source)
        let text = output.text.string
        #expect(text.contains("▾ More options") && text.contains("Hidden text."), "\(text)")
        #expect(isBold(font(output, at: "More options")))
        #expect(!text.contains("details") && !text.contains("summary"))
    }

    @Test func htmlWithOtherTagsStaysSource() {
        let output = MarkdownRenderer.render("<table>\n<tr><td><b>x</b></td></tr>\n</table>\n")
        #expect(output.text.string.contains("<tr><td><b>x</b></td></tr>"))
        #expect(decoration(output, at: "<tr>")?.kind == .codeBlock)
    }

    @Test func textInsideHTMLMapsToItsSource() {
        for source in ["<p align=\"center\">\n  <b>Mark up any file.</b> Fish &amp; chips\n</p>\n",
                       "> <div align=\"center\">\n>   <b>Mark up any file.</b> Fish &amp; chips\n> </div>\n"] {
            let output = MarkdownRenderer.render(source)
            let text = output.text.string as NSString
            #expect(text.contains("Mark up any file. Fish & chips"), "\(text)")
            let words = output.map.sourceRange(forRendered: text.range(of: "any file"))!
            #expect(words.exact && (source as NSString).substring(with: words.source) == "any file", "in \(source)")
            let ampersand = output.map.sourceRange(forRendered: text.range(of: "&"))!
            #expect(!ampersand.exact && (source as NSString).substring(with: ampersand.source) == "&amp;")
            for span in output.map.spans where span.exact {
                #expect((text.substring(with: span.rendered)) == (source as NSString).substring(with: span.source))
            }
        }
    }

    @Test func generatedHTMLTextNeverMaps() {
        let source = "<p>one<br>two</p>\n\n<details><summary>Sum</summary></details>\n\nInline <b>bold</b><br>next\n"
        let output = MarkdownRenderer.render(source)
        let text = output.text.string as NSString
        #expect(text.contains("one\u{2028}two") && text.contains("▾ Sum") && text.contains("bold\u{2028}next"), "\(text)")
        for span in output.map.spans {
            let rendered = text.substring(with: span.rendered)
            #expect(!rendered.contains("\u{2028}") && !rendered.contains("▾"), "span \(span) covers generated text")
        }
    }

    @Test func manyInlineTagsRenderQuickly() {
        let clock = ContinuousClock()
        let pairs = String(repeating: "<b>x</b> ", count: 2000)
        let unclosed = String(repeating: "<b>x ", count: 500)
        let block = "<div>\n" + (0..<8000).map { "word \($0)" }.joined(separator: "\n") + "\n</div>\n"
        for source in [pairs, unclosed, block] {
            let elapsed = clock.measure { _ = MarkdownRenderer.render(source) }
            #expect(elapsed < .seconds(1), "\(source.prefix(12))… took \(elapsed)")
        }
    }

    @Test func misnestedInlineTagsLeaveNoSource() {
        let output = MarkdownRenderer.render("<i><b>x</i></b> after\n")
        let text = output.text.string
        #expect(!text.contains("<") && text.contains("x after"), "\(text)")
        #expect(!isBold(font(output, at: "after")))
    }

    @Test func sizesFromHTMLStayFinite() {
        #expect(MarkdownHTML.pixels("inf") == nil && MarkdownHTML.pixels("1e400") == nil && MarkdownHTML.pixels("nan") == nil)
        #expect(MarkdownHTML.pixels("20000") == 10_000 && MarkdownHTML.pixels("128px") == 128 && MarkdownHTML.pixels("50%") == nil)
        let output = MarkdownRenderer.render("<img src=\"z.png\" width=\"50\">\n\n<img src=\"z.png\" height=\"1e400\">\n", images: ["z.png": NSImage(size: .zero)])
        output.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.text.length)) { value, _, _ in
            guard let attachment = value as? FittedImageAttachment else { return }
            #expect(attachment.naturalSize.width.isFinite && attachment.naturalSize.height.isFinite, "\(attachment.naturalSize)")
        }
    }

    @Test func inlineHTMLStylesMatchedTagsAndShowsTheRest() {
        let output = MarkdownRenderer.render("Some <b>bold</b>, <kbd>K</kbd>, <em>open and <code>x()</code>\n")
        let text = output.text.string
        #expect(isBold(font(output, at: "bold")) && !text.contains("<b>"))
        #expect(text.contains("<kbd>") && text.contains("</kbd>"), "unknown tags stay source")
        #expect(text.contains("<em>"), "a tag without its end stays source")
        #expect(!text.contains("<code>") && font(output, at: "x()")?.isFixedPitch == true)
        #expect(!isBold(font(output, at: ", ")), "bold ends at its end tag")
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
