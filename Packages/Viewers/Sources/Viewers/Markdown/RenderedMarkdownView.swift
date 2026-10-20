import AppKit
import Core
import SwiftUI

/// Read-only, selectable rendered markdown with note highlights.
public struct RenderedMarkdownView: NSViewRepresentable {
    public let controller: MarkdownViewerController

    public init(controller: MarkdownViewerController) {
        self.controller = controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public func makeNSView(context: Context) -> RenderedMarkdownContainerView {
        // TextKit 2, with the layout manager that keeps selection to what shows of a wide table.
        let layoutManager = MarkdownTextLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: MarkdownRenderer.proseWidth(), height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = textContainer
        let contentStorage = NSTextContentStorage()
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.primaryTextLayoutManager = layoutManager
        let textView = RenderedTextView(frame: .zero, textContainer: textContainer)
        textView.controller = controller
        textView.onAttachedToWindow = { [weak coordinator = context.coordinator] in coordinator?.sync() }
        textView.isEditable = false
        textView.isSelectable = true
        // Edit › Find (⌘F) searches the page as read, as it searches the source.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: RenderedTextView.minimumMargin, height: 20)
        textView.textContainer?.lineFragmentPadding = 0
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.textLayoutManager?.delegate = context.coordinator.layoutDelegate
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // The column is sized and centred by the view itself (`RenderedTextView.updateColumn`), not by tracking it.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: MarkdownRenderer.proseWidth(), height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.postsFrameChangedNotifications = true
        let minimap = RenderedMinimapView()
        minimap.controller = controller
        minimap.textView = textView
        let container = RenderedMarkdownContainerView(scrollView: scroll, minimap: minimap)
        context.coordinator.minimap = minimap
        context.coordinator.attach(textView: textView)
        context.coordinator.sync()
        return container
    }

    public func updateNSView(_ nsView: RenderedMarkdownContainerView, context: Context) {
        context.coordinator.sync()
    }

    public static func dismantleNSView(_ nsView: RenderedMarkdownContainerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: MarkdownViewerController

        /// Every click goes through `MarkdownLink`; returning true keeps NSTextView from opening the URL itself.
        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            switch MarkdownLink.classify(link, documentDirectory: controller.documentDirectory) {
            case .external(let url): NSWorkspace.shared.open(url)
            case .document(let path, let fragment): controller.onOpenDocument(path, fragment)
            case .sameDocument(let fragment):
                // A table of contents: the heading it names, at the top, as a browser scrolls to an anchor.
                let source = controller.source
                if let line = MarkdownAnchors.line(of: fragment, in: source.text) {
                    controller.scroll(toSource: source.lineIndex.contentRange(ofLine: line), select: false, atTop: true)
                } else if !fragment.isEmpty {
                    NSSound.beep()
                }
            case .refused: NSSound.beep()
            }
            return true
        }
        private weak var textView: NSTextView?
        private weak var backdrop: HighlightBackdropView?
        private weak var imageOverlay: EmbeddedImageOverlayView?
        private weak var animatedPictures: AnimatedPicturesView?
        weak var minimap: RenderedMinimapView?
        private var settingsObserver: (any NSObjectProtocol)?
        private var appliedVersion = -1
        private var appliedScrollVersion = 0
        private var isSyncing = false
        private var highlightToken: UUID?
        private var scrollObserver: (any NSObjectProtocol)?
        private var frameObserver: (any NSObjectProtocol)?
        private var textFrameObserver: (any NSObjectProtocol)?
        /// Held here: the layout manager keeps its delegate weakly.
        let layoutDelegate = MarkdownLayoutDelegate()

        init(controller: MarkdownViewerController) {
            self.controller = controller
        }

        func attach(textView: NSTextView) {
            self.textView = textView
            backdrop = HighlightBackdropView.install(in: textView)
            backdrop?.sourceLines = { [weak controller] range in controller?.sourceLines(forRendered: range) }
            if let clip = textView.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak backdrop = self.backdrop, weak controller] _ in
                    MainActor.assumeIsolated {
                        backdrop?.needsDisplay = true
                        controller?.noteGeometry.changed()
                        self?.animatedPictures?.layOut()
                        self?.minimap?.needsDisplay = true
                        (self?.textView as? RenderedTextView)?.layOutTableScrollers()
                    }
                }
            }
            if let scroll = textView.enclosingScrollView {
                frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.controller.noteGeometry.changed()
                        self?.animatedPictures?.layOut()
                        self?.minimap?.needsDisplay = true
                    }
                }
            }
            // Layout replaces estimated heights after the text is set, and pictures arriving (from the host or the web)
            // resize theirs: either moves the text below without scrolling, so the outlines around notes must follow
            // then too, or they keep the first layout's positions until the next scroll.
            textView.postsFrameChangedNotifications = true
            textFrameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self, weak backdrop = self.backdrop] _ in
                MainActor.assumeIsolated {
                    backdrop?.needsDisplay = true
                    self?.imageOverlay?.needsDisplay = true
                    self?.controller.noteGeometry.changed()
                    self?.animatedPictures?.layOut()
                    self?.minimap?.needsDisplay = true
                }
            }
            // Settings › Editor › Show minimap and the text size, while this view is open.
            settingsObserver = NotificationCenter.default.addObserver(forName: Theme.editorSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    (self?.textView as? RenderedTextView)?.updateColumn(force: true)
                    self?.minimap?.superview?.needsLayout = true
                    self?.minimap?.needsDisplay = true
                }
            }
            (textView as? RenderedTextView)?.onLayout = { [weak self] in
                // A table scrolled sideways moves its notes' highlights without the page scrolling.
                self?.backdrop?.needsDisplay = true
                self?.imageOverlay?.needsDisplay = true
                self?.minimap?.needsDisplay = true
                self?.controller.noteGeometry.changed()
                self?.animatedPictures?.layOut()
            }
            controller.renderedRectProvider = { [weak self] range in self?.rect(for: range) }
            controller.topVisibleRenderedLocationProvider = { [weak self] in self?.textView?.topVisibleCharacterIndex }
            let overlay = EmbeddedImageOverlayView(frame: textView.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.textView = textView as? RenderedTextView
            overlay.controller = controller
            // Playing pictures lie under the overlay, so a note's region is drawn over the moving frame.
            let pictures = AnimatedPicturesView(frame: textView.bounds)
            pictures.autoresizingMask = [.width, .height]
            pictures.textView = textView as? RenderedTextView
            textView.addSubview(pictures)
            animatedPictures = pictures
            textView.addSubview(overlay, positioned: .above, relativeTo: pictures)
            imageOverlay = overlay
            controller.imageFrameProvider = { [weak textView] image in
                guard let textView = textView as? RenderedTextView, let frame = textView.frame(of: image) else { return nil }
                return textView.topLeftWindowRect(frame)
            }
            controller.noteGeometry.viewport = { [weak textView] in textView?.visibleWindowRect() }
            controller.noteGeometry.visibleNoteRects = { [weak textView, weak controller] in
                guard let textView, let controller else { return [:] }
                var rects = textView.visibleHighlightRects(for: controller.renderedHighlights().filter { !$0.isInvalidated }.map { ($0.id, $0.range) })
                // Notes on pictures are their regions on the picture.
                let visible = textView.visibleWindowRect()
                for highlight in controller.imageHighlights {
                    guard let rect = controller.rect(for: highlight.image, region: highlight.region, pixelSize: highlight.pixelSize),
                          visible.map({ $0.intersects(rect) }) ?? true else { continue }
                    rects[highlight.id, default: []].append(rect)
                }
                return rects
            }
            highlightToken = controller.source.addHighlightObserver { [weak self] in self?.invalidateHighlights() }
        }

        private func invalidateHighlights() {
            let highlights = controller.renderedHighlights().filter { !$0.isInvalidated }
            let codeIDs = Set(highlights.filter { MarkdownRenderer.isCode(at: $0.range.location,in: controller.rendered) }.map(\.id))
            controller.noteGeometry.codeNoteIDs = codeIDs
            backdrop?.entries = highlights.map {
                HighlightBackdropView.Entry(range: $0.range, color: $0.color, state: $0.state, focused: controller.source.isFocused($0.id),code: codeIDs.contains($0.id))
            }
            // An iteration's changes, tinted on the paragraphs that show the changed lines.
            backdrop?.lineChanges = controller.source.lineChanges
            imageOverlay?.needsDisplay = true
            minimap?.needsDisplay = true
            controller.noteGeometry.changed()
        }

        func detach() {
            if let highlightToken { controller.source.removeHighlightObserver(highlightToken) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let textFrameObserver { NotificationCenter.default.removeObserver(textFrameObserver) }
            if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
            textView?.delegate = nil
        }

        func sync() {
            guard let textView else { return }
            // Read the highlight version here so SwiftUI re-runs this update when notes change;
            // the rendering validator alone runs outside SwiftUI's dependency tracking.
            _ = controller.source.highlightsVersion
            _ = controller.imageHighlights
            _ = controller.imageSelection
            imageOverlay?.needsDisplay = true
            isSyncing = true
            defer { isSyncing = false }
            if appliedVersion != controller.renderedVersion {
                appliedVersion = controller.renderedVersion
                let selection = textView.selectedRange()
                let top = textView.topVisibleCharacterIndex
                let sameText = textView.string == controller.rendered.string
                textView.textStorage?.setAttributedString(controller.rendered)
                (textView as? RenderedTextView)?.textWasSet(controller.rendered)
                // A page that gained or lost its tables changes how wide its container is.
                (textView as? RenderedTextView)?.updateColumn(force: true)
                let length = textView.string.utf16.count
                let location = min(selection.location,length)
                textView.setSelectedRange(NSRange(location: location,length: sameText ? min(selection.length,length-location) : 0))
                if sameText, let top { textView.scrollToTop(top) }
                animatedPictures?.textChanged()
            }
            // Waits for a window like the source editor does (see `SourceTextView.onAttachedToWindow`).
            if appliedScrollVersion != controller.pendingRenderedScrollVersion, let range = controller.pendingRenderedScroll,
               textView.window != nil, !textView.visibleRect.isEmpty {
                appliedScrollVersion = controller.pendingRenderedScrollVersion
                (textView as? RenderedTextView)?.revealInTable(range)
                if controller.pendingRenderedScrollAtTop { textView.scrollToTop(range.location) } else { textView.scrollRangeToVisible(range) }
                if controller.pendingRenderedScrollSelects {
                    textView.setSelectedRange(range)
                    textView.window?.makeFirstResponder(textView)
                }
            }
            invalidateHighlights()
            animatedPictures?.layOut()
        }

        func rect(for range: NSRange) -> CGRect? {
            guard let textView, let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager,
                  let container = textView.enclosingScrollView else { return nil }
            if range.length == 0, let caret = textView.caretRect(at: range.location) { return textView.topLeftWindowRect(caret) }
            let documentStart = contentManager.documentRange.location
            guard let from = contentManager.location(documentStart, offsetBy: range.location),
                  let to = contentManager.location(documentStart, offsetBy: range.location + range.length),
                  let textRange = NSTextRange(location: from, end: to) else { return nil }
            var union: CGRect?
            layoutManager.enumerateTextSegments(in: textRange, type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
                union = union.map { $0.union(frame) } ?? frame
                return true
            }
            guard var rect = union else { return nil }
            if rect.width < 2 { rect.size.width = 2 }
            rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            _ = container
            return textView.topLeftWindowRect(rect)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !isSyncing else { return }
            controller.renderedSelection = textView.selectedRange()
        }
    }
}

/// Segmented Rendered / Source toggle above the matching view.
public struct MarkdownViewerView: View {
    public let controller: MarkdownViewerController

    public init(controller: MarkdownViewerController) {
        self.controller = controller
    }

    public var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            ViewerToolbar {
                // What a reader wants to know at a glance, as writing apps show it; the kind is in the status bar.
                Label(controller.readingSummary, systemImage: "text.document")
                    .contentTransition(.numericText())
                    .help("Markdown")
            } trailing: {
                ModeSwitch([
                    .init(MarkdownViewerController.Mode.rendered, "Rendered", symbol: "eye"),
                    .init(MarkdownViewerController.Mode.source, "Source", symbol: "chevron.left.forwardslash.chevron.right"),
                ], selection: $controller.mode)
                .help("Toggle rendered and source")
            }
            switch controller.mode {
            case .rendered:
                RenderedMarkdownView(controller: controller)
            case .source:
                TextEditorView(controller: controller.source)
            }
        }
    }
}

/// The rendered view's text view, reporting when it is in a window so a pending jump can be applied. A drag that
/// starts on a picture chooses a region of it for a note, and a click chooses the whole picture; anywhere else the
/// text selects as usual.
final class RenderedTextView: NSTextView {
    var onAttachedToWindow: (() -> Void)?
    /// After each viewport layout: TextKit 2 settles estimated heights (and pictures that arrived) as it lays out,
    /// moving text without scrolling or resizing, so anything drawn over the text follows here.
    var onLayout: (() -> Void)?

    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        onLayout?()
        layOutTableScrollers()
    }

    /// Add Note on a selection of the page, as the source editor's menu has it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if let menu {
            // Selected text, or a region chosen on a picture (which selects no text).
            let offered = controller?.source.onAddNote != nil && (selectedRange().length > 0 || controller?.imageSelection != nil)
            AddNoteMenuItem.insert(into: menu, when: offered, target: self, action: #selector(addNoteFromMenu(_:)))
        }
        return menu
    }

    @objc func addNoteFromMenu(_ sender: Any?) { controller?.source.onAddNote?() }

    /// Under a card floated over the page (Review), the card has the pointer, not the page's I-beam.
    override func mouseMoved(with event: NSEvent) {
        if isCovered(at: event) { return }
        hoveredTable = wideTable(at: convert(event.locationInWindow, from: nil), below: TableScrollerView.height + 4)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTable = nil
        super.mouseExited(with: event)
    }

    /// The notes list held its place while the window was resized; it follows the page again now, and a column held
    /// back while the window grew takes its new width.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateColumn(force: true)
        onLayout?()
    }

    /// The reading column: as wide as a comfortable line of text (`MarkdownRenderer.proseWidth`), narrower only when
    /// the view is, centred with at least `minimumMargin` either side. A page with a table wider than the column has
    /// a container wider than it by `laidOutColumn.inset` either side, room the table scrolls into, kept out of
    /// sight. Centred by moving the container's origin, never by changing `textContainerInset` or letting the
    /// container track the view's width: either makes TextKit lay the whole document out again on every step of a
    /// window resize (#20), blanking and re-wrapping the text. So while the window is dragged wider the column only
    /// moves; dragged narrower it narrows at once, or it would be clipped.
    static let minimumMargin: CGFloat = 24

    override var textContainerOrigin: NSPoint {
        let laid = controller?.laidOutColumn
        let column = laid?.width ?? textContainer?.size.width ?? 0
        let centred = ((bounds.width - column) / 2).rounded(.down)
        // A page with tables in a view narrower than its column while it waits to be laid out again stays centred,
        // its edges cut off, so its column stays whole.
        return NSPoint(x: (laid != nil ? centred : max(Self.minimumMargin, centred)) - (laid?.inset ?? 0), y: textContainerInset.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateColumn()
    }

    /// Sizes the column for the view and re-centres it; `force` after the text size changes, the page is rendered
    /// again, or a resize ends.
    private var centredFor: CGFloat = -1
    func updateColumn(force: Bool = false) {
        // Not before the view has a width: a page laid out for a zero-width view would be thrown away at once.
        guard let container = textContainer, bounds.width > Self.minimumMargin * 2, force || bounds.width != centredFor else { return }
        centredFor = bounds.width
        let fitted = max(1, min(bounds.width - Self.minimumMargin * 2, MarkdownRenderer.proseWidth()))
        // A page with tables keeps the column it was laid out for until it is laid out again for the new one; any
        // other page just wraps to its new column.
        var width: CGFloat
        if let laid = controller?.laidOutColumn {
            width = laid.width + laid.inset * 2
        } else {
            width = fitted
            if inLiveResize, width > container.size.width { width = container.size.width }
        }
        if container.size.width != width {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        (textLayoutManager as? MarkdownTextLayoutManager)?.column = controller?.laidOutColumn.map { $0.inset...($0.inset + $0.width) }
        // Tables are laid out again for the new width once, when a resize ends, not whenever a drag pauses.
        if !inLiveResize { controller?.columnWidth = fitted }
        invalidateTextContainerOrigin()
        layOutTableScrollers()
    }
    weak var controller: MarkdownViewerController?

    /// The picture under `point` (view coordinates), with its index in the text and its frame.
    func picture(at point: NSPoint) -> (attachment: FittedImageAttachment, frame: CGRect, index: Int)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard let attachment = storage.attribute(.attachment, at: candidate, effectiveRange: nil) as? FittedImageAttachment,
                  attachment.source != nil, let segment = frame(ofCharacterAt: candidate) else { continue }
            let frame = Self.pictureFrame(segment, attachment: attachment)
            guard frame.contains(point) else { continue }
            return (attachment, frame, candidate)
        }
        return nil
    }

    /// The frame of one character (an attachment's picture), in view coordinates.
    func frame(ofCharacterAt index: Int) -> CGRect? {
        guard let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager else { return nil }
        let start = contentManager.documentRange.location
        guard let from = contentManager.location(start, offsetBy: index), let to = contentManager.location(start, offsetBy: index + 1),
              let range = NSTextRange(location: from, end: to) else { return nil }
        var frame: CGRect?
        layoutManager.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, rect, _, _ in
            frame = rect
            return false
        }
        return frame?.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// An embed's frame in view coordinates, found by its source and occurrence.
    func frame(of image: MarkdownViewerController.EmbeddedImageRef) -> CGRect? {
        guard let index = index(of: image), let segment = frame(ofCharacterAt: index) else { return nil }
        let attachment = textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? FittedImageAttachment
        guard let attachment else { return segment }
        return Self.pictureFrame(segment, attachment: attachment)
    }

    /// The picture itself within its character's frame: the text segment runs on into the line's descent, so the size
    /// is the attachment's own, fitted to the segment's width as it was laid out (an embed's `width` and `height`
    /// included, whatever the picture's own proportions).
    static func pictureFrame(_ segment: CGRect, attachment: FittedImageAttachment) -> CGRect {
        let fitted = FittedImageAttachment.fitted(attachment.naturalSize, width: segment.width).size
        guard fitted.width > 0, fitted.height > 0 else { return segment }
        return CGRect(x: segment.minX, y: segment.minY, width: fitted.width, height: min(segment.height, fitted.height))
    }

    func index(of image: MarkdownViewerController.EmbeddedImageRef) -> Int? {
        guard let storage = textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let attachment = value as? FittedImageAttachment, attachment.source == image.source, attachment.occurrence == image.occurrence {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard let controller, let hit = picture(at: start), let source = hit.attachment.source else {
            controller?.imageSelection = nil
            return super.mouseDown(with: keptToShownCells(event))
        }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: hit.index, length: 0))
        let ref = MarkdownViewerController.EmbeddedImageRef(source: source, occurrence: hit.attachment.occurrence)
        let embed = controller.map.sourceRange(forRendered: NSRange(location: hit.index, length: 1))?.source ?? NSRange(location: 0, length: 0)
        let pixelSize = hit.attachment.pixelSize
        func select(_ rect: CGRect) {
            controller.imageSelection = .init(image: ref, region: MarkdownViewerController.pixels(forViewRect: rect, pixelSize: pixelSize, in: hit.frame),
                                              pixelSize: pixelSize, embedSource: embed)
            for case let overlay as EmbeddedImageOverlayView in subviews { overlay.needsDisplay = true }
        }
        // Drag out a region, as in the image viewer; a click without a drag takes the whole picture, or follows the
        // link a linked picture (a badge, a thumbnail) carries.
        var dragged = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged {
                if hypot(point.x - start.x, point.y - start.y) > 3 { dragged = true }
                if dragged {
                    select(CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y)))
                    autoscroll(with: next)
                }
            } else {
                if !dragged, let link = textStorage?.attribute(.link, at: hit.index, effectiveRange: nil) {
                    controller.imageSelection = nil
                    _ = delegate?.textView?(self, clickedOnLink: link, at: hit.index)
                    break
                }
                if !dragged || (controller.imageSelection?.region.width ?? 0) < 2 || (controller.imageSelection?.region.height ?? 0) < 2 {
                    controller.imageSelection = .init(image: ref, region: CGRect(origin: .zero, size: pixelSize), pixelSize: pixelSize, embedSource: embed)
                }
                break
            }
        }
    }

    /// Copies plain text: code lines are joined by line separators and images are attachment characters, neither
    /// of which pastes well into a terminal or an editor.
    /// A table's cells are copied in order, a tab between cells and a line between rows, however they wrapped.
    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { return super.copy(sender) }
        let text = selectedRanges.map { Self.copiedText(storage.attributedSubstring(from: $0.rangeValue)) }.joined(separator: "\n")
        let plain = Self.plainText(text)
        guard !plain.isEmpty else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
    }

    /// The selected text with each table's wrapped pieces put back together as rows of cells.
    static func copiedText(_ selected: NSAttributedString) -> String {
        var result = ""
        var table: (id: Int, rows: [Int: [Int: String]])?
        func flush() {
            guard let finished = table else { return }
            result += finished.rows.keys.sorted().map { row in
                let cells = finished.rows[row] ?? [:]
                return (0...(cells.keys.max() ?? 0)).map { cells[$0] ?? "" }.joined(separator: "\t")
            }.joined(separator: "\n")
            table = nil
        }
        let string = selected.string as NSString
        selected.enumerateAttribute(MarkdownRenderer.tableCellKey, in: NSRange(location: 0, length: selected.length)) { value, range, _ in
            guard let mark = value as? TableCellMark else {
                flush()
                result += string.substring(with: range)
                return
            }
            if table?.id != mark.table {
                flush()
                table = (mark.table, [:])
            }
            if table?.rows[mark.row] == nil { table?.rows[mark.row] = [:] }
            guard mark.column >= 0 else { return }
            let cell = table?.rows[mark.row]?[mark.column]
            table?.rows[mark.row]?[mark.column] = (cell.map { $0 + mark.joined } ?? "") + string.substring(with: range)
        }
        flush()
        return result
    }

    static func plainText(_ rendered: String) -> String {
        rendered.replacingOccurrences(of: MarkdownRenderer.lineSeparator, with: "\n")
            .replacingOccurrences(of: "\u{FFFC}\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Diagrams follow light and dark: Mermaid draws them again in the matching theme.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.setDarkAppearance(effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    // MARK: Wide tables

    /// The page's tables wider than the column, by id, and the text they were found in (the rendered page as it
    /// came from the renderer, unscrolled).
    private var wideTables: [Int: MarkdownTableScroll.Table] = [:]
    private var tableBase: NSAttributedString?
    /// Each wide table's header row, so an offset kept through an edit goes back to the same table even when one
    /// above it was added or taken out.
    private var tableHeaders: [Int: String] = [:]
    /// How far each wide table is scrolled; kept while the page renders again (as it does while it is edited).
    private(set) var tableOffsets: [Int: CGFloat] = [:]
    private var tableScrollers: [Int: TableScrollerView] = [:]
    /// The table under the pointer, whose scroller shows.
    private var hoveredTable: Int? {
        didSet { if hoveredTable != oldValue { layOutTableScrollers() } }
    }
    /// Tables scrolled a moment ago, whose scrollers show for a little while after.
    private var recentlyScrolled: [Int: Date] = [:]
    private var scrollerHideTimer: Timer?

    /// The text was set to `base` (`controller.rendered`): find its wide tables and scroll them back to where they were.
    func textWasSet(_ base: NSAttributedString) {
        tableBase = base
        wideTables = MarkdownTableScroll.wideTables(in: base)
        let keptHeaders = tableHeaders
        tableHeaders = wideTables.compactMapValues { table in table.rows.first.map { (base.string as NSString).substring(with: $0) } }
        var byHeader: [String: CGFloat] = [:]
        for (id, offset) in tableOffsets { if let header = keptHeaders[id] { byHeader[header] = offset } }
        tableOffsets = [:]
        for (id, header) in tableHeaders { if let offset = byHeader[header] { scrollTable(id, to: offset) } }
        layOutTableScrollers()
    }

    /// Scrolls table `id` sideways, `offset` points from its start.
    func scrollTable(_ id: Int, to offset: CGFloat) {
        guard let table = wideTables[id], let storage = textStorage, let base = tableBase, base.length == storage.length else { return }
        let scale = window?.backingScaleFactor ?? 2
        let clamped = (min(max(0, offset), table.overflow) * scale).rounded() / scale
        guard clamped != tableOffsets[id] ?? 0 else { return }
        tableOffsets[id] = clamped
        MarkdownTableScroll.scroll(table, to: clamped, in: storage, base: base)
        onLayout?()
        layOutTableScrollers()
    }

    /// The wide table whose row is at `point` (view coordinates), within the column, or up to `below` points under
    /// its last row (where its scroller is).
    func wideTable(at point: NSPoint, below: CGFloat = 0) -> Int? {
        guard !wideTables.isEmpty, let layoutManager = textLayoutManager else { return nil }
        let origin = textContainerOrigin
        for dy in below > 0 ? [0, -below] : [0] {
            let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y + dy)
            guard inContainer.y >= 0, let fragment = layoutManager.textLayoutFragment(for: inContainer) as? MarkdownLayoutFragment,
                  let chrome = fragment.decoration.table, chrome.overflow > 0, wideTables[chrome.id] != nil,
                  chrome.visible.contains(point.x - origin.x) else { continue }
            if dy == 0 || chrome.last { return chrome.id }
        }
        return nil
    }

    /// Sideways scrolling over a wide table scrolls the table; any other scrolling, the page. A trackpad gesture
    /// keeps to the direction it started in, its momentum included, as a scroll view's does.
    private var wheelTable: Int?
    private var wheelSideways: Bool?
    override func scrollWheel(with event: NSEvent) {
        let gesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if !gesture || event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            wheelTable = wideTable(at: convert(event.locationInWindow, from: nil))
            wheelSideways = nil
        }
        if wheelSideways == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            wheelSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        guard wheelSideways == true, let id = wheelTable else { return super.scrollWheel(with: event) }
        // A mouse's wheel (with Shift) counts lines, a trackpad points.
        let delta = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 12)
        scrollTable(id, to: (tableOffsets[id] ?? 0) - delta)
        recentlyScrolled[id] = Date()
        layOutTableScrollers()
    }

    /// Selecting or finding text in a wide table's hidden part scrolls the table to it first.
    override func scrollRangeToVisible(_ range: NSRange) {
        revealInTable(range)
        super.scrollRangeToVisible(range)
    }

    /// Scrolls the wide table `range` starts in so its start shows.
    func revealInTable(_ range: NSRange) {
        guard !wideTables.isEmpty, let storage = textStorage, range.location < storage.length,
              let chrome = (storage.attribute(MarkdownRenderer.blockKey, at: range.location, effectiveRange: nil) as? MarkdownBlockDecoration)?.table,
              chrome.overflow > 0, wideTables[chrome.id] != nil,
              let rect = containerRect(of: NSRange(location: range.location, length: max(1, min(range.length, storage.length - range.location)))) else { return }
        let margin: CGFloat = 24
        let shown = chrome.visible
        var offset = tableOffsets[chrome.id] ?? 0
        if rect.minX < shown.lowerBound + margin {
            offset -= shown.lowerBound + margin - rect.minX
        } else if min(rect.maxX, rect.minX + shown.upperBound - shown.lowerBound - margin * 2) > shown.upperBound - margin {
            offset += min(rect.maxX, rect.minX + shown.upperBound - shown.lowerBound - margin * 2) - (shown.upperBound - margin)
        }
        scrollTable(chrome.id, to: offset)
    }

    /// The first line's segments of `range`, in container coordinates.
    private func containerRect(of range: NSRange) -> CGRect? {
        guard let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager else { return nil }
        let start = contentManager.documentRange.location
        guard let from = contentManager.location(start, offsetBy: range.location), let to = contentManager.location(start, offsetBy: NSMaxRange(range)),
              let textRange = NSTextRange(location: from, end: to) else { return nil }
        var union: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            if let first = union, frame.minY >= first.maxY - 1 { return false }
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return union
    }

    /// A click beside a scrolled table, level with it, lands on the cell at the column's edge, not on one scrolled
    /// out of sight there.
    private func keptToShownCells(_ event: NSEvent) -> NSEvent {
        guard !wideTables.isEmpty, let layoutManager = textLayoutManager else { return event }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: point.y - origin.y)) as? MarkdownLayoutFragment,
              let chrome = fragment.decoration.table, chrome.overflow > 0 else { return event }
        let x = point.x - origin.x
        guard !chrome.visible.contains(x) else { return event }
        let kept = NSPoint(x: min(max(x, chrome.visible.lowerBound + 1), chrome.visible.upperBound - 1) + origin.x, y: point.y)
        return NSEvent.mouseEvent(with: event.type, location: convert(kept, to: nil), modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                  windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount,
                                  pressure: event.pressure) ?? event
    }

    /// Places a scroller under each wide table on screen, showing while the pointer is over the table or it was just
    /// scrolled, or always when the system shows scroll bars always.
    func layOutTableScrollers() {
        guard let layoutManager = textLayoutManager, !wideTables.isEmpty || !tableScrollers.isEmpty else { return }
        let origin = textContainerOrigin
        let now = Date()
        recentlyScrolled = recentlyScrolled.filter { now.timeIntervalSince($0.value) < 1.2 }
        let always = NSScroller.preferredScrollerStyle == .legacy
        var placed: Set<Int> = []
        if let viewport = layoutManager.textViewportLayoutController.viewportRange {
            layoutManager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
                guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
                guard let fragment = fragment as? MarkdownLayoutFragment, let chrome = fragment.decoration.table, chrome.last,
                      let table = wideTables[chrome.id], let row = fragment.tableRowFrame else { return true }
                let scroller = tableScrollers[chrome.id] ?? {
                    let view = TableScrollerView()
                    view.onScroll = { [weak self] id, offset in
                        self?.scrollTable(id, to: offset)
                        self?.recentlyScrolled[id] = Date()
                    }
                    addSubview(view, positioned: .above, relativeTo: nil)
                    tableScrollers[chrome.id] = view
                    return view
                }()
                scroller.table = chrome.id
                scroller.frame = NSRect(x: table.visible.lowerBound + origin.x, y: row.maxY + origin.y + 2,
                                        width: table.visible.upperBound - table.visible.lowerBound, height: TableScrollerView.height)
                scroller.update(offset: tableOffsets[chrome.id] ?? 0, overflow: table.overflow,
                                shown: always || hoveredTable == chrome.id || recentlyScrolled[chrome.id] != nil, legacy: always)
                placed.insert(chrome.id)
                return true
            }
        }
        for (id, scroller) in tableScrollers where !placed.contains(id) {
            scroller.removeFromSuperview()
            tableScrollers[id] = nil
        }
        scrollerHideTimer?.invalidate()
        if !recentlyScrolled.isEmpty {
            scrollerHideTimer = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.layOutTableScrollers() }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            scrollerHideTimer?.invalidate()
            return
        }
        controller?.setDarkAppearance(effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.onAttachedToWindow?() }
        }
    }
}

/// A wide table's scroller, under it: a thin knob in the system's overlay style, which can be dragged, or clicked
/// beside to jump there.
final class TableScrollerView: NSView {
    static let height: CGFloat = 11
    var table = 0
    var onScroll: ((Int, CGFloat) -> Void)?
    private var offset: CGFloat = 0
    private var overflow: CGFloat = 1
    private var legacy = false
    private var hovered = false
    private var dragStart: (x: CGFloat, offset: CGFloat)?
    private var shown = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(offset: CGFloat, overflow: CGFloat, shown: Bool, legacy: Bool) {
        self.offset = offset
        self.overflow = max(1, overflow)
        self.legacy = legacy
        let show = shown || dragStart != nil
        if show != self.shown {
            self.shown = show
            NSAnimationContext.runAnimationGroup { context in
                context.duration = show ? 0.12 : 0.3
                animator().alphaValue = show ? 1 : 0
            }
        }
        needsDisplay = true
    }

    private var knob: CGRect {
        let track = bounds.insetBy(dx: 2, dy: 0)
        let width = max(28, track.width * track.width / (track.width + overflow))
        let x = track.minX + (track.width - width) * offset / overflow
        let thickness: CGFloat = hovered || dragStart != nil ? 8 : 6
        return CGRect(x: x, y: (bounds.height - thickness) / 2, width: width, height: thickness)
    }

    override func draw(_ dirtyRect: NSRect) {
        if legacy || hovered || dragStart != nil {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: (bounds.height - 2) / 2, yRadius: (bounds.height - 2) / 2).fill()
        }
        let knob = knob
        NSColor.labelColor.withAlphaComponent(hovered || dragStart != nil ? 0.5 : 0.35).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.height / 2, yRadius: knob.height / 2).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        shown ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let knob = knob
        let track = bounds.insetBy(dx: 2, dy: 0)
        let travel = max(1, track.width - knob.width)
        // Beside the knob: it jumps there, centred under the pointer, and is dragged on from there.
        var start = (x: x, offset: offset)
        if !knob.contains(CGPoint(x: x, y: knob.midY)) {
            start.offset = min(max(0, (x - track.minX - knob.width / 2) / travel * overflow), overflow)
            onScroll?(table, start.offset)
        }
        dragStart = start
        needsDisplay = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let moved = convert(next.locationInWindow, from: nil).x - start.x
            onScroll?(table, start.offset + moved / travel * overflow)
        }
        dragStart = nil
        needsDisplay = true
    }
}

/// Draws notes' regions on the pictures in rendered Markdown, and the region being chosen, over the text.
final class EmbeddedImageOverlayView: NSView {
    weak var textView: RenderedTextView?
    weak var controller: MarkdownViewerController?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let controller else { return }
        for highlight in controller.imageHighlights {
            guard let frame = textView.frame(of: highlight.image), frame.intersects(dirtyRect) else { continue }
            let rect = MarkdownViewerController.viewRect(forPixels: highlight.region, pixelSize: highlight.pixelSize, in: frame)
            RegionStyle.drawNote(rect, color: highlight.color, state: highlight.state, selected: controller.source.isFocused(highlight.id), unit: 1)
        }
        if let selection = controller.imageSelection, let frame = textView.frame(of: selection.image) {
            let rect = MarkdownViewerController.viewRect(forPixels: selection.region, pixelSize: selection.pixelSize, in: frame)
            RegionStyle.drawSelection(rect, in: frame, unit: 1, label: "\(Int(selection.region.width)) × \(Int(selection.region.height)) px")
        }
    }
}

/// Plays the animated pictures in rendered Markdown. TextKit draws an attachment as one still image, so each
/// playing picture on screen gets an image view laid over its attachment's frame (the attachment draws nothing
/// beneath it). Views exist only for pictures in view, and stop while the window is hidden. Clicks pass through to
/// the text view, which keeps choosing regions and whole pictures as it does for still ones.
///
/// `NSTextAttachmentViewProvider` is the framework's way to put a view in text; on macOS 26 a text view inside a scroll
/// view in an on-screen window asks for one, but a bare text view never loads its view. Laying views over the frames
/// works the same in both, keeps the notes overlay on top and the clicks with the text view.
final class AnimatedPicturesView: NSView {
    weak var textView: RenderedTextView?
    /// Where the playing pictures are in the text, found once per render.
    private var indices: [Int] = []
    private var views: [Int: PlayingPictureView] = [:]
    private var occlusionObserver: (any NSObjectProtocol)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Grows with the text view as its text is laid out, which moves the pictures.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    func textChanged() {
        views.values.forEach { $0.removeFromSuperview() }
        views = [:]
        indices = []
        guard let storage = textView?.textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? FittedImageAttachment, attachment.plays { indices.append(range.location) }
        }
        layOut()
    }

    /// Places a view over each playing picture in view (with a margin), and drops the rest.
    func layOut() {
        guard let textView, !indices.isEmpty else { return }
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -textView.visibleRect.height / 2)
        let playing = window?.occlusionState.contains(.visible) ?? false
        for index in indices {
            guard let attachment = textView.textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? FittedImageAttachment,
                  let segment = textView.frame(ofCharacterAt: index) else { continue }
            let frame = RenderedTextView.pictureFrame(segment, attachment: attachment)
            guard frame.intersects(visible), frame.width > 0, frame.height > 0 else {
                views.removeValue(forKey: index)?.removeFromSuperview()
                continue
            }
            let view = views[index] ?? {
                let view = PlayingPictureView(image: attachment.image)
                addSubview(view)
                views[index] = view
                return view
            }()
            if view.frame != frame { view.frame = frame }
            view.cornerRadius = FittedImageAttachment.cornerRadius(for: frame.size)
            if view.animates != playing { view.animates = playing }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let newWindow else { return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: newWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layOut() }
        }
    }

    isolated deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }
}

/// One playing picture, set into the page as still ones are: rounded corners and a hairline edge.
final class PlayingPictureView: NSImageView {
    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { layer?.cornerRadius = cornerRadius } }
    }

    init(image: NSImage?) {
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleAxesIndependently
        imageFrameStyle = .none
        isEditable = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        updateBorder()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        }
    }
}
