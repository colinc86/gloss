import AppKit
import Core
import Foundation
import Markdown

/// Renders markdown source into an attributed string whose runs remember where they came from.
///
/// Block chrome (code fills, quote bars, rules, table rules, heading underlines) is not text: each paragraph carries
/// a `MarkdownBlockDecoration` under `blockKey`, and `MarkdownLayoutFragment` draws it. Generated text (list markers,
/// tabs, line separators inside code blocks) never appears in the source map.
public struct MarkdownRenderer {
    public struct Output: Sendable {
        public let text: NSAttributedString
        public let map: RenderedSourceMap
    }

    public static let sourceSpanKey = NSAttributedString.Key("gloss.sourceSpan")
    nonisolated public static let blockKey = NSAttributedString.Key("gloss.markdownBlock")

    /// `baseURL` is the document's folder on this Mac; relative images resolve against it. Without one (remote
    /// documents) images show as placeholders.
    public static func render(_ source: String, baseURL: URL? = nil) -> Output {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var walker = Walker(source: source, table: SourceLineTable(source), baseURL: baseURL)
        walker.visit(document)
        walker.finish()
        return Output(text: walker.output, map: RenderedSourceMap(spans: walker.spans, blocks: walker.blocks))
    }

    // MARK: Styles

    nonisolated static var bodyFont: NSFont { NSFont.systemFont(ofSize: 14) }
    nonisolated static var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) }

    nonisolated static func headingFont(level: Int) -> NSFont {
        let sizes: [CGFloat] = [28, 22, 18, 16, 14, 13]
        return NSFont.systemFont(ofSize: sizes[max(0, min(5, level - 1))], weight: .semibold)
    }

    /// Inner padding of code blocks and table cells, shared with `MarkdownLayoutFragment`.
    nonisolated static let codePadding: CGFloat = 14
    nonisolated static let codeVerticalPadding: CGFloat = 10
    nonisolated static let tableRowPadding: CGFloat = 6
    nonisolated static let tableCellPadding: CGFloat = 10
    /// Widest table laid out in aligned columns; wider tables flow (see `layOutTable`).
    static let tableFitWidth: CGFloat = 620
    /// Line separator between code lines: one paragraph per code block, so its fill is one shape.
    nonisolated static let lineSeparator = "\u{2028}"
    /// Code blocks longer than this are shown without syntax colours.
    static let highlightLimit = 20_000

    struct Style {
        var font: NSFont = MarkdownRenderer.bodyFont
        var color: NSColor = .textColor
        var bold = false
        var italic = false
        var monospaced = false
        var codeBackground = false
        var strikethrough = false
        var link: String?

        var attributes: [NSAttributedString.Key: Any] {
            var font = monospaced ? MarkdownRenderer.codeFont.withSize((self.font.pointSize * 0.9).rounded()) : self.font
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
            }
            if codeBackground { attributes[.backgroundColor] = NSColor.quaternarySystemFill }
            return attributes
        }
    }

    /// Fenced-code info string to a grammar name: `swift`, `sh`, `ts`, `py` and friends.
    nonisolated static func grammarName(forFence info: String?) -> String? {
        guard let word = info?.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first?.lowercased(), !word.isEmpty else { return nil }
        let aliases = ["shell": "bash", "console": "bash", "shellsession": "bash", "golang": "go", "md": "markdown"]
        if let alias = aliases[word] { return alias }
        if GrammarCatalog.supportedLanguageNames().contains(word) { return word }
        return GrammarCatalog.languageName(forPath: "x.\(word)")
    }

    // MARK: Walker

    struct Walker: MarkupWalker {
        let source: String
        let table: SourceLineTable
        let sourceNS: NSString
        let baseURL: URL?
        var output = NSMutableAttributedString()
        var spans: [SourceSpan] = []
        var blocks: [SourceSpan] = []
        private var style = Style()
        private var needsBlockSeparator = false
        private var listNumbers: [Int?] = []   // nil for bullet lists
        private var listMarkerWidths: [CGFloat] = []

        // Paragraph state, read by `paragraphStyle()` on every append.
        /// Left edge of the current block's text, in container coordinates.
        private var indent: CGFloat = 0
        /// First-line indent of a list item's first paragraph (the marker hangs to the left of `indent`).
        private var firstLineIndent: CGFloat?
        private var tabStops: [NSTextTab] = []
        /// A list item's marker, emitted by the next `openBlock` so it joins whatever block the item starts with
        /// (paragraph, code block, quote, nested list) and takes that block's chrome.
        private var pendingMarker: (text: String, attributes: [NSAttributedString.Key: Any])?
        private var pendingGap: CGFloat?
        private var kind: MarkdownBlockDecoration.Kind = .plain
        private var gap: CGFloat = 0
        private var decoration = MarkdownBlockDecoration(kind: .plain, leading: 0, quoteBars: [])

        // Block rhythm.
        private enum LastBlock: Equatable { case none, heading(Int), listItem, other }
        private var lastBlock = LastBlock.none
        private var blockCount = 0
        /// Left edge of each open quote's bar and the block count when it opened.
        private var quotes: [(x: CGFloat, openedAt: Int)] = []

        init(source: String, table: SourceLineTable, baseURL: URL?) {
            self.source = source
            self.table = table
            self.baseURL = baseURL
            sourceNS = source as NSString
        }

        // MARK: Emission

        private mutating func append(_ string: String, source: NSRange?, exact: Bool, extra: [NSAttributedString.Key: Any] = [:]) {
            guard !string.isEmpty else { return }
            var attributes = style.attributes.merging(extra) { _, new in new }
            attributes[.paragraphStyle] = paragraphStyle()
            attributes[MarkdownRenderer.blockKey] = decoration
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
            let paragraph = NSMutableParagraphStyle()
            let textIndent = kind == .codeBlock ? indent + MarkdownRenderer.codePadding : indent
            paragraph.headIndent = textIndent
            paragraph.firstLineHeadIndent = firstLineIndent ?? textIndent
            // A hanging list marker tabs to the text.
            paragraph.tabStops = firstLineIndent != nil ? [NSTextTab(textAlignment: .left, location: textIndent, options: [:])] : tabStops
            paragraph.defaultTabInterval = 28
            paragraph.paragraphSpacingBefore = gap
            switch kind {
            case .codeBlock:
                paragraph.lineHeightMultiple = 1.15
                paragraph.tailIndent = -MarkdownRenderer.codePadding
                paragraph.paragraphSpacingBefore = gap + MarkdownRenderer.codeVerticalPadding
                paragraph.paragraphSpacing = MarkdownRenderer.codeVerticalPadding
            case .heading:
                paragraph.lineHeightMultiple = 1.1
            case .rule:
                paragraph.lineHeightMultiple = 1
            case .tableRow:
                paragraph.lineHeightMultiple = 1.2
            case .plain:
                paragraph.lineHeightMultiple = 1.3
            }
            return paragraph
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

        /// Starts a paragraph-level block: separator, spacing above it, and its decoration.
        private mutating func openBlock(_ kind: MarkdownBlockDecoration.Kind = .plain, gapOverride: CGFloat? = nil) {
            beginBlock()
            blockRenderedStarts.append(output.length)
            self.kind = kind
            let gapOverride = gapOverride ?? pendingGap
            pendingGap = nil
            if pendingMarker == nil { firstLineIndent = nil }
            if blockCount == 0 {
                gap = 0
            } else if let gapOverride {
                gap = gapOverride
            } else if case .heading(let level) = kind {
                gap = level <= 2 ? 26 : 20
            } else if case .heading(let level) = lastBlock {
                gap = level <= 2 ? 16 : 10
            } else {
                gap = kind == .rule ? 16 : 12
            }
            let bars = quotes.map { MarkdownBlockDecoration.QuoteBar(x: $0.x, continuesFromAbove: blockCount > $0.openedAt) }
            decoration = MarkdownBlockDecoration(kind: kind, leading: indent, quoteBars: bars)
            blockCount += 1
            if case .heading(let level) = kind { lastBlock = .heading(level) } else { lastBlock = .other }
            if let marker = pendingMarker {
                pendingMarker = nil
                appendGenerated(marker.text, extra: marker.attributes)
                lastBlock = .listItem
            }
        }

        /// Starts a container (quote) that only groups blocks: no text, no spacing of its own.
        private mutating func openContainer() {
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
            openBlock(.heading(level: heading.level))
            let saved = style
            style.font = MarkdownRenderer.headingFont(level: heading.level)
            if heading.level >= 6 { style.color = .secondaryLabelColor }
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
            openContainer()
            let saved = (style, indent)
            style.color = .secondaryLabelColor
            quotes.append((x: indent, openedAt: blockCount))
            indent += 18
            for child in blockQuote.children { visit(child) }
            quotes.removeLast()
            style = saved.0
            indent = saved.1
            endBlock(blockQuote)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            openBlock(.codeBlock)
            decoration = decoration.labelled(MarkdownBlockDecoration.languageName(codeBlock.language))
            let saved = style
            style.monospaced = true
            style.font = MarkdownRenderer.bodyFont
            let codeStart = output.length
            // One span per code line, so a note on code inside markdown is line-precise.
            var lines = codeBlock.code.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true { lines.removeLast() }
            if let range = codeBlock.range {
                // Fenced blocks start on the fence line; indented blocks start on the first code line. Decided by
                // line count, since a fence inside a list item or quote does not start its source line.
                let isFenced = range.upperBound.line - range.lowerBound.line + 1 > lines.count
                appendSourceLines(lines, firstLine: range.lowerBound.line + (isFenced ? 1 : 0))
            } else {
                append(codeBlock.code.replacingOccurrences(of: "\n", with: MarkdownRenderer.lineSeparator), source: nil, exact: false)
            }
            if output.length == codeStart { appendGenerated(" ") }
            colorCode(codeBlock.code, language: codeBlock.language, renderedStart: codeStart)
            style = saved
            endBlock(codeBlock)
        }

        /// One span per line joined by generated line separators. A line is exact when its source line ends with
        /// it (container prefixes such as `> ` or list indentation are skipped), so notes stay line-precise.
        private mutating func appendSourceLines(_ lines: [Substring], firstLine: Int) {
            for (offset, line) in lines.enumerated() {
                if offset > 0 { appendGenerated(MarkdownRenderer.lineSeparator) }
                let text = String(line)
                let lineRange = table.index.contentRange(ofLine: firstLine + offset)
                let length = (text as NSString).length
                if sourceNS.substring(with: lineRange).hasSuffix(text), length <= lineRange.length {
                    append(text, source: NSRange(location: lineRange.location + lineRange.length - length, length: length), exact: true)
                } else {
                    append(text, source: lineRange, exact: false)
                }
            }
        }

        /// Syntax colours for a fenced block. The rendered code is the source code with each newline swapped for a
        /// one-unit line separator, so capture offsets carry over unchanged.
        private mutating func colorCode(_ code: String, language: String?, renderedStart: Int) {
            guard code.utf16.count <= MarkdownRenderer.highlightLimit, let name = MarkdownRenderer.grammarName(forFence: language),
                  let highlighter = Highlighter(languageName: name, text: code) else { return }
            let renderedLength = output.length - renderedStart
            for capture in highlighter.captures {
                guard let color = SyntaxTheme.color(forCapture: capture.name) else { continue }
                let location = capture.range.location
                let end = min(location + capture.range.length, renderedLength)
                guard location < end else { continue }
                output.addAttribute(.foregroundColor, value: color, range: NSRange(location: renderedStart + location, length: end - location))
            }
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            openBlock(.codeBlock)
            let saved = style
            style.monospaced = true
            style.color = .secondaryLabelColor
            let trimmed = html.rawHTML.trimmingCharacters(in: .newlines)
            if let range = html.range {
                appendSourceLines(trimmed.split(separator: "\n", omittingEmptySubsequences: false), firstLine: range.lowerBound.line)
            } else {
                append(trimmed.replacingOccurrences(of: "\n", with: MarkdownRenderer.lineSeparator), source: nil, exact: false)
            }
            style = saved
            endBlock(html)
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
            openBlock(.rule)
            appendGenerated("\u{00A0}", extra: [.font: NSFont.systemFont(ofSize: 6)])
            endBlock(thematicBreak)
        }

        mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
            listNumbers.append(nil)
            listMarkerWidths.append(20)
            for child in unorderedList.children { visit(child) }
            listMarkerWidths.removeLast()
            listNumbers.removeLast()
        }

        mutating func visitOrderedList(_ orderedList: OrderedList) {
            let start = Int(orderedList.startIndex)
            let widest = "\(start + max(0, orderedList.childCount - 1))." as NSString
            let width = widest.size(withAttributes: [.font: MarkdownRenderer.bodyFont]).width
            listNumbers.append(start)
            listMarkerWidths.append(max(22, ceil(width) + 8))
            for child in orderedList.children { visit(child) }
            listMarkerWidths.removeLast()
            listNumbers.removeLast()
        }

        mutating func visitListItem(_ listItem: ListItem) {
            let marker: String
            if let number = listNumbers.last ?? nil {
                marker = "\(number)."
                listNumbers[listNumbers.count - 1] = number + 1
            } else {
                let bullets = ["•", "◦", "▪"]
                marker = bullets[(listNumbers.count - 1) % bullets.count]
            }
            let savedIndent = indent
            let savedStyle = style
            let markerIndent = indent
            openContainer()
            indent += listMarkerWidths.last ?? 20
            firstLineIndent = markerIndent
            pendingGap = lastBlock == .listItem ? 4 : nil
            // An item that opens with a nested list (`- - a`) shows both markers on its first line.
            let outerMarker = pendingMarker?.text ?? ""
            if pendingMarker != nil { firstLineIndent = firstLineIndent.map { min($0, markerIndent) } }
            switch listItem.checkbox {
            case .checked?:
                pendingMarker = (outerMarker + "☑\t", [.foregroundColor: NSColor.controlAccentColor])
                style.color = .secondaryLabelColor
            case .unchecked?:
                pendingMarker = (outerMarker + "☐\t", [.foregroundColor: NSColor.secondaryLabelColor])
            case nil:
                pendingMarker = (outerMarker + marker + "\t", [.foregroundColor: NSColor.secondaryLabelColor])
            }
            for child in listItem.children { visit(child) }
            // An empty item still shows its marker.
            if pendingMarker != nil {
                openBlock()
                _ = blockRenderedStarts.popLast()
            }
            firstLineIndent = nil
            pendingGap = nil
            indent = savedIndent
            style = savedStyle
            endBlock(listItem)
            lastBlock = .listItem
        }

        mutating func visitTable(_ table: Table) {
            openBlock(.tableRow(header: true, width: 0))
            let saved = style
            // A tab at the very start of a line makes TextKit draw a faint sliver at the table's left edge, so a
            // left-aligned first column is placed by the row's first-line indent instead of a leading tab.
            let leadingTab = table.columnAlignments.first.map { $0 == .right || $0 == .center } ?? false
            var rows: [[Table.Cell]] = [Array(table.head.cells)]
            for row in table.body.rows { rows.append(Array(row.cells)) }
            var rowRanges: [NSRange] = []
            var cellRanges: [[NSRange]] = []
            for (rowIndex, cells) in rows.enumerated() {
                if rowIndex > 0 { appendGenerated("\n") }
                let rowStart = output.length
                var ranges: [NSRange] = []
                for (column, cell) in cells.enumerated() {
                    if column > 0 || leadingTab { appendGenerated("\t") }
                    let before = style
                    if rowIndex == 0 { style.bold = true }
                    let cellStart = output.length
                    blockRenderedStarts.append(cellStart)
                    descendInto(cell)
                    endBlock(cell)
                    ranges.append(NSRange(location: cellStart, length: output.length - cellStart))
                    needsBlockSeparator = false
                    style = before
                }
                rowRanges.append(NSRange(location: rowStart, length: output.length - rowStart))
                cellRanges.append(ranges)
            }
            layOutTable(rowRanges: rowRanges, cellRanges: cellRanges, alignments: table.columnAlignments, leadingTab: leadingTab)
            style = saved
            endBlock(table)
        }

        /// Column widths from the widest cell, then one tab stop per column (aligned as the table asks) and a row
        /// decoration that knows the table's width.
        private mutating func layOutTable(rowRanges: [NSRange], cellRanges: [[NSRange]], alignments: [Table.ColumnAlignment?], leadingTab: Bool) {
            let columns = cellRanges.map(\.count).max() ?? 0
            guard columns > 0 else { return }
            var widths = [CGFloat](repeating: 24, count: columns)
            for cells in cellRanges {
                for (column, range) in cells.enumerated() where range.length > 0 {
                    widths[column] = max(widths[column], ceil(output.attributedSubstring(from: range).size().width))
                }
            }
            let padding = MarkdownRenderer.tableCellPadding
            var starts: [CGFloat] = []
            var x = indent + padding
            for width in widths {
                starts.append(x)
                x += width + padding * 2
            }
            var tableWidth = x - padding - indent
            // Tab stops cannot wrap a cell, so a table wider than a narrow pane would overprint its own columns.
            // Wide tables use the default tab interval instead: cells flow and wrap, never overlap.
            let fits = tableWidth <= MarkdownRenderer.tableFitWidth - indent
            if !fits { tableWidth = .greatestFiniteMagnitude }
            let stops = !fits ? [] : (0..<columns).map { column -> NSTextTab in
                let alignment = column < alignments.count ? alignments[column] : nil
                return switch alignment {
                case .right?: NSTextTab(textAlignment: .right, location: starts[column] + widths[column], options: [:])
                case .center?: NSTextTab(textAlignment: .center, location: starts[column] + widths[column] / 2, options: [:])
                default: NSTextTab(textAlignment: .left, location: starts[column], options: [:])
                }
            }
            let bars = decoration.quoteBars
            for (row, range) in rowRanges.enumerated() {
                let paragraph = NSMutableParagraphStyle()
                paragraph.tabStops = stops
                paragraph.defaultTabInterval = 24
                paragraph.headIndent = indent + padding
                paragraph.firstLineHeadIndent = leadingTab ? indent : indent + padding
                paragraph.lineHeightMultiple = 1.2
                paragraph.paragraphSpacingBefore = (row == 0 ? gap : 0) + MarkdownRenderer.tableRowPadding
                paragraph.paragraphSpacing = MarkdownRenderer.tableRowPadding
                let rowDecoration = MarkdownBlockDecoration(kind: .tableRow(header: row == 0, width: tableWidth), leading: indent, quoteBars: bars)
                // Include the newline that ends the row so the paragraph's attributes are uniform.
                let full = NSRange(location: range.location, length: min(range.length + 1, output.length - range.location))
                output.addAttribute(.paragraphStyle, value: paragraph, range: full)
                output.addAttribute(MarkdownRenderer.blockKey, value: rowDecoration, range: full)
            }
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
            let saved = style
            style.strikethrough = true
            style.color = .secondaryLabelColor
            descendInto(strikethrough)
            style = saved
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            let saved = style
            style.monospaced = true
            style.codeBackground = true
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
            style = saved
        }

        mutating func visitLink(_ link: Link) {
            let saved = style.link
            style.link = link.destination
            descendInto(link)
            style.link = saved
        }

        mutating func visitImage(_ image: Image) {
            let alt = image.plainText
            let (range, _) = exactness(image, rendered: alt)
            if let picture = MarkdownImageLoader.image(source: image.source, baseURL: baseURL) {
                let attachment = FittedImageAttachment()
                attachment.image = picture
                attachment.naturalSize = picture.size
                append("\u{FFFC}", source: range, exact: false, extra: [.attachment: attachment])
                return
            }
            let saved = style
            style.color = .secondaryLabelColor
            style.italic = true
            if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: "Image")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])) {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                appendGenerated("\u{FFFC}\u{00A0}", extra: [.attachment: attachment])
            }
            append(alt.isEmpty ? (image.source ?? "image") : alt, source: range, exact: false)
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
            append(MarkdownRenderer.lineSeparator, source: range, exact: false)
        }
    }
}

/// Paragraph chrome drawn by `MarkdownLayoutFragment`. Immutable; one instance per block.
public nonisolated final class MarkdownBlockDecoration: NSObject, Sendable {
    public enum Kind: Equatable, Sendable {
        case plain
        case codeBlock
        case rule
        case heading(level: Int)
        case tableRow(header: Bool, width: CGFloat)
    }

    public struct QuoteBar: Equatable, Sendable {
        /// Left edge of the bar, in container coordinates.
        public var x: CGFloat
        /// False on a quote's first paragraph, so the bar starts at the text instead of in the gap above it.
        public var continuesFromAbove: Bool
    }

    public let kind: Kind
    /// Left edge of the block (where a code fill or rule starts), in container coordinates.
    public let leading: CGFloat
    public let quoteBars: [QuoteBar]
    /// A code block's language, as people name it ("Swift", "Shell"), drawn small in its corner.
    public let label: String?

    public init(kind: Kind, leading: CGFloat, quoteBars: [QuoteBar], label: String? = nil) {
        self.kind = kind
        self.leading = leading
        self.quoteBars = quoteBars
        self.label = label
    }

    func labelled(_ label: String?) -> MarkdownBlockDecoration {
        MarkdownBlockDecoration(kind: kind, leading: leading, quoteBars: quoteBars, label: label)
    }

    /// A fence's info string as a language name: the common ones spelled as their communities spell them, anything
    /// else as written. Nil for a bare fence.
    public static func languageName(_ info: String?) -> String? {
        guard let word = info?.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init), !word.isEmpty else { return nil }
        let names = ["swift": "Swift", "py": "Python", "python": "Python", "js": "JavaScript", "javascript": "JavaScript",
                     "jsx": "JSX", "ts": "TypeScript", "typescript": "TypeScript", "tsx": "TSX", "sh": "Shell", "bash": "Shell",
                     "zsh": "Shell", "shell": "Shell", "console": "Console", "json": "JSON", "yaml": "YAML", "yml": "YAML",
                     "toml": "TOML", "md": "Markdown", "markdown": "Markdown", "html": "HTML", "xml": "XML", "css": "CSS",
                     "rb": "Ruby", "ruby": "Ruby", "go": "Go", "rs": "Rust", "rust": "Rust", "c": "C", "cpp": "C++",
                     "c++": "C++", "objc": "Objective-C", "java": "Java", "kotlin": "Kotlin", "kt": "Kotlin", "sql": "SQL",
                     "diff": "Diff", "text": "Text", "txt": "Text", "lua": "Lua", "php": "PHP", "r": "R", "dockerfile": "Dockerfile"]
        return names[word.lowercased()] ?? word
    }

    /// Whether the fragment has anything to draw.
    public var isDrawn: Bool {
        if !quoteBars.isEmpty { return true }
        return switch kind {
        case .plain: false
        case .heading(let level): level <= 2
        case .codeBlock, .rule, .tableRow: true
        }
    }
}

extension Image {
    /// Alt text of an image node.
    var plainText: String {
        children.compactMap { ($0 as? Text)?.string }.joined()
    }
}

/// Loads local images for rendered markdown, cached by path and modification date so re-rendering while typing
/// does not reread them.
enum MarkdownImageLoader {
    private static var cache: [String: (modified: Date, image: NSImage)] = [:]
    static let maximumFileSize = 25 * 1024 * 1024

    static func image(source: String?, baseURL: URL?) -> NSImage? {
        guard let baseURL, let source, !source.isEmpty else { return nil }
        if let scheme = URL(string: source)?.scheme, scheme != "file" { return nil }
        let decoded = source.removingPercentEncoding ?? source
        let url: URL
        if decoded.hasPrefix("file://"), let fileURL = URL(string: source) {
            url = fileURL
        } else if decoded.hasPrefix("/") {
            url = URL(fileURLWithPath: decoded)
        } else {
            url = baseURL.appending(path: decoded)
        }
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size <= maximumFileSize,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if let cached = cache[path], cached.modified == modified { return cached.image }
        guard let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[path] = (modified, image)
        return image
    }
}

/// An image that shrinks to the line it sits on, so a narrow pane never clips it, and never grows taller than
/// `maximumHeight`, so a large picture does not fill the whole view.
nonisolated final class FittedImageAttachment: NSTextAttachment {
    var naturalSize = CGSize.zero
    static let maximumHeight: CGFloat = 480

    static func fitted(_ size: CGSize, width: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, width > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(1, width / size.width, maximumHeight / size.height)
        return CGRect(x: 0, y: 0, width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
                                   proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        Self.fitted(naturalSize, width: proposedLineFragment.width - position.x)
    }

    /// Corner radius for a picture of this size: soft on photos, barely there on icons, so neither looks pasted on
    /// nor turns into a blob.
    static func cornerRadius(for size: CGSize) -> CGFloat {
        min(8, min(size.width, size.height) / 8).rounded(.down)
    }

    /// The picture as a reader's app sets it into a page (Bear, Craft): continuous rounded corners and a hairline edge,
    /// so a pale image keeps its shape on a white page. Drawn when shown, so the hairline follows light and dark.
    override func image(for imageBounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? {
        guard let picture = image, imageBounds.width > 0, imageBounds.height > 0 else { return image }
        let radius = Self.cornerRadius(for: imageBounds.size)
        return NSImage(size: imageBounds.size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            edge.lineWidth = 0.5
            NSColor.labelColor.withAlphaComponent(0.14).setStroke()
            edge.stroke()
            return true
        }
    }
}
