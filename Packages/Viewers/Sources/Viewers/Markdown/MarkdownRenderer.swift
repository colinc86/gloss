import AppKit
import Core
import Foundation
import Markdown
import Synchronization

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
        /// Mermaid blocks with no drawing yet, by their source: the controller draws them and renders again.
        public var unresolvedDiagrams: [String] = []
        /// Each drawn diagram's source, by its occurrence, so a region note's crop reads the right PNG.
        public var diagramSources: [Int: String] = [:]
        /// Tables are laid out for the column's width, so a page that changes width renders again; nothing else
        /// needs to.
        public var hasTables = false
        /// The text column's width the page was laid out for.
        public var columnWidth: CGFloat = 0
        /// How far the text column is set in from the container's left edge (and its right edge from the
        /// container's): room for tables wider than the column to scroll into. Zero unless one is.
        public var inset: CGFloat = 0
    }

    /// The longest a line of text gets: about 90 characters of body text, a comfortable line to read. Text keeps
    /// to it however wide the window is; a table wider than it scrolls sideways.
    public static func proseWidth(readingSize: CGFloat = Theme.readingFontSize) -> CGFloat {
        (readingSize * 42).rounded()
    }

    public static let sourceSpanKey = NSAttributedString.Key("gloss.sourceSpan")
    nonisolated public static let blockKey = NSAttributedString.Key("gloss.markdownBlock")
    /// Every character of a laid-out table carries its `TableCellMark`, so a copy can put the cells back in order.
    nonisolated public static let tableCellKey = NSAttributedString.Key("gloss.tableCell")

    /// `baseURL` is the document's folder on this Mac; relative images resolve against it. `images` are pictures
    /// already fetched from a document's own host (an ssh host, a ticket's attachments), by source as written.
    /// Anything else shows as a placeholder. Under `reduceMotion` animated pictures hold still, and a `<picture>`
    /// draws a source meant for reduced motion. `diagrams` are Mermaid blocks already drawn (or refused), by their
    /// source; any other Mermaid block shows as code until it is.
    /// Text and tables fit `columnWidth` (the reading column's width; `proseWidth` when it is not known yet), and
    /// text is `readingSize` points (`Theme.readingFontSize` by default). A table that can't fit without breaking
    /// its words keeps its width and scrolls sideways within the column (`MarkdownTableScroll`).
    public static func render(_ source: String, baseURL: URL? = nil, images: [String: NSImage] = [:], diagrams: [String: MermaidRenderer.Result] = [:],
                              reduceMotion: Bool = false, codeTheme: CodeTheme? = nil, codeAppearance: NSAppearance.Name? = nil,
                              columnWidth: CGFloat? = nil, readingSize: CGFloat? = nil) -> Output {
        readingFontSize = readingSize ?? Theme.readingFontSize
        let document = Document(parsing: source, options: [.disableSmartOpts])
        let column = max(1, columnWidth ?? proseWidth(readingSize: readingFontSize))
        func walk(inset: CGFloat) -> Walker {
            var walker = Walker(source: source, table: SourceLineTable(source), baseURL: baseURL)
            walker.columnWidth = column
            walker.setInset(inset)
            walker.images = images
            walker.diagrams = diagrams
            walker.reduceMotion = reduceMotion
            let appearance = codeAppearance.flatMap(NSAppearance.init(named:)) ?? Theme.effectiveAppearance
            walker.theme = codeTheme ?? ActiveCodeTheme.theme(for: appearance)
            walker.dynamicTheme = codeTheme == nil
            walker.visit(document)
            walker.finish()
            return walker
        }
        var walker = walk(inset: 0)
        // A table wider than the column lays its rows out whole, past the column's right edge, and scrolls by moving
        // them left, so the container has room either side of the column for the widest one. How much is known
        // only once the tables are measured: lay the page out again with it.
        if walker.overflow > 0 { walker = walk(inset: walker.overflow.rounded(.up)) }
        var output = Output(text: walker.output, map: RenderedSourceMap(spans: walker.spans, blocks: walker.blocks))
        output.unresolvedImages = walker.unresolvedImages
        output.unresolvedDiagrams = walker.unresolvedDiagrams
        output.diagramSources = walker.diagramSources
        output.hasTables = walker.tableCount > 0
        output.columnWidth = column
        output.inset = walker.inset
        return output
    }

    /// A fence whose language is Mermaid, read as `EmbedScanner` reads it.
    nonisolated static func isMermaid(fence info: String?) -> Bool {
        info?.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first?.lowercased() == "mermaid"
    }

    // MARK: Styles

    /// The body size of the render under way; set by `render` on the main thread before anything reads it.
    nonisolated(unsafe) static var readingFontSize: CGFloat = 14
    nonisolated static var bodyFont: NSFont { NSFont.systemFont(ofSize: readingFontSize) }
    nonisolated static var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) }

    /// Heading sizes for 14 pt text, scaled with the reading size.
    nonisolated static func headingFont(level: Int) -> NSFont {
        let sizes: [CGFloat] = [28, 22, 18, 16, 14, 13]
        return NSFont.systemFont(ofSize: (sizes[max(0, min(5, level - 1))] * readingFontSize / 14).rounded(), weight: .semibold)
    }

    /// Inner padding of code blocks and table cells, shared with `MarkdownLayoutFragment`.
    nonisolated static let codePadding: CGFloat = 14
    nonisolated static let codeVerticalPadding: CGFloat = 10
    nonisolated static let tableRowPadding: CGFloat = 6
    nonisolated static let tableCellPadding: CGFloat = 12
    /// Line separator between code lines: one paragraph per code block, so its fill is one shape.
    nonisolated static let lineSeparator = "\u{2028}"
    /// Code blocks longer than this are shown without syntax colours.
    static let highlightLimit = 20_000

    /// Code blocks' highlight captures by grammar and code. A document renders again 150 ms after each edit and
    /// whenever a picture or diagram arrives, and each render parsed every code block anew: half of a 360 KB
    /// document's two-second render. An unchanged block now reuses its captures.
    nonisolated static let highlightCache = Mutex(HighlightCache())

    nonisolated struct HighlightCache: ~Copyable {
        struct Key: Hashable { let grammar: String; let code: String }
        private var entries: [Key: [HighlightCapture]] = [:]
        private var size = 0
        /// Code held at most, in UTF-16 units; past it the cache starts over rather than tracking use.
        static let capacity = 4_000_000

        func captures(for key: Key) -> [HighlightCapture]? { entries[key] }

        mutating func store(_ captures: [HighlightCapture], for key: Key) {
            let length = key.code.utf16.count
            if size + length > Self.capacity {
                entries = [:]
                size = 0
            }
            entries[key] = captures
            size += length
        }

        var count: Int { entries.count }
    }

    /// The captures for `code` in `grammar`, from the cache or a fresh parse; nil when the grammar can't be loaded.
    static func highlightCaptures(grammar: String, code: String) -> [HighlightCapture]? {
        let key = HighlightCache.Key(grammar: grammar, code: code)
        if let cached = highlightCache.withLock({ $0.captures(for: key) }) { return cached }
        guard let captures = Highlighter(languageName: grammar, text: code)?.captures else { return nil }
        highlightCache.withLock { $0.store(captures, for: key) }
        return captures
    }

    struct Style {
        var font: NSFont = MarkdownRenderer.bodyFont
        var color: NSColor = .textColor
        var bold = false
        var italic = false
        var monospaced = false
        var codeBackground = false
        var codeTheme: CodeTheme?
        var blockCode = false
        var strikethrough = false
        var underline = false
        /// Superscript (1) or subscript (-1): smaller, off the baseline.
        var baseline = 0
        var link: String?

        var attributes: [NSAttributedString.Key: Any] {
            var font = self.font
            if monospaced {
                let size = (self.font.pointSize * 0.9).rounded()
                if let theme = codeTheme {
                    if blockCode { font = theme.font.resolved(defaultSize: theme.id == "gloss" ? size : Theme.editorFontSize) }
                    else { var family = theme.font; family.size = nil; font = family.resolved(defaultSize: size) }
                } else { font = MarkdownRenderer.codeFont.withSize(size) }
            }
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            let size = font.pointSize
            if baseline != 0 { font = font.withSize((size * 0.75).rounded()) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if baseline != 0 { attributes[.baselineOffset] = baseline > 0 ? (size * 0.35).rounded() : -(size * 0.15).rounded() }
            if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                // The real destination on hover: link text can say anything.
                attributes[.toolTip] = link
            }
            if codeBackground { attributes[.backgroundColor] = NSColor.quaternarySystemFill }
            return attributes
        }
    }

    nonisolated private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The addresses GitHub links on its own in `text` (UTF-16 ranges) with where each goes: `http(s)://…` as written,
    /// `www.…` over https, an e-mail address as `mailto:`. A bare `example.com` is left as text, as GitHub leaves it.
    nonisolated static func autolinks(in text: String) -> [(range: NSRange, link: String)] {
        guard let detector = linkDetector, text.contains(where: { $0 == "." || $0 == "@" }) else { return [] }
        let ns = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let written = ns.substring(with: match.range)
            let lowered = written.lowercased()
            if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return (match.range, written) }
            if lowered.hasPrefix("www.") { return (match.range, "https://" + written) }
            if match.url?.scheme == "mailto", written.contains("@"), !written.contains(":") { return (match.range, "mailto:" + written) }
            return nil
        }
    }

    /// Fenced-code info string to a grammar name: `swift`, `sh`, `ts`, `py` and friends.
    nonisolated static func grammarName(forFence info: String?) -> String? { GrammarCatalog.grammarName(forFence: info) }

    // MARK: Walker

    struct Walker: MarkupWalker {
        let source: String
        let table: SourceLineTable
        let sourceNS: NSString
        let baseURL: URL?
        var images: [String: NSImage] = [:]
        var diagrams: [String: MermaidRenderer.Result] = [:]
        var reduceMotion = false
        var unresolvedImages: [String] = []
        var unresolvedDiagrams: [String] = []
        var diagramSources: [Int: String] = [:]
        /// The reading column's width, which text and tables fit.
        var columnWidth: CGFloat = 588
        /// How far the column is set in from either side of the container, so tables wider than it have room to
        /// scroll; zero unless the page has one.
        private(set) var inset: CGFloat = 0
        /// How far the widest table runs past the column's right edge.
        private(set) var overflow: CGFloat = 0
        /// Tables laid out so far; cells are numbered across the document (`SourceSpan.cell`).
        var tableCount = 0
        private var cellCount = 0
        /// Where each picture is embedded, by `EmbedScanner` (read on the first picture), so a repeated one is told
        /// apart exactly as the re-anchorer tells it apart.
        private var embedLocations: [String: [Int]]?
        /// Pictures with no source range, counted as they come.
        var imageOccurrences: [String: Int] = [:]
        /// The `<source>` an open `<picture>` draws instead of its `<img>`, and that tag's source range.
        private var pictureChoice: (source: String, range: NSRange?)?
        var output = NSMutableAttributedString()
        var spans: [SourceSpan] = []
        var blocks: [SourceSpan] = []
        private var style = Style()
        var theme = CodeTheme.gloss { didSet { style.codeTheme = theme } }
        var dynamicTheme = true
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
        /// Left edge of each open quote's bar, the block count when it opened, and its kind when it is an alert.
        private var quotes: [(x: CGFloat, openedAt: Int, alert: MarkdownAlert?)] = []
        /// An alert's `[!NOTE]` line is being read: its text becomes the alert's title, its break a line break.
        private var pendingAlert: MarkdownAlert?
        private var alertTitled = false

        init(source: String, table: SourceLineTable, baseURL: URL?) {
            self.source = source
            self.table = table
            self.baseURL = baseURL
            sourceNS = source as NSString
        }

        // MARK: Emission

        private mutating func append(_ string: String, source: NSRange?, exact: Bool, extra: [NSAttributedString.Key: Any] = [:]) {
            guard !string.isEmpty else { return }
            var runStyle = style
            if kind == .codeBlock {
                runStyle.blockCode = true
                runStyle.color = theme.id == "gloss" ? .textColor : (dynamicTheme ? ActiveCodeTheme.editorColor(\.foreground) : theme.editor.foreground.nsColor)
            }
            var attributes = runStyle.attributes.merging(extra) { _, new in new }
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
            paragraph.tailIndent = -inset
            switch kind {
            case .codeBlock:
                paragraph.lineHeightMultiple = CGFloat(theme.font.lineSpacing ?? 1.15)
                paragraph.tailIndent = -inset - MarkdownRenderer.codePadding
                paragraph.paragraphSpacingBefore = gap + MarkdownRenderer.codeVerticalPadding
                paragraph.paragraphSpacing = MarkdownRenderer.codeVerticalPadding
            case .heading:
                paragraph.lineHeightMultiple = 1.15
            case .rule:
                paragraph.lineHeightMultiple = 1
            case .tableRow:
                paragraph.lineHeightMultiple = 1.2
            case .plain:
                paragraph.lineHeightMultiple = 1.4
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
                gap = level == 1 ? 32 : level == 2 ? 28 : 22
            } else if case .heading(let level) = lastBlock {
                gap = level <= 2 ? 16 : 10
            } else {
                gap = kind == .rule ? 18 : 14
            }
            // Spacing written for 14 pt text grows and shrinks with it.
            gap = (gap * MarkdownRenderer.readingFontSize / 14).rounded()
            let bars = quotes.map { MarkdownBlockDecoration.QuoteBar(x: $0.x, continuesFromAbove: blockCount > $0.openedAt, alert: $0.alert) }
            decoration = MarkdownBlockDecoration(kind: kind, leading: indent, quoteBars: bars)
            if kind == .codeBlock {
                decoration = decoration.withCodeColors(background: theme.id == "gloss" ? MarkdownLayoutFragment.fill : (dynamicTheme ? ActiveCodeTheme.editorColor(\.codeBlockBackground) : theme.editor.codeBlockBackground.nsColor),
                                                        foreground: theme.id == "gloss" ? nil : (dynamicTheme ? ActiveCodeTheme.editorColor(\.foreground) : theme.editor.foreground.nsColor))
            }
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

        mutating func setInset(_ inset: CGFloat) {
            self.inset = inset
            indent = inset
        }

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
            // A `[!NOTE]` alone in its paragraph: the title is the whole paragraph.
            pendingAlert = nil
            endBlock(paragraph)
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            openContainer()
            let saved = (style, indent)
            let alert = MarkdownAlert(quote: blockQuote)
            // An alert reads as body text, as on GitHub; a plain quote is set back.
            style.color = alert == nil ? .secondaryLabelColor : .textColor
            quotes.append((x: indent, openedAt: blockCount, alert: alert))
            indent += 18
            pendingAlert = alert
            alertTitled = false
            for child in blockQuote.children { visit(child) }
            quotes.removeLast()
            style = saved.0
            indent = saved.1
            endBlock(blockQuote)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            guard MarkdownRenderer.isMermaid(fence: codeBlock.language) else { return drawCode(codeBlock) }
            switch diagrams[codeBlock.code] {
            case .diagram(let image, _)?:
                appendDiagram(image, code: codeBlock.code, range: codeBlock.range.map { table.nsRange($0) })
                endBlock(codeBlock)
            case .failed(let reason)?:
                drawCode(codeBlock)
                appendDiagramFailure(reason)
            case .unavailable?, nil:
                if !unresolvedDiagrams.contains(codeBlock.code) { unresolvedDiagrams.append(codeBlock.code) }
                drawCode(codeBlock)
            }
        }

        /// A Mermaid diagram drawn as a picture mapped to its whole fenced block, so a note on it is a note on an
        /// embedded picture whose source is `EmbedScanner.mermaidSource`.
        private mutating func appendDiagram(_ image: NSImage, code: String, range: NSRange?) {
            openBlock()
            let attachment = FittedImageAttachment()
            attachment.image = image
            attachment.naturalSize = image.size
            attachment.pixelSize = FittedImageAttachment.pixelSize(of: image)
            // Notes only on a diagram `EmbedScanner` sees where it is drawn, so a fence it reads otherwise never
            // takes another diagram's number.
            if let range, scannedEmbed(of: EmbedScanner.mermaidSource, at: range.location) {
                attachment.source = EmbedScanner.mermaidSource
                attachment.occurrence = occurrence(of: EmbedScanner.mermaidSource, at: range)
                diagramSources[attachment.occurrence] = code
            }
            append("\u{FFFC}", source: range, exact: false, extra: [.attachment: attachment])
        }

        /// One line under a diagram Mermaid refused, saying why.
        private mutating func appendDiagramFailure(_ reason: String) {
            openBlock(gapOverride: 6)
            let saved = style
            style.color = .secondaryLabelColor
            style.font = NSFont.systemFont(ofSize: 12)
            if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Diagram error")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])) {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                appendGenerated("\u{FFFC}\u{00A0}", extra: [.attachment: attachment])
            }
            appendGenerated("Mermaid couldn't draw this diagram: \(reason)")
            style = saved
            endBlock(source: nil)
        }

        private mutating func drawCode(_ codeBlock: CodeBlock) {
            openBlock(.codeBlock)
            decoration = decoration.labelled(MarkdownBlockDecoration.languageName(codeBlock.language))
            decoration = decoration.withCodeColors(background: theme.id == "gloss" ? MarkdownLayoutFragment.fill : (dynamicTheme ? ActiveCodeTheme.editorColor(\.codeBlockBackground) : theme.editor.codeBlockBackground.nsColor),
                                                    foreground: theme.id == "gloss" ? nil : (dynamicTheme ? ActiveCodeTheme.editorColor(\.foreground) : theme.editor.foreground.nsColor))
            let saved = style
            style.monospaced = true
            style.blockCode = true
            style.color = theme.id == "gloss" ? .textColor : (dynamicTheme ? ActiveCodeTheme.editorColor(\.foreground) : theme.editor.foreground.nsColor)
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
                  let captures = MarkdownRenderer.highlightCaptures(grammar: name, code: code) else { return }
            let renderedLength = output.length - renderedStart
            for capture in captures {
                let token = theme.style(forCapture: capture.name)
                let color = dynamicTheme && theme.id != "gloss" ? ActiveCodeTheme.color(forCapture: capture.name) : token?.color?.nsColor
                let location = capture.range.location
                let end = min(location + capture.range.length, renderedLength)
                guard location < end else { continue }
                let range = NSRange(location: renderedStart + location,length: end - location)
                if let color { output.addAttribute(.foregroundColor,value: color,range: range) }
                if let token, token.bold || token.italic,
                   let base = output.attribute(.font,at: range.location,effectiveRange: nil) as? NSFont {
                    output.addAttribute(.font,value: token.font(from: base),range: range)
                }
            }
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            let tokens = MarkdownHTML.tokens(html.rawHTML)
            guard MarkdownHTML.isDrawable(tokens, in: html.rawHTML) else {
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

        /// An open element of an HTML block, and the layout to restore when it ends.
        private struct HTMLElement {
            var name: String
            var align: NSTextAlignment?
            var style: Style
            var indent: CGFloat
            var quotes: Int
            var lists: Int
        }

        /// A table drawn from HTML: its rows and cells so far, laid out as a Markdown table is when it ends.
        private struct HTMLTable {
            var rowRanges: [NSRange] = []
            var cellRanges: [[NSRange]] = []
            var headers: [Bool] = []
            var alignments: [Table.ColumnAlignment?] = []
            var leadingTab = false
            var source: NSRange?
            /// The open row: where it starts in the output, its cells, and whether it is a header row (in a
            /// `thead`, or `th` cells only).
            var rowStart: Int?
            var rowCells: [NSRange] = []
            var rowInHead = false
            var rowAllHeaders = true
            /// The open cell.
            var cellStart: Int?
            var cellSource: NSRange?
            var inHead = false
        }

        /// What drawing one HTML block keeps track of: its open elements, the paragraph or table being drawn and the
        /// whitespace waiting to be collapsed.
        private struct HTMLState {
            var elements: [HTMLElement] = []
            var paragraphOpen = false
            var paragraphSource: NSRange?
            var lineHasText = false
            var pendingSpace = false
            var table: HTMLTable?
            /// Inside `<pre>` whitespace is kept; line breaks wait until text follows them, so the one after `<pre>`
            /// and the one before `</pre>` draw nothing, as in a browser.
            var preformatted = false
            var pendingLines = 0
            var preStart = false
        }

        /// Draws an HTML block whose every tag is one rendered Markdown knows: block elements become paragraphs,
        /// lists, quotes, code blocks, rules and tables drawn as their Markdown forms are, inline ones style their
        /// text, whitespace collapses as a browser collapses it, and text maps back to its source (exactly where the
        /// drawn text is the source text).
        private mutating func drawHTML(_ html: HTMLBlock, tokens: [MarkdownHTML.Token]) {
            let raw = html.rawHTML as NSString
            let units = Array(html.rawHTML.utf16)
            let lines = htmlLines(html)
            let saved = style
            var state = HTMLState()
            for (offset, token) in tokens.enumerated() {
                switch token {
                case .start(let name, let attributes, let range):
                    startHTMLElement(name, attributes: attributes, range: range, tokens: tokens, at: offset, lines: lines, state: &state)
                case .end(let name, _):
                    guard let index = state.elements.lastIndex(where: { $0.name == name }) else { continue }
                    endHTMLElements(from: index, state: &state)
                case .text(let range):
                    if state.preformatted {
                        appendPreText(range, raw: raw, units: units, lines: lines, state: &state)
                    } else if state.table == nil || state.table?.cellStart != nil {
                        appendHTMLText(range, raw: raw, units: units, lines: lines, state: &state)
                    }
                case .comment, .other:
                    continue
                }
            }
            endHTMLElements(from: 0, state: &state)
            closeHTMLParagraph(&state)
            style = saved
        }

        private mutating func startHTMLElement(_ name: String, attributes: [String: String], range: NSRange, tokens: [MarkdownHTML.Token], at offset: Int,
                                               lines: HTMLLines, state: inout HTMLState) {
            // End tags a browser implies.
            switch name {
            case "td", "th": endHTMLElements(["td", "th"], within: ["table", "tr"], state: &state)
            case "tr": endHTMLElements(["tr", "td", "th"], within: ["table", "thead", "tbody", "tfoot"], state: &state)
            case "thead", "tbody", "tfoot": endHTMLElements(MarkdownHTML.tableParts, within: ["table"], state: &state)
            case "li": endHTMLElements(["li"], within: ["ul", "ol"], state: &state)
            case "dt", "dd": endHTMLElements(["dt", "dd"], within: ["dl"], state: &state)
            default: break
            }
            switch name {
            case "br":
                if state.table != nil {
                    state.pendingSpace = true
                } else if state.preformatted {
                    state.pendingLines += 1
                } else if state.paragraphOpen {
                    appendGenerated(MarkdownRenderer.lineSeparator)
                    state.lineHasText = false
                    state.pendingSpace = false
                }
                return
            case "img":
                beginHTMLContent(&state)
                if state.preformatted {
                    // Line breaks in a `<pre>` wait for what follows them, a picture included.
                    for _ in 0..<state.pendingLines { appendGenerated(MarkdownRenderer.lineSeparator) }
                    state.pendingLines = 0
                    state.preStart = false
                }
                let source = lines.source(of: range)
                let inPicture = state.elements.contains { $0.name == "picture" }
                noteHTMLSource(source?.0, state: &state)
                appendHTMLPicture(attributes, source: source?.0, inPicture: inPicture)
                state.lineHasText = true
                return
            case "hr":
                closeHTMLParagraph(&state)
                openBlock(.rule)
                appendGenerated("\u{00A0}", extra: [.font: NSFont.systemFont(ofSize: 6)])
                endBlock(source: lines.source(of: range)?.0)
                return
            case "source":
                if state.elements.contains(where: { $0.name == "picture" }) { choosePictureSource(attributes, range: lines.source(of: range)?.0) }
                return
            default:
                break
            }
            if name == "picture" { pictureChoice = nil }
            if MarkdownHTML.blockTags.contains(name) { closeHTMLParagraph(&state) }
            state.elements.append(HTMLElement(name: name, align: Self.alignment(attributes["align"]), style: style, indent: indent,
                                              quotes: quotes.count, lists: listNumbers.count))
            switch name {
            case "blockquote":
                style.color = .secondaryLabelColor
                quotes.append((x: indent, openedAt: blockCount, alert: nil))
                indent += 18
            case "ul":
                listNumbers.append(nil)
                listMarkerWidths.append(20)
            case "ol":
                // CommonMark's own bound on a list's start, so counting on never overflows.
                let start = min(max(attributes["start"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1, 0), 999_999_999)
                let widest = "\(start + max(0, Self.listItemCount(tokens, after: offset) - 1))." as NSString
                listNumbers.append(start)
                listMarkerWidths.append(max(22, ceil(widest.size(withAttributes: [.font: MarkdownRenderer.bodyFont]).width) + 8))
            case "li":
                startListItem(checkbox: nil)
            case "dd":
                indent += 28
            case "pre":
                state.preformatted = true
                state.preStart = true
                state.pendingLines = 0
                style.monospaced = true
                style.font = MarkdownRenderer.bodyFont
            case "table":
                state.table = HTMLTable()
            case "thead":
                state.table?.inHead = true
            case "tr":
                beginHTMLRow(&state)
            case "td", "th":
                beginHTMLCell(header: name == "th", align: attributes["align"], state: &state)
            default:
                break
            }
            applyHTMLStyle(name, attributes: attributes, preformatted: state.preformatted)
        }

        /// Ends the open element named `names` nearest the top, if one is open inside the innermost `containers`.
        private mutating func endHTMLElements(_ names: Set<String>, within containers: Set<String>, state: inout HTMLState) {
            let boundary = state.elements.lastIndex { containers.contains($0.name) } ?? -1
            if let index = state.elements.indices.first(where: { $0 > boundary && names.contains(state.elements[$0].name) }) {
                endHTMLElements(from: index, state: &state)
            }
        }

        /// Ends the elements from `index` up, innermost first, restoring the layout each one changed.
        private mutating func endHTMLElements(from index: Int, state: inout HTMLState) {
            while state.elements.count > index {
                let element = state.elements.removeLast()
                if MarkdownHTML.blockTags.contains(element.name) { closeHTMLParagraph(&state) }
                switch element.name {
                case "li":
                    if finishListItem() { needsBlockSeparator = true }
                    lastBlock = .listItem
                case "pre":
                    state.preformatted = false
                    state.pendingLines = 0
                case "td", "th":
                    finishHTMLCell(&state)
                case "tr":
                    finishHTMLRow(&state)
                case "thead":
                    state.table?.inHead = false
                case "table":
                    finishHTMLTable(&state)
                default:
                    break
                }
                style = element.style
                indent = element.indent
                quotes.removeLast(quotes.count - min(quotes.count, element.quotes))
                listNumbers.removeLast(listNumbers.count - min(listNumbers.count, element.lists))
                listMarkerWidths.removeLast(listMarkerWidths.count - min(listMarkerWidths.count, element.lists))
            }
        }

        /// How many items the list whose start tag is at `offset` holds (not counting nested lists').
        private static func listItemCount(_ tokens: [MarkdownHTML.Token], after offset: Int) -> Int {
            var depth = 0
            var count = 0
            for token in tokens[(offset + 1)...] {
                switch token {
                case .start("ul", _, _), .start("ol", _, _): depth += 1
                case .end("ul", _), .end("ol", _):
                    if depth == 0 { return count }
                    depth -= 1
                case .start("li", _, _) where depth == 0: count += 1
                default: break
                }
            }
            return count
        }

        // MARK: HTML tables

        private mutating func beginHTMLRow(_ state: inout HTMLState) {
            guard state.table != nil else { return }
            finishHTMLRow(&state)
            if state.table?.rowRanges.isEmpty == true {
                openBlock(.tableRow(header: true, width: 0))
            } else {
                appendGenerated("\n")
            }
            let inHead = state.table?.inHead ?? false
            state.table?.rowStart = output.length
            state.table?.rowCells = []
            state.table?.rowInHead = inHead
            state.table?.rowAllHeaders = true
        }

        private mutating func beginHTMLCell(header: Bool, align: String?, state: inout HTMLState) {
            guard state.table != nil else { return }
            if state.table?.rowStart == nil { beginHTMLRow(&state) }
            guard var table = state.table else { return }
            let column = table.rowCells.count
            let alignment: Table.ColumnAlignment? = switch align?.lowercased() {
            case "center"?: .center
            case "right"?: .right
            case "left"?: .left
            default: nil
            }
            // As in a Markdown table, a right- or center-aligned first column starts its rows with a tab.
            if table.rowRanges.isEmpty, column == 0 { table.leadingTab = alignment == .right || alignment == .center }
            if table.rowRanges.isEmpty { table.alignments.append(alignment) }
            if !header { table.rowAllHeaders = false }
            state.table = table
            if column > 0 || table.leadingTab { appendGenerated("\t") }
            state.table?.cellStart = output.length
            state.table?.cellSource = nil
            state.lineHasText = false
            state.pendingSpace = false
        }

        private mutating func finishHTMLCell(_ state: inout HTMLState) {
            guard let table = state.table, let start = table.cellStart else { return }
            let range = NSRange(location: start, length: output.length - start)
            state.table?.rowCells.append(range)
            if let source = table.cellSource { blocks.append(SourceSpan(rendered: range, source: source, exact: false)) }
            state.table?.cellStart = nil
        }

        private mutating func finishHTMLRow(_ state: inout HTMLState) {
            finishHTMLCell(&state)
            guard let table = state.table, let start = table.rowStart else { return }
            state.table?.rowRanges.append(NSRange(location: start, length: output.length - start))
            state.table?.cellRanges.append(table.rowCells)
            state.table?.headers.append(table.rowInHead || (table.rowAllHeaders && !table.rowCells.isEmpty))
            state.table?.rowStart = nil
        }

        private mutating func finishHTMLTable(_ state: inout HTMLState) {
            finishHTMLRow(&state)
            guard let table = state.table else { return }
            state.table = nil
            guard !table.rowRanges.isEmpty else { return }
            layOutTable(rowRanges: table.rowRanges, cellRanges: table.cellRanges, alignments: table.alignments, leadingTab: table.leadingTab,
                        headers: table.headers)
            endBlock(source: table.source)
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
            openBlock(state.preformatted ? .codeBlock : level.map { .heading(level: $0) } ?? .plain)
            state.paragraphOpen = true
            state.paragraphSource = nil
            state.lineHasText = false
            state.pendingSpace = false
            // A details summary is always drawn open.
            if state.elements.contains(where: { $0.name == "summary" }) { appendGenerated("▾ ") }
        }

        /// Before drawn content: its paragraph (a table's cell needs none), and the space collapsed whitespace left
        /// (never at a line's start).
        private mutating func beginHTMLContent(_ state: inout HTMLState) {
            if state.table == nil { openHTMLParagraph(&state) }
            if state.pendingSpace, state.lineHasText { appendGenerated(" ") }
            state.pendingSpace = false
        }

        /// Where drawn content came from, for the paragraph's (or the cell's and table's) block span.
        private func noteHTMLSource(_ source: NSRange?, state: inout HTMLState) {
            if var table = state.table {
                table.cellSource = Self.union(table.cellSource, source)
                table.source = Self.union(table.source, source)
                state.table = table
            } else {
                state.paragraphSource = Self.union(state.paragraphSource, source)
            }
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
                noteHTMLSource(source?.0, state: &state)
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

        /// A text run inside `<pre>`: spaces kept, each line its own exact stretch, line breaks generated.
        private mutating func appendPreText(_ range: NSRange, raw: NSString, units: [UInt16], lines: HTMLLines, state: inout HTMLState) {
            var runStart: Int?
            func emit(_ text: String, _ rawRange: NSRange, exact: Bool, state: inout HTMLState) {
                openHTMLParagraph(&state)
                for _ in 0..<state.pendingLines { appendGenerated(MarkdownRenderer.lineSeparator) }
                state.pendingLines = 0
                state.preStart = false
                let source = lines.source(of: rawRange)
                append(text, source: source?.0, exact: exact && source?.1 == true)
                noteHTMLSource(source?.0, state: &state)
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
                if units[i] == 10 || units[i] == 13 {
                    flush(to: i, state: &state)
                    if state.preStart { state.preStart = false } else { state.pendingLines += 1 }
                    i += units[i] == 13 && i + 1 < end && units[i + 1] == 10 ? 2 : 1
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
        private mutating func applyHTMLStyle(_ name: String, attributes: [String: String], preformatted: Bool = false) {
            switch name {
            case "b", "strong", "summary", "th", "dt":
                style.bold = true
            case "i", "em":
                style.italic = true
            case "code", "kbd":
                style.monospaced = true
                // Code inside `<pre>` sits on the block's fill already.
                if !preformatted { style.codeBackground = true }
            case "a":
                if let href = attributes["href"] { style.link = MarkdownHTML.decoded(href) }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(name.dropFirst()) ?? 1
                style.font = MarkdownRenderer.headingFont(level: level)
                if level >= 6 { style.color = .secondaryLabelColor }
            case "s", "del", "strike":
                style.strikethrough = true
                style.color = .secondaryLabelColor
            case "ins", "u":
                style.underline = true
            case "sup":
                style.baseline = 1
            case "sub":
                style.baseline = -1
            default:
                break
            }
        }

        /// An `<img>`, sized by its `width` and `height` when it gives them. In a `<picture>` that chose a `<source>`,
        /// that source's picture is drawn in its place (mapped to the `<source>` tag, which `EmbedScanner` counts).
        private mutating func appendHTMLPicture(_ attributes: [String: String], source range: NSRange?, inPicture: Bool = false) {
            let chosen = inPicture ? pictureChoice : nil
            appendPicture(source: chosen?.source ?? attributes["src"], alt: MarkdownHTML.decoded(attributes["alt"] ?? ""), range: chosen.map(\.range) ?? range,
                          width: MarkdownHTML.pixels(attributes["width"]), height: MarkdownHTML.pixels(attributes["height"]))
        }

        /// A `<picture>`'s `<source>`: the first whose `media` holds is drawn instead of the `<img>`.
        private mutating func choosePictureSource(_ attributes: [String: String], range: NSRange?) {
            guard pictureChoice == nil, let srcset = attributes["srcset"], MarkdownHTML.mediaMatches(attributes["media"], reduceMotion: reduceMotion) else { return }
            let source = EmbedScanner.firstCandidate(inSrcset: srcset)
            if !source.isEmpty { pictureChoice = (source, range) }
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
            let savedIndent = indent
            let savedStyle = style
            openContainer()
            startListItem(checkbox: listItem.checkbox)
            for child in listItem.children { visit(child) }
            finishListItem()
            indent = savedIndent
            style = savedStyle
            endBlock(listItem)
            lastBlock = .listItem
        }

        /// Indents a list item and readies its marker, which joins whatever block the item starts with.
        private mutating func startListItem(checkbox: Checkbox?) {
            let marker: String
            if let number = listNumbers.last ?? nil {
                marker = "\(number)."
                listNumbers[listNumbers.count - 1] = number + 1
            } else {
                let bullets = ["•", "◦", "▪"]
                marker = bullets[max(0, listNumbers.count - 1) % bullets.count]
            }
            let markerIndent = indent
            indent += listMarkerWidths.last ?? 20
            firstLineIndent = markerIndent
            pendingGap = lastBlock == .listItem ? 4 : nil
            // An item that opens with a nested list (`- - a`) shows both markers on its first line.
            let outerMarker = pendingMarker?.text ?? ""
            if pendingMarker != nil { firstLineIndent = firstLineIndent.map { min($0, markerIndent) } }
            switch checkbox {
            case .checked?:
                pendingMarker = (outerMarker + "☑\t", [.foregroundColor: NSColor.controlAccentColor])
                style.color = .secondaryLabelColor
            case .unchecked?:
                pendingMarker = (outerMarker + "☐\t", [.foregroundColor: NSColor.secondaryLabelColor])
            case nil:
                pendingMarker = (outerMarker + marker + "\t", [.foregroundColor: NSColor.secondaryLabelColor])
            }
        }

        /// Ends a list item; an empty one still shows its marker. True when that marker was drawn here.
        @discardableResult
        private mutating func finishListItem() -> Bool {
            let empty = pendingMarker != nil
            if empty {
                openBlock()
                _ = blockRenderedStarts.popLast()
            }
            firstLineIndent = nil
            pendingGap = nil
            return empty
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

        /// Lays the rows drawn so far out as columns that fit the page, as a browser lays out an automatic table:
        /// columns keep their natural widths when they all fit, otherwise each gets its longest word and the space
        /// left is shared by how much more each wants. A cell wider than its column wraps within it: a row of several
        /// lines is drawn line by line, each line holding every cell's piece at its column's tab stop, with generated
        /// line separators between. Pieces stay exact runs of their cell's source, so notes, Find and highlights
        /// work in tables as in any text.
        private mutating func layOutTable(rowRanges: [NSRange], cellRanges: [[NSRange]], alignments: [Table.ColumnAlignment?], leadingTab: Bool,
                                          headers: [Bool]? = nil) {
            let columns = cellRanges.map(\.count).max() ?? 0
            guard columns > 0, let firstRow = rowRanges.first, let lastRow = rowRanges.last else { return }
            let tableID = tableCount
            tableCount += 1
            let padding = MarkdownRenderer.tableCellPadding
            // The table starts where the text beside it does and fits the column if it can.
            let left = indent
            // A column narrower than the indent (a deeply nested table in a narrow pane) still leaves the table room.
            let textRight = max(inset + columnWidth, left + 24)
            let available = max(CGFloat(24 * columns), textRight - left - CGFloat(columns) * padding * 2 - 2)
            // No cell is wider than the column: a long one wraps there.
            let cap = max(24, textRight - left - padding * 2 - 2)

            // Natural widths; the narrowest each column can be only when they don't all fit.
            var natural = [CGFloat](repeating: 24, count: columns)
            for cells in cellRanges {
                for (column, range) in cells.enumerated() where range.length > 0 {
                    natural[column] = max(natural[column], Self.measure(output.attributedSubstring(from: range)).width)
                }
            }
            let maximum = natural.map { min($0, cap) }
            var widths = maximum
            if maximum.reduce(0, +) > available {
                // A column narrows to its longest word, and no narrower than a few words of text unless its text is
                // shorter. A very long word (a URL, say) breaks between characters rather than widening its column
                // past a third or so of the column.
                let comfortable = (MarkdownRenderer.readingFontSize * 7).rounded()
                let longestKept = (MarkdownRenderer.readingFontSize * 16).rounded()
                var minimum = maximum.map { min($0, comfortable) }
                for cells in cellRanges {
                    for (column, range) in cells.enumerated() where range.length > 0 {
                        let word = min(longestKept, Self.longestWord(in: output.attributedSubstring(from: range)))
                        minimum[column] = min(maximum[column], max(minimum[column], word))
                    }
                }
                let least = minimum.reduce(0, +)
                if least >= available {
                    // Too wide even then: the table keeps those widths and scrolls sideways.
                    widths = minimum
                } else {
                    let wanted = zip(maximum, minimum).map { max(0, $0 - $1) }.reduce(0, +)
                    widths = (0..<columns).map { column in
                        let extra = wanted > 0 ? (maximum[column] - minimum[column]) * (available - least) / wanted : 0
                        return (minimum[column] + max(0, extra)).rounded(.down)
                    }
                }
            }
            let tableWidth = widths.reduce(0, +) + CGFloat(columns) * padding * 2
            let tableOverflow = max(0, (left + tableWidth - textRight).rounded(.up))
            overflow = max(overflow, tableOverflow)
            var starts: [CGFloat] = []
            var x = left + padding
            for width in widths {
                starts.append(x)
                x += width + padding * 2
            }
            let stops = (0..<columns).map { column -> NSTextTab in
                let alignment = column < alignments.count ? alignments[column] : nil
                return switch alignment {
                case .right?: NSTextTab(textAlignment: .right, location: starts[column] + widths[column], options: [:])
                case .center?: NSTextTab(textAlignment: .center, location: starts[column] + widths[column] / 2, options: [:])
                default: NSTextTab(textAlignment: .left, location: starts[column], options: [:])
                }
            }

            // Each cell's pieces: the lines it wraps to in its column, without the whitespace or breaks between them.
            struct Piece { var old: NSRange; var new = 0; var cell: Int; var joined: String }
            var rowPieces: [[[Piece]]] = []
            for cells in cellRanges {
                var row: [[Piece]] = []
                for (column, range) in cells.enumerated() {
                    let id = cellCount
                    cellCount += 1
                    let text = output.attributedSubstring(from: range)
                    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                        (value as? FittedImageAttachment)?.maximumWidth = widths[column]
                    }
                    let lines = natural[column] <= widths[column] ? Self.forcedLines(in: text) : Self.wrappedLines(of: text, width: widths[column])
                    row.append(Self.trimmedPieces(lines, in: text).map { Piece(old: NSRange(location: range.location + $0.range.location, length: $0.range.length), cell: id, joined: $0.joined) })
                }
                rowPieces.append(row)
            }

            // The rows again, line by line, from the pieces.
            let region = NSRange(location: firstRow.location, length: NSMaxRange(lastRow) - firstRow.location)
            let rebuilt = NSMutableAttributedString()
            var newRows: [NSRange] = []
            for (rowIndex, row) in rowPieces.enumerated() {
                // The row's own style; an empty row (or table) takes what comes before it, if anything does.
                let styled = rowRanges[rowIndex].length > 0 ? rowRanges[rowIndex].location : region.length > 0 ? region.location : region.location - 1
                var generated = styled >= 0 && styled < output.length ? output.attributes(at: styled, effectiveRange: nil) : [:]
                for key in [MarkdownRenderer.sourceSpanKey, .link, .toolTip, .backgroundColor, .attachment, .underlineStyle, .strikethroughStyle, .baselineOffset] {
                    generated[key] = nil
                }
                func separator(_ string: String, column: Int = -1) {
                    var attributes = generated
                    attributes[MarkdownRenderer.tableCellKey] = TableCellMark(table: tableID, row: rowIndex, column: column, joined: "")
                    rebuilt.append(NSAttributedString(string: string, attributes: attributes))
                }
                if rowIndex > 0 { separator("\n") }
                let rowStart = rebuilt.length
                let lineCount = max(1, row.map(\.count).max() ?? 0)
                for line in 0..<lineCount {
                    if line > 0 { separator(MarkdownRenderer.lineSeparator) }
                    for column in row.indices {
                        if column > 0 || leadingTab { separator("\t") }
                        guard line < row[column].count else { continue }
                        var piece = row[column][line]
                        piece.new = rebuilt.length
                        let text = NSMutableAttributedString(attributedString: output.attributedSubstring(from: piece.old))
                        text.addAttribute(MarkdownRenderer.tableCellKey, value: TableCellMark(table: tableID, row: rowIndex, column: column, joined: piece.joined),
                                          range: NSRange(location: 0, length: text.length))
                        rebuilt.append(text)
                        rowPieces[rowIndex][column][line] = piece
                    }
                }
                newRows.append(NSRange(location: region.location + rowStart, length: rebuilt.length - rowStart))
            }

            // Runs of source follow their characters into the pieces; a run split by a wrap becomes one per piece.
            let pieces = rowPieces.flatMap { $0.flatMap { $0 } }.sorted { $0.old.location < $1.old.location }
            /// The pieces from the first that could overlap `range` on (they are in their old order and don't overlap).
            func candidates(_ range: NSRange) -> ArraySlice<Piece> {
                var low = 0, high = pieces.count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(pieces[middle].old) < range.location {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
                var end = low
                while end < pieces.count, pieces[end].old.location <= NSMaxRange(range) { end += 1 }
                return pieces[low..<end]
            }
            var kept = spans.filter { $0.rendered.location < region.location || $0.rendered.location >= NSMaxRange(region) }
            for span in spans where span.rendered.location >= region.location && span.rendered.location < NSMaxRange(region) {
                for piece in candidates(span.rendered) {
                    let overlap = NSIntersectionRange(span.rendered, piece.old)
                    guard overlap.length > 0 else { continue }
                    let rendered = NSRange(location: region.location + piece.new + overlap.location - piece.old.location, length: overlap.length)
                    let source = span.exact ? NSRange(location: span.source.location + overlap.location - span.rendered.location, length: overlap.length) : span.source
                    kept.append(SourceSpan(rendered: rendered, source: source, exact: span.exact, cell: piece.cell))
                }
            }
            spans = kept
            // A cell's block becomes one per piece: its pieces are no longer one range.
            var keptBlocks = blocks.filter { $0.rendered.location < region.location || $0.rendered.location >= NSMaxRange(region) }
            for block in blocks where block.rendered.location >= region.location && block.rendered.location < NSMaxRange(region) {
                for piece in candidates(block.rendered) where NSIntersectionRange(block.rendered, piece.old).length > 0 || (piece.old.length == 0 && piece.old.location == block.rendered.location) {
                    keptBlocks.append(SourceSpan(rendered: NSRange(location: region.location + piece.new, length: piece.old.length), source: block.source, exact: false))
                }
            }
            blocks = keptBlocks
            output.replaceCharacters(in: region, with: rebuilt)

            let bars = decoration.quoteBars
            // A quote's bar runs on through the padding between rows, not only beside each row's text.
            let continued = bars.map { MarkdownBlockDecoration.QuoteBar(x: $0.x, continuesFromAbove: true, alert: $0.alert) }
            let dividers = starts.dropFirst().map { $0 - padding }
            var body = 0
            for (row, range) in newRows.enumerated() {
                let paragraph = NSMutableParagraphStyle()
                paragraph.tabStops = stops
                paragraph.defaultTabInterval = 24
                paragraph.headIndent = left + padding
                paragraph.firstLineHeadIndent = leadingTab ? left : left + padding
                paragraph.lineHeightMultiple = 1.2
                paragraph.paragraphSpacingBefore = (row == 0 ? gap : 0) + MarkdownRenderer.tableRowPadding
                paragraph.paragraphSpacing = MarkdownRenderer.tableRowPadding
                let header = headers.map { row < $0.count && $0[row] } ?? (row == 0)
                let chrome = MarkdownBlockDecoration.TableChrome(dividers: Array(dividers), striped: !header && body % 2 == 1,
                                                                  first: row == 0, last: row == newRows.count - 1,
                                                                  id: tableID, visible: left...textRight, overflow: tableOverflow)
                if !header { body += 1 }
                let rowDecoration = MarkdownBlockDecoration(kind: .tableRow(header: header, width: tableWidth), leading: left, quoteBars: row == 0 ? bars : continued, table: chrome)
                // Include the newline that ends the row so the paragraph's attributes are uniform.
                let full = NSRange(location: range.location, length: min(range.length + 1, output.length - range.location))
                output.addAttribute(.paragraphStyle, value: paragraph, range: full)
                output.addAttribute(MarkdownRenderer.blockKey, value: rowDecoration, range: full)
            }
        }

        /// A cell's text as it measures alone: no row indents or tab stops.
        private static func measurable(_ text: NSAttributedString) -> NSAttributedString {
            let plain = NSMutableAttributedString(attributedString: text)
            plain.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: plain.length))
            return plain
        }

        /// The widest line of a cell set unwrapped (it breaks only where it has line breaks).
        private static func measure(_ text: NSAttributedString) -> CGSize {
            let size = measurable(text).size()
            return CGSize(width: ceil(size.width), height: ceil(size.height))
        }

        /// The widest run of a cell's text without whitespace: the narrowest its column can be without breaking a word.
        private static func longestWord(in text: NSAttributedString) -> CGFloat {
            let plain = measurable(text)
            let string = plain.string as NSString
            var widest: CGFloat = 0
            var start: Int?
            for index in 0...string.length {
                let breaks = index == string.length || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: index)) ?? " ")
                if breaks {
                    if let from = start { widest = max(widest, ceil(plain.attributedSubstring(from: NSRange(location: from, length: index - from)).size().width)) }
                    start = nil
                } else if start == nil {
                    start = index
                }
            }
            return widest
        }

        /// A cell's lines where it has line breaks; the breaks stay at the ends of their lines.
        private static func forcedLines(in text: NSAttributedString) -> [NSRange] {
            let string = text.string as NSString
            var lines: [NSRange] = []
            var start = 0
            for index in 0..<string.length where string.character(at: index) == 0x2028 || string.character(at: index) == 0x0A {
                lines.append(NSRange(location: start, length: index + 1 - start))
                start = index + 1
            }
            lines.append(NSRange(location: start, length: string.length - start))
            return lines
        }

        /// A cell's lines wrapped to `width`, as TextKit wraps them (words, then characters for a word too long).
        private static func wrappedLines(of text: NSAttributedString, width: CGFloat) -> [NSRange] {
            let storage = NSTextStorage(attributedString: measurable(text))
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            var lines: [NSRange] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
                lines.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            }
            return lines.isEmpty ? [NSRange(location: 0, length: text.length)] : lines
        }

        /// Lines without the whitespace and breaks at their ends (they would push a right-aligned piece off its
        /// stop), each saying what joined it to the line before: a space where some was taken out, nothing where a
        /// long word was broken.
        private static func trimmedPieces(_ lines: [NSRange], in text: NSAttributedString) -> [(range: NSRange, joined: String)] {
            let string = text.string as NSString
            func isSpace(_ index: Int) -> Bool {
                let unit = string.character(at: index)
                return unit == 0x2028 || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(unit) ?? " ")
            }
            var pieces: [(range: NSRange, joined: String)] = []
            var trimmed = false
            for (index, line) in lines.enumerated() {
                var from = line.location, to = NSMaxRange(line)
                var leading = false
                while from < to, isSpace(from) { from += 1; leading = true }
                var trailing = false
                while to > from, isSpace(to - 1) { to -= 1; trailing = true }
                guard to > from || index == 0 else { trimmed = trimmed || leading || trailing; continue }
                pieces.append((NSRange(location: from, length: to - from), index == 0 ? "" : (trimmed || leading ? " " : "")))
                trimmed = trailing
            }
            return pieces
        }

        // MARK: Inlines

        mutating func visitText(_ text: Text) {
            if let alert = pendingAlert {
                // The marker's text, shown as the alert's title; generated, so it maps to no source.
                if !alertTitled {
                    let saved = style
                    style.bold = true
                    style.color = alert.color
                    appendGenerated(alert.title)
                    style = saved
                    alertTitled = true
                }
                return
            }
            let (range, exact) = exactness(text, rendered: text.string)
            let start = output.length
            append(text.string, source: range, exact: exact)
            if style.link == nil { linkAddresses(in: text.string, at: start) }
        }

        /// GitHub links a bare `https://…`, `www.…` or e-mail address in text (not in code, not inside a link);
        /// without it a URL in a README or an issue could not be followed.
        private mutating func linkAddresses(in string: String, at start: Int) {
            for (range, link) in MarkdownRenderer.autolinks(in: string) {
                let target = NSRange(location: start + range.location, length: range.length)
                guard NSMaxRange(target) <= output.length else { continue }
                output.addAttributes([.link: link, .foregroundColor: NSColor.linkColor, .toolTip: link], range: target)
            }
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
                attachment.isAnimated = FittedImageAttachment.isAnimated(picture)
                attachment.plays = attachment.isAnimated && !reduceMotion
                append("\u{FFFC}", source: range, exact: false, extra: [.attachment: attachment])
                return
            }
            // A web picture, or a relative one this Mac doesn't have: the controller fetches it from the web or from
            // the document's host (an attachment, a remote file).
            if let source, !source.isEmpty, !unresolvedImages.contains(source),
               WebImageLoader.handles(source) || (baseURL == nil && URL(string: source)?.scheme == nil) {
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

        /// Whether `EmbedScanner` finds an embed of `source` starting at `location`.
        private mutating func scannedEmbed(of source: String, at location: Int) -> Bool {
            loadEmbedLocations()
            return embedLocations?[source]?.contains(location) ?? false
        }

        private mutating func loadEmbedLocations() {
            if embedLocations == nil {
                embedLocations = Dictionary(grouping: EmbedScanner.embeds(in: self.source), by: \.source).mapValues { $0.map(\.range.location) }
            }
        }

        /// Which embed of `source` the one at `range` is, as `EmbedScanner` numbers them.
        private mutating func occurrence(of source: String, at range: NSRange?) -> Int {
            guard let range else {
                defer { imageOccurrences[source, default: 0] += 1 }
                return imageOccurrences[source, default: 0]
            }
            loadEmbedLocations()
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
                    appendHTMLPicture(attributes, source: range, inPicture: inlineElements.contains { $0.name == "picture" })
                    return
                case "source" where inlineElements.contains(where: { $0.name == "picture" }):
                    choosePictureSource(attributes, range: range)
                    return
                default:
                    if !MarkdownHTML.voidTags.contains(name), let close = closingTag(of: inlineHTML, name: name) {
                        if name == "picture" { pictureChoice = nil }
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
            if pendingAlert != nil {
                pendingAlert = nil
                appendGenerated(MarkdownRenderer.lineSeparator)
                return
            }
            let (range, _) = exactness(softBreak, rendered: " ")
            append(" ", source: range, exact: false)
        }

        mutating func visitLineBreak(_ lineBreak: LineBreak) {
            if pendingAlert != nil {
                pendingAlert = nil
                appendGenerated(MarkdownRenderer.lineSeparator)
                return
            }
            let (range, _) = exactness(lineBreak, rendered: "\n")
            append(MarkdownRenderer.lineSeparator, source: range, exact: false)
        }
    }
}

/// Where a character of a laid-out table belongs: its table, row and column (-1 for the tabs and separators
/// between cells), and for the first character of a cell's later piece, what joined it to the piece before.
public nonisolated final class TableCellMark: NSObject, Sendable {
    public let table: Int
    public let row: Int
    public let column: Int
    public let joined: String

    init(table: Int, row: Int, column: Int, joined: String) {
        self.table = table
        self.row = row
        self.column = column
        self.joined = joined
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
        /// The bar of a GitHub alert is drawn in its colour.
        public var alert: MarkdownAlert? = nil
    }

    public let kind: Kind
    /// Left edge of the block (where a code fill or rule starts), in container coordinates.
    public let leading: CGFloat
    public let quoteBars: [QuoteBar]
    /// A code block's language, as people name it ("Swift", "Shell"), drawn small in its corner.
    public let label: String?
    public let codeBackground: NSColor?
    public let codeForeground: NSColor?
    /// A table row's place in its table: where its column rules go and which edges of the outline it draws.
    public let table: TableChrome?

    public struct TableChrome: Equatable, Sendable {
        /// The rules between columns, in container coordinates.
        public var dividers: [CGFloat]
        /// Every other body row is shaded.
        public var striped: Bool
        public var first: Bool
        public var last: Bool
        /// The table, numbered in the document.
        public var id: Int = 0
        /// The part of the container the table shows in (its left edge to the column's right), in container
        /// coordinates; it is drawn clipped to it.
        public var visible: ClosedRange<CGFloat> = 0...CGFloat.greatestFiniteMagnitude
        /// How far it runs past the column, which it can scroll by; zero when it fits.
        public var overflow: CGFloat = 0
        /// How far it is scrolled now.
        public var offset: CGFloat = 0
    }

    public init(kind: Kind, leading: CGFloat, quoteBars: [QuoteBar], label: String? = nil, codeBackground: NSColor? = nil, codeForeground: NSColor? = nil,
                table: TableChrome? = nil) {
        self.kind = kind
        self.leading = leading
        self.quoteBars = quoteBars
        self.label = label
        self.codeBackground = codeBackground; self.codeForeground = codeForeground
        self.table = table
    }

    func labelled(_ label: String?) -> MarkdownBlockDecoration {
        MarkdownBlockDecoration(kind: kind, leading: leading, quoteBars: quoteBars, label: label, codeBackground: codeBackground, codeForeground: codeForeground, table: table)
    }

    func withCodeColors(background: NSColor,foreground: NSColor?) -> MarkdownBlockDecoration {
        MarkdownBlockDecoration(kind: kind,leading: leading,quoteBars: quoteBars,label: label,codeBackground: background,codeForeground: foreground,table: table)
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
    /// The widest it is drawn: its table column's width, in a table.
    var maximumWidth: CGFloat?
    /// The picture as the Markdown names it, and which embed of it this is (0 for the first).
    var source: String?
    var occurrence = 0
    /// The picture's own pixels, the space region notes are kept in.
    var pixelSize = CGSize.zero
    /// An animated picture (GIF, APNG), and whether it plays: then the rendered view lays a playing image view over
    /// the attachment's frame, and the attachment itself draws nothing beneath it.
    var isAnimated = false
    var plays = false

    /// More than one frame in any of its bitmaps.
    static func isAnimated(_ image: NSImage) -> Bool {
        image.representations.contains { (($0 as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int ?? 0) > 1 }
    }

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
        Self.fitted(naturalSize, width: min(maximumWidth ?? .greatestFiniteMagnitude, proposedLineFragment.width - position.x))
    }

    /// TextKit 1's question, asked when a table measures and wraps its cells.
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        Self.fitted(naturalSize, width: min(maximumWidth ?? .greatestFiniteMagnitude, lineFrag.width > 0 ? lineFrag.width - position.x : .greatestFiniteMagnitude))
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
        if plays { return NSImage(size: imageBounds.size) }
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

/// A GitHub alert: a quote whose first line is `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]`, drawn
/// with a coloured bar and its title in place of the marker. Without it the marker showed as text in a grey quote.
nonisolated public enum MarkdownAlert: String, CaseIterable, Sendable {
    case note, tip, important, warning, caution

    /// The alert a quote is, when its first paragraph's first line is the marker alone (case aside), as GitHub reads it.
    init?(quote: BlockQuote) {
        guard let paragraph = quote.child(at: 0) as? Paragraph else { return nil }
        var marker = ""
        for child in paragraph.children {
            if child is SoftBreak || child is LineBreak { break }
            guard let text = child as? Text else { return nil }
            marker += text.string
        }
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        self.init(rawValue: trimmed.dropFirst(2).dropLast().lowercased())
    }

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public var color: NSColor {
        switch self {
        case .note: .systemBlue
        case .tip: .systemGreen
        case .important: .systemPurple
        case .warning: .systemOrange
        case .caution: .systemRed
        }
    }
}

// Classification is cached with highlights, never looked up by scanning notes during native path drawing.
extension MarkdownRenderer {
    static func isCode(at location: Int,in text: NSAttributedString) -> Bool {
        guard location >= 0, location < text.length else { return false }
        return (text.attribute(blockKey,at: location,effectiveRange: nil) as? MarkdownBlockDecoration)?.kind == .codeBlock
    }
}
