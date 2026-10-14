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
    /// Updated with highlights, so native path redraws can classify a code note in constant time.
    public var codeNoteIDs: Set<NoteID> = []

    public func changed() {
        onChange?()
    }

    /// How wide a removal point's caret is drawn: wide enough to see and to aim a path at.
    public static let caretWidth: CGFloat = 2

    /// The caret drawn for a removal point (a zero-length note), centred on the insertion point's segment and as
    /// tall as its line.
    public static func caretBar(at segment: CGRect) -> CGRect {
        CGRect(x: segment.minX - caretWidth / 2, y: segment.minY, width: caretWidth, height: segment.height)
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
        let inset = textContainerOrigin
        var result: [NoteID: [CGRect]] = [:]
        for (id, range) in ranges {
            // A removal point is its caret, so a path reaches where the text was.
            if range.length == 0 {
                guard range.location >= visibleStart, range.location <= visibleEnd, let caret = caretRect(at: range.location) else { continue }
                let clipped = caret.intersection(visible)
                if !clipped.isNull, clipped.height > 0, let rect = topLeftWindowRect(clipped) { result[id, default: []].append(rect) }
                continue
            }
            let lower = max(range.location, visibleStart)
            let upper = min(range.location + range.length, visibleEnd)
            guard upper > lower,
                  let from = contentManager.location(start, offsetBy: lower),
                  let to = contentManager.location(start, offsetBy: upper),
                  let textRange = NSTextRange(location: from, end: to) else { continue }
            var rects: [CGRect] = []
            layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
                let clipped = frame.offsetBy(dx: inset.x, dy: inset.y).intersection(visible)
                if !clipped.isNull, clipped.height > 0, let rect = self.topLeftWindowRect(clipped) { rects.append(rect) }
                return true
            }
            if !rects.isEmpty { result[id, default: []] += rects }
        }
        return result
    }
}

extension NSTextView {
    /// The caret of a removal point at `offset`: the insertion point there, `NoteGeometry.caretWidth` wide and as
    /// tall as its line, in this view's coordinates (container inset applied). Nil when TextKit has no segment there.
    func caretRect(at offset: Int) -> CGRect? {
        guard let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset) else { return nil }
        var segment: CGRect?
        // `.standard` gives an empty range its insertion point, as a text view's own caret is found.
        layoutManager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            segment = frame
            return false
        }
        guard var frame = segment else { return nil }
        if frame.height < 1 {
            // After the last line TextKit gives the caret no height: use a line of the editor's font.
            let font = self.font ?? Theme.editorFont
            frame.size.height = (font.ascender - font.descender + font.leading).rounded(.up)
        }
        return NoteGeometry.caretBar(at: frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
    }
}
