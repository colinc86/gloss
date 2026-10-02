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
        private var appliedVersion = -1
        private var appliedScrollVersion = 0

        init(controller: MarkdownViewerController) {
            self.controller = controller
        }

        func attach(textView: NSTextView) {
            self.textView = textView
            textView.textLayoutManager?.renderingAttributesValidator = { [weak self] layoutManager, fragment in
                MainActor.assumeIsolated { self?.validate(layoutManager, fragment) }
            }
            controller.renderedRectProvider = { [weak self] range in self?.rect(for: range) }
        }

        func detach() {
            textView?.textLayoutManager?.renderingAttributesValidator = nil
            textView?.delegate = nil
        }

        func sync() {
            guard let textView else { return }
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
            if let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager {
                layoutManager.invalidateRenderingAttributes(for: contentManager.documentRange)
                textView.needsDisplay = true
            }
        }

        private func validate(_ layoutManager: NSTextLayoutManager, _ fragment: NSTextLayoutFragment) {
            guard let contentManager = layoutManager.textContentManager else { return }
            let documentStart = contentManager.documentRange.location
            let fragmentStart = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let fragmentEnd = contentManager.offset(from: documentStart, to: fragment.rangeInElement.endLocation)
            for highlight in controller.renderedHighlights() where !highlight.isInvalidated {
                let start = max(highlight.range.location, fragmentStart)
                let end = min(highlight.range.location + highlight.range.length, fragmentEnd)
                guard start < end,
                      let from = contentManager.location(documentStart, offsetBy: start),
                      let to = contentManager.location(documentStart, offsetBy: end),
                      let range = NSTextRange(location: from, end: to) else { continue }
                if highlight.state == .orphaned {
                    layoutManager.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle.patternDash.rawValue | NSUnderlineStyle.single.rawValue, for: range)
                } else {
                    layoutManager.addRenderingAttribute(.backgroundColor, value: Theme.highlightBackground(for: highlight.highlight), for: range)
                }
            }
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
            return textView.convert(rect, to: container)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
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
