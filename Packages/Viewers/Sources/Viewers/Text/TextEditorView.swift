import AppKit
import Core
import OSLog
import SwiftUI

/// SwiftUI wrapper for `SourceTextView`. All state flows through `TextEditorController`.
public struct TextEditorView: NSViewRepresentable {
    public let controller: TextEditorController

    public init(controller: TextEditorController) {
        self.controller = controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public func makeNSView(context: Context) -> TextEditorContainerView {
        let textView = SourceTextView.make()
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let gutter = LineNumberGutterView(textView: textView, controller: controller)
        let container = TextEditorContainerView(gutter: gutter, scrollView: scroll)
        context.coordinator.attach(textView: textView, gutter: gutter, scrollView: scroll)
        context.coordinator.loadContent()
        return container
    }

    public func updateNSView(_ nsView: TextEditorContainerView, context: Context) {
        context.coordinator.sync()
    }

    public static func dismantleNSView(_ nsView: TextEditorContainerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let controller: TextEditorController
        private weak var textView: SourceTextView?
        private weak var gutter: LineNumberGutterView?
        private weak var backdrop: HighlightBackdropView?
        private var observers: [any NSObjectProtocol] = []
        private var loadedContentVersion = -1
        private var appliedHighlightsVersion = -1
        private var appliedScrollVersion = 0
        private var isApplyingContent = false
        private var highlightToken: UUID?

        init(controller: TextEditorController) {
            self.controller = controller
        }

        func attach(textView: SourceTextView, gutter: LineNumberGutterView, scrollView: NSScrollView) {
            self.textView = textView
            self.gutter = gutter
            backdrop = HighlightBackdropView.install(in: textView)
            textView.delegate = self
            textView.textStorage?.delegate = self
            textView.structuralExpansion = { [controller] range in controller.structuralExpansion(of: range) }
            controller.rectProvider = { [weak self] range in self?.rect(for: range) }
            textView.textLayoutManager?.renderingAttributesValidator = { [weak self] layoutManager, fragment in
                MainActor.assumeIsolated { self?.validateRenderingAttributes(layoutManager, fragment) }
            }
            controller.onRenderingInvalidation = { [weak self] range in
                guard let self, let textView = self.textView, let layoutManager = textView.textLayoutManager,
                      let contentManager = layoutManager.textContentManager else { return }
                if let range, let from = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
                   let to = contentManager.location(contentManager.documentRange.location, offsetBy: range.location + range.length),
                   let textRange = NSTextRange(location: from, end: to) {
                    Coordinator.revalidate(layoutManager, range: textRange)
                } else {
                    Coordinator.revalidate(layoutManager, range: contentManager.documentRange)
                }
                textView.needsLayout = true
                textView.needsDisplay = true
            }
            highlightToken = controller.addHighlightObserver { [weak self] in self?.invalidateHighlights() }
            scrollView.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak gutter, weak backdrop] _ in
                MainActor.assumeIsolated {
                    gutter?.needsDisplay = true
                    backdrop?.needsDisplay = true
                }
            })
        }

        func detach() {
            if let highlightToken { controller.removeHighlightObserver(highlightToken) }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            textView?.textLayoutManager?.renderingAttributesValidator = nil
            textView?.delegate = nil
            textView?.textStorage?.delegate = nil
        }

        func loadContent() {
            guard let textView else { return }
            isApplyingContent = true
            textView.replaceAllText(with: controller.text)
            isApplyingContent = false
            loadedContentVersion = controller.contentVersion
            textView.isEditable = controller.isEditable
            gutter?.updateWidth()
            invalidateHighlights()
        }

        /// Pushes controller changes into the view; called from `updateNSView`.
        func sync() {
            guard let textView else { return }
            if loadedContentVersion != controller.contentVersion { loadContent() }
            if textView.isEditable != controller.isEditable { textView.isEditable = controller.isEditable }
            if appliedHighlightsVersion != controller.highlightsVersion { invalidateHighlights() }
            if appliedScrollVersion != controller.pendingScrollVersion, let range = controller.pendingScroll {
                appliedScrollVersion = controller.pendingScrollVersion
                let clamped = NSRange(location: min(range.location, textView.string.utf16.count), length: 0)
                textView.scrollRangeToVisible(NSRange(location: clamped.location, length: range.length))
                textView.setSelectedRange(range.length > 0 ? range : clamped)
                textView.window?.makeFirstResponder(textView)
            }
        }

        /// Union of the selection segments for `range`, converted to the container view's coordinates.
        func rect(for range: NSRange) -> CGRect? {
            guard let textView, let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager else { return nil }
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
            return textView.topLeftWindowRect(rect)
        }

        private func invalidateHighlights() {
            appliedHighlightsVersion = controller.highlightsVersion
            backdrop?.entries = controller.highlights.filter { !$0.isInvalidated }.map {
                HighlightBackdropView.Entry(range: $0.range, color: $0.state == .orphaned ? Theme.color(for: $0.color) : Theme.highlightBackground(for: $0.highlight), orphaned: $0.state == .orphaned)
            }
            gutter?.needsDisplay = true
        }

        /// The validator only runs when a fragment is laid out, so invalidating rendering attributes alone leaves
        /// fragments that are already on screen unchanged; invalidating their layout makes TextKit ask again.
        static func revalidate(_ layoutManager: NSTextLayoutManager, range: NSTextRange) {
            layoutManager.invalidateRenderingAttributes(for: range)
            layoutManager.invalidateLayout(for: range)
        }

        // MARK: Rendering attributes (note highlights)

        private func validateRenderingAttributes(_ layoutManager: NSTextLayoutManager, _ fragment: NSTextLayoutFragment) {
            guard let contentManager = layoutManager.textContentManager else { return }
            let documentStart = contentManager.documentRange.location
            let fragmentRange = fragment.rangeInElement
            let fragmentStart = contentManager.offset(from: documentStart, to: fragmentRange.location)
            let fragmentEnd = contentManager.offset(from: documentStart, to: fragmentRange.endLocation)
            if let highlighter = controller.highlighter {
                for capture in highlighter.captures(in: NSRange(location: fragmentStart, length: fragmentEnd - fragmentStart)) {
                    guard let color = SyntaxTheme.color(forCapture: capture.name) else { continue }
                    let start = max(capture.range.location, fragmentStart)
                    let end = min(capture.range.location + capture.range.length, fragmentEnd)
                    guard start < end,
                          let from = contentManager.location(documentStart, offsetBy: start),
                          let to = contentManager.location(documentStart, offsetBy: end),
                          let range = NSTextRange(location: from, end: to) else { continue }
                    layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: range)
                }
            }
        }

        // MARK: NSTextViewDelegate

        public func textDidChange(_ notification: Notification) {
            guard !isApplyingContent, let textView else { return }
            controller.viewDidChangeText(textView.string)
            gutter?.updateWidth()
            gutter?.needsDisplay = true
            backdrop?.needsDisplay = true
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !isApplyingContent else { return }
            controller.selection = textView.selectedRange()
            controller.onSelectionChange(textView.selectedRange())
            gutter?.needsDisplay = true
        }

        // MARK: NSTextStorageDelegate (nonisolated in AppKit; always called on the main thread for a view-owned storage)

        public nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            let edit = NSRange(location: editedRange.location, length: editedRange.length - delta)
            let newText = textStorage.string
            MainActor.assumeIsolated {
                guard !isApplyingContent else { return }
                controller.viewDidProcessEdit(edit: edit, replacementLength: editedRange.length, newText: newText)
            }
        }
    }
}
