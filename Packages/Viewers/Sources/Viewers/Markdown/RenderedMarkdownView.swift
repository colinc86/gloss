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

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = RenderedTextView(usingTextLayoutManager: true)
        textView.controller = controller
        textView.onAttachedToWindow = { [weak coordinator = context.coordinator] in coordinator?.sync() }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: Coordinator.minimumInset, height: 20)
        textView.textContainer?.lineFragmentPadding = 0
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.textLayoutManager?.delegate = context.coordinator.layoutDelegate
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.postsFrameChangedNotifications = true
        context.coordinator.attach(textView: textView)
        context.coordinator.sync()
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.sync()
    }

    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: MarkdownViewerController

        /// Every click goes through `MarkdownLink`; returning true keeps NSTextView from opening the URL itself.
        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            switch MarkdownLink.classify(link, documentDirectory: controller.documentDirectory) {
            case .external(let url): NSWorkspace.shared.open(url)
            case .document(let path): controller.onOpenDocument(path)
            case .sameDocument: break
            case .refused: NSSound.beep()
            }
            return true
        }
        private weak var textView: NSTextView?
        private weak var backdrop: HighlightBackdropView?
        private weak var imageOverlay: EmbeddedImageOverlayView?
        private weak var animatedPictures: AnimatedPicturesView?
        private var appliedVersion = -1
        private var appliedScrollVersion = 0
        private var isSyncing = false
        private var highlightToken: UUID?
        private var scrollObserver: (any NSObjectProtocol)?
        private var frameObserver: (any NSObjectProtocol)?
        private var textFrameObserver: (any NSObjectProtocol)?
        /// Held here: the layout manager keeps its delegate weakly.
        let layoutDelegate = MarkdownLayoutDelegate()
        static let minimumInset: CGFloat = 24
        /// Widest text column; wider panes centre it.
        static let readableWidth: CGFloat = 780

        init(controller: MarkdownViewerController) {
            self.controller = controller
        }

        func attach(textView: NSTextView) {
            self.textView = textView
            backdrop = HighlightBackdropView.install(in: textView)
            if let clip = textView.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak backdrop = self.backdrop, weak controller] _ in
                    MainActor.assumeIsolated {
                        backdrop?.needsDisplay = true
                        controller?.noteGeometry.changed()
                        self?.animatedPictures?.layOut()
                    }
                }
            }
            if let scroll = textView.enclosingScrollView {
                frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateReadableWidth()
                        self?.controller.noteGeometry.changed()
                        self?.animatedPictures?.layOut()
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
                }
            }
            (textView as? RenderedTextView)?.onLayout = { [weak self] in
                self?.imageOverlay?.needsDisplay = true
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
            backdrop?.entries = controller.renderedHighlights().filter { !$0.isInvalidated }.map {
                HighlightBackdropView.Entry(range: $0.range, color: $0.color, state: $0.state, focused: controller.source.isFocused($0.id))
            }
            imageOverlay?.needsDisplay = true
            controller.noteGeometry.changed()
        }

        func detach() {
            if let highlightToken { controller.source.removeHighlightObserver(highlightToken) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let textFrameObserver { NotificationCenter.default.removeObserver(textFrameObserver) }
            textView?.delegate = nil
        }

        /// Caps the text column at `readableWidth`, centred, so long lines stay readable in a wide pane.
        func updateReadableWidth() {
            guard let textView, let scroll = textView.enclosingScrollView else { return }
            let width = scroll.contentSize.width
            let inset = max(Self.minimumInset, ((width - Self.readableWidth) / 2).rounded(.down))
            guard textView.textContainerInset.width != inset else { return }
            textView.textContainerInset = NSSize(width: inset, height: textView.textContainerInset.height)
            backdrop?.needsDisplay = true
        }

        func sync() {
            guard let textView else { return }
            updateReadableWidth()
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
                textView.textStorage?.setAttributedString(controller.rendered)
                let length = textView.string.utf16.count
                textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                animatedPictures?.textChanged()
            }
            // Waits for a window like the source editor does (see `SourceTextView.onAttachedToWindow`).
            if appliedScrollVersion != controller.pendingRenderedScrollVersion, let range = controller.pendingRenderedScroll,
               textView.window != nil, !textView.visibleRect.isEmpty {
                appliedScrollVersion = controller.pendingRenderedScrollVersion
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
            rect = rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
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
        return frame?.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
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
            return super.mouseDown(with: event)
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
    override func copy(_ sender: Any?) {
        let text = selectedRanges.map { (string as NSString).substring(with: $0.rangeValue) }.joined(separator: "\n")
        let plain = Self.plainText(text)
        guard !plain.isEmpty else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
    }

    static func plainText(_ rendered: String) -> String {
        rendered.replacingOccurrences(of: MarkdownRenderer.lineSeparator, with: "\n")
            .replacingOccurrences(of: "\u{FFFC}\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.onAttachedToWindow?() }
        }
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
