import AppKit
import Core

/// Where a viewer's notes sit on screen, for the notes panel's link and paths. The view fills in the closures when it
/// attaches; the app sets `onChange` and reads after each change. Rects are top-left window coordinates (SwiftUI's
/// `.global`).
public final class NoteGeometry {
    public init() {}

    /// The visible part of the document; nil while the view is not in a window.
    public var viewport: () -> CGRect? = { nil }
    /// Each note with a highlight on screen, as one rect per line fragment (the highlight's own shape), clipped to
    /// the viewport.
    public var visibleNoteRects: () -> [NoteID: [CGRect]] = { [:] }
    /// Set by the app; called after the view scrolls, resizes, lays out again, or its highlights change.
    public var onChange: (() -> Void)?

    public func changed() {
        onChange?()
    }
}

extension NSTextView {
    /// The visible part of the text view, in top-left window coordinates.
    func visibleWindowRect() -> CGRect? {
        let visible = visibleRect
        guard window != nil, !visible.isEmpty else { return nil }
        return topLeftWindowRect(visible)
    }

    /// Each range's highlight segments (the shapes the backdrop fills) that are on screen, clipped to the visible
    /// rect, in top-left window coordinates. Only the laid-out viewport is walked, so the cost is what is on screen.
    func visibleHighlightRects(for ranges: [(id: NoteID, range: NSRange)]) -> [NoteID: [CGRect]] {
        guard window != nil, let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else { return [:] }
        let start = contentManager.documentRange.location
        let visibleStart = contentManager.offset(from: start, to: viewport.location)
        let visibleEnd = contentManager.offset(from: start, to: viewport.endLocation)
        let visible = visibleRect
        let inset = textContainerInset
        var result: [NoteID: [CGRect]] = [:]
        for (id, range) in ranges where range.length > 0 {
            let lower = max(range.location, visibleStart)
            let upper = min(range.location + range.length, visibleEnd)
            guard upper > lower,
                  let from = contentManager.location(start, offsetBy: lower),
                  let to = contentManager.location(start, offsetBy: upper),
                  let textRange = NSTextRange(location: from, end: to) else { continue }
            var rects: [CGRect] = []
            layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
                let clipped = frame.offsetBy(dx: inset.width, dy: inset.height).intersection(visible)
                if !clipped.isNull, clipped.height > 0, let rect = self.topLeftWindowRect(clipped) { rects.append(rect) }
                return true
            }
            if !rects.isEmpty { result[id, default: []] += rects }
        }
        return result
    }
}
