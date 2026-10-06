import AppKit
import Core

/// A thin strip at the editor's trailing edge that maps the whole file: a tick per note in its colour, at its place in
/// the file, and a faint band for the part on screen, as Xcode's issue markers and VS Code's overview ruler do. Ticks
/// widen under the pointer and a click scrolls to the note (as browsing the notes panel does); a click or drag anywhere
/// else scrolls there. Only shown while the file has notes.
final class OverviewRulerView: NSView {
    weak var controller: TextEditorController?
    weak var scrollView: NSScrollView?

    static let width: CGFloat = 12
    private static let inset: CGFloat = 4

    /// One note's place in the file, as fractions of its lines; pure so the mapping is testable.
    struct Mark: Equatable {
        var noteID: NoteID
        var color: NoteColor
        var state: NoteState
        var invalidated: Bool
        var line: Int
        var start: CGFloat
        var end: CGFloat
    }

    nonisolated static func marks(for highlights: [TextHighlight], lineIndex: LineIndex) -> [Mark] {
        let lines = CGFloat(max(1, lineIndex.lineCount))
        // Settled notes underneath, open work on top.
        let order: [NoteState: Int] = [.resolved: 0, .sent: 1, .orphaned: 2, .draft: 3]
        return highlights.map { highlight in
            let first = lineIndex.position(forUTF16Offset: highlight.range.location).line
            let last = lineIndex.position(forUTF16Offset: highlight.range.location + max(0, highlight.range.length - 1)).line
            return Mark(noteID: highlight.id, color: highlight.color, state: highlight.state, invalidated: highlight.isInvalidated,
                        line: first, start: CGFloat(first - 1) / lines, end: CGFloat(last) / lines)
        }
        .sorted { (order[$0.state] ?? 0, $0.line) < (order[$1.state] ?? 0, $1.line) }
    }

    /// A hunk's place in the file, as fractions of its lines.
    struct HunkMark: Equatable {
        var lines: ClosedRange<Int>
        var isDeletion: Bool
        var start: CGFloat
        var end: CGFloat
    }

    nonisolated static func hunkMarks(for changes: LineChanges, lineIndex: LineIndex) -> [HunkMark] {
        let lines = CGFloat(max(1, lineIndex.lineCount))
        let added = changes.added.map { HunkMark(lines: $0, isDeletion: false, start: CGFloat($0.lowerBound - 1) / lines, end: CGFloat($0.upperBound) / lines) }
        let deleted = changes.deletions.map { HunkMark(lines: $0...$0, isDeletion: true, start: CGFloat($0 - 1) / lines, end: CGFloat($0 - 1) / lines) }
        return (added + deleted).sorted { $0.lines.lowerBound < $1.lines.lowerBound }
    }

    private var hits: [(rect: NSRect, mark: Mark)] = []
    private var hunkHits: [(rect: NSRect, mark: HunkMark)] = []
    private var hovered: NoteID? {
        didSet { if oldValue != hovered { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    var hasMarks: Bool { !(controller?.highlights.isEmpty ?? true) || !(controller?.lineChanges?.isEmpty ?? true) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private var track: NSRect { bounds.insetBy(dx: 0, dy: Self.inset) }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        // The part of the file on screen.
        if let scrollView, let document = scrollView.documentView, document.frame.height > 0 {
            let visible = scrollView.documentVisibleRect
            let top = track.minY + track.height * visible.minY / document.frame.height
            let height = max(8, track.height * min(1, visible.height / document.frame.height))
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: top, width: bounds.width - 3, height: min(height, track.maxY - top)), xRadius: 3, yRadius: 3).fill()
        }

        // Hunks in a lane of their own at the left, under the notes.
        hunkHits = []
        if let changes = controller.lineChanges {
            for hunk in Self.hunkMarks(for: changes, lineIndex: controller.lineIndex) {
                let y = (track.minY + track.height * hunk.start).rounded()
                let rect = hunk.isDeletion
                    ? NSRect(x: 1.5, y: min(y, track.maxY - 2), width: 3, height: 2)
                    : NSRect(x: 1.5, y: min(y, track.maxY - 3), width: 2, height: max(3, (track.height * (hunk.end - hunk.start)).rounded()))
                (hunk.isDeletion ? Theme.changeDeletedMarker : Theme.changeBar).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                hunkHits.append((rect.insetBy(dx: -2, dy: -3), hunk))
            }
        }
        hits = []
        for mark in Self.marks(for: controller.highlights, lineIndex: controller.lineIndex) {
            let isHovered = mark.noteID == hovered
            let x: CGFloat = isHovered ? 2 : 3.5
            let y = (track.minY + track.height * mark.start).rounded()
            let height = max(3, (track.height * (mark.end - mark.start)).rounded())
            let rect = NSRect(x: x, y: min(y, track.maxY - 3), width: bounds.width - x - 1.5, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            let color = Theme.color(for: mark.color)
            if mark.state == .orphaned || mark.invalidated {
                color.setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                let alpha = Theme.strength(for: mark.state)
                color.withAlphaComponent(isHovered ? 1 : alpha).setFill()
                path.fill()
            }
            // A generous target: thin ticks are hard to hit.
            hits.append((rect.insetBy(dx: -3, dy: -3), mark))
        }
    }

    private func mark(at point: NSPoint) -> Mark? {
        hits.last { $0.rect.contains(point) }?.mark
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = mark(at: convert(event.locationInWindow, from: nil))?.noteID
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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
        scroll(toTrackPoint: point)
    }

    override func mouseDragged(with event: NSEvent) {
        scroll(toTrackPoint: convert(event.locationInWindow, from: nil))
    }

    /// Centres the view on the part of the file under the point, like scrubbing a minimap.
    private func scroll(toTrackPoint point: NSPoint) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let fraction = min(1, max(0, (point.y - track.minY) / max(1, track.height)))
        let visible = scrollView.documentVisibleRect.height
        let y = min(max(0, document.frame.height * fraction - visible / 2), max(0, document.frame.height - visible))
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func isAccessibilityElement() -> Bool { false }
}
