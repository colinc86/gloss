import AppKit
import Core

/// Flipped so view points equal pixel coordinates at magnification 1 (origin top-left).
final class ImageCanvasView: NSView {
    weak var controller: ImageViewerController?
    private var dragStart: CGPoint?

    init(controller: ImageViewerController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: controller.image.width, height: controller.image.height))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let context = NSGraphicsContext.current?.cgContext else { return }
        let image = controller.image.cgImage
        let magnification = enclosingScrollView?.magnification ?? 1
        context.interpolationQuality = magnification >= 4 ? .none : .high
        // The context is flipped; undo it for the image so it is not drawn upside down.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()

        for highlight in controller.highlights {
            let color = Theme.color(for: highlight.color)
            let path = NSBezierPath(rect: highlight.rect)
            path.lineWidth = max(1, 1.5 / magnification)
            color.withAlphaComponent(highlight.state == .resolved ? 0.08 : 0.2).setFill()
            path.fill()
            color.setStroke()
            if highlight.state == .orphaned { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
            if highlight.id == controller.selectedNoteID {
                NSColor.controlAccentColor.setStroke()
                let outer = NSBezierPath(rect: highlight.rect.insetBy(dx: -2 / magnification, dy: -2 / magnification))
                outer.lineWidth = 2 / magnification
                outer.stroke()
            }
        }
        if let selection = controller.selection {
            let path = NSBezierPath(rect: selection)
            path.lineWidth = max(1, 1.5 / magnification)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func pixelPoint(from event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let point = pixelPoint(from: event)
        if event.clickCount == 1, let hit = controller.highlights.last(where: { $0.rect.contains(point) }) {
            controller.selectedNoteID = hit.id
            controller.selection = nil
            dragStart = nil
            needsDisplay = true
            if event.clickCount == 1 { controller.onNoteClick(hit.id) }
            return
        }
        dragStart = point
        controller.selectedNoteID = nil
        controller.selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let start = dragStart else { return }
        let point = pixelPoint(from: event)
        controller.selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller, dragStart != nil else { return }
        dragStart = nil
        if let selection = controller.selection, selection.width < 2 || selection.height < 2 {
            controller.selection = nil
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // escape
            controller?.selection = nil
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}
