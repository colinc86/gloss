import AppKit

/// Draws a rendered markdown paragraph's chrome (code fill, quote bars, rule, table row, heading underline) behind
/// its text. Geometry comes from the line fragments, so it follows whatever spacing the paragraph style asked for.
nonisolated final class MarkdownLayoutFragment: NSTextLayoutFragment {
    let decoration: MarkdownBlockDecoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: MarkdownBlockDecoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    // MARK: Colours

    static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 0, alpha: 0.035)
    }
    /// Opaque, so where two paragraphs' pieces of one quote bar overlap by a pixel the bar does not darken.
    static let quoteBar = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.36, alpha: 1)
            : NSColor(white: 0.80, alpha: 1)
    }
    static let border = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10)
            : NSColor(white: 0, alpha: 0.08)
    }
    /// A table's outline and the rules between its cells: firmer than a code block's border, quieter than text.
    static let tableRule = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(white: 0, alpha: 0.12)
    }
    static let headerFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 0, alpha: 0.045)
    }
    static let stripe = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.03)
            : NSColor(white: 0, alpha: 0.018)
    }
    static let tableCorner: CGFloat = 6

    // MARK: Geometry (fragment coordinates)

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.maxX
    }

    private var lineBounds: CGRect? {
        textLineFragments.reduce(nil as CGRect?) { union, line in union.map { $0.union(line.typographicBounds) } ?? line.typographicBounds }
    }

    private struct Shapes {
        var fill: CGRect?
        var fillRounded = false
        var lines: [CGRect] = []
        var bars: [CGRect] = []
        /// A table row: its rect, and which of the table's rounded corners it holds.
        var tableRow: CGRect?
    }

    private func shapes() -> Shapes? {
        guard let text = lineBounds else { return nil }
        let originX = layoutFragmentFrame.minX
        let left = decoration.leading - originX
        let right = max(left, containerWidth - originX)
        var shapes = Shapes()
        switch decoration.kind {
        case .plain:
            break
        case .codeBlock:
            let pad = MarkdownRenderer.codeVerticalPadding
            shapes.fill = CGRect(x: left, y: text.minY - pad, width: right - left, height: text.height + pad * 2)
            shapes.fillRounded = true
        case .rule:
            shapes.lines.append(CGRect(x: left, y: text.midY.rounded(.down), width: right - left, height: 1))
        case .heading(let level):
            if level <= 2 { shapes.lines.append(CGRect(x: left, y: text.maxY + 5, width: right - left, height: 1)) }
        case .tableRow(_, let width):
            let pad = MarkdownRenderer.tableRowPadding
            shapes.tableRow = CGRect(x: left, y: text.minY - pad, width: min(width, right - left), height: text.height + pad * 2)
        }
        if !decoration.quoteBars.isEmpty {
            // Bars span the paragraph's own spacing so consecutive paragraphs of one quote join up.
            let paragraph = (textElement as? NSTextParagraph).flatMap { $0.attributedString.length > 0 ? $0.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil }
            let below = paragraph?.paragraphSpacing ?? 0
            for bar in decoration.quoteBars {
                let above = bar.continuesFromAbove ? paragraph?.paragraphSpacingBefore ?? 0 : 2
                shapes.bars.append(CGRect(x: bar.x - originX, y: text.minY - above, width: 3, height: text.height + above + max(2, below)))
            }
        }
        return shapes
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        guard let shapes = shapes() else { return bounds }
        for rect in [shapes.fill, shapes.tableRow].compactMap({ $0 }) + shapes.lines + shapes.bars {
            bounds = bounds.union(rect.insetBy(dx: -1, dy: -1))
        }
        return bounds
    }

    /// The code block's language, small and quiet in the fill's top-right corner, as GitHub and Craft mark theirs.
    private func drawLabel(_ label: String, in fill: CGRect, context: CGContext) {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: decoration.codeForeground?.withAlphaComponent(0.7) ?? NSColor.tertiaryLabelColor,
            .kern: 0.3,
        ])
        let size = text.size()
        let origin = CGPoint(x: fill.maxX - size.width - 10, y: fill.minY + 5)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A row of a table: its shading, the rules between its columns and below it, and its part of the table's
    /// rounded outline (the top corners on the first row, the bottom ones on the last).
    private func drawTableRow(_ row: CGRect, context: CGContext) {
        guard case .tableRow(let header, _) = decoration.kind else { return }
        let chrome = decoration.table
        let first = chrome?.first ?? header, last = chrome?.last ?? false
        let radius = min(Self.tableCorner, row.height / 2)
        let inset = row.insetBy(dx: 0.5, dy: 0)
        let top = first ? inset.minY + 0.5 : inset.minY
        let bottom = last ? inset.maxY - 0.5 : inset.maxY
        let outline = CGMutablePath()
        // Clockwise from the bottom left, rounding only the corners this row holds.
        outline.move(to: CGPoint(x: inset.minX, y: bottom - (last ? radius : 0)))
        if first {
            outline.addLine(to: CGPoint(x: inset.minX, y: top + radius))
            outline.addArc(tangent1End: CGPoint(x: inset.minX, y: top), tangent2End: CGPoint(x: inset.minX + radius, y: top), radius: radius)
            outline.addArc(tangent1End: CGPoint(x: inset.maxX, y: top), tangent2End: CGPoint(x: inset.maxX, y: top + radius), radius: radius)
        } else {
            outline.addLine(to: CGPoint(x: inset.minX, y: top))
            outline.addLine(to: CGPoint(x: inset.maxX, y: top))
        }
        if last {
            outline.addLine(to: CGPoint(x: inset.maxX, y: bottom - radius))
            outline.addArc(tangent1End: CGPoint(x: inset.maxX, y: bottom), tangent2End: CGPoint(x: inset.maxX - radius, y: bottom), radius: radius)
            outline.addArc(tangent1End: CGPoint(x: inset.minX, y: bottom), tangent2End: CGPoint(x: inset.minX, y: bottom - radius), radius: radius)
        } else {
            outline.addLine(to: CGPoint(x: inset.maxX, y: bottom))
            outline.addLine(to: CGPoint(x: inset.minX, y: bottom))
        }
        outline.closeSubpath()
        if header || chrome?.striped == true {
            context.addPath(outline)
            context.setFillColor((header ? Self.headerFill : Self.stripe).cgColor)
            context.fillPath()
        }
        context.setFillColor(Self.tableRule.cgColor)
        let originX = layoutFragmentFrame.minX
        for divider in chrome?.dividers ?? [] {
            let x = (divider - originX).rounded(.down)
            guard x > row.minX, x < row.maxX - 1 else { continue }
            context.fill(CGRect(x: x, y: row.minY, width: 1, height: row.height))
        }
        if !last {
            // The rule under the header row is the separator's own colour, as GitHub draws it a little firmer.
            context.setFillColor((header ? NSColor.separatorColor : Self.tableRule).cgColor)
            context.fill(CGRect(x: row.minX, y: row.maxY - 1, width: row.width, height: 1))
        }
        // The outline: its sides on every row, its rounded top and bottom on the rows that hold them.
        context.setFillColor(Self.tableRule.cgColor)
        let sideTop = first ? row.minY + radius : row.minY
        let sideBottom = last ? row.maxY - radius : row.maxY
        context.fill(CGRect(x: row.minX, y: sideTop, width: 1, height: max(0, sideBottom - sideTop)))
        context.fill(CGRect(x: row.maxX - 1, y: sideTop, width: 1, height: max(0, sideBottom - sideTop)))
        let edges = CGMutablePath()
        if first {
            edges.move(to: CGPoint(x: inset.minX, y: sideTop))
            edges.addArc(tangent1End: CGPoint(x: inset.minX, y: top), tangent2End: CGPoint(x: inset.minX + radius, y: top), radius: radius)
            edges.addArc(tangent1End: CGPoint(x: inset.maxX, y: top), tangent2End: CGPoint(x: inset.maxX, y: sideTop), radius: radius)
        }
        if last {
            edges.move(to: CGPoint(x: inset.maxX, y: sideBottom))
            edges.addArc(tangent1End: CGPoint(x: inset.maxX, y: bottom), tangent2End: CGPoint(x: inset.maxX - radius, y: bottom), radius: radius)
            edges.addArc(tangent1End: CGPoint(x: inset.minX, y: bottom), tangent2End: CGPoint(x: inset.minX, y: sideBottom), radius: radius)
        }
        if !edges.isEmpty {
            context.addPath(edges)
            context.setStrokeColor(Self.tableRule.cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let shapes = shapes() {
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            if let row = shapes.tableRow { drawTableRow(row, context: context) }
            if let fill = shapes.fill {
                let path = shapes.fillRounded ? CGPath(roundedRect: fill, cornerWidth: 6, cornerHeight: 6, transform: nil) : CGPath(rect: fill, transform: nil)
                context.addPath(path)
                context.setFillColor((decoration.codeBackground ?? Self.fill).cgColor)
                context.fillPath()
                if shapes.fillRounded {
                    context.addPath(CGPath(roundedRect: fill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil))
                    context.setStrokeColor(Self.border.cgColor)
                    context.setLineWidth(1)
                    context.strokePath()
                }
                if let label = decoration.label {
                    drawLabel(label, in: fill, context: context)
                }
            }
            context.setFillColor(NSColor.separatorColor.cgColor)
            for line in shapes.lines { context.fill(line) }
            for (index, bar) in shapes.bars.enumerated() {
                // An alert's bar in its colour; the bars are in `quoteBars` order.
                let alert = index < decoration.quoteBars.count ? decoration.quoteBars[index].alert : nil
                context.setFillColor((alert?.color ?? Self.quoteBar).cgColor)
                context.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                context.fillPath()
            }
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}

/// Hands TextKit a `MarkdownLayoutFragment` for every decorated paragraph of the rendered view.
nonisolated final class MarkdownLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let decoration = paragraph.attributedString.attribute(MarkdownRenderer.blockKey, at: 0, effectiveRange: nil) as? MarkdownBlockDecoration,
           decoration.isDrawn {
            return MarkdownLayoutFragment(textElement: textElement, range: textElement.elementRange, decoration: decoration)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
