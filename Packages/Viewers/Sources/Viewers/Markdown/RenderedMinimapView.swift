import AppKit
import Core

/// The whole rendered document laid out once more, offscreen, at the reading column's width: TextKit 2 lays out only
/// what is near the screen, so a snapshot of the view itself would be blank (or at estimated heights) everywhere
/// else. Kept for its geometry as well as its picture, so marks and the slider are placed on the page as drawn.
@MainActor
final class RenderedPage {
    /// Past this, the page is not laid out again: a full TextKit layout of a very long document is too slow to redo.
    static let maximumLength = 150_000
    /// The tallest picture made, in pixels; a page that would be taller is drawn at a lower resolution.
    static let maximumPixelHeight = 16_384

    struct Key: Equatable {
        var version: Int
        var width: CGFloat
        var appearance: NSAppearance.Name?
        var backingScale: CGFloat
    }

    let key: Key
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    /// Held here: the layout manager keeps its delegate weakly.
    private let layoutDelegate = MarkdownLayoutDelegate()
    /// The page's height in its own points, at `key.width`.
    private(set) var height: CGFloat = 0
    /// The picture, `thumbnailWidth` points wide; nil when the page is too tall to draw.
    private(set) var picture: NSBitmapImageRep?
    /// Every picture in the text and its frame on the page; the page never changes, so found once.
    private(set) var pictures: [(attachment: FittedImageAttachment, frame: CGRect)] = []

    init(text: NSAttributedString, key: Key, thumbnailWidth: CGFloat, appearance: NSAppearance) {
        self.key = key
        contentStorage.textStorage?.setAttributedString(text)
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.delegate = layoutDelegate
        let container = NSTextContainer(size: CGSize(width: key.width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        height = max(1, layoutManager.usageBoundsForTextContainer.maxY)
        pictures = findPictures()
        picture = draw(width: thumbnailWidth, appearance: appearance, backingScale: key.backingScale)
    }

    /// Points on the thumbnail per point of page.
    func scale(forThumbnailWidth width: CGFloat) -> CGFloat { width / max(1, key.width) }

    private func draw(width: CGFloat, appearance: NSAppearance, backingScale: CGFloat) -> NSBitmapImageRep? {
        let scale = scale(forThumbnailWidth: width)
        let pointHeight = height * scale
        let pixelsPerPoint = min(backingScale, CGFloat(Self.maximumPixelHeight) / max(1, pointHeight))
        guard pixelsPerPoint >= 0.5 else { return nil }
        let pixelsWide = Int((width * pixelsPerPoint).rounded(.up)), pixelsHigh = Int((pointHeight * pixelsPerPoint).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let context = bitmapContext.cgContext
        // Page points, top-left origin, as TextKit lays them out.
        context.translateBy(x: 0, y: CGFloat(pixelsHigh))
        context.scaleBy(x: scale * pixelsPerPoint, y: -scale * pixelsPerPoint)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        appearance.performAsCurrentDrawingAppearance {
            layoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location, options: [.ensuresLayout]) { fragment in
                fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
                return true
            }
            // A playing picture draws nothing in the text (the view lays a moving one over it): draw its still here.
            for (attachment, frame) in pictures where attachment.plays {
                attachment.image?.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: width, height: pointHeight)
        return rep
    }

    // MARK: Geometry, in page points

    private func location(_ offset: Int) -> (any NSTextLocation)? {
        let documentRange = contentStorage.documentRange
        return contentStorage.location(documentRange.location, offsetBy: min(max(0, offset), length))
    }

    var length: Int { contentStorage.textStorage?.length ?? 0 }

    /// The line holding the character: its top and bottom on the page.
    func lineSpan(at offset: Int) -> ClosedRange<CGFloat>? {
        guard let location = location(offset) else { return nil }
        var span: ClosedRange<CGFloat>?
        layoutManager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            span = frame.minY...frame.maxY
            return false
        }
        return span
    }

    /// The rects a rendered range covers on the page, one per line.
    func rects(for range: NSRange) -> [CGRect] {
        guard let from = location(range.location), let to = location(range.location + range.length),
              let textRange = NSTextRange(location: from, end: to) else { return [] }
        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
            rects.append(frame)
            return true
        }
        return rects
    }

    /// The character at the start of the line at `y` on the page.
    func characterIndex(atY y: CGFloat) -> Int? {
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: min(max(0, y), height - 1))) else { return nil }
        let documentStart = contentStorage.documentRange.location
        let start = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let line = fragment.textLineFragments.last { $0.typographicBounds.minY + frame.minY <= y } ?? fragment.textLineFragments.first
        return start + (line?.characterRange.location ?? 0)
    }

    private func findPictures() -> [(attachment: FittedImageAttachment, frame: CGRect)] {
        guard let storage = contentStorage.textStorage else { return [] }
        var found: [(FittedImageAttachment, CGRect)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? FittedImageAttachment, let segment = rects(for: NSRange(location: range.location, length: 1)).first
            else { return }
            found.append((attachment, RenderedTextView.pictureFrame(segment, attachment: attachment)))
        }
        return found
    }

    func pictureFrame(of image: MarkdownViewerController.EmbeddedImageRef) -> CGRect? {
        pictures.first { $0.attachment.source == image.source && $0.attachment.occurrence == image.occurrence }?.frame
    }
}

/// A small picture of the whole rendered page at the trailing edge, as the editor's `MinimapView` is of the code:
/// headings, code blocks, tables, quotes, pictures and diagrams as they render, with notes tinted over their text or
/// their region of a picture, and a slider over the part on screen. Positions come from locations, not pixels: the
/// view's own height is partly TextKit's estimate until it has laid everything out. A click on a note goes to it; a
/// click elsewhere centres that part of the page, and a drag moves the slider.
final class RenderedMinimapView: NSView {
    weak var controller: MarkdownViewerController?
    weak var textView: RenderedTextView?

    /// Margin either side of the picture.
    private static let inset: CGFloat = 4
    private var thumbnailWidth: CGFloat { max(1, bounds.width - Self.inset * 2) }

    private var page: RenderedPage?
    private var rebuildTask: Task<Void, Never>?
    /// The page the pending rebuild is for, so a redraw with nothing new doesn't restart its wait.
    private var scheduledKey: RenderedPage.Key?

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        sliderDragStart = nil
        if newWindow == nil { cancelRebuild() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        sliderDragStart = nil
    }

    // MARK: The page

    /// What the page would be built from now; nil while there is nothing to draw.
    private var currentKey: RenderedPage.Key? {
        guard let controller, let width = textView?.textContainer?.size.width, width > 50,
              controller.rendered.length <= RenderedPage.maximumLength else { return nil }
        return RenderedPage.Key(version: controller.renderedVersion, width: width.rounded(), appearance: effectiveAppearance.name,
                                backingScale: window?.backingScaleFactor ?? 2)
    }

    /// Laying the whole page out is the expensive part, so it waits: a change is built once the text, width and
    /// display have held still for 150 ms (typing in Source, pictures arriving, dragging a pane), and not at all
    /// during a window's live resize. A change of appearance alone is built at once, so a dark page never sits on a
    /// light picture. The first page is built on the next turn, out of drawing.
    private func refreshPage() {
        guard let key = currentKey else {
            page = nil
            cancelRebuild()
            return
        }
        guard page?.key != key else { return }
        if let page, page.key.version == key.version, page.key.width == key.width, page.key.backingScale == key.backingScale {
            build(key)
            return
        }
        if page != nil, inLiveResize { return }
        guard scheduledKey != key else { return }
        cancelRebuild()
        scheduledKey = key
        let waits = page != nil
        rebuildTask = Task { [weak self] in
            if waits { try? await Task.sleep(for: .milliseconds(150)) }
            guard let self, !Task.isCancelled else { return }
            self.rebuildTask = nil
            self.scheduledKey = nil
            // A resize that began while this waited: build when it ends (`viewDidEndLiveResize`).
            guard !self.inLiveResize || self.page == nil else { return }
            if let key = self.currentKey, self.page?.key != key { self.build(key) }
            self.needsDisplay = true
        }
    }

    private func cancelRebuild() {
        rebuildTask?.cancel()
        rebuildTask = nil
        scheduledKey = nil
    }

    private func build(_ key: RenderedPage.Key) {
        guard let controller else { return }
        page = RenderedPage(text: controller.rendered, key: key, thumbnailWidth: thumbnailWidth, appearance: effectiveAppearance)
    }

    // MARK: Layout

    /// The part of the page on screen, from the first and last characters the view shows.
    private func visibleSpan(on page: RenderedPage) -> ClosedRange<CGFloat>? {
        guard let textView, let scroll = textView.enclosingScrollView, let document = scroll.documentView,
              document.frame.height > scroll.documentVisibleRect.height + 1,
              let top = textView.topVisibleCharacterIndex else { return nil }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let bottom = textView.characterIndexForInsertion(at: NSPoint(x: max(visible.minX, origin.x) + 1, y: visible.maxY - 1))
        guard let first = page.lineSpan(at: top), let last = page.lineSpan(at: bottom) else { return nil }
        return first.lowerBound...max(first.lowerBound, last.upperBound)
    }

    private func layout(for page: RenderedPage) -> MinimapView.PageLayout {
        let scale = page.scale(forThumbnailWidth: thumbnailWidth)
        let span = visibleSpan(on: page).map { ($0.lowerBound * scale)...($0.upperBound * scale) }
        return MinimapView.PageLayout(contentHeight: page.height * scale, viewHeight: bounds.height, visible: span)
    }

    // MARK: Drawing

    private var hits: [(rect: NSRect, noteID: NoteID)] = []
    private var hovered: NoteID? {
        didSet { if oldValue != hovered { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        MinimapStyle.drawSeparator(height: bounds.height)
        refreshPage()
        hits = []
        guard let controller, let page else { return }
        let layout = layout(for: page)
        let scale = page.scale(forThumbnailWidth: thumbnailWidth)
        // Page points to the minimap's.
        func place(_ rect: CGRect) -> NSRect {
            NSRect(x: Self.inset + rect.minX * scale, y: rect.minY * scale - layout.offset, width: rect.width * scale, height: rect.height * scale)
        }

        if let picture = page.picture {
            picture.draw(in: NSRect(x: Self.inset, y: -layout.offset, width: thumbnailWidth, height: picture.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let slider = layout.slider {
            MinimapStyle.drawSlider(NSRect(x: 1, y: slider.y, width: bounds.width - 1, height: slider.height), dragging: sliderDragStart != nil)
        }

        // Until the page catches up with the text, notes would land where the old page had their places.
        guard page.key.version == controller.renderedVersion else { return }
        // Changes in a lane of their own at the left, under the notes, as in the editor's minimap: each hunk's source
        // lines found on the page.
        if let changes = controller.source.lineChanges {
            let index = controller.source.lineIndex
            for hunk in MinimapView.hunkMarks(for: changes) {
                let first = index.contentRange(ofLine: hunk.lines.lowerBound)
                let last = index.contentRange(ofLine: hunk.lines.upperBound)
                let source = hunk.isDeletion ? NSRange(location: first.location, length: 0)
                                             : NSRange(location: first.location, length: last.location + last.length - first.location)
                let lines = controller.map.renderedRanges(forSource: source).flatMap { page.rects(for: $0) }.map(place)
                guard let union = lines.dropFirst().reduce(lines.first, { $0?.union($1) }), union.maxY >= 0, union.minY <= bounds.height else { continue }
                let rect = hunk.isDeletion
                    ? NSRect(x: 1.5, y: union.minY - 1, width: 3, height: 2)
                    : NSRect(x: 1.5, y: union.minY, width: 2, height: max(2, union.height))
                (hunk.isDeletion ? Theme.changeDeletedMarker : Theme.changeBar).setFill()
                rect.fill()
            }
        }
        // Settled notes underneath, open work on top, as in the editor's minimap.
        let order: [NoteState: Int] = [.resolved: 0, .sent: 1, .orphaned: 2, .draft: 3]
        for highlight in controller.renderedHighlights().filter({ !$0.isInvalidated }).sorted(by: { (order[$0.state] ?? 0) < (order[$1.state] ?? 0) }) {
            let lines = page.rects(for: highlight.range).map(place)
            guard let union = lines.dropFirst().reduce(lines.first, { $0?.union($1) }), union.maxY >= 0, union.minY <= bounds.height else { continue }
            // The lines the note covers, across the page: at this scale a word is a pixel, so its lines are the mark.
            let rect = NSRect(x: Self.inset, y: union.minY, width: thumbnailWidth, height: max(2, union.height))
            MinimapStyle.drawNote(rect, barX: bounds.width - 3, color: highlight.color, state: highlight.state,
                                  isPoint: highlight.range.length == 0, hovered: highlight.id == hovered || controller.source.isFocused(highlight.id),code: MarkdownRenderer.isCode(at: highlight.range.location,in: controller.rendered))
            hits.append((rect.insetBy(dx: 0, dy: -2), highlight.id))
        }
        // Notes on pictures are their regions of the picture.
        for highlight in controller.imageHighlights {
            guard let frame = page.pictureFrame(of: highlight.image), highlight.pixelSize.width > 0, highlight.pixelSize.height > 0 else { continue }
            let region = place(MarkdownViewerController.viewRect(forPixels: highlight.region, pixelSize: highlight.pixelSize, in: frame))
            guard region.maxY >= 0, region.minY <= bounds.height else { continue }
            let isHovered = highlight.id == hovered || controller.source.isFocused(highlight.id)
            let color = Theme.color(for: highlight.color)
            color.withAlphaComponent((isHovered ? 0.6 : 0.4) * Theme.strength(for: highlight.state)).setFill()
            region.insetBy(dx: -0.5, dy: -0.5).fill(using: .sourceOver)
            color.withAlphaComponent(isHovered ? 1 : Theme.strength(for: highlight.state)).setFill()
            NSRect(x: bounds.width - 3, y: region.minY, width: 3, height: max(2, region.height)).fill()
            hits.append((region.insetBy(dx: -2, dy: -2), highlight.id))
        }
    }

    // MARK: Interaction

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hovered = hits.last { $0.rect.contains(point) }?.noteID
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    /// Where a slider drag began: the pointer's y and the visible span's fraction then.
    private var sliderDragStart: (y: CGFloat, fraction: CGFloat)? {
        didSet { if (oldValue == nil) != (sliderDragStart == nil) { needsDisplay = true } }
    }

    override func mouseDown(with event: NSEvent) {
        guard let page, let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        let layout = layout(for: page)
        if let noteID = hits.last(where: { $0.rect.contains(point) })?.noteID,
           let range = controller.source.highlights.first(where: { $0.id == noteID })?.range {
            // Go to the note, the way browsing the notes panel does: the view moves there, the keyboard stays put.
            controller.source.dismissPeek()
            controller.scroll(toSource: range, select: false)
            return
        }
        if let slider = layout.slider, point.y >= slider.y, point.y <= slider.y + slider.height {
            sliderDragStart = (point.y, layout.fraction)
            return
        }
        // Centre that part of the page, then let a drag carry on from there, as the editor's minimap does.
        let scale = page.scale(forThumbnailWidth: thumbnailWidth)
        if let index = page.characterIndex(atY: layout.contentY(atViewY: point.y) / scale) {
            show(index, centred: true)
        }
        sliderDragStart = (point.y, self.layout(for: page).fraction)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = sliderDragStart, let page else { return }
        let layout = layout(for: page)
        guard layout.sliderTravel > 0 else { return }
        let fraction = start.fraction + (convert(event.locationInWindow, from: nil).y - start.y) / layout.sliderTravel
        let scale = page.scale(forThumbnailWidth: thumbnailWidth)
        if let index = page.characterIndex(atY: layout.spanTop(forFraction: fraction) / scale) {
            show(index, centred: false)
        }
    }

    override func mouseUp(with event: NSEvent) {
        sliderDragStart = nil
    }

    /// Scrolls the rendered view to a character, centred or at the top. What lies above it may still be at estimated
    /// heights, so once the scroll has laid out real ones it looks again and corrects.
    private func show(_ index: Int, centred: Bool, settling: Bool = true) {
        guard let textView else { return }
        if centred { textView.scrollToCentre(index) } else { textView.scrollToTop(index) }
        guard settling else { return }
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.show(index, centred: centred, settling: false) }
        }
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// The rendered view's scroll view, with the minimap at its trailing edge while Settings › Editor has it on.
public final class RenderedMarkdownContainerView: NSView {
    let scrollView: NSScrollView
    let minimap: RenderedMinimapView

    init(scrollView: NSScrollView, minimap: RenderedMinimapView) {
        self.scrollView = scrollView
        self.minimap = minimap
        super.init(frame: .zero)
        addSubview(scrollView)
        addSubview(minimap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func layout() {
        super.layout()
        let width = Theme.showsMinimap ? MinimapView.width : 0
        minimap.isHidden = width == 0
        scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        minimap.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }
}
