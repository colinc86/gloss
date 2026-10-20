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
        // The picture lies on the canvas like a sheet, as Preview and Pixelmator set theirs (NSView's own shadow:
        // AppKit owns a layer-backed view's layer properties).
        updateShadow(magnification: 1)
    }

    private var shadowMagnification: CGFloat = 0

    /// The shadow is in canvas points, which zoom with the picture; keep it the same on screen.
    private func updateShadow(magnification: CGFloat) {
        guard magnification != shadowMagnification else { return }
        shadowMagnification = magnification
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 10 / magnification
        shadow.shadowOffset = NSSize(width: 0, height: -2 / magnification)
        self.shadow = shadow
    }

    /// Whether the picture has transparent areas worth showing as a checkerboard.
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Quiet checker squares behind transparent pixels, 8 screen points whatever the zoom.
    private func drawCheckerboard(in rect: CGRect, unit: CGFloat, context: CGContext) {
        let side = 8 * unit
        // A dirty rect outside the picture intersects to the null rect, whose infinite edges cannot become
        // column numbers; a zero magnification makes the square infinite. Draw nothing then.
        guard !rect.isEmpty, side.isFinite, side > 0 else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Whole squares are laid down; the clip keeps the last row and column from spilling past the picture.
        context.saveGState()
        context.clip(to: rect)
        defer { context.restoreGState() }
        context.setFillColor(NSColor(white: dark ? 0.20 : 1, alpha: 1).cgColor)
        context.fill(rect)
        var squares: [CGRect] = []
        let firstColumn = Int(floor(rect.minX / side)), lastColumn = Int(ceil(rect.maxX / side))
        let firstRow = Int(floor(rect.minY / side)), lastRow = Int(ceil(rect.maxY / side))
        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn where (row + column) % 2 == 0 {
                squares.append(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side))
            }
        }
        context.setFillColor(NSColor(white: dark ? 0.25 : 0.93, alpha: 1).cgColor)
        context.fill(squares)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let context = NSGraphicsContext.current?.cgContext else { return }
        let image = controller.image.cgImage
        let magnification = enclosingScrollView?.magnification ?? 1
        context.interpolationQuality = magnification >= 4 ? .none : .high
        updateShadow(magnification: magnification)
        if Self.hasAlpha(image) {
            drawCheckerboard(in: dirtyRect.intersection(bounds), unit: 1 / magnification, context: context)
        }
        // The context is flipped; undo it for the image so it is not drawn upside down.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()

        // Everything is sized in screen points: divide by the magnification so strokes, handles, and labels look
        // the same at any zoom.
        let unit = 1 / magnification
        for highlight in controller.highlights {
            RegionStyle.drawNote(highlight.rect, color: highlight.color, state: highlight.state, selected: highlight.id == controller.selectedNoteID, unit: unit)
        }
        if let selection = controller.selection, selection.width >= 1, selection.height >= 1 {
            RegionStyle.drawSelection(selection, in: bounds, unit: unit, label: "\(Int(selection.width)) × \(Int(selection.height)) px")
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

    /// Add Note on the region drawn, and Copy: the canvas has no other menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: controller.selection == nil ? "Copy Image" : "Copy Region", action: #selector(copy(_:)), keyEquivalent: "").target = self
        AddNoteMenuItem.insert(into: menu, when: controller.addNote?.canAdd() ?? false, target: self, action: #selector(addNoteFromMenu(_:)))
        return menu
    }

    @objc func addNoteFromMenu(_ sender: Any?) { controller?.addNote?.add() }

    override func selectAll(_ sender: Any?) {
        controller?.selectAll()
        needsDisplay = true
    }

    /// Edit › Copy (⌘C): the selected region, or the whole picture when nothing is selected, as PNG and TIFF so it
    /// pastes into chats, issues, and image editors alike.
    @objc func copy(_ sender: Any?) {
        guard let controller else { return }
        let image = controller.selection.flatMap { ImageDecoder.crop(controller.image, to: $0) } ?? controller.image.cgImage
        let item = NSPasteboardItem()
        if let png = ImageDecoder.pngData(image) { item.setData(png, forType: .png) }
        if let tiff = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        controller.copyCount += 1
    }
}
