import AppKit
import Core

/// Draws note highlight backgrounds beneath a TextKit 2 text view's content. TextKit 2 applies foreground rendering
/// attributes but not background ones, so backgrounds are painted here from the layout manager's segment rects.
final class HighlightBackdropView: NSView {
    struct Entry {
        var range: NSRange
        var color: NSColor
        var orphaned: Bool
    }

    weak var textView: NSTextView?
    var entries: [Entry] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Installs the backdrop as the bottom-most subview so text content draws over it.
    static func install(in textView: NSTextView) -> HighlightBackdropView {
        let backdrop = HighlightBackdropView(frame: textView.bounds)
        backdrop.textView = textView
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        textView.addSubview(backdrop, positioned: .below, relativeTo: nil)
        return backdrop
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager else { return }
        let documentStart = contentManager.documentRange.location
        let inset = textView.textContainerInset
        for entry in entries where entry.range.length > 0 {
            guard let from = contentManager.location(documentStart, offsetBy: entry.range.location),
                  let to = contentManager.location(documentStart, offsetBy: entry.range.location + entry.range.length),
                  let textRange = NSTextRange(location: from, end: to) else { continue }
            layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
                let rect = frame.offsetBy(dx: inset.width, dy: inset.height)
                guard rect.intersects(dirtyRect) else { return true }
                if entry.orphaned {
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: rect.minX, y: rect.maxY - 1))
                    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 1))
                    path.setLineDash([3, 2], count: 2, phase: 0)
                    path.lineWidth = 1
                    entry.color.setStroke()
                    path.stroke()
                } else {
                    entry.color.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                }
                return true
            }
        }
    }
}
