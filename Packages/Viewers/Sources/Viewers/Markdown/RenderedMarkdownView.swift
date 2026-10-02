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
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 18, height: 16)
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
        private weak var textView: NSTextView?
        private weak var backdrop: HighlightBackdropView?
        private var appliedVersion = -1
        private var appliedScrollVersion = 0
        private var isSyncing = false
        private var highlightToken: UUID?
        private var scrollObserver: (any NSObjectProtocol)?

        init(controller: MarkdownViewerController) {
            self.controller = controller
        }

        func attach(textView: NSTextView) {
            self.textView = textView
            backdrop = HighlightBackdropView.install(in: textView)
            if let clip = textView.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak backdrop = self.backdrop] _ in
                    MainActor.assumeIsolated { backdrop?.needsDisplay = true }
                }
            }
            controller.renderedRectProvider = { [weak self] range in self?.rect(for: range) }
            highlightToken = controller.source.addHighlightObserver { [weak self] in self?.invalidateHighlights() }
        }

        private func invalidateHighlights() {
            backdrop?.entries = controller.renderedHighlights().filter { !$0.isInvalidated }.map {
                HighlightBackdropView.Entry(range: $0.range, color: $0.state == .orphaned ? Theme.color(for: $0.color) : Theme.highlightBackground(for: $0.highlight), orphaned: $0.state == .orphaned)
            }
        }

        func detach() {
            if let highlightToken { controller.source.removeHighlightObserver(highlightToken) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            textView?.delegate = nil
        }

        func sync() {
            guard let textView else { return }
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
            if appliedScrollVersion != controller.pendingRenderedScrollVersion, let range = controller.pendingRenderedScroll {
                appliedScrollVersion = controller.pendingRenderedScrollVersion
                textView.scrollRangeToVisible(range)
                textView.setSelectedRange(range)
                textView.window?.makeFirstResponder(textView)
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
            HStack {
                Spacer()
                Picker("Mode", selection: $controller.mode) {
                    Text("Rendered").tag(MarkdownViewerController.Mode.rendered)
                    Text("Source").tag(MarkdownViewerController.Mode.source)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .help("Toggle rendered and source (⌘⇧M)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch controller.mode {
            case .rendered:
                RenderedMarkdownView(controller: controller)
            case .source:
                TextEditorView(controller: controller.source)
            }
        }
    }
}
