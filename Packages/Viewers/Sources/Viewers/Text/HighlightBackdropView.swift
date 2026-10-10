import AppKit
import Core

/// Draws note highlight backgrounds beneath a TextKit 2 text view's content. TextKit 2 applies foreground rendering
/// attributes but not background ones, so backgrounds are painted here from the layout manager's segment rects.
final class HighlightBackdropView: NSView {
    struct Entry {
        var range: NSRange
        var noteColor: NoteColor
        var mark: Theme.NoteMark
        /// How strong a removal point's caret is: the state ladder, full while in focus.
        var strength: CGFloat

        init(range: NSRange, color: NoteColor, state: NoteState, focused: Bool) {
            self.range = range
            noteColor = color
            mark = Theme.mark(for: state, focused: focused)
            strength = focused ? 1 : Theme.strength(for: state)
        }
    }

    weak var textView: NSTextView?
    var entries: [Entry] = [] {
        didSet { needsDisplay = true }
    }

    /// A change's lines: full-width tinted rows for added ones, a hairline where lines were taken out.
    var lineChanges: LineChanges? {
        didSet { if oldValue != lineChanges { needsDisplay = true } }
    }

    /// For a view whose text isn't the source (rendered Markdown): the source lines a laid-out paragraph shows, from
    /// its character range in the view; nil for one that shows none. Line changes are then matched by source line, a
    /// paragraph tinted when any of its lines changed.
    var sourceLines: ((NSRange) -> ClosedRange<Int>?)? {
        didSet { needsDisplay = true }
    }

    /// The caret's location while nothing is selected and the editor has focus; its line gets a quiet full-width band.
    var caretLocation: Int? {
        didSet { if oldValue != caretLocation { needsDisplay = true } }
    }

    /// Indent guides for the lines around what is on screen, worked out when first drawn after a change or when
    /// scrolling nears the edge of what was built.
    private var guides: IndentGuides?
    private var guidesWindow: ClosedRange<Int>?
    /// The editor's line index (kept up to date on every edit), so guides read lines without rescanning the text.
    var lineIndex: () -> LineIndex? = { nil }
    private static let guideMargin = 200
    var showsIndentGuides = true {
        didSet { if oldValue != showsIndentGuides { needsDisplay = true } }
    }

    /// The text changed; guides are worked out again on the next draw.
    func invalidateIndentGuides() {
        guides = nil
        guidesWindow = nil
        needsDisplay = true
    }

    /// Hairlines quiet enough to sit under text without competing with it; the caret's block is a step stronger.
    static let guideColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07)
    }
    static let activeGuideColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.24) : NSColor(white: 0, alpha: 0.22)
    }

    static let currentLineColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05)
            : NSColor(white: 0, alpha: 0.04)
    }

    /// The round cap on a removal point's caret.
    static let caretCap: CGFloat = 5

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Installs the backdrop as the bottom-most subview so text content draws over it.
    static func install(in textView: NSTextView) -> HighlightBackdropView {
        let backdrop = HighlightBackdropView(frame: textView.bounds)
        backdrop.textView = textView
        backdrop.showsIndentGuides = Theme.showsIndentGuides
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        textView.addSubview(backdrop, positioned: .below, relativeTo: nil)
        return backdrop
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager else { return }
        let documentStart = contentManager.documentRange.location
        let inset = textView.textContainerOrigin
        if let lineChanges, !lineChanges.isEmpty {
            drawLineChanges(lineChanges, in: dirtyRect, layoutManager: layoutManager, contentManager: contentManager)
        }
        if let caret = caretLocation, let band = currentLineRect(caret, layoutManager: layoutManager, contentManager: contentManager), band.intersects(dirtyRect) {
            Self.currentLineColor.setFill()
            band.fill()
        }
        if showsIndentGuides {
            drawIndentGuides(in: dirtyRect, layoutManager: layoutManager, contentManager: contentManager)
        }
        for entry in entries {
            // Text an agent or an edit removed: a caret where it was, in the note's colour, with a round cap on top.
            if entry.range.length == 0 {
                guard let caret = textView.caretRect(at: entry.range.location), caret.insetBy(dx: -3, dy: -3).intersects(dirtyRect) else { continue }
                Theme.color(for: entry.noteColor).withAlphaComponent(entry.strength).setFill()
                NSBezierPath(roundedRect: caret, xRadius: caret.width / 2, yRadius: caret.width / 2).fill()
                let cap = Self.caretCap
                NSBezierPath(ovalIn: NSRect(x: caret.midX - cap / 2, y: caret.minY, width: cap, height: cap)).fill()
                continue
            }
            guard let from = contentManager.location(documentStart, offsetBy: entry.range.location),
                  let to = contentManager.location(documentStart, offsetBy: entry.range.location + entry.range.length),
                  let textRange = NSTextRange(location: from, end: to) else { continue }
            layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
                let rect = frame.offsetBy(dx: inset.x, dy: inset.y)
                guard rect.intersects(dirtyRect) else { return true }
                let color = Theme.color(for: entry.noteColor)
                switch entry.mark {
                case .fill:
                    Theme.highlightFill(for: entry.noteColor).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                case .underline, .dottedUnderline, .dashedUnderline:
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: rect.minX, y: rect.maxY - 1))
                    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 1))
                    switch entry.mark {
                    case .underline:
                        path.lineWidth = 1.5
                        color.withAlphaComponent(0.85).setStroke()
                    case .dottedUnderline:
                        path.lineWidth = 1.25
                        path.lineCapStyle = .round
                        path.setLineDash([0.5, 3], count: 2, phase: 0)
                        color.withAlphaComponent(0.6).setStroke()
                    default:
                        path.lineWidth = 1
                        path.setLineDash([3, 2], count: 2, phase: 0)
                        color.setStroke()
                    }
                    path.stroke()
                }
                return true
            }
        }
    }

    /// Tinted rows and deletion hairlines for the fragments in view: the same walk the guides make, so the cost is
    /// what is on screen, not the file.
    private func drawLineChanges(_ changes: LineChanges, in dirtyRect: NSRect, layoutManager: NSTextLayoutManager, contentManager: NSTextContentManager) {
        if let sourceLines {
            drawSourceLineChanges(changes, sourceLines: sourceLines, in: dirtyRect, layoutManager: layoutManager, contentManager: contentManager)
            return
        }
        guard let textView, let index = lineIndex(), index.lineCount > 0 else { return }
        let inset = textView.textContainerOrigin
        let documentStart = contentManager.documentRange.location
        let scale = window?.backingScaleFactor ?? 2
        guard let first = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, dirtyRect.minY - inset.y))) else { return }
        layoutManager.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + inset.y > dirtyRect.maxY { return false }
            let line = index.position(forUTF16Offset: contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)).line
            let height = fragment.textLineFragments.filter { $0.characterRange.length > 0 }.reduce(0) { $0 + $1.typographicBounds.height }
            let rowsHeight = height > 0 ? height : frame.height
            let top = frame.minY + inset.y
            if changes.contains(line: line) {
                Theme.changeAddedBackground.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: rowsHeight).fill()
            }
            if changes.deletions.contains(line) {
                Theme.changeDeletedMarker.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: 1 / scale).fill()
            }
            // Lines taken out after the last line sit on its bottom edge.
            if line == index.lineCount, changes.deletions.contains(line + 1) {
                Theme.changeDeletedMarker.setFill()
                NSRect(x: 0, y: top + rowsHeight - 1 / scale, width: bounds.width, height: 1 / scale).fill()
            }
            return true
        }
    }

    /// Line changes on a view showing the source another way: a paragraph is tinted when a line it shows changed, and
    /// lines taken out since the paragraph before (or inside it) put a hairline on its top edge.
    private func drawSourceLineChanges(_ changes: LineChanges, sourceLines: (NSRange) -> ClosedRange<Int>?, in dirtyRect: NSRect,
                                       layoutManager: NSTextLayoutManager, contentManager: NSTextContentManager) {
        guard let textView else { return }
        let inset = textView.textContainerOrigin
        let documentStart = contentManager.documentRange.location
        let scale = window?.backingScaleFactor ?? 2
        guard let first = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, dirtyRect.minY - inset.y))) else { return }
        // The source line the paragraph above the first drawn one ended on, so a removal between the two is found.
        var previousEnd = 0
        if let before = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, first.layoutFragmentFrame.minY - 1))), before !== first {
            let start = contentManager.offset(from: documentStart, to: before.rangeInElement.location)
            let end = contentManager.offset(from: documentStart, to: before.rangeInElement.endLocation)
            previousEnd = sourceLines(NSRange(location: start, length: end - start))?.upperBound ?? 0
        }
        layoutManager.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + inset.y > dirtyRect.maxY { return false }
            let start = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let end = contentManager.offset(from: documentStart, to: fragment.rangeInElement.endLocation)
            guard let lines = sourceLines(NSRange(location: start, length: end - start)) else { return true }
            let top = frame.minY + inset.y
            if changes.added.contains(where: { $0.overlaps(lines) }) {
                Theme.changeAddedBackground.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: frame.height).fill()
            }
            if changes.deletions.contains(where: { $0 > previousEnd && $0 <= lines.upperBound }) {
                Theme.changeDeletedMarker.setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: 1 / scale).fill()
            }
            previousEnd = max(previousEnd, lines.upperBound)
            return true
        }
    }

    private func drawIndentGuides(in dirtyRect: NSRect, layoutManager: NSTextLayoutManager, contentManager: NSTextContentManager) {
        guard let textView, let storage = textView.textStorage, let index = lineIndex(), index.lineCount > 0 else { return }
        let inset = textView.textContainerOrigin
        let documentStart = contentManager.documentRange.location
        // The lines on screen, then guides for them plus a margin (rebuilt only near its edge or after an edit).
        func line(atY y: CGFloat) -> Int {
            guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y - inset.y))) else { return index.lineCount }
            return index.position(forUTF16Offset: contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)).line
        }
        let visible = line(atY: visibleRect.minY)...max(line(atY: visibleRect.minY), line(atY: visibleRect.maxY))
        let needed = max(1, visible.lowerBound - Self.guideMargin / 4)...min(index.lineCount, visible.upperBound + Self.guideMargin / 4)
        if guides == nil || !(guidesWindow.map { $0.contains(needed.lowerBound) && $0.contains(needed.upperBound) } ?? false) {
            let window = max(1, visible.lowerBound - Self.guideMargin)...min(index.lineCount, visible.upperBound + Self.guideMargin)
            guides = IndentGuides(window: window, text: storage.mutableString, lineIndex: index)
            guidesWindow = window
        }
        guard let guides, guides.levels.contains(where: { $0 > 0 }) else { return }
        let space = (" " as NSString).size(withAttributes: [.font: textView.font ?? Theme.editorFont]).width
        let active = caretLocation.flatMap { guides.covers($0) ? guides.activeGuide(aroundLine: guides.line(at: $0)) : nil }
        let scale = window?.backingScaleFactor ?? 2
        guard let first = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, dirtyRect.minY - inset.y))) else { return }
        layoutManager.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + inset.y > dirtyRect.maxY { return false }
            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard guides.covers(offset) else { return true }
            let line = guides.line(at: offset)
            let count = guides.levels.indices.contains(line) ? guides.levels[line] : 0
            guard count > 0, let row = fragment.textLineFragments.first else { return true }
            // Column 0 is where the line's first character sits, whatever padding the container adds.
            let origin = frame.minX + row.typographicBounds.minX + row.locationForCharacter(at: 0).x + inset.x
            let height = fragment.textLineFragments.filter { $0.characterRange.length > 0 }.reduce(0) { $0 + $1.typographicBounds.height }
            let rowsHeight = height > 0 ? height : frame.height
            for level in 0..<count {
                let x = (origin + CGFloat(level * guides.unit) * space).rounded(.down) + 0.5 / scale
                let isActive = active.map { $0.level == level && $0.lines.contains(line) } ?? false
                (isActive ? Self.activeGuideColor : Self.guideColor).setFill()
                NSRect(x: x, y: frame.minY + inset.y, width: 1 / scale * (isActive ? 2 : 1), height: rowsHeight).fill()
            }
            return true
        }
    }

    /// The caret's paragraph (all its wrapped lines) across the whole view, in this view's coordinates. None on an
    /// empty last line, which has no layout fragment of its own.
    private func currentLineRect(_ caret: Int, layoutManager: NSTextLayoutManager, contentManager: NSTextContentManager) -> NSRect? {
        guard let textView else { return nil }
        let text = textView.string as NSString
        var offset = caret
        if caret >= text.length {
            guard caret > 0, text.character(at: text.length - 1) != 0x0A else { return nil }
            offset = text.length - 1
        }
        guard let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        let frame = fragment.layoutFragmentFrame
        // Leave out the empty line fragment TextKit adds after a paragraph's newline.
        let height = fragment.textLineFragments.filter { $0.characterRange.length > 0 }.reduce(0) { $0 + $1.typographicBounds.height }
        return NSRect(x: 0, y: frame.minY + textView.textContainerOrigin.y, width: bounds.width, height: height > 0 ? height : frame.height)
    }
}
