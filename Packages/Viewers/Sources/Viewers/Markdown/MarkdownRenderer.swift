import AppKit
import Core
import Foundation
import Markdown

/// Renders markdown source into an attributed string whose runs remember where they came from.
public struct MarkdownRenderer {
    public struct Output: Sendable {
        public let text: NSAttributedString
        public let map: RenderedSourceMap
    }

    public static let sourceSpanKey = NSAttributedString.Key("gloss.sourceSpan")

    public static func render(_ source: String) -> Output {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var walker = Walker(source: source, table: SourceLineTable(source))
        walker.visit(document)
        walker.finish()
        return Output(text: walker.output, map: RenderedSourceMap(spans: walker.spans, blocks: walker.blocks))
    }

    // MARK: Styles

    nonisolated static var bodyFont: NSFont { NSFont.systemFont(ofSize: 14) }
    nonisolated static var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) }

    nonisolated static func headingFont(level: Int) -> NSFont {
        let sizes: [CGFloat] = [26, 22, 18, 16, 14, 13]
        return NSFont.systemFont(ofSize: sizes[max(0, min(5, level - 1))], weight: .bold)
    }

    struct Style {
        var font: NSFont = MarkdownRenderer.bodyFont
        var color: NSColor = .textColor
        var bold = false
        var italic = false
        var monospaced = false
        var strikethrough = false
        var link: String?

        var attributes: [NSAttributedString.Key: Any] {
            var font = monospaced ? MarkdownRenderer.codeFont.withSize(self.font.pointSize * 0.92) : self.font
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if monospaced { attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
            return attributes
        }
    }

    // MARK: Walker

    struct Walker: MarkupWalker {
        let source: String
        let table: SourceLineTable
        let sourceNS: NSString
        var output = NSMutableAttributedString()
        var spans: [SourceSpan] = []
        var blocks: [SourceSpan] = []
        private var style = Style()
        private var blockDepth = 0
        private var needsBlockSeparator = false
        private var listNumbers: [Int?] = []   // nil for bullet lists
        private var indent: CGFloat = 0

        init(source: String, table: SourceLineTable) {
            self.source = source
            self.table = table
            sourceNS = source as NSString
        }

        // MARK: Emission

        private mutating func append(_ string: String, source: NSRange?, exact: Bool, extra: [NSAttributedString.Key: Any] = [:]) {
            guard !string.isEmpty else { return }
            var attributes = style.attributes.merging(extra) { _, new in new }
            attributes[.paragraphStyle] = paragraphStyle()
            let rendered = NSRange(location: output.length, length: (string as NSString).length)
            if let source {
                let span = SourceSpan(rendered: rendered, source: source, exact: exact)
                attributes[MarkdownRenderer.sourceSpanKey] = span.source.location
                spans.append(span)
            }
            output.append(NSAttributedString(string: string, attributes: attributes))
        }

        /// Generated text (bullets, separators) with no source.
        private mutating func appendGenerated(_ string: String, extra: [NSAttributedString.Key: Any] = [:]) {
            append(string, source: nil, exact: false, extra: extra)
        }

        private func paragraphStyle() -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            return style
        }

        private mutating func beginBlock() {
            if needsBlockSeparator { appendGenerated("\n") }
            needsBlockSeparator = false
        }

        private mutating func endBlock(_ markup: any Markup) {
            if let range = markup.range {
                let sourceRange = table.nsRange(range)
                let renderedStart = blockRenderedStarts.popLast() ?? output.length
                blocks.append(SourceSpan(rendered: NSRange(location: renderedStart, length: output.length - renderedStart), source: sourceRange, exact: false))
            } else {
                _ = blockRenderedStarts.popLast()
            }
            needsBlockSeparator = true
        }

        private var blockRenderedStarts: [Int] = []

        private mutating func openBlock() {
            beginBlock()
            blockRenderedStarts.append(output.length)
        }

        mutating func finish() {}

        /// Exact when the node's rendered string equals its source bytes (no escapes or entities).
        private func exactness(_ markup: any Markup, rendered: String) -> (NSRange?, Bool) {
            guard let range = markup.range else { return (nil, false) }
            let nsRange = table.nsRange(range)
            let sourceText = sourceNS.substring(with: nsRange)
            return (nsRange, sourceText == rendered)
        }

        // MARK: Blocks

        mutating func visitHeading(_ heading: Heading) {
            openBlock()
            let saved = style
            style.font = MarkdownRenderer.headingFont(level: heading.level)
            descendInto(heading)
            style = saved
            endBlock(heading)
        }

        mutating func visitParagraph(_ paragraph: Paragraph) {
            openBlock()
            descendInto(paragraph)
            endBlock(paragraph)
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            openBlock()
            let saved = (style, indent)
            style.color = .secondaryLabelColor
            indent += 18
            for child in blockQuote.children { visit(child) }
            style = saved.0
            indent = saved.1
            endBlock(blockQuote)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            openBlock()
            let saved = style
            style.monospaced = true
            // One span per code line, so a note on code inside markdown is line-precise.
            let lines = codeBlock.code.split(separator: "\n", omittingEmptySubsequences: false)
            if let range = codeBlock.range {
                let fenceLine = range.lowerBound.line
                for (offset, line) in lines.enumerated() {
                    if offset == lines.count - 1 && line.isEmpty { break }
                    let lineNumber = fenceLine + 1 + offset
                    let sourceRange = table.index.contentRange(ofLine: lineNumber)
                    let exact = sourceNS.substring(with: sourceRange) == String(line)
                    append(String(line), source: sourceRange, exact: exact)
                    if offset < lines.count - 1 { appendGenerated("\n") }
                }
            } else {
                append(codeBlock.code, source: nil, exact: false)
            }
            style = saved
            endBlock(codeBlock)
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            openBlock()
            let saved = style
            style.monospaced = true
            style.color = .secondaryLabelColor
            let (range, exact) = exactness(html, rendered: html.rawHTML)
            append(html.rawHTML.trimmingCharacters(in: .newlines), source: range, exact: exact && !html.rawHTML.hasSuffix("\n"))
            style = saved
            endBlock(html)
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            openBlock()
            appendGenerated("────────", extra: [.foregroundColor: NSColor.separatorColor])
            endBlock(thematicBreak)
        }

        mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
            listNumbers.append(nil)
            indent += 18
            for child in unorderedList.children { visit(child) }
            indent -= 18
            listNumbers.removeLast()
        }

        mutating func visitOrderedList(_ orderedList: OrderedList) {
            listNumbers.append(Int(orderedList.startIndex))
            indent += 22
            for child in orderedList.children { visit(child) }
            indent -= 22
            listNumbers.removeLast()
        }

        mutating func visitListItem(_ listItem: ListItem) {
            openBlock()
            let marker: String
            if let number = listNumbers.last ?? nil {
                marker = "\(number). "
                listNumbers[listNumbers.count - 1] = number + 1
            } else {
                marker = "•  "
            }
            let checkbox: String = switch listItem.checkbox {
            case .checked?: "☑ "
            case .unchecked?: "☐ "
            case nil: ""
            }
            appendGenerated(marker + checkbox, extra: [.foregroundColor: NSColor.secondaryLabelColor])
            var first = true
            for child in listItem.children {
                if !first { appendGenerated("\n") }
                first = false
                needsBlockSeparator = false
                if child is Paragraph {
                    // Inline the paragraph so the marker and the text share a line.
                    blockRenderedStarts.append(output.length)
                    descendInto(child)
                    endBlock(child)
                } else {
                    visit(child)
                }
            }
            endBlock(listItem)
        }

        mutating func visitTable(_ table: Table) {
            openBlock()
            let saved = style
            style.monospaced = true
            var rows: [[Table.Cell]] = [Array(table.head.cells)]
            for row in table.body.rows { rows.append(Array(row.cells)) }
            for (rowIndex, cells) in rows.enumerated() {
                if rowIndex > 0 { appendGenerated("\n") }
                if rowIndex == 1 { appendGenerated(String(repeating: "─", count: 24) + "\n", extra: [.foregroundColor: NSColor.separatorColor]) }
                for (cellIndex, cell) in cells.enumerated() {
                    if cellIndex > 0 { appendGenerated("  │  ", extra: [.foregroundColor: NSColor.separatorColor]) }
                    let before = style
                    if rowIndex == 0 { style.bold = true }
                    blockRenderedStarts.append(output.length)
                    descendInto(cell)
                    endBlock(cell)
                    needsBlockSeparator = false
                    style = before
                }
            }
            style = saved
            endBlock(table)
        }

        // MARK: Inlines

        mutating func visitText(_ text: Text) {
            let (range, exact) = exactness(text, rendered: text.string)
            append(text.string, source: range, exact: exact)
        }

        mutating func visitEmphasis(_ emphasis: Emphasis) {
            let saved = style.italic
            style.italic = true
            descendInto(emphasis)
            style.italic = saved
        }

        mutating func visitStrong(_ strong: Strong) {
            let saved = style.bold
            style.bold = true
            descendInto(strong)
            style.bold = saved
        }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
            let saved = style.strikethrough
            style.strikethrough = true
            descendInto(strikethrough)
            style.strikethrough = saved
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            let saved = style.monospaced
            style.monospaced = true
            // The node range includes the backticks; find the code inside it for an exact inner span.
            var source: NSRange?
            var exact = false
            if let range = inlineCode.range {
                let outer = table.nsRange(range)
                let inner = sourceNS.range(of: inlineCode.code, options: [.literal], range: outer)
                if inner.location != NSNotFound {
                    source = inner
                    exact = true
                } else {
                    source = outer
                }
            }
            append(inlineCode.code, source: source, exact: exact)
            style.monospaced = saved
        }

        mutating func visitLink(_ link: Link) {
            let saved = style.link
            style.link = link.destination
            descendInto(link)
            style.link = saved
        }

        mutating func visitImage(_ image: Image) {
            let saved = style
            style.italic = true
            style.color = .secondaryLabelColor
            let alt = image.plainText
            let (range, _) = exactness(image, rendered: alt)
            append(alt.isEmpty ? "[image]" : "[image: \(alt)]", source: range, exact: false)
            style = saved
        }

        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
            let saved = style
            style.monospaced = true
            style.color = .secondaryLabelColor
            let (range, exact) = exactness(inlineHTML, rendered: inlineHTML.rawHTML)
            append(inlineHTML.rawHTML, source: range, exact: exact)
            style = saved
        }

        mutating func visitSoftBreak(_ softBreak: SoftBreak) {
            let (range, _) = exactness(softBreak, rendered: " ")
            append(" ", source: range, exact: false)
        }

        mutating func visitLineBreak(_ lineBreak: LineBreak) {
            let (range, _) = exactness(lineBreak, rendered: "\n")
            append("\n", source: range, exact: false)
        }
    }
}

extension Image {
    /// Alt text of an image node.
    var plainText: String {
        children.compactMap { ($0 as? Text)?.string }.joined()
    }
}
