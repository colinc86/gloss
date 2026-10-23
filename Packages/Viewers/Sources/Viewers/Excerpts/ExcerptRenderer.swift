import AppKit
import Core
import ImageIO
import PDFKit

/// A small window onto a document as the viewer shows it, centered on a note's anchor with the anchor tinted: a
/// rendered Markdown page, a PDF page's region, a picture's surroundings, a web page's element. The review card
/// shows two of these, one taken when the note was sent and one drawn now, so what the agent changed can be seen
/// without reading the document behind the card.
public enum ExcerptRenderer {
    /// The window's size in points and the pixels per point it is drawn at.
    public struct Window: Hashable, Sendable {
        public var width: CGFloat
        public var height: CGFloat
        public var scale: CGFloat

        public init(width: CGFloat = 760, height: CGFloat = 220, scale: CGFloat = 2) {
            self.width = width
            self.height = height
            self.scale = scale
        }

        public var size: CGSize { CGSize(width: width, height: height) }
    }

    /// Margin kept around a focus so it never sits on the window's edge.
    static let margin: CGFloat = 16

    // MARK: Markdown

    /// The page rendered as the Markdown viewer renders it (headings, code fills, tables, pictures from `baseURL`
    /// or `images`), scrolled so the anchor's rendered text sits in the middle of the window.
    public static func markdown(_ source: String, anchor: TextAnchor, baseURL: URL?, images: [String: NSImage] = [:],
                                window: Window, tint: NSColor, appearance: NSAppearance) -> CGImage? {
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let codeAppearance: NSAppearance.Name = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .darkAqua : .aqua
            let output = MarkdownRenderer.render(source, baseURL: baseURL, images: images, codeAppearance: codeAppearance,
                                                 columnWidth: window.width - 2 * margin)
            let layoutManager = MarkdownTextLayoutManager()
            let container = NSTextContainer(size: NSSize(width: output.columnWidth + 2 * output.inset, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.textContainer = container
            let delegate = MarkdownLayoutDelegate()
            layoutManager.delegate = delegate
            let storage = NSTextContentStorage()
            storage.addTextLayoutManager(layoutManager)
            storage.primaryTextLayoutManager = layoutManager
            storage.attributedString = output.text
            if output.inset > 0 { layoutManager.column = output.inset...(output.inset + output.columnWidth) }
            layoutManager.ensureLayout(for: layoutManager.documentRange)

            let sourceRange = LineIndex(source).range(for: anchor)
            var focusRects: [CGRect] = []
            for rendered in output.map.renderedRanges(forSource: sourceRange) {
                guard let textRange = textRange(rendered, in: storage) else { continue }
                layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
                    if frame.width > 0 || frame.height > 0 { focusRects.append(frame) }
                    return true
                }
            }
            let focus = focusRects.reduce(CGRect.null) { $0.union($1) }
            let contentHeight = layoutManager.usageBoundsForTextContainer.height
            // The window's top in container coordinates: centered on the focus, within the page plus a margin.
            let top = windowTop(focus: focus.isNull ? nil : focus, contentHeight: contentHeight, window: window)
            image = draw(window: window, background: .textBackgroundColor, flipped: true) { context in
                // The column starts `inset` in when a wide table needs room beside it, as the viewer cancels too.
                context.translateBy(x: margin - output.inset, y: -top)
                layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
                    let frame = fragment.layoutFragmentFrame
                    if frame.maxY < top { return true }
                    if frame.minY > top + window.height { return false }
                    fragment.draw(at: frame.origin, in: context)
                    return true
                }
                highlight(focusRects, tint: tint, in: context)
            }
            withExtendedLifetime(delegate) {}
        }
        return image
    }

    /// Where the window's top goes so `focus` is centered, a margin above the first line at the top and below the
    /// last at the bottom; a focus taller than the window shows from its top.
    static func windowTop(focus: CGRect?, contentHeight: CGFloat, window: Window) -> CGFloat {
        let lowest = -margin
        let highest = max(lowest, contentHeight + margin - window.height)
        guard let focus else { return lowest }
        var top = focus.height > window.height - 2 * margin ? focus.minY - margin : focus.midY - window.height / 2
        top = min(max(top, lowest), highest)
        return top
    }

    private static func textRange(_ range: NSRange, in storage: NSTextContentStorage) -> NSTextRange? {
        guard let start = storage.location(storage.documentRange.location, offsetBy: range.location),
              let end = storage.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    // MARK: PDF

    /// The page at reading zoom (its width filling the window), the window centered on `bounds` (page space, as
    /// `PDFAnchor.bounds` keeps it) or showing the page's top when the anchor has none.
    public static func pdf(_ document: PDFDocument, page index: Int, bounds: CGRect?, window: Window, tint: NSColor) -> CGImage? {
        guard let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .cropBox)
        // Drawn space: the page rotated and its box moved to the origin, what `draw(with:to:)` produces.
        let drawnBox = box.applying(page.transform(for: .cropBox)).standardized
        guard drawnBox.width > 0, drawnBox.height > 0 else { return nil }
        let focus = bounds.map { $0.intersection(box) }.flatMap { $0.isEmpty ? nil : $0.applying(page.transform(for: .cropBox)).standardized }
        let zoom = window.width / drawnBox.width
        let windowHeight = window.height / zoom
        // Page space runs up from the bottom: the window's origin is its bottom-left corner.
        var originY: CGFloat
        if let focus {
            originY = focus.height > windowHeight - 2 * margin / zoom ? focus.maxY + margin / zoom - windowHeight : focus.midY - windowHeight / 2
        } else {
            originY = drawnBox.maxY - windowHeight
        }
        // Within the page; a page shorter than the window sits at the window's top.
        originY = drawnBox.height < windowHeight ? drawnBox.maxY - windowHeight : min(max(originY, drawnBox.minY), drawnBox.maxY - windowHeight)
        return draw(window: window, background: .white, flipped: false) { context in
            context.scaleBy(x: zoom, y: zoom)
            context.translateBy(x: -drawnBox.minX, y: -originY)
            page.draw(with: .cropBox, to: context)
            if let focus { highlight([focus], tint: tint, in: context, lineWidth: 1.5 / zoom) }
        }
    }

    // MARK: Pictures

    /// The picture around `region` (pixels, origin top-left as `ImageAnchor` keeps it), never enlarged, zoomed out
    /// only as far as the region needs to take no more than most of the window.
    public static func image(_ image: DecodedImage, region: CGRect, window: Window, tint: NSColor, appearance: NSAppearance) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard !bounds.isEmpty else { return nil }
        let region = region.intersection(bounds).isEmpty ? bounds : region.intersection(bounds)
        let zoom = min(1, 0.6 * window.width / max(region.width, 1), 0.6 * window.height / max(region.height, 1))
        let shown = CGSize(width: window.width / zoom, height: window.height / zoom)
        func place(_ wanted: CGFloat, size: CGFloat, total: CGFloat) -> CGFloat {
            total <= size ? (total - size) / 2 : min(max(wanted, 0), total - size)
        }
        // Top-left pixel coordinates of the window.
        let origin = CGPoint(x: place(region.midX - shown.width / 2, size: shown.width, total: bounds.width),
                             y: place(region.midY - shown.height / 2, size: shown.height, total: bounds.height))
        var result: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            result = draw(window: window, background: .windowBackgroundColor, flipped: true) { context in
                context.scaleBy(x: zoom, y: zoom)
                context.translateBy(x: -origin.x, y: -origin.y)
                // CGImage drawing expects y up: flip the picture's own rect back.
                context.saveGState()
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image.cgImage, in: bounds)
                context.restoreGState()
                highlight([region], tint: tint, in: context, lineWidth: 1.5 / zoom)
            }
        }
        return result
    }

    // MARK: Web

    /// The rectangle to ask the browser for around an element: the window's size at least, the element centered.
    public static func captureRect(around element: ElementRect, window: Window) -> ElementRect {
        let width = max(window.width, element.w + 2 * margin)
        let height = max(window.height, element.h + 2 * margin)
        return ElementRect(x: max(0, element.x + element.w / 2 - width / 2), y: max(0, element.y + element.h / 2 - height / 2), w: width, h: height)
    }

    /// A browser snapshot of `captured` (CSS pixels, page coordinates) with `element` outlined on it.
    public static func web(snapshot png: Data, captured: ElementRect, element: ElementRect, tint: NSColor) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let picture = CGImageSourceCreateImageAtIndex(source, 0, nil),
              captured.w > 0, captured.h > 0 else { return nil }
        let width = picture.width, height = picture.height
        // The browser may have cut the capture to its viewport: scale by what it drew.
        let scale = CGFloat(width) / captured.w
        let rect = CGRect(x: (element.x - captured.x) * scale, y: (element.y - captured.y) * scale, width: element.w * scale, height: element.h * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Flip to top-left coordinates for the outline.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        highlight([rect], tint: tint, in: context, lineWidth: 1.5 * scale)
        return context.makeImage()
    }

    // MARK: Drawing

    /// A bitmap of the window, filled with `background`, with `body` drawing into it under an AppKit graphics
    /// context: `flipped` puts the origin at the top-left, as text and pictures are laid out.
    static func draw(window: Window, background: NSColor, flipped: Bool, _ body: (CGContext) -> Void) -> CGImage? {
        let width = Int((window.width * window.scale).rounded()), height = Int((window.height * window.scale).rounded())
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: window.scale, y: window.scale)
        if flipped {
            context.translateBy(x: 0, y: window.height)
            context.scaleBy(x: 1, y: -1)
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        context.saveGState()
        body(context)
        context.restoreGState()
        NSGraphicsContext.current = previous
        return context.makeImage()
    }

    /// Fills and outlines the anchor's rects in the note's color, in the context's current coordinates.
    static func highlight(_ rects: [CGRect], tint: NSColor, in context: CGContext, lineWidth: CGFloat = 1.5) {
        guard !rects.isEmpty else { return }
        context.saveGState()
        context.setFillColor(tint.withAlphaComponent(0.18).cgColor)
        for rect in rects { context.fill(rect) }
        context.setStrokeColor(tint.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(lineWidth)
        let outline = rects.reduce(CGRect.null) { $0.union($1) }
        context.stroke(outline.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
        context.restoreGState()
    }
}
