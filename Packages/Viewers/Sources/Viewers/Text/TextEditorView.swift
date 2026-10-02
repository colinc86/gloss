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
        private var observers: [any NSObjectProtocol] = []
        private var loadedContentVersion = -1
        private var appliedHighlightsVersion = -1
        private var appliedScrollVersion = 0
        private var isApplyingContent = false

        init(controller: TextEditorController) {
            self.controller = controller
        }

        func attach(textView: SourceTextView, gutter: LineNumberGutterView, scrollView: NSScrollView) {
            self.textView = textView
            self.gutter = gutter
            textView.delegate = self
            textView.textStorage?.delegate = self
            textView.structuralExpansion = { [controller] range in controller.structuralExpansion(of: range) }
            textView.textLayoutManager?.renderingAttributesValidator = { [weak self] layoutManager, fragment in
                MainActor.assumeIsolated { self?.validateRenderingAttributes(layoutManager, fragment) }
            }
            controller.onRenderingInvalidation = { [weak self] range in
                guard let self, let textView = self.textView, let layoutManager = textView.textLayoutManager,
                      let contentManager = layoutManager.textContentManager else { return }
                if let range, let from = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
                   let to = contentManager.location(contentManager.documentRange.location, offsetBy: range.location + range.length),
                   let textRange = NSTextRange(location: from, end: to) {
                    layoutManager.invalidateRenderingAttributes(for: textRange)
                } else {
                    layoutManager.invalidateRenderingAttributes(for: contentManager.documentRange)
                }
                textView.needsDisplay = true
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak gutter] _ in
                MainActor.assumeIsolated { gutter?.needsDisplay = true }
            })
        }

        func detach() {
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

        private func invalidateHighlights() {
            appliedHighlightsVersion = controller.highlightsVersion
            guard let textView, let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager else { return }
            layoutManager.invalidateRenderingAttributes(for: contentManager.documentRange)
            textView.needsDisplay = true
            gutter?.needsDisplay = true
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
            for highlight in controller.highlights where !highlight.isInvalidated {
                let start = max(highlight.range.location, fragmentStart)
                let end = min(highlight.range.location + highlight.range.length, fragmentEnd)
                guard start < end,
                      let from = contentManager.location(documentStart, offsetBy: start),
                      let to = contentManager.location(documentStart, offsetBy: end),
                      let range = NSTextRange(location: from, end: to) else { continue }
                if highlight.state == .orphaned {
                    layoutManager.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle.patternDash.rawValue | NSUnderlineStyle.single.rawValue, for: range)
                    layoutManager.addRenderingAttribute(.underlineColor, value: Theme.color(for: highlight.color), for: range)
                } else {
                    layoutManager.addRenderingAttribute(.backgroundColor, value: Theme.highlightBackground(for: highlight.highlight), for: range)
                }
            }
        }

        // MARK: NSTextViewDelegate

        public func textDidChange(_ notification: Notification) {
            guard !isApplyingContent, let textView else { return }
            controller.viewDidChangeText(textView.string)
            gutter?.updateWidth()
            gutter?.needsDisplay = true
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
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
