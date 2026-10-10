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

    /// A note whose text was removed maps to one rendered point: exact inside text, the start of an inexact run,
    /// and between blocks the end of the run before; never a whole run or block.
    @Test func aSourcePointMapsToARenderedPoint() {
        let source = "# Head\n\nOne two three.\n"
        let output = MarkdownRenderer.render(source)
        let two = (source as NSString).range(of: "two")
        let inText = output.map.renderedRanges(forSource: NSRange(location: two.location, length: 0))
        #expect(inText.count == 1 && inText[0].length == 0)
        #expect((output.text.string as NSString).substring(from: inText[0].location).hasPrefix("two"))
        let betweenBlocks = output.map.renderedRanges(forSource: NSRange(location: 7, length: 0))
        #expect(betweenBlocks.count == 1 && betweenBlocks[0].length == 0)
        let map = RenderedSourceMap(spans: [SourceSpan(rendered: NSRange(location: 10, length: 4), source: NSRange(location: 20, length: 9), exact: false)], blocks: [])
        #expect(map.renderedRanges(forSource: NSRange(location: 24, length: 0)) == [NSRange(location: 10, length: 0)], "an inexact run's start")
        #expect(map.renderedRanges(forSource: NSRange(location: 29, length: 0)) == [NSRange(location: 14, length: 0)], "right after a run: its end")
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

    /// A render after an edit elsewhere reuses an unchanged code block's colours instead of parsing it again, with
    /// the same result; an edited block is parsed afresh.
    @Test func unchangedCodeBlocksKeepTheirColoursWithoutAParse() {
        let name = "token_\(UUID().uuidString.prefix(8).lowercased())"
        let code = "let \(name) = \"x\"\nfunc f() {}\n"
        let source = "Intro\n\n```swift\n\(code)```\n"
        func cached(_ code: String) -> [HighlightCapture]? {
            MarkdownRenderer.highlightCache.withLock { $0.captures(for: .init(grammar: "swift", code: code)) }
        }
        #expect(cached(code) == nil)
        let first = MarkdownRenderer.render(source)
        let stored = cached(code)
        #expect(stored?.isEmpty == false, "the block's captures are kept")
        #expect(stored == Highlighter(languageName: "swift", text: code)?.captures, "as a fresh parse finds them")

        let again = MarkdownRenderer.render(source + "\nMore text.\n")
        let range = (first.text.string as NSString).range(of: "func f() {}")
        func colours(_ output: MarkdownRenderer.Output) -> [NSColor?] {
            (0..<range.length).map { output.text.attribute(.foregroundColor, at: range.location + $0, effectiveRange: nil) as? NSColor }
        }
        #expect(colours(again) == colours(first), "the same colours from the cache")
        #expect(colours(first).contains(SyntaxTheme.color(forCapture: "keyword")))

        let edited = code.replacingOccurrences(of: "func f", with: "func g")
        _ = MarkdownRenderer.render(source.replacingOccurrences(of: code, with: edited))
        #expect(cached(edited)?.isEmpty == false, "an edited block is parsed and kept under its new text")
    }

    /// A GitHub alert: the `[!NOTE]` marker shows as a coloured title on its own line, the bar takes the alert's
    /// colour, and the text after it maps to its source as in any quote.
    @Test func gitHubAlertsShowTheirTitleAndColour() {
        let source = "> [!WARNING]\n> Back up first.\n"
        let output = MarkdownRenderer.render(source)
        let text = output.text.string as NSString
        #expect(!text.contains("[!WARNING]"))
        #expect(text.contains("Warning\u{2028}Back up first."), "\(text)")
        let title = text.range(of: "Warning")
        #expect(output.text.attribute(.foregroundColor, at: title.location, effectiveRange: nil) as? NSColor == .systemOrange)
        #expect(output.map.sourceRange(forRendered: title)?.exact != true, "the title is generated, not the marker's text")
        #expect(decoration(output, at: "Back up")?.quoteBars.first?.alert == .warning)
        let body = output.map.sourceRange(forRendered: text.range(of: "Back up first."))
        #expect(body.map { (source as NSString).substring(with: $0.source) } == "Back up first.")

        let alone = MarkdownRenderer.render("> [!tip]\n>\n> Second paragraph.\n")
        #expect((alone.text.string as NSString).contains("Tip"), "case aside, alone in its paragraph")
        #expect(decoration(alone, at: "Second")?.quoteBars.first?.alert == .tip)
        for plain in ["> [!FOO]\n> x\n", "> [!NOTE] extra\n> x\n", "> Note: [!NOTE]\n"] {
            let rendered = MarkdownRenderer.render(plain)
            #expect(rendered.text.string.contains("[!"), "not an alert: \(plain)")
            #expect(decoration(rendered, at: "[!")?.quoteBars.first?.alert == nil)
        }
    }

    /// Bare addresses link as GitHub links them: a URL, a www address over https, an e-mail; not in code, not a
    /// bare domain, and a written link keeps its own target.
    @Test func bareAddressesBecomeLinks() {
        func links(_ markdown: String) -> [String] {
            let output = MarkdownRenderer.render(markdown)
            var found: [String] = []
            output.text.enumerateAttribute(.link, in: NSRange(location: 0, length: output.text.length)) { value, range, _ in
                if let value { found.append((output.text.string as NSString).substring(with: range) + " → \(value)") }
            }
            return found
        }
        #expect(links("See https://example.com/a?b=1 now.") == ["https://example.com/a?b=1 → https://example.com/a?b=1"], "a trailing full stop stays out")
        #expect(links("Visit www.example.com today") == ["www.example.com → https://www.example.com"])
        #expect(links("Mail me@example.com") == ["me@example.com → mailto:me@example.com"])
        #expect(links("Docs at https://example.com/snake_case_path/x") == ["https://example.com/snake_case_path/x → https://example.com/snake_case_path/x"])
        #expect(links("Just example.com here").isEmpty, "a bare domain is not a link on GitHub either")
        #expect(links("Run `curl https://example.com` first").isEmpty, "code stays code")
        #expect(links("[the site](https://example.org) and more") == ["the site → https://example.org"])
        let output = MarkdownRenderer.render("See https://example.com now.")
        let url = (output.text.string as NSString).range(of: "https://example.com")
        #expect(output.map.sourceRange(forRendered: url).map { ("See https://example.com now." as NSString).substring(with: $0.source) } == "https://example.com",
                "the link maps to its source as the text did")
    }

    /// A ```diff block is coloured by line as GitHub colours it.
    @Test func diffBlocksAreColouredByLine() {
        let output = MarkdownRenderer.render("```diff\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same\n```\n")
        let text = output.text.string as NSString
        func color(_ needle: String) -> NSColor? {
            output.text.attribute(.foregroundColor, at: text.range(of: needle).location, effectiveRange: nil) as? NSColor
        }
        #expect(color("-old") == .systemRed && color("+new") == .systemGreen && color("@@") == .systemPurple)
        #expect(color("--- a/x") == .secondaryLabelColor && color("+++ b/x") == .secondaryLabelColor, "file headers are not a removal and an addition")
        #expect(color(" same") != .systemRed && color(" same") != .systemGreen)
        #expect(MarkdownRenderer.isDiff(fence: "patch") && !MarkdownRenderer.isDiff(fence: "swift"))
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
        let source = "<section>\n<article>hi</article>\n</section>\n"
        let output = MarkdownRenderer.render(source)
        let mapping = output.map.sourceRange(forRendered: (output.text.string as NSString).range(of: "<article>hi</article>"))!
        #expect(mapping.exact && (source as NSString).substring(with: mapping.source) == "<article>hi</article>")
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
        let output = MarkdownRenderer.render("<section>\n<article><b>x</b></article>\n</section>\n")
        #expect(output.text.string.contains("<article><b>x</b></article>"))
        #expect(decoration(output, at: "<article>")?.kind == .codeBlock)
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

    private func isHeaderRow(_ output: MarkdownRenderer.Output, at needle: String) -> Bool? {
        guard case .tableRow(let header, _)? = decoration(output, at: needle)?.kind else { return nil }
        return header
    }

    @Test func htmlTablesDrawAsMarkdownTables() {
        let source = """
        <table>
          <thead><tr><th>Name</th><th align="right">Size</th></tr></thead>
          <tbody>
            <tr><td>alpha <b>one</b></td><td align="right">12</td></tr>
            <tr><td>beta<td>3
          </tbody>
        </table>

        After.
        """
        let output = MarkdownRenderer.render(source)
        let text = output.text.string as NSString
        #expect(text.contains("Name\tSize\nalpha one\t12\nbeta\t3"), "\(text)")
        #expect(isHeaderRow(output, at: "Name") == true && isHeaderRow(output, at: "alpha") == false && isHeaderRow(output, at: "beta") == false)
        #expect(isBold(font(output, at: "Name")) && isBold(font(output, at: "one")) && !isBold(font(output, at: "alpha")))
        let stops = paragraph(output, at: "alpha")?.tabStops ?? []
        #expect(stops.count == 2 && stops.last?.alignment == .right, "the align attribute aligns its column")
        let mapping = output.map.sourceRange(forRendered: text.range(of: "alpha"))!
        #expect(mapping.exact && (source as NSString).substring(with: mapping.source) == "alpha")
        for span in output.map.spans {
            let rendered = text.substring(with: span.rendered)
            #expect(!rendered.contains("\t") && !rendered.contains("\n"), "span \(span) covers generated text")
        }
        #expect(decoration(output, at: "After")?.kind == .plain)
    }

    @Test func htmlListsQuotesRulesAndDefinitions() {
        let source = """
        <ul>
          <li>first</li>
          <li>second
            <ol start="3"><li>three</li><li>four</li></ol>
          </li>
          <li></li>
        </ul>
        <blockquote>quoted <i>words</i></blockquote>
        <hr>
        <dl><dt>Term</dt><dd>Meaning</dd></dl>
        """
        let output = MarkdownRenderer.render(source)
        let text = output.text.string
        for needle in ["•\tfirst", "•\tsecond", "3.\tthree", "4.\tfour", "\n•\t"] { #expect(text.contains(needle), "\(needle) in \(text)") }
        #expect((paragraph(output, at: "three")?.headIndent ?? 0) > (paragraph(output, at: "first")?.headIndent ?? 0))
        #expect(decoration(output, at: "quoted")?.quoteBars.count == 1 && decoration(output, at: "first")?.quoteBars.isEmpty == true)
        #expect(output.text.attribute(.foregroundColor, at: (text as NSString).range(of: "quoted").location, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        #expect(text.contains("\u{00A0}") && !text.contains("<hr"))
        #expect(isBold(font(output, at: "Term")) && paragraph(output, at: "Meaning")?.headIndent == 28)
        #expect(decoration(output, at: "Term")?.quoteBars.isEmpty == true, "the quote ends with its element")
        let mapping = output.map.sourceRange(forRendered: (text as NSString).range(of: "four"))!
        #expect(mapping.exact && (source as NSString).substring(with: mapping.source) == "four")
    }

    @Test func htmlPreKeepsItsLines() {
        let source = "<pre><code>let a = 1\n  indented &lt;x&gt;\n</code></pre>\n\nAfter.\n"
        let output = MarkdownRenderer.render(source)
        let text = output.text.string as NSString
        #expect(text.contains("let a = 1\u{2028}  indented <x>\n"), "\(text)")
        #expect(decoration(output, at: "let a")?.kind == .codeBlock && font(output, at: "let a")?.isFixedPitch == true)
        #expect(output.text.attribute(.backgroundColor, at: text.range(of: "let a").location, effectiveRange: nil) == nil, "no inline fill on the block's fill")
        let mapping = output.map.sourceRange(forRendered: text.range(of: "  indented"))!
        #expect(mapping.exact && (source as NSString).substring(with: mapping.source) == "  indented")
    }

    @Test func htmlInlineFormatting() {
        let source = "<p><kbd>K</kbd> x<sup>2</sup> H<sub>2</sub>O <s>old</s> <del>gone</del> <ins>new</ins> <u>under</u> <span>plain</span></p>\n\nPress <kbd>Q</kbd> and y<sup>3</sup> <del>no</del>.\n"
        let output = MarkdownRenderer.render(source)
        let text = output.text.string as NSString
        #expect(!text.contains("<"), "\(text)")
        func attribute(_ key: NSAttributedString.Key, at needle: String) -> Any? {
            output.text.attribute(key, at: text.range(of: needle).location, effectiveRange: nil)
        }
        for key in ["K", "Q"] {
            #expect(font(output, at: key)?.isFixedPitch == true && attribute(.backgroundColor, at: key) != nil)
        }
        #expect(((attribute(.baselineOffset, at: "2") as? CGFloat) ?? 0) > 0 && ((attribute(.baselineOffset, at: "3") as? CGFloat) ?? 0) > 0)
        let sub = text.range(of: "H2O").location
        #expect(((output.text.attribute(.baselineOffset, at: sub + 1, effectiveRange: nil) as? CGFloat) ?? 0) < 0)
        #expect(((output.text.attribute(.baselineOffset, at: sub + 2, effectiveRange: nil) as? CGFloat) ?? 0) == 0, "the offset ends with its element")
        #expect((font(output, at: "2")?.pointSize ?? 99) < MarkdownRenderer.bodyFont.pointSize)
        for needle in ["old", "gone", "no"] { #expect(attribute(.strikethroughStyle, at: needle) != nil, "\(needle)") }
        for needle in ["new", "under"] { #expect(attribute(.underlineStyle, at: needle) != nil, "\(needle)") }
        #expect(attribute(.underlineStyle, at: "plain") == nil && attribute(.strikethroughStyle, at: "plain") == nil)
    }

    @Test func htmlOutsideGitHubsListStaysSource() {
        for source in ["<table><tr><td><p>block</p></td></tr></table>\n", "<li>stray</li>\n", "<table>\nloose text\n</table>\n",
                       "<ul><li><script>x()</script></li></ul>\n", "<div><iframe src=\"x\"></iframe></div>\n",
                       "<div><form><input name=\"q\"></form></div>\n", "<pre><div>x</div></pre>\n", "<table><tr><td><table></table></td></tr></table>\n"] {
            let output = MarkdownRenderer.render(source)
            #expect(output.text.string.hasPrefix(String(source.prefix(4))), "\(source) stays source")
            #expect(decoration(output, at: "<")?.kind == .codeBlock, "\(source)")
        }
    }

    @Test func hugeListStartsAreCapped() {
        let output = MarkdownRenderer.render("<ol start=\"9223372036854775807\"><li>a</li><li>b</li></ol>\n")
        #expect(output.text.string.contains("999999999.\ta") && output.text.string.contains("1000000000.\tb"))
    }

    @Test func definitionsLooseInATableStaySource() {
        let output = MarkdownRenderer.render("<table><tr><dd>hello</dd></tr></table>\n")
        #expect(output.text.string.contains("<dd>hello</dd>"))
    }

    @Test func blocksInsidePreStaySource() {
        for source in ["<pre>a\n<dd>b</dd></pre>\n", "<ul><li><pre>a\n<li>b</li></pre></li></ul>\n"] {
            #expect(MarkdownRenderer.render(source).text.string.contains("<pre>"), "\(source)")
        }
    }

    @Test func aPictureInPreKeepsItsOwnLine() {
        let output = MarkdownRenderer.render("<pre>a\n<img src=\"x.png\">\nb</pre>\n")
        let text = output.text.string
        #expect(text.contains("a\u{2028}\u{FFFC}") && text.contains("x.png\u{2028}b") && !text.contains("\u{2028}\u{2028}"), "\(text.debugDescription)")
    }

    @Test func bigHTMLTablesAndListsRenderQuickly() {
        let clock = ContinuousClock()
        let rows = (0..<2000).map { "<tr><td>cell \($0)</td><td><b>bold</b> \($0)</td></tr>" }.joined(separator: "\n")
        let lists = String(repeating: "<ul><li>a", count: 200) + String(repeating: "</li></ul>", count: 200)
        for source in ["<table>\n\(rows)\n</table>\n", lists + "\n"] {
            let elapsed = clock.measure { _ = MarkdownRenderer.render(source) }
            #expect(elapsed < .seconds(1), "\(source.prefix(12))… took \(elapsed)")
        }
    }

    @Test func inlineHTMLStylesMatchedTagsAndShowsTheRest() {
        let output = MarkdownRenderer.render("Some <b>bold</b>, <blink>K</blink>, <em>open and <code>x()</code>\n")
        let text = output.text.string
        #expect(isBold(font(output, at: "bold")) && !text.contains("<b>"))
        #expect(text.contains("<blink>") && text.contains("</blink>"), "unknown tags stay source")
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
