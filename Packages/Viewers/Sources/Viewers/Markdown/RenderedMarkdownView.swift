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
        private var appliedVersion = -1
        private var appliedScrollVersion = 0
        private var isSyncing = false
        private var highlightToken: UUID?
        private var scrollObserver: (any NSObjectProtocol)?
        private var frameObserver: (any NSObjectProtocol)?
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
                scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak backdrop = self.backdrop, weak controller] _ in
                    MainActor.assumeIsolated {
                        backdrop?.needsDisplay = true
                        controller?.noteGeometry.changed()
                    }
                }
            }
            if let scroll = textView.enclosingScrollView {
                frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateReadableWidth()
                        self?.controller.noteGeometry.changed()
                    }
                }
            }
            controller.renderedRectProvider = { [weak self] range in self?.rect(for: range) }
            controller.noteGeometry.viewport = { [weak textView] in textView?.visibleWindowRect() }
            controller.noteGeometry.visibleNoteRects = { [weak textView, weak controller] in
                guard let textView, let controller else { return [:] }
                return textView.visibleHighlightRects(for: controller.renderedHighlights().filter { !$0.isInvalidated }.map { ($0.id, $0.range) })
            }
            highlightToken = controller.source.addHighlightObserver { [weak self] in self?.invalidateHighlights() }
        }

        private func invalidateHighlights() {
            backdrop?.entries = controller.renderedHighlights().filter { !$0.isInvalidated }.map {
                HighlightBackdropView.Entry(range: $0.range, color: $0.color, state: $0.state, focused: controller.source.isFocused($0.id))
            }
            controller.noteGeometry.changed()
        }

        func detach() {
            if let highlightToken { controller.source.removeHighlightObserver(highlightToken) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
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
            isSyncing = true
            defer { isSyncing = false }
            if appliedVersion != controller.renderedVersion {
                appliedVersion = controller.renderedVersion
                let selection = textView.selectedRange()
                textView.textStorage?.setAttributedString(controller.rendered)
                let length = textView.string.utf16.count
                textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            }
            // Waits for a window like the source editor does (see `SourceTextView.onAttachedToWindow`).
            if appliedScrollVersion != controller.pendingRenderedScrollVersion, let range = controller.pendingRenderedScroll,
               textView.window != nil, !textView.visibleRect.isEmpty {
                appliedScrollVersion = controller.pendingRenderedScrollVersion
                textView.scrollRangeToVisible(range)
                if controller.pendingRenderedScrollSelects {
                    textView.setSelectedRange(range)
                    textView.window?.makeFirstResponder(textView)
                }
            }
            invalidateHighlights()
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

/// The rendered view's text view, reporting when it is in a window so a pending jump can be applied.
final class RenderedTextView: NSTextView {
    var onAttachedToWindow: (() -> Void)?

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
