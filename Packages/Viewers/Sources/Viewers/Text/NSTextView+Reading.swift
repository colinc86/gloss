import AppKit

/// Where the reader is in a text view, and putting them back there (#9).
extension NSTextView {
    /// The character at the top-left of what is on screen; nil before the view has a visible area.
    var topVisibleCharacterIndex: Int? {
        guard !visibleRect.isEmpty else { return nil }
        // View coordinates; kept below the top inset, where the probe would find the end of the document.
        let origin = textContainerOrigin
        return characterIndexForInsertion(at: NSPoint(x: max(visibleRect.minX, origin.x) + 1, y: max(visibleRect.minY, origin.y) + 1))
    }

    /// Scrolls so the line holding `location` is at the top of the visible area. Reveals it first, so TextKit lays
    /// it out and its frame is a real one, not an estimate.
    func scrollToTop(_ location: Int) {
        let clamped = min(max(location, 0), string.utf16.count)
        scrollRangeToVisible(NSRange(location: clamped, length: 0))
        guard let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: clamped) else { return }
        var top: CGFloat?
        layoutManager.enumerateTextSegments(in: NSTextRange(location: start), type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            top = frame.minY
            return false
        }
        guard let top else { return }
        scroll(NSPoint(x: visibleRect.minX, y: max(0, top + textContainerOrigin.y)))
    }
}
