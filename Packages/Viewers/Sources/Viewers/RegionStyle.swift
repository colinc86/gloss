import AppKit
import Core

/// How marked regions look in every viewer that has them (images, PDF pages), drawn in a flipped view.
/// `unit` is one screen point in the view's coordinates (1 / magnification), so strokes and labels keep their size.
enum RegionStyle {
    /// A note's region: a soft rounded tint, its colour as a border, and a tab at the top-left corner so regions
    /// read as notes rather than as part of the picture.
    static func drawNote(_ rect: CGRect, color noteColor: NoteColor, state: NoteState, selected: Bool, unit: CGFloat) {
        let color = Theme.color(for: noteColor)
        let radius = min(6 * unit, min(rect.width, rect.height) / 4)
        let region = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let settled = state == .resolved
        color.withAlphaComponent(settled ? 0.06 : 0.16).setFill()
        region.fill()
        region.lineWidth = (selected ? 2.5 : 1.5) * unit
        if state == .orphaned { region.setLineDash([4 * unit, 3 * unit], count: 2, phase: 0) }
        color.withAlphaComponent(settled ? 0.45 : 1).setStroke()
        region.stroke()
        if selected {
            // A halo outside the border marks the note chosen in the panel.
            let halo = NSBezierPath(roundedRect: rect.insetBy(dx: -3 * unit, dy: -3 * unit), xRadius: radius + 3 * unit, yRadius: radius + 3 * unit)
            halo.lineWidth = 3 * unit
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            halo.stroke()
        }
        // The tab: a small filled pill hanging off the top-left corner.
        let tab = NSRect(x: rect.minX, y: rect.minY - 7 * unit, width: 18 * unit, height: 7 * unit)
        if tab.minY >= 0 {
            color.withAlphaComponent(settled ? 0.45 : 1).setFill()
            NSBezierPath(roundedRect: tab, xRadius: 3.5 * unit, yRadius: 3.5 * unit).fill()
        }
    }

    /// The region being chosen, drawn like a crop tool: the rest of the image dims, the edge is a white line with a
    /// dark outline (visible on any picture), the corners carry handles, and a pill shows the size in pixels.
    static func drawSelection(_ selection: CGRect, in bounds: CGRect, unit: CGFloat, label text: String) {
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: selection))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill()
        dim.fill()

        let edge = NSBezierPath(rect: selection)
        edge.lineWidth = 3 * unit
        NSColor.black.withAlphaComponent(0.35).setStroke()
        edge.stroke()
        edge.lineWidth = 1.5 * unit
        NSColor.white.setStroke()
        edge.stroke()

        // L-shaped handles at the corners.
        let arm = min(14 * unit, selection.width / 2, selection.height / 2)
        let handles = NSBezierPath()
        for (x, y, dx, dy) in [(selection.minX, selection.minY, 1.0, 1.0), (selection.maxX, selection.minY, -1.0, 1.0),
                               (selection.minX, selection.maxY, 1.0, -1.0), (selection.maxX, selection.maxY, -1.0, -1.0)] {
            handles.move(to: NSPoint(x: x + dx * arm, y: y))
            handles.line(to: NSPoint(x: x, y: y))
            handles.line(to: NSPoint(x: x, y: y + dy * arm))
        }
        handles.lineCapStyle = .round
        handles.lineJoinStyle = .round
        // A dark outline under the white handles keeps them visible on white pages and pale images.
        handles.lineWidth = 6 * unit
        NSColor.black.withAlphaComponent(0.35).setStroke()
        handles.stroke()
        handles.lineWidth = 4 * unit
        NSColor.white.setStroke()
        handles.stroke()

        // Size pill centred below the selection (above it at the bottom edge); the Add Note button owns the space
        // above.
        let label = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * unit, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let pillSize = NSSize(width: size.width + 12 * unit, height: size.height + 4 * unit)
        var pill = NSRect(x: selection.midX - pillSize.width / 2, y: selection.maxY + 8 * unit, width: pillSize.width, height: pillSize.height)
        if pill.maxY > bounds.height { pill.origin.y = selection.minY - pillSize.height - 8 * unit }
        pill.origin.x = min(max(0, pill.minX), bounds.width - pill.width)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 6 * unit, y: pill.minY + 2 * unit), withAttributes: attributes)
    }

}
