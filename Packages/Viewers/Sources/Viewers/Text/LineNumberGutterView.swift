import AppKit
import Core

/// Line numbers and note markers beside a `SourceTextView`. A plain sibling of the scroll view, not an
/// `NSRulerView`: a vertical ruler stops TextKit 2's content layers from drawing on screen (seen on macOS 26).
final class LineNumberGutterView: NSView {
    weak var controller: TextEditorController?
    private weak var textView: SourceTextView?
    private var markerRects: [(rect: NSRect, noteID: NoteID)] = []
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
        let width = CGFloat(digits) * 7 + 22
        if abs(gutterWidth - width) > 0.5 {
            gutterWidth = width
            superview?.needsLayout = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let controller, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        markerRects = []

        let visible = textView.visibleRect
        let inset = textView.textContainerInset
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let currentAttributes: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: NSColor.secondaryLabelColor]
        let currentLine = controller.lineIndex.position(forUTF16Offset: controller.selection.location).line
        let markersByLine = Dictionary(grouping: controller.highlights) { controller.lineIndex.position(forUTF16Offset: $0.range.location).line }
        let documentStart = contentManager.documentRange.location

        let topPoint = CGPoint(x: 0, y: max(0, visible.minY - inset.height))
        let startLocation = layoutManager.textLayoutFragment(for: topPoint)?.rangeInElement.location ?? documentStart
        layoutManager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let y = frame.minY + inset.height - visible.minY
            if y > bounds.maxY { return false }
            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let line = controller.lineIndex.position(forUTF16Offset: offset).line
            let firstLineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            let label = NSAttributedString(string: String(line), attributes: line == currentLine ? currentAttributes : attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: gutterWidth - size.width - 6, y: y + (firstLineHeight - size.height) / 2))
            if let marks = markersByLine[line] {
                for (index, mark) in marks.prefix(3).enumerated() {
                    let dot = NSRect(x: 4 + CGFloat(index) * 6, y: y + firstLineHeight / 2 - 3, width: 6, height: 6)
                    Theme.color(for: mark.color).withAlphaComponent(mark.state == .resolved ? 0.4 : 1).setFill()
                    NSBezierPath(ovalIn: dot).fill()
                    markerRects.append((NSRect(x: 0, y: y, width: gutterWidth, height: firstLineHeight), mark.id))
                }
            }
            return true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let textView, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = markerRects.first(where: { $0.rect.contains(point) }) {
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

/// Gutter on the left, scroll view on the right.
public final class TextEditorContainerView: NSView {
    let gutter: LineNumberGutterView
    let scrollView: NSScrollView

    init(gutter: LineNumberGutterView, scrollView: NSScrollView) {
        self.gutter = gutter
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func layout() {
        super.layout()
        let width = gutter.gutterWidth
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }
}
