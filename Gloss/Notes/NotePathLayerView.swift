import AppKit
import Core
import QuartzCore
import SwiftUI
import Viewers

/// Draws the paths from notes on the page to their cards: an outline around each note's highlight and a tapered
/// ribbon from it into the top of the card's colour rail.
///
/// AppKit layers, not a SwiftUI canvas: the link model updates them inside the page's own scroll notification, so
/// they land in the same Core Animation transaction as the scrolled text and never trail it by a frame. The view sits
/// in the window's frame view just above the content view, covers it exactly, and is invisible to clicks and
/// accessibility.
///
/// It also draws the one outline around each run of adjacent selected cards (issue #19), which shows whether or not
/// paths do.
@MainActor
final class NotePathLayerView: NSView {
    struct Item {
        var id: NoteID
        var shapes: [NoteOutline.Shape]
        var outline: CGPath
        var card: CGRect?
        var color: NSColor
        /// The state ladder's strength (#12): drafts 1, sent notes quieter, resolved ones faint.
        var strength: CGFloat
        var strong: Bool
    }

    /// A run of adjacent selected cards: the rect its outline goes around, and its color stops top to bottom.
    struct Selection {
        var rect: CGRect
        var stops: [(location: CGFloat, color: NSColor)]
    }

    /// The rail as `NoteCard` draws it: inset by the card's leading padding (`DS.Space.xs`), running the card's
    /// height inside its vertical padding, so its middle is the card's.
    static let railInset: CGFloat = 4
    /// Ribbons fade out over this distance as their card slides out of the list.
    static let edgeFade: CGFloat = 12

    /// The paths (outlines and ribbons), which fade in and out together.
    private let paths = CALayer()
    private let outlines = CALayer()
    private let ribbons = CALayer()
    /// Selection outlines, clipped to the list, in a layer of their own that fades with the notes panel.
    private let selectionFade = CALayer()
    private let selections = CALayer()
    private var selectionLayers: [(gradient: CAGradientLayer, mask: CAShapeLayer)] = []
    private var layers: [NoteID: (outline: CAShapeLayer, ribbon: CALayer, gradient: CAGradientLayer, mask: CAShapeLayer)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        outlines.masksToBounds = true
        paths.addSublayer(outlines)
        paths.addSublayer(ribbons)
        paths.opacity = 0
        layer?.addSublayer(paths)
        selections.masksToBounds = true
        selectionFade.addSublayer(selections)
        layer?.addSublayer(selectionFade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    /// Puts the view above `window`'s content view, covering it; nothing if it is already there.
    func install(in window: NSWindow) {
        guard let content = window.contentView, let frameView = content.superview else { return }
        if superview !== frameView {
            removeFromSuperview()
            frame = content.frame
            autoresizingMask = [.width, .height]
            frameView.addSubview(self, positioned: .above, relativeTo: content)
        }
    }

    /// Shows or hides every path, with a short fade.
    func setShown(_ shown: Bool) {
        fade(paths, shown)
    }

    /// Shows or hides the selection outlines with the notes panel, with the same fade.
    func setSelectionsShown(_ shown: Bool) {
        fade(selectionFade, shown)
    }

    /// Called when the window turns light or dark, with that appearance current: colors are resolved again.
    var onAppearanceChange: () -> Void = {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { onAppearanceChange() }
    }

    private func fade(_ layer: CALayer, _ shown: Bool) {
        let target: Float = shown ? 1 : 0
        guard layer.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = target
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "fade")
        layer.opacity = target
        CATransaction.commit()
    }

    /// Redraws the selection outlines inside `list`, the part of the notes list cards can be seen in: a 1.5 pt
    /// rounded stroke around each run, a vertical gradient through its cards' colors, at full strength while the list
    /// is `active` and half otherwise, as a lone selected card's.
    func updateSelections(_ runs: [Selection], list: CGRect?, active: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let runs = list == nil ? [] : runs
        while selectionLayers.count > runs.count { selectionLayers.removeLast().gradient.removeFromSuperlayer() }
        guard let list else { return }
        selections.frame = list
        selections.sublayerTransform = CATransform3DMakeTranslation(-list.minX, -list.minY, 0)
        selections.opacity = active ? 1 : 0.5
        for (index, run) in runs.enumerated() {
            if index == selectionLayers.count {
                let gradient = CAGradientLayer(), mask = CAShapeLayer()
                mask.fillColor = nil
                mask.strokeColor = NSColor.black.cgColor
                mask.lineWidth = 1.5
                gradient.mask = mask
                selections.addSublayer(gradient)
                selectionLayers.append((gradient, mask))
            }
            let parts = selectionLayers[index]
            // The stroke sits inside the rect, with continuous corners, as SwiftUI's `strokeBorder` drew it on each card.
            parts.gradient.frame = run.rect
            parts.mask.frame = parts.gradient.bounds
            parts.mask.path = RoundedRectangle(cornerRadius: SelectionOutline.radius, style: .continuous)
                .path(in: parts.gradient.bounds.insetBy(dx: 0.75, dy: 0.75)).cgPath
            // One stop is one color, drawn flat.
            let stops = run.stops.count == 1 ? run.stops + run.stops : run.stops
            parts.gradient.colors = stops.map(\.color.cgColor)
            parts.gradient.locations = stops.count == run.stops.count ? stops.map { NSNumber(value: Double($0.location)) } : nil
            parts.gradient.startPoint = CGPoint(x: 0.5, y: 0)
            parts.gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }
    }

    /// Redraws every path; window coordinates (top-left) are this view's own, since it covers the content view.
    func update(_ items: [Item], viewerViewport: CGRect?, panelViewport: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let viewerViewport, let panelViewport else {
            for id in layers.keys { remove(id) }
            return
        }
        outlines.frame = viewerViewport
        outlines.sublayerTransform = CATransform3DMakeTranslation(-viewerViewport.minX, -viewerViewport.minY, 0)
        ribbons.frame = bounds
        var seen = Set<NoteID>()
        for item in items {
            seen.insert(item.id)
            let parts = layers[item.id] ?? make(item.id)
            let color = item.color.cgColor
            parts.outline.path = item.outline
            parts.outline.strokeColor = color
            parts.outline.lineWidth = item.strong ? 2.5 : 1.5
            parts.outline.opacity = Self.opacity(item)
            parts.outline.zPosition = item.strong ? 1 : 0
            glow(parts.outline, item.strong ? item.color : nil)
            applyRibbon(item, parts: parts, viewerViewport: viewerViewport, panelViewport: panelViewport)
        }
        for id in layers.keys where !seen.contains(id) { remove(id) }
    }

    /// Moves one note's ribbon (its card moved); the outlines stay as they are.
    func updateRibbon(_ item: Item, viewerViewport: CGRect?, panelViewport: CGRect?) {
        guard let parts = layers[item.id], let viewerViewport, let panelViewport else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyRibbon(item, parts: parts, viewerViewport: viewerViewport, panelViewport: panelViewport)
        CATransaction.commit()
    }

    private static func opacity(_ item: Item) -> Float {
        item.strong ? 1 : Float(item.strength)
    }

    private func applyRibbon(_ item: Item, parts: (outline: CAShapeLayer, ribbon: CALayer, gradient: CAGradientLayer, mask: CAShapeLayer),
                             viewerViewport: CGRect, panelViewport: CGRect) {
        let width: CGFloat = item.strong ? 2.5 : 1.5
        guard let card = item.card, let start = NoteOutline.departure(item.shapes) else {
            parts.ribbon.isHidden = true
            return
        }
        // The rail's side at its middle: the path meets it square, as a line meets a bar.
        let end = CGPoint(x: card.minX + Self.railInset, y: card.midY)
        // A card scrolling out of the list takes its ribbon with it, fading over the last few points.
        let inside = min(end.y - panelViewport.minY, panelViewport.maxY - end.y)
        guard inside > 0 else {
            parts.ribbon.isHidden = true
            return
        }
        let connector = NoteConnector(from: start, viewerEdge: viewerViewport.maxX, to: end)
        let ribbon = connector.ribbon(width: width)
        let box = ribbon.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
        parts.ribbon.isHidden = false
        parts.ribbon.frame = box
        parts.ribbon.opacity = Self.opacity(item) * Float(min(inside / Self.edgeFade, 1))
        parts.ribbon.zPosition = item.strong ? 1 : 0
        glow(parts.ribbon, item.strong ? item.color : nil)
        parts.gradient.frame = CGRect(origin: .zero, size: box.size)
        parts.mask.frame = parts.gradient.bounds
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        parts.mask.path = ribbon.copy(using: &shift)
        // Deepens to the rail's full colour as it arrives.
        parts.gradient.colors = [item.color.withAlphaComponent(0.75).cgColor, item.color.cgColor]
        parts.gradient.startPoint = CGPoint(x: (connector.start.x - box.minX) / box.width, y: (connector.start.y - box.minY) / box.height)
        parts.gradient.endPoint = CGPoint(x: (end.x - box.minX) / box.width, y: (end.y - box.minY) / box.height)
    }

    private func make(_ id: NoteID) -> (outline: CAShapeLayer, ribbon: CALayer, gradient: CAGradientLayer, mask: CAShapeLayer) {
        let outline = CAShapeLayer()
        outline.fillColor = nil
        outline.lineJoin = .round
        outline.lineCap = .round
        outlines.addSublayer(outline)
        let ribbon = CALayer()
        let gradient = CAGradientLayer()
        let mask = CAShapeLayer()
        gradient.mask = mask
        ribbon.addSublayer(gradient)
        ribbons.addSublayer(ribbon)
        let parts = (outline: outline, ribbon: ribbon, gradient: gradient, mask: mask)
        layers[id] = parts
        return parts
    }

    private func remove(_ id: NoteID) {
        guard let parts = layers.removeValue(forKey: id) else { return }
        parts.outline.removeFromSuperlayer()
        parts.ribbon.removeFromSuperlayer()
    }

    /// The rail's hover glow, on the hovered or selected note's outline and ribbon.
    private func glow(_ layer: CALayer, _ color: NSColor?) {
        layer.shadowColor = color?.cgColor
        layer.shadowOpacity = color == nil ? 0 : 0.5
        layer.shadowRadius = 4
        layer.shadowOffset = .zero
    }
}
