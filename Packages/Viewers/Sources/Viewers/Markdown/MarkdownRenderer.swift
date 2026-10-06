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
        /// Relative image sources that were neither on this Mac nor given: the controller fetches them from the
        /// document's host and renders again.
        public var unresolvedImages: [String] = []
    }

    public static let sourceSpanKey = NSAttributedString.Key("gloss.sourceSpan")
    nonisolated public static let blockKey = NSAttributedString.Key("gloss.markdownBlock")

    /// `baseURL` is the document's folder on this Mac; relative images resolve against it. `images` are pictures
    /// already fetched from a document's own host (an ssh host, a ticket's attachments), by source as written.
    /// Anything else shows as a placeholder.
    public static func render(_ source: String, baseURL: URL? = nil, images: [String: NSImage] = [:]) -> Output {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var walker = Walker(source: source, table: SourceLineTable(source), baseURL: baseURL)
        walker.images = images
        walker.visit(document)
        walker.finish()
        var output = Output(text: walker.output, map: RenderedSourceMap(spans: walker.spans, blocks: walker.blocks))
        output.unresolvedImages = walker.unresolvedImages
        return output
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
                // The real destination on hover: link text can say anything.
                attributes[.toolTip] = (link as? URL)?.absoluteString ?? "\(link)"
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
        var images: [String: NSImage] = [:]
        var unresolvedImages: [String] = []
        /// Where each picture is embedded, by `EmbedScanner` (read on the first picture), so a repeated one is told
        /// apart exactly as the re-anchorer tells it apart.
        private var embedLocations: [String: [Int]]?
        /// Pictures with no source range, counted as they come.
        var imageOccurrences: [String: Int] = [:]
        var output = NSMutableAttributedString()
        var spans: [SourceSpan] = []
        var blocks: [SourceSpan] = []
        private var style = Style()
        private var needsBlockSeparator = false
        private var listNumbers: [Int?] = []   // nil for bullet lists
        private var listMarkerWidths: [CGFloat] = []
        /// Inline HTML elements open in the current paragraph: the source of the end tag that closes each, and the
        /// style to restore there.
        private var inlineElements: [(name: String, close: NSRange, style: Style)] = []
        /// End tags of inline elements that ended early, with an element they were nested in.
        private var endedInlineTags: Set<NSRange> = []
        /// Each inline start tag's end tag (by the start's index), worked out once per parent, keyed by the parent's
        /// path from the document.
        private var inlineClosings: [[Int]: [Int: NSRange]] = [:]

        // Paragraph state, read by `paragraphStyle()` on every append.
        /// Left edge of the current block's text, in container coordinates.
        private var indent: CGFloat = 0
        /// First-line indent of a list item's first paragraph (the marker hangs to the left of `indent`).
        private var firstLineIndent: CGFloat?
        private var tabStops: [NSTextTab] = []
        /// Set by HTML `align` (`<p align="center">`); natural everywhere else.
        private var alignment = NSTextAlignment.natural
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
            paragraph.alignment = alignment
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
            endBlock(source: markup.range.map { table.nsRange($0) })
        }

        /// Ends a block that is part of a node (a paragraph inside one HTML block) by its own source range.
        private mutating func endBlock(source: NSRange?) {
            if let source {
                let renderedStart = blockRenderedStarts.popLast() ?? output.length
                blocks.append(SourceSpan(rendered: NSRange(location: renderedStart, length: output.length - renderedStart), source: source, exact: false))
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
            let tokens = MarkdownHTML.tokens(html.rawHTML)
            guard MarkdownHTML.isDrawable(tokens) else {
                showHTMLSource(html)
                return
            }
            drawHTML(html, tokens: tokens)
        }

        /// HTML the renderer does not draw, as its source lines.
        private mutating func showHTMLSource(_ html: HTMLBlock) {
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

        /// Where each line of an HTML block's `rawHTML` sits in the source. Inside a quote or list item the raw
        /// lines lose their container prefix, so a line maps exactly only when its source line ends with it.
        private struct HTMLLines {
            /// Offset in `rawHTML` where each line starts, and its length.
            var raw: [NSRange] = []
            /// Source offset of each raw line's first unit, when the source line ends with it.
            var exactStart: [Int?] = []
            var source: [NSRange] = []

            /// The source of a range of `rawHTML`, exact when it lies on one line that maps exactly. A range over
            /// several lines runs from its first unit to its last where those lines map exactly (a tag broken over
            /// lines), and covers the whole lines otherwise.
            func source(of range: NSRange) -> (NSRange, Bool)? {
                let end = range.location + max(range.length, 1) - 1
                guard let first = line(containing: range.location), let last = line(containing: end) else { return nil }
                if first == last, let start = exactStart[first], range.location + range.length <= raw[first].location + raw[first].length {
                    return (NSRange(location: start + range.location - raw[first].location, length: range.length), true)
                }
                if let start = exactStart[first], let lastStart = exactStart[last], end < raw[last].location + raw[last].length {
                    let from = start + range.location - raw[first].location
                    return (NSRange(location: from, length: lastStart + end - raw[last].location + 1 - from), false)
                }
                return (NSUnionRange(source[first], source[last]), false)
            }

            /// The last line starting at or before `offset`.
            private func line(containing offset: Int) -> Int? {
                var low = 0, high = raw.count
                while low < high {
                    let mid = (low + high) / 2
                    if raw[mid].location <= offset { low = mid + 1 } else { high = mid }
                }
                return low > 0 ? low - 1 : nil
            }
        }

        private func htmlLines(_ html: HTMLBlock) -> HTMLLines {
            var lines = HTMLLines()
            guard let range = html.range else { return lines }
            let raw = html.rawHTML as NSString
            var location = 0
            for (offset, line) in html.rawHTML.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let length = (String(line) as NSString).length
                defer { location += length + 1 }
                let number = range.lowerBound.line + offset
                guard number <= range.upperBound.line, location <= raw.length else { break }
                let lineRange = table.index.contentRange(ofLine: number)
                let text = String(line)
                lines.raw.append(NSRange(location: location, length: length))
                lines.source.append(lineRange)
                let exact = length <= lineRange.length && sourceNS.substring(with: lineRange).hasSuffix(text)
                lines.exactStart.append(exact ? lineRange.location + lineRange.length - length : nil)
            }
            return lines
        }

        /// What drawing one HTML block keeps track of: its open elements, the paragraph being drawn and the
        /// whitespace waiting to be collapsed.
        private struct HTMLState {
            var elements: [(name: String, align: NSTextAlignment?, style: Style)] = []
            var paragraphOpen = false
            var paragraphSource: NSRange?
            var lineHasText = false
            var pendingSpace = false
        }

        /// Draws an HTML block whose every tag is one rendered Markdown knows: block elements become paragraphs,
        /// inline ones style their text, whitespace collapses as a browser collapses it, and text maps back to
        /// its source (exactly where the drawn text is the source text).
        private mutating func drawHTML(_ html: HTMLBlock, tokens: [MarkdownHTML.Token]) {
            let raw = html.rawHTML as NSString
            let units = Array(html.rawHTML.utf16)
            let lines = htmlLines(html)
            let saved = style
            var state = HTMLState()
            for token in tokens {
                switch token {
                case .start(let name, let attributes, let range):
                    if MarkdownHTML.blockTags.contains(name) {
                        closeHTMLParagraph(&state)
                        state.elements.append((name, Self.alignment(attributes["align"]), style))
                        applyHTMLStyle(name, attributes: attributes)
                    } else if name == "br" {
                        guard state.paragraphOpen else { continue }
                        appendGenerated(MarkdownRenderer.lineSeparator)
                        state.lineHasText = false
                        state.pendingSpace = false
                    } else if name == "img" {
                        beginHTMLContent(&state)
                        let source = lines.source(of: range)
                        state.paragraphSource = Self.union(state.paragraphSource, source?.0)
                        appendHTMLPicture(attributes, source: source?.0)
                        state.lineHasText = true
                    } else if !MarkdownHTML.voidTags.contains(name) {
                        state.elements.append((name, nil, style))
                        applyHTMLStyle(name, attributes: attributes)
                    }
                case .end(let name, _):
                    guard let index = state.elements.lastIndex(where: { $0.name == name }) else { continue }
                    if MarkdownHTML.blockTags.contains(name) { closeHTMLParagraph(&state) }
                    style = state.elements[index].style
                    state.elements.removeSubrange(index...)
                case .text(let range):
                    appendHTMLText(range, raw: raw, units: units, lines: lines, state: &state)
                case .comment, .other:
                    continue
                }
            }
            closeHTMLParagraph(&state)
            style = saved
        }

        private static func alignment(_ value: String?) -> NSTextAlignment? {
            switch value?.lowercased() {
            case "center"?: .center
            case "right"?: .right
            case "left"?: .left
            default: nil
            }
        }

        private static func union(_ a: NSRange?, _ b: NSRange?) -> NSRange? {
            guard let a else { return b }
            guard let b else { return a }
            return NSUnionRange(a, b)
        }

        /// Starts a paragraph for the next drawn content of an HTML block, styled by the elements it sits in.
        private mutating func openHTMLParagraph(_ state: inout HTMLState) {
            guard !state.paragraphOpen else { return }
            let level = state.elements.last { $0.name.count == 2 && $0.name.hasPrefix("h") }.flatMap { Int($0.name.dropFirst()) }
            alignment = state.elements.last { $0.align != nil }?.align ?? .natural
            openBlock(level.map { .heading(level: $0) } ?? .plain)
            state.paragraphOpen = true
            state.paragraphSource = nil
            state.lineHasText = false
            state.pendingSpace = false
            // A details summary is always drawn open.
            if state.elements.contains(where: { $0.name == "summary" }) { appendGenerated("▾ ") }
        }

        /// Before drawn content: its paragraph, and the space collapsed whitespace left (never at a line's start).
        private mutating func beginHTMLContent(_ state: inout HTMLState) {
            openHTMLParagraph(&state)
            if state.pendingSpace, state.lineHasText { appendGenerated(" ") }
            state.pendingSpace = false
        }

        private mutating func closeHTMLParagraph(_ state: inout HTMLState) {
            guard state.paragraphOpen else { return }
            endBlock(source: state.paragraphSource)
            alignment = .natural
            state.paragraphOpen = false
        }

        /// A text run of an HTML block: whitespace runs collapse to one space (none at a line's start), entities
        /// decode, and each stretch of text that is its own source maps exactly.
        private mutating func appendHTMLText(_ range: NSRange, raw: NSString, units: [UInt16], lines: HTMLLines, state: inout HTMLState) {
            var runStart: Int?
            func emit(_ text: String, _ rawRange: NSRange, exact: Bool, state: inout HTMLState) {
                beginHTMLContent(&state)
                let source = lines.source(of: rawRange)
                append(text, source: source?.0, exact: exact && source?.1 == true)
                state.paragraphSource = Self.union(state.paragraphSource, source?.0)
                state.lineHasText = true
            }
            func flush(to end: Int, state: inout HTMLState) {
                guard let start = runStart, end > start else { return }
                let rawRange = NSRange(location: start, length: end - start)
                emit(raw.substring(with: rawRange), rawRange, exact: true, state: &state)
                runStart = nil
            }
            let end = range.location + range.length
            var i = range.location
            while i < end {
                if HTMLTextProjection.isSpace(units[i]) {
                    var j = i
                    while j < end, HTMLTextProjection.isSpace(units[j]) { j += 1 }
                    // A single space between words stays in the run, so a sentence maps as one stretch.
                    if units[i] == 32, j == i + 1, runStart != nil, j < end {
                        i = j
                        continue
                    }
                    flush(to: i, state: &state)
                    state.pendingSpace = true
                    i = j
                } else if units[i] == 38, let entity = HTMLTextProjection.entity(in: units, at: i) {
                    flush(to: i, state: &state)
                    emit(entity.text, NSRange(location: i, length: entity.length), exact: false, state: &state)
                    i += entity.length
                } else {
                    if runStart == nil { runStart = i }
                    i += 1
                }
            }
            flush(to: end, state: &state)
        }

        /// The style an HTML element gives what it contains.
        private mutating func applyHTMLStyle(_ name: String, attributes: [String: String]) {
            switch name {
            case "b", "strong", "summary":
                style.bold = true
            case "i", "em":
                style.italic = true
            case "code":
                style.monospaced = true
                style.codeBackground = true
            case "a":
                if let href = attributes["href"] { style.link = MarkdownHTML.decoded(href) }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(name.dropFirst()) ?? 1
                style.font = MarkdownRenderer.headingFont(level: level)
                if level >= 6 { style.color = .secondaryLabelColor }
            default:
                break
            }
        }

        /// An `<img>`, sized by its `width` and `height` when it gives them.
        private mutating func appendHTMLPicture(_ attributes: [String: String], source range: NSRange?) {
            appendPicture(source: attributes["src"], alt: MarkdownHTML.decoded(attributes["alt"] ?? ""), range: range,
                          width: MarkdownHTML.pixels(attributes["width"]), height: MarkdownHTML.pixels(attributes["height"]))
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
            appendPicture(source: image.source, alt: alt, range: exactness(image, rendered: alt).0)
        }

        /// A picture embed (`![]()`, `<img>`), mapped to the whole embed. The picture itself when this Mac or the
        /// document's host has it, at `width` × `height` when the embed gives them; otherwise its alt text.
        private mutating func appendPicture(source: String?, alt: String, range: NSRange?, width: CGFloat? = nil, height: CGFloat? = nil) {
            if let picture = source.flatMap({ images[$0] }) ?? MarkdownImageLoader.image(source: source, baseURL: baseURL) {
                let attachment = FittedImageAttachment()
                attachment.image = picture
                let size = picture.size
                switch size.width > 0 && size.height > 0 ? (width, height) : (nil, nil) {
                case let (width?, height?): attachment.naturalSize = CGSize(width: width, height: height)
                case let (width?, nil): attachment.naturalSize = CGSize(width: width, height: width * size.height / size.width)
                case let (nil, height?): attachment.naturalSize = CGSize(width: height * size.width / size.height, height: height)
                case (nil, nil): attachment.naturalSize = size
                }
                // What a region note on the picture needs: which picture, which embed of it, and its own pixels.
                if let source {
                    attachment.source = source
                    attachment.occurrence = occurrence(of: source, at: range)
                }
                attachment.pixelSize = FittedImageAttachment.pixelSize(of: picture)
                append("\u{FFFC}", source: range, exact: false, extra: [.attachment: attachment])
                return
            }
            // A relative picture this Mac doesn't have: its document's host may (an attachment, a remote file).
            if baseURL == nil, let source, !source.isEmpty, URL(string: source)?.scheme == nil, !unresolvedImages.contains(source) {
                unresolvedImages.append(source)
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
            append(alt.isEmpty ? (source ?? "image") : alt, source: range, exact: false)
            style = saved
        }

        /// Which embed of `source` the one at `range` is, as `EmbedScanner` numbers them.
        private mutating func occurrence(of source: String, at range: NSRange?) -> Int {
            guard let range else {
                defer { imageOccurrences[source, default: 0] += 1 }
                return imageOccurrences[source, default: 0]
            }
            if embedLocations == nil {
                embedLocations = Dictionary(grouping: EmbedScanner.embeds(in: self.source), by: \.source).mapValues { $0.map(\.range.location) }
            }
            let locations = embedLocations?[source] ?? []
            // Sorted, as the scanner reads in document order: count those before this embed.
            var low = 0, high = locations.count
            while low < high {
                let mid = (low + high) / 2
                if locations[mid] < range.location { low = mid + 1 } else { high = mid }
            }
            return low
        }

        /// Inline HTML arrives one tag per node, so an element's start and end tags are siblings. A known element
        /// whose end tag follows among them styles what lies between; anything else stays grey source.
        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
            let (range, exact) = exactness(inlineHTML, rendered: inlineHTML.rawHTML)
            let tokens = MarkdownHTML.tokens(inlineHTML.rawHTML)
            switch tokens.count == 1 ? tokens[0] : nil {
            case .comment?:
                return
            case .start(let name, let attributes, _)? where MarkdownHTML.inlineTags.contains(name):
                switch name {
                case "br":
                    appendGenerated(MarkdownRenderer.lineSeparator)
                    return
                case "img":
                    appendHTMLPicture(attributes, source: range)
                    return
                case "source" where inlineElements.contains(where: { $0.name == "picture" }):
                    return
                default:
                    if !MarkdownHTML.voidTags.contains(name), let close = closingTag(of: inlineHTML, name: name) {
                        inlineElements.append((name, close, style))
                        applyHTMLStyle(name, attributes: attributes)
                        return
                    }
                }
            case .end(let name, _)?:
                if let range, let index = inlineElements.lastIndex(where: { $0.name == name && $0.close == range }) {
                    style = inlineElements[index].style
                    // Elements still open inside it end here too (`<i><b>x</i></b>`); their own end tags draw nothing.
                    endedInlineTags.formUnion(inlineElements[(index + 1)...].map(\.close))
                    inlineElements.removeSubrange(index...)
                    return
                }
                if let range, endedInlineTags.remove(range) != nil { return }
            default:
                break
            }
            let saved = style
            style.monospaced = true
            style.color = .secondaryLabelColor
            append(inlineHTML.rawHTML, source: range, exact: exact)
            style = saved
        }

        /// The source range of the sibling that ends the element `node` starts, if one does. Start and end tags are
        /// paired in one pass over the parent's children, the first time any of them asks.
        private mutating func closingTag(of node: InlineHTML, name: String) -> NSRange? {
            guard let parent = node.parent else { return nil }
            var path: [Int] = []
            var ancestor: (any Markup)? = parent
            while let current = ancestor {
                path.append(current.indexInParent)
                ancestor = current.parent
            }
            if inlineClosings[path] == nil {
                var closings: [Int: NSRange] = [:]
                var open: [String: [Int]] = [:]
                for (index, child) in parent.children.enumerated() {
                    guard let html = child as? InlineHTML else { continue }
                    let tokens = MarkdownHTML.tokens(html.rawHTML)
                    guard tokens.count == 1 else { continue }
                    switch tokens[0] {
                    case .start(let name, _, _) where !MarkdownHTML.voidTags.contains(name):
                        open[name, default: []].append(index)
                    case .end(let name, _):
                        if let start = open[name]?.popLast(), let range = html.range { closings[start] = table.nsRange(range) }
                    default:
                        continue
                    }
                }
                inlineClosings[path] = closings
            }
            return inlineClosings[path]?[node.indexInParent]
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
    /// The picture as the Markdown names it, and which embed of it this is (0 for the first).
    var source: String?
    var occurrence = 0
    /// The picture's own pixels, the space region notes are kept in.
    var pixelSize = CGSize.zero

    /// The largest bitmap among the image's representations; its point size when it has none (a PDF or SVG).
    static func pixelSize(of image: NSImage) -> CGSize {
        let bitmap = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.max { $0.width < $1.width }
        if let bitmap, bitmap.width > 0, bitmap.height > 0 { return bitmap }
        return image.size
    }
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
