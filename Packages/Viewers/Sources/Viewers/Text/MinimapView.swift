import AppKit
import Core

/// A small picture of the whole file at the editor's trailing edge, as VS Code's minimap draws one: each run of
/// characters a block in its syntax colour, two points to a line, with notes tinted over their lines and changes in a
/// lane at the left. A slider covers the lines on screen. Geometry is in real points, so a short file is a short
/// picture with small marks rather than one stretched over the pane; a long one scrolls with the editor. A click on a
/// note goes to it (as browsing the notes panel does); a click anywhere else centres that line, and a drag moves the
/// slider. Settings › Editor turns it off (`Theme.showsMinimap`).
final class MinimapView: NSView {
    weak var controller: TextEditorController?
    weak var scrollView: NSScrollView?
    /// The first and last source lines on screen, from TextKit, so wrapped lines count once.
    var visibleLines: () -> ClosedRange<Int>? = { nil }
    /// Scrolls the editor to a line: centred on it, or with it at the top.
    var showLine: (_ line: Int, _ centred: Bool) -> Void = { _, _ in }

    static let width: CGFloat = 100
    /// Where the code starts, past the changes lane.
    private static let codeInset: CGFloat = 6
    private static let columnWidth: CGFloat = 0.8
    private static let blockHeight: CGFloat = 1.5
    private static let tabWidth = 4
    private static var columns: Int { Int((width - codeInset - 4) / columnWidth) }

    /// Line positions in the minimap's own points; pure so the mapping is testable.
    nonisolated struct Layout: Equatable {
        static let lineHeight: CGFloat = 2
        var lineCount: Int
        var viewHeight: CGFloat
        /// How far the editor is scrolled, 0 at the top and 1 at the bottom, in source lines (`fraction(firstLine:…)`):
        /// a pixel fraction drifts from the picture when lines wrap to different heights.
        var scrollFraction: CGFloat
        /// The lines on screen; nil when the whole file is.
        var visibleLines: ClosedRange<Int>?

        var contentHeight: CGFloat { CGFloat(max(1, lineCount)) * Self.lineHeight }
        private var fraction: CGFloat { min(1, max(0, scrollFraction)) }
        /// How far the picture is scrolled: only a file taller than the view moves, in step with the editor.
        var offset: CGFloat { max(0, contentHeight - viewHeight) * fraction }

        func top(ofLine line: Int) -> CGFloat { CGFloat(line - 1) * Self.lineHeight - offset }

        /// The scroll fraction with `first` the top line on screen and `count` lines showing: the slider then sits
        /// exactly over those lines in the picture.
        static func fraction(firstLine first: Int, visibleCount count: Int, lineCount: Int) -> CGFloat {
            let range = lineCount - count
            return range > 0 ? min(1, max(0, CGFloat(first - 1) / CGFloat(range))) : 0
        }

        /// The top line for a scroll fraction, the inverse of `fraction(firstLine:…)`.
        static func firstLine(forFraction fraction: CGFloat, visibleCount count: Int, lineCount: Int) -> Int {
            Int((min(1, max(0, fraction)) * CGFloat(max(0, lineCount - count))).rounded()) + 1
        }

        /// A span of lines; a point (a removal) still gets a mark you can see.
        func rect(forLines lines: ClosedRange<Int>, isPoint: Bool = false) -> (y: CGFloat, height: CGFloat) {
            (top(ofLine: lines.lowerBound), isPoint ? Self.lineHeight : CGFloat(lines.count) * Self.lineHeight)
        }

        func line(atY y: CGFloat) -> Int {
            min(max(1, lineCount), max(1, Int(floor((y + offset) / Self.lineHeight)) + 1))
        }

        /// The lines the minimap shows at its current scroll.
        var shownLines: ClosedRange<Int> {
            let first = min(max(1, lineCount), Int(floor(offset / Self.lineHeight)) + 1)
            return first...max(first, min(lineCount, Int(ceil((offset + viewHeight) / Self.lineHeight))))
        }

        /// How far the slider can travel: the picture's height on screen, less the slider.
        var sliderTravel: CGFloat {
            guard let slider else { return 0 }
            return max(0, min(viewHeight, contentHeight) - slider.height)
        }

        /// The band over the lines on screen, at the same fraction of its travel as the editor's scroll.
        var slider: (y: CGFloat, height: CGFloat)? {
            guard let visibleLines else { return nil }
            let track = min(viewHeight, contentHeight)
            let height = min(track, max(Self.lineHeight * 2, CGFloat(visibleLines.count) * Self.lineHeight))
            return ((track - height) * fraction, height)
        }
    }

    /// One note's lines; pure so the mapping is testable.
    nonisolated struct Mark: Equatable {
        var noteID: NoteID
        var color: NoteColor
        var state: NoteState
        /// The note's text was removed: an outlined tick at the point where it was.
        var isPoint: Bool
        var lines: ClosedRange<Int>
        var line: Int { lines.lowerBound }
    }

    nonisolated static func marks(for highlights: [TextHighlight], lineIndex: LineIndex) -> [Mark] {
        // Settled notes underneath, open work on top.
        let order: [NoteState: Int] = [.resolved: 0, .sent: 1, .orphaned: 2, .draft: 3]
        // Text replaced under a note leaves no place to mark, as in the gutter.
        return highlights.filter { !$0.isInvalidated }.map { highlight in
            let first = lineIndex.position(forUTF16Offset: highlight.range.location).line
            let last = lineIndex.position(forUTF16Offset: highlight.range.location + max(0, highlight.range.length - 1)).line
            return Mark(noteID: highlight.id, color: highlight.color, state: highlight.state,
                        isPoint: highlight.range.length == 0, lines: first...max(first, last))
        }
        .sorted { (order[$0.state] ?? 0, $0.line) < (order[$1.state] ?? 0, $1.line) }
    }

    /// A hunk's lines; a deletion is the point where lines were taken out.
    nonisolated struct HunkMark: Equatable {
        var lines: ClosedRange<Int>
        var isDeletion: Bool
    }

    nonisolated static func hunkMarks(for changes: LineChanges) -> [HunkMark] {
        let added = changes.added.map { HunkMark(lines: $0, isDeletion: false) }
        let deleted = changes.deletions.map { HunkMark(lines: $0...$0, isDeletion: true) }
        return (added + deleted).sorted { $0.lines.lowerBound < $1.lines.lowerBound }
    }

    /// A run of characters drawn as one block: columns from the line's start, and what colours it.
    nonisolated struct Run<Key: Equatable>: Equatable {
        var column: Int
        var length: Int
        var key: Key
    }

    /// The blocks for one line: whitespace separates them, tabs advance to the next stop, a change of key (the syntax
    /// capture under the characters) starts a new one, and nothing past `maxColumns` is drawn.
    nonisolated static func runs<Key: Equatable>(in line: some Collection<UInt16>, tabWidth: Int, maxColumns: Int,
                                                 key: (Int) -> Key) -> [Run<Key>] {
        var runs: [Run<Key>] = []
        var column = 0
        for (offset, unit) in line.enumerated() {
            guard column < maxColumns else { break }
            switch unit {
            case 0x09:
                column = (column / tabWidth + 1) * tabWidth
            case 0x20, 0x0A, 0x0D, 0xA0, 0x0B, 0x0C:
                column += 1
            case 0xDC00...0xDFFF:
                continue   // the second half of a surrogate pair: one character, one column
            default:
                let current = key(offset)
                if var last = runs.last, last.column + last.length == column, last.key == current {
                    last.length += 1
                    runs[runs.count - 1] = last
                } else {
                    runs.append(Run(column: column, length: 1, key: current))
                }
                column += 1
            }
        }
        return runs
    }

    // MARK: Drawing

    /// Each line's blocks, keyed by capture name; cleared when the text or the highlighter's colouring changes.
    private var lineRuns: [Int: [Run<String?>]] = [:]
    private var cachedGeneration = -1
    private var text: NSString?

    /// The text changed: drop what was drawn from it.
    func textDidChange() {
        lineRuns = [:]
        text = nil
        needsDisplay = true
    }

    private var hits: [(rect: NSRect, mark: Mark)] = []
    private var hunkHits: [(rect: NSRect, mark: HunkMark)] = []
    private var hovered: NoteID? {
        didSet { if oldValue != hovered { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var wholeFileShows: Bool {
        guard let scrollView, let document = scrollView.documentView else { return true }
        return document.frame.height <= scrollView.documentVisibleRect.height + 1
    }

    private var layout: Layout {
        let lineCount = controller?.lineIndex.lineCount ?? 1
        let visible = wholeFileShows ? nil : visibleLines()
        let fraction = visible.map { Layout.fraction(firstLine: $0.lowerBound, visibleCount: $0.count, lineCount: lineCount) } ?? 0
        return Layout(lineCount: lineCount, viewHeight: bounds.height, scrollFraction: fraction, visibleLines: visible)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let context = NSGraphicsContext.current?.cgContext else { return }
        MinimapStyle.drawSeparator(height: bounds.height)
        let layout = layout

        if let generation = controller.highlighter?.generation, generation != cachedGeneration {
            cachedGeneration = generation
            lineRuns = [:]
        }
        drawCode(in: context, layout: layout, controller: controller)

        if let slider = layout.slider {
            MinimapStyle.drawSlider(NSRect(x: 1, y: slider.y, width: bounds.width - 1, height: slider.height), dragging: sliderDragStart != nil)
        }

        // Changes in a lane of their own at the left, under the notes.
        hunkHits = []
        if let changes = controller.lineChanges {
            for hunk in Self.hunkMarks(for: changes) {
                let span = layout.rect(forLines: hunk.lines, isPoint: hunk.isDeletion)
                guard span.y + span.height >= 0, span.y <= bounds.height else { continue }
                let rect = hunk.isDeletion
                    ? NSRect(x: 1.5, y: span.y - 1, width: 3, height: 2)
                    : NSRect(x: 1.5, y: span.y, width: 2, height: span.height)
                (hunk.isDeletion ? Theme.changeDeletedMarker : Theme.changeBar).setFill()
                rect.fill()
                hunkHits.append((rect.insetBy(dx: -2, dy: -2), hunk))
            }
        }

        hits = []
        for mark in Self.marks(for: controller.drawnHighlights, lineIndex: controller.lineIndex) {
            let span = layout.rect(forLines: mark.lines, isPoint: mark.isPoint)
            guard span.y + span.height >= 0, span.y <= bounds.height else { continue }
            let rect = NSRect(x: Self.codeInset - 1, y: span.y, width: bounds.width - Self.codeInset + 1, height: span.height)
            MinimapStyle.drawNote(rect, barX: bounds.width - 3, color: mark.color, state: mark.state, isPoint: mark.isPoint,
                                  hovered: mark.noteID == hovered || controller.isFocused(mark.noteID))
            // A generous target: a one-line note is two points tall.
            hits.append((rect.insetBy(dx: 0, dy: -2), mark))
        }
    }

    /// The code itself, one block per run of characters, batched by colour so a draw is a few fills.
    /// Keeps the cache to about what is drawn, so scrolling through a long file doesn't hold every line.
    private func trimCache(to shown: ClosedRange<Int>) {
        guard lineRuns.count > shown.count * 4 + 200 else { return }
        lineRuns = lineRuns.filter { shown.contains($0.key) }
    }

    private func drawCode(in context: CGContext, layout: Layout, controller: TextEditorController) {
        let text = self.text ?? (controller.text as NSString)
        self.text = text
        var byCapture: [String?: [CGRect]] = [:]
        trimCache(to: layout.shownLines)
        for line in layout.shownLines {
            let runs = lineRuns[line] ?? {
                let made = runs(forLine: line, in: text, controller: controller)
                lineRuns[line] = made
                return made
            }()
            let y = layout.top(ofLine: line) + (Layout.lineHeight - Self.blockHeight) / 2
            for run in runs {
                byCapture[run.key, default: []].append(CGRect(x: Self.codeInset + CGFloat(run.column) * Self.columnWidth, y: y,
                                                              width: CGFloat(run.length) * Self.columnWidth, height: Self.blockHeight))
            }
        }
        for (capture, rects) in byCapture {
            let color = capture.flatMap(SyntaxTheme.color(forCapture:)) ?? NSColor.textColor
            context.setFillColor(color.withAlphaComponent(0.55).cgColor)
            context.fill(rects)
        }
    }

    private func runs(forLine line: Int, in text: NSString, controller: TextEditorController) -> [Run<String?>] {
        let range = controller.lineIndex.contentRange(ofLine: line)
        guard range.length > 0, NSMaxRange(range) <= text.length else { return [] }
        var units = [UInt16](repeating: 0, count: min(range.length, Self.columns * 2))
        text.getCharacters(&units, range: NSRange(location: range.location, length: units.count))
        // The colour under each character, as TextKit draws it: later (inner) captures win.
        var names = [String?](repeating: nil, count: units.count)
        for capture in controller.highlighter?.captures(in: NSRange(location: range.location, length: units.count)) ?? []
        where SyntaxTheme.color(forCapture: capture.name) != nil {
            let start = max(0, capture.range.location - range.location)
            let end = min(units.count, capture.range.location + capture.range.length - range.location)
            if start < end { for index in start..<end { names[index] = capture.name } }
        }
        return Self.runs(in: units, tabWidth: Self.tabWidth, maxColumns: Self.columns) { names[$0] }
    }

    // MARK: Interaction

    private func mark(at point: NSPoint) -> Mark? {
        hits.last { $0.rect.contains(point) }?.mark
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = mark(at: convert(event.locationInWindow, from: nil))?.noteID
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    /// Where a slider drag began: the pointer's y, the scroll fraction then, and how many lines were showing.
    private var sliderDragStart: (y: CGFloat, fraction: CGFloat, visibleCount: Int)? {
        didSet { if (oldValue == nil) != (sliderDragStart == nil) { needsDisplay = true } }
    }

    private func beginSliderDrag(at y: CGFloat) {
        let layout = layout
        sliderDragStart = (y, layout.scrollFraction, layout.visibleLines?.count ?? layout.lineCount)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = layout
        if let mark = mark(at: point), let controller,
           let range = controller.highlights.first(where: { $0.id == mark.noteID })?.range {
            // Go to the note, the way browsing the notes panel does: the view moves there, the keyboard stays put.
            controller.dismissPeek()
            controller.scroll(to: range, select: false)
            return
        }
        if let hunk = hunkHits.last(where: { $0.rect.contains(point) })?.mark, let controller {
            controller.scroll(to: controller.lineIndex.contentRange(ofLine: hunk.lines.lowerBound), select: false)
            return
        }
        // Marks under the slider stay clickable; a press anywhere else on the slider drags it.
        if let slider = layout.slider, point.y >= slider.y, point.y <= slider.y + slider.height {
            beginSliderDrag(at: point.y)
            return
        }
        // Centre the line under the pointer, then let a drag carry on from there, as VS Code's minimap does.
        showLine(layout.line(atY: point.y), true)
        beginSliderDrag(at: point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = sliderDragStart, let controller else { return }
        let travel = layout.sliderTravel
        guard travel > 0 else { return }
        let fraction = start.fraction + (convert(event.locationInWindow, from: nil).y - start.y) / travel
        showLine(Layout.firstLine(forFraction: fraction, visibleCount: start.visibleCount,
                                  lineCount: controller.lineIndex.lineCount), false)
    }

    override func mouseUp(with event: NSEvent) {
        sliderDragStart = nil
    }

    // A drag cut short (hidden from Settings, the window closing) never gets its mouse-up.
    override func viewDidHide() {
        super.viewDidHide()
        sliderDragStart = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        sliderDragStart = nil
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// How both minimaps (the editor's and rendered Markdown's) draw their chrome, so they read the same.
@MainActor
enum MinimapStyle {
    static func drawSeparator(height: CGFloat) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: height).fill()
    }

    static func drawSlider(_ rect: NSRect, dragging: Bool) {
        NSColor.labelColor.withAlphaComponent(dragging ? 0.14 : 0.08).setFill()
        rect.fill(using: .sourceOver)
    }

    /// A note's place: its span tinted, with a solid bar at `barX` (the trailing edge) so it is found at a glance, on
    /// the state ladder. A removal is a hairline where the text was, as the gutter's hollow dot: a place, not text; an
    /// orphan is outlined.
    static func drawNote(_ rect: NSRect, barX: CGFloat, color noteColor: NoteColor, state: NoteState, isPoint: Bool, hovered: Bool) {
        let color = Theme.color(for: noteColor)
        let strength = Theme.strength(for: state)
        if isPoint {
            color.withAlphaComponent(hovered ? 1 : max(0.6, strength)).setFill()
            NSRect(x: rect.minX, y: rect.minY - 0.5, width: rect.width, height: 1).fill()
        } else if state == .orphaned {
            color.withAlphaComponent(strength).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        } else {
            color.withAlphaComponent((hovered ? 0.45 : 0.28) * strength).setFill()
            rect.fill(using: .sourceOver)
            color.withAlphaComponent(hovered ? 1 : strength).setFill()
            NSRect(x: barX, y: rect.minY, width: 3, height: max(2, rect.height)).fill()
        }
    }
}

extension MinimapView {
    /// Where a page of rendered content sits in a minimap, in the minimap's points: the same rule as `Layout`, for a
    /// picture whose rows are not lines. `visible` is the part on screen, in content points, nil when all of it is.
    nonisolated struct PageLayout: Equatable {
        var contentHeight: CGFloat
        var viewHeight: CGFloat
        var visible: ClosedRange<CGFloat>?

        private var spanHeight: CGFloat { visible.map { max(4, $0.upperBound - $0.lowerBound) } ?? contentHeight }

        /// How far along the visible span is: the slider then sits exactly over it.
        var fraction: CGFloat {
            guard let visible else { return 0 }
            let range = contentHeight - spanHeight
            return range > 0 ? min(1, max(0, visible.lowerBound / range)) : 0
        }

        var offset: CGFloat { max(0, contentHeight - viewHeight) * fraction }

        var slider: (y: CGFloat, height: CGFloat)? {
            guard visible != nil else { return nil }
            let track = min(viewHeight, contentHeight)
            let height = min(track, spanHeight)
            return ((track - height) * fraction, height)
        }

        var sliderTravel: CGFloat {
            guard let slider else { return 0 }
            return max(0, min(viewHeight, contentHeight) - slider.height)
        }

        func contentY(atViewY y: CGFloat) -> CGFloat { min(contentHeight, max(0, y + offset)) }

        /// The top of the visible span for a fraction, the inverse of `fraction`.
        func spanTop(forFraction fraction: CGFloat) -> CGFloat {
            min(1, max(0, fraction)) * max(0, contentHeight - spanHeight)
        }
    }
}
