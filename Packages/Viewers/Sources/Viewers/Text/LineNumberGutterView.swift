import AppKit
import Core

/// Line numbers and note markers beside a `SourceTextView`. A plain sibling of the scroll view, not an
/// `NSRulerView`: a vertical ruler stops TextKit 2's content layers from drawing on screen (seen on macOS 26).
final class LineNumberGutterView: NSView {
    weak var controller: TextEditorController?
    private weak var textView: SourceTextView?
    private var markerRects: [(rect: NSRect, noteID: NoteID)] = []
    /// Earlier notes' marks, one per line they start on: where each is, and its notes.
    private var earlierRects: [(rect: NSRect, ids: [NoteID], range: NSRange)] = []
    private var hoveredEarlierLine: NSRect?
    private(set) var gutterWidth: CGFloat = 44

    init(textView: SourceTextView, controller: TextEditorController) {
        self.textView = textView
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func updateWidth() {
        let digits = max(3, String(controller?.lineIndex.lineCount ?? 1).count)
        // Room for three note lanes before the numbers, and a column for earlier notes' marks while there are any.
        let width = CGFloat(digits) * 7 + 26 + (controller?.earlierMarks.isEmpty == false ? Self.earlierColumn : 0)
        if abs(gutterWidth - width) > 0.5 {
            gutterWidth = width
            superview?.needsLayout = true
        }
        needsDisplay = true
    }

    /// The note bar under the pointer, drawn wider; hovering a bar also shows that note's peek.
    private var hoveredNoteID: NoteID?
    private var hoverTracking: NSTrackingArea?

    /// Lanes for note bars: notes whose lines overlap sit side by side, up to `maxLanes`.
    static let maxLanes = 3
    static let barWidth: CGFloat = 3
    static let laneGap: CGFloat = 2
    /// A removal point's hollow dot.
    static let pointDiameter: CGFloat = 6
    /// The column after the lanes holding earlier notes' marks.
    static let earlierColumn: CGFloat = 11
    static let earlierX: CGFloat = 3 + CGFloat(maxLanes) * (barWidth + laneGap) + 1

    /// Earlier marks grouped by the line each starts on, the line's notes in the order given (newest first).
    static func earlierByLine(_ marks: [EarlierMark], lineIndex: LineIndex) -> [(line: Int, ids: [NoteID], range: NSRange)] {
        var lines: [Int: (ids: [NoteID], range: NSRange)] = [:]
        for mark in marks {
            let line = lineIndex.positions(for: mark.range).start.line
            if var entry = lines[line] {
                entry.ids.append(mark.id)
                entry.range = NSUnionRange(entry.range, mark.range)
                lines[line] = entry
            } else {
                lines[line] = ([mark.id], mark.range)
            }
        }
        return lines.sorted { $0.key < $1.key }.map { ($0.key, $0.value.ids, $0.value.range) }
    }

    /// One earlier note: a small hollow card; several: two stacked, with the count in the tooltip.
    private func drawEarlierMark(count: Int, at rect: NSRect, hovered: Bool) {
        (hovered ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
        let card = NSRect(x: rect.minX + 1, y: rect.minY + 2, width: rect.width - 3, height: rect.height - 4)
        if count > 1 {
            let back = NSBezierPath(roundedRect: card.offsetBy(dx: 1.5, dy: -1.5), xRadius: 1.5, yRadius: 1.5)
            back.lineWidth = 1
            back.stroke()
            ActiveCodeTheme.editorColor(\.gutterBackground).setFill()
            NSBezierPath(roundedRect: card, xRadius: 1.5, yRadius: 1.5).fill()
        }
        let front = NSBezierPath(roundedRect: card, xRadius: 1.5, yRadius: 1.5)
        front.lineWidth = 1
        front.stroke()
    }

    /// Assigns each highlight (by start and end line) the first lane free at its start; extras share the last lane.
    static func lanes(for spans: [(id: NoteID, start: Int, end: Int)]) -> [NoteID: Int] {
        var laneEnds: [Int] = []
        var result: [NoteID: Int] = [:]
        for span in spans.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let free = laneEnds.firstIndex(where: { $0 < span.start }) {
                laneEnds[free] = span.end
                result[span.id] = free
            } else if laneEnds.count < maxLanes {
                laneEnds.append(span.end)
                result[span.id] = laneEnds.count - 1
            } else {
                laneEnds[maxLanes - 1] = max(laneEnds[maxLanes - 1], span.end)
                result[span.id] = maxLanes - 1
            }
        }
        return result
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let earlierHit = earlierRects.last { $0.rect.insetBy(dx: -1, dy: -1).contains(point) }
        let earlier = earlierHit?.rect
        if earlier != hoveredEarlierLine {
            hoveredEarlierLine = earlier
            needsDisplay = true
            if earlier != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            toolTip = earlierHit.map { $0.ids.count == 1 ? "1 earlier note here" : "\($0.ids.count) earlier notes here" }
        }
        if earlier != nil {
            // Straight from a note's bar to the earlier column: the bar is no longer under the pointer.
            if hoveredNoteID != nil {
                hoveredNoteID = nil
                controller?.hover(at: nil)
            }
            return
        }
        let hit = markerRects.last { $0.rect.contains(point) }?.noteID
        guard hit != hoveredNoteID else { return }
        hoveredNoteID = hit
        needsDisplay = true
        if let hit, let range = controller?.highlights.first(where: { $0.id == hit })?.range {
            controller?.hover(at: range.length > 0 ? range.location : nil, caret: range.length > 0 ? nil : range.location)
        } else {
            controller?.hover(at: nil)
        }
        if hit != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredNoteID != nil {
            hoveredNoteID = nil
            needsDisplay = true
            controller?.hover(at: nil)
        }
        NSCursor.arrow.set()
    }

    /// Carries the editor's current-line band across the gutter, so number and line read as one row.
    var showsCurrentLine = false {
        didSet { if oldValue != showsCurrentLine { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let controller, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        ActiveCodeTheme.editorColor(\.gutterBackground).setFill()
        bounds.fill()
        markerRects = []

        let visible = textView.visibleRect
        let inset = textView.textContainerInset
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: ActiveCodeTheme.editorColor(\.lineNumbers)]
        let currentAttributes: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: ActiveCodeTheme.editorColor(\.currentLineNumber)]
        let currentLine = controller.lineIndex.position(forUTF16Offset: controller.selection.location).line
        let documentStart = contentManager.documentRange.location

        // Each visible line's vertical extent, for bars spanning several lines.
        var lineFrames: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
        var firstVisible = Int.max, lastVisible = 0
        let topPoint = CGPoint(x: 0, y: max(0, visible.minY - inset.height))
        let startLocation = layoutManager.textLayoutFragment(for: topPoint)?.rangeInElement.location ?? documentStart
        layoutManager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let y = frame.minY + inset.height - visible.minY
            if y > bounds.maxY { return false }
            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let line = controller.lineIndex.position(forUTF16Offset: offset).line
            let firstLineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            if line == currentLine, showsCurrentLine, controller.selection.length == 0 {
                let height = fragment.textLineFragments.filter { $0.characterRange.length > 0 }.reduce(0) { $0 + $1.typographicBounds.height }
                HighlightBackdropView.currentLineColor.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: height > 0 ? height : frame.height).fill()
            }
            lineFrames[line] = (y, y + frame.height)
            firstVisible = min(firstVisible, line)
            lastVisible = max(lastVisible, line)
            if let changes = controller.lineChanges {
                // A change bar at the text's edge, as VS Code marks changed rows, and a hairline where lines went.
                if changes.contains(line: line) {
                    let rows = fragment.textLineFragments.filter { $0.characterRange.length > 0 }.reduce(0) { $0 + $1.typographicBounds.height }
                    Theme.changeBar.setFill()
                    NSRect(x: gutterWidth - 2, y: y, width: 2, height: rows > 0 ? rows : frame.height).fill()
                }
                if changes.deletions.contains(line) {
                    Theme.changeDeletedMarker.setFill()
                    NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
                }
            }
            let label = NSAttributedString(string: String(line), attributes: line == currentLine ? currentAttributes : attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: gutterWidth - size.width - 6, y: y + (firstLineHeight - size.height) / 2))
            return true
        }
        guard firstVisible <= lastVisible else { return }

        // Earlier iterations' notes: a small card on the line each starts on, in its own column after the lanes.
        earlierRects = []
        for entry in Self.earlierByLine(controller.drawnEarlierMarks, lineIndex: controller.lineIndex) {
            guard let frame = lineFrames[entry.line] else { continue }
            let rect = NSRect(x: Self.earlierX, y: frame.top + 1, width: Self.earlierColumn - 2, height: min(14, frame.bottom - frame.top - 2))
            drawEarlierMark(count: entry.ids.count, at: rect, hovered: rect == hoveredEarlierLine)
            earlierRects.append((rect, entry.ids, entry.range))
        }

        // Note bars: one per note, spanning its lines, in lanes when notes overlap.
        let spans = controller.drawnHighlights.filter { !$0.isInvalidated }.map { highlight -> (id: NoteID, start: Int, end: Int) in
            let (start, end) = controller.lineIndex.positions(for: highlight.range)
            // A range ending at column 1 of the next line does not cover that line.
            let last = end.line > start.line && end.col <= 1 ? end.line - 1 : end.line
            return (highlight.id, start.line, max(start.line, last))
        }
        let lanes = Self.lanes(for: spans)
        for span in spans {
            guard let highlight = controller.highlights.first(where: { $0.id == span.id }) else { continue }
            let hovered = span.id == hoveredNoteID
            let lane = CGFloat(lanes[span.id] ?? 0)
            let color = Theme.codeColor(for: highlight.color)
            // A removal point is a hollow dot on its caret's row: there is no text left for a bar to span. Placed by
            // the caret itself, since the empty last line after a final newline has no layout fragment of its own.
            if highlight.range.length == 0 {
                let diameter = Self.pointDiameter + (hovered ? 1.5 : 0)
                guard let caret = textView.caretRect(at: highlight.range.location) else { continue }
                let caretY = caret.midY - visible.minY
                guard caretY >= -diameter, caretY <= bounds.height + diameter else { continue }
                let dot = NSRect(x: 3 + lane * (Self.barWidth + Self.laneGap) + Self.barWidth / 2 - diameter / 2, y: caretY - diameter / 2,
                                 width: diameter, height: diameter).insetBy(dx: 0.75, dy: 0.75)
                let ring = NSBezierPath(ovalIn: dot)
                ring.lineWidth = 1.5
                color.withAlphaComponent(hovered || highlight.needsReview ? 1 : 0.9 * Theme.strength(for: highlight.state)).setStroke()
                ring.stroke()
                markerRects.append((dot.insetBy(dx: -3, dy: -3), span.id))
                continue
            }
            guard span.end >= firstVisible, span.start <= lastVisible else { continue }
            let topLine = max(span.start, firstVisible), bottomLine = min(span.end, lastVisible)
            guard let top = (topLine...bottomLine).lazy.compactMap({ lineFrames[$0]?.top }).first,
                  let bottom = (topLine...bottomLine).reversed().lazy.compactMap({ lineFrames[$0]?.bottom }).first else { continue }
            let width = Self.barWidth + (hovered ? 1.5 : 0)
            let bar = NSRect(x: 3 + lane * (Self.barWidth + Self.laneGap) - (hovered ? 0.75 : 0), y: top + 2, width: width, height: max(4, bottom - top - 4))
            let path = NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2)
            switch highlight.state {
            case .orphaned:
                color.withAlphaComponent(0.8).setStroke()
                path.lineWidth = 1
                path.setLineDash([2, 2], count: 2, phase: 0)
                path.stroke()
            default:
                // The state ladder (#12): drafts strong, sent quieter, resolved faint; hover brings any up.
                color.withAlphaComponent(hovered || highlight.needsReview ? 1 : 0.9 * Theme.strength(for: highlight.state)).setFill()
                path.fill()
            }
            // Generous hit area: the lane plus a little either side, over the whole span.
            markerRects.append((NSRect(x: bar.minX - 2, y: top, width: bar.width + 4, height: bottom - top), span.id))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let textView, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = earlierRects.last(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(point) }) {
            controller.dismissPeek()
            // A second click on the same mark puts its card away.
            controller.earlierPeek = controller.earlierPeek?.ids == hit.ids ? nil : (hit.ids, hit.range)
            return
        }
        controller.earlierPeek = nil
        if let hit = markerRects.last(where: { $0.rect.contains(point) }) {
            controller.dismissPeek()
            let location = controller.highlights.first { $0.id == hit.noteID }?.range.location ?? 0
            controller.onGutterClick(controller.lineIndex.position(forUTF16Offset: location).line, hit.noteID)
            return
        }
        let textPoint = CGPoint(x: 0, y: point.y + textView.visibleRect.minY - textView.textContainerInset.height)
        guard let fragment = layoutManager.textLayoutFragment(for: textPoint) else { return }
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        controller.onGutterClick(controller.lineIndex.position(forUTF16Offset: offset).line, nil)
    }
}

/// Gutter on the left, scroll view in the middle, minimap on the right.
public final class TextEditorContainerView: NSView {
    let gutter: LineNumberGutterView
    let scrollView: NSScrollView
    let minimap: MinimapView

    init(gutter: LineNumberGutterView, scrollView: NSScrollView, minimap: MinimapView) {
        self.gutter = gutter
        self.scrollView = scrollView
        self.minimap = minimap
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        addSubview(minimap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func layout() {
        super.layout()
        let width = gutter.gutterWidth
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        // The minimap takes no room while Settings › Editor has it off.
        let minimapWidth = Theme.showsMinimap ? MinimapView.width : 0
        minimap.isHidden = minimapWidth == 0
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width - minimapWidth), height: bounds.height)
        minimap.frame = NSRect(x: bounds.width - minimapWidth, y: 0, width: minimapWidth, height: bounds.height)
    }
}
