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
        scroll.hasHorizontalScroller = !Theme.wrapsLines
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let gutter = LineNumberGutterView(textView: textView, controller: controller)
        let ruler = OverviewRulerView()
        ruler.controller = controller
        ruler.scrollView = scroll
        let container = TextEditorContainerView(gutter: gutter, scrollView: scroll, ruler: ruler)
        context.coordinator.attach(textView: textView, gutter: gutter, scrollView: scroll)
        context.coordinator.ruler = ruler
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
        weak var ruler: OverviewRulerView? {
            didSet { ruler?.superview?.needsLayout = true }
        }
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
            backdrop?.lineIndex = { [weak controller] in controller?.lineIndex }
            textView.delegate = self
            textView.textStorage?.delegate = self
            textView.onAttachedToWindow = { [weak self] in self?.sync() }
            textView.onFocusChange = { [weak self] in self?.updateCurrentLine() }
            textView.structuralExpansion = { [controller] range in controller.structuralExpansion(of: range) }
            textView.onHoverCharacter = { [weak controller] index in controller?.hover(at: index) }
            controller.rectProvider = { [weak self] range in self?.rect(for: range) }
            controller.topVisibleLocationProvider = { [weak self] in self?.textView?.topVisibleCharacterIndex }
            controller.noteGeometry.viewport = { [weak textView] in textView?.visibleWindowRect() }
            controller.noteGeometry.visibleNoteRects = { [weak textView, weak controller] in
                guard let textView, let controller else { return [:] }
                return textView.visibleHighlightRects(for: controller.drawnHighlights.filter { !$0.isInvalidated }.map { ($0.id, $0.range) })
            }
            textView.textLayoutManager?.renderingAttributesValidator = { [weak self] layoutManager, fragment in
                MainActor.assumeIsolated { self?.validateRenderingAttributes(layoutManager, fragment) }
            }
            controller.onRenderingInvalidation = { [weak self] range in
                // Arrives from inside the text storage's edit processing; touching the layout manager there let
                // TextKit drop the colors of every paragraph but the edited one. Run once the edit has finished.
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { self?.invalidateRendering(range) }
                }
            }
            highlightToken = controller.addHighlightObserver { [weak self] in self?.invalidateHighlights() }
            // Layout replaces estimated line heights as text scrolls in, which resizes the text view without
            // scrolling; the gutter and highlights must redraw then too, or they keep the estimated positions.
            textView.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: textView, queue: .main
            ) { [weak self, weak gutter, weak backdrop] _ in
                MainActor.assumeIsolated {
                    gutter?.needsDisplay = true
                    backdrop?.needsDisplay = true
                    self?.widthMayHaveChanged()
                    self?.controller.noteGeometry.changed()
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: Theme.editorSettingsDidChange, object: nil, queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    scrollView?.hasHorizontalScroller = !Theme.wrapsLines   // before the text view resizes to the new mode
                    self?.scheduleEditorSettings()
                }
            })
            scrollView.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self, weak gutter, weak backdrop] _ in
                MainActor.assumeIsolated {
                    gutter?.needsDisplay = true
                    backdrop?.needsDisplay = true
                    self?.ruler?.needsDisplay = true
                    self?.recolorVisibleIfStale()
                    // A peek points at where the note was; once the text scrolls it would point at nothing.
                    self?.controller.dismissPeek()
                    self?.controller.noteGeometry.changed()
                }
            })
        }

        /// A slider drag announces every step; restyle once per run-loop turn with the latest values.
        private var settingsPending = false
        private func scheduleEditorSettings() {
            guard !settingsPending else { return }
            settingsPending = true
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.settingsPending = false
                    self?.applyEditorSettings()
                }
            }
        }

        /// The wrap-indent cap is a share of the column, so a real change of width restyles; small jitters don't.
        private var styledWidth: CGFloat = 0
        private var widthPending = false
        private func widthMayHaveChanged() {
            guard let width = textView?.textContainer?.size.width, width > 100, abs(width - styledWidth) >= 40, !widthPending else { return }
            widthPending = true
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textView else { return }
                    self.widthPending = false
                    self.styledWidth = textView.textContainer?.size.width ?? 0
                    textView.applyWrapIndents(in: NSRange(location: 0, length: (textView.string as NSString).length))
                }
            }
        }

        /// Settings › Editor changed while this editor is open: restyle it now rather than on the next open.
        private func applyEditorSettings() {
            textView?.applyEditorSettings()
            backdrop?.showsIndentGuides = Theme.showsIndentGuides
            backdrop?.invalidateIndentGuides()
            gutter?.updateWidth()
            invalidateHighlights()
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
            // Styled at this width (none yet before layout, so the first real width restyles once with its cap).
            styledWidth = (textView.textContainer?.size.width ?? 0) > 100 ? textView.textContainer?.size.width ?? 0 : 0
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
            // A jump that arrives while the document is still opening waits for a window to scroll in and to focus;
            // `onAttachedToWindow` runs `sync` again then.
            if appliedScrollVersion != controller.pendingScrollVersion, let range = controller.pendingScroll,
               textView.window != nil, !textView.visibleRect.isEmpty {
                appliedScrollVersion = controller.pendingScrollVersion
                let clamped = NSRange(location: min(range.location, textView.string.utf16.count), length: 0)
                let target = NSRange(location: clamped.location, length: range.length)
                if controller.pendingScrollAtTop {
                    textView.scrollToTop(clamped.location)
                    gutter?.needsDisplay = true
                } else {
                    reveal(target, in: textView)
                }
                if controller.pendingScrollSelects {
                    textView.setSelectedRange(range.length > 0 ? range : clamped)
                    textView.window?.makeFirstResponder(textView)
                }
                // Where the jump landed, said the way Xcode says it: a brief find-indicator pop over the target, so
                // the eye finds it at once. Not for caret moves (no length), and only over a long note's first line.
                if range.length > 0 {
                    let target = Self.indicatorRange(for: range, in: controller.lineIndex)
                    RunLoop.main.perform(inModes: [.common]) { [weak textView] in
                        MainActor.assumeIsolated { textView?.showFindIndicator(for: target) }
                    }
                }
            }
        }

        /// A note's range, or just its first line's part of it when it runs over several lines.
        nonisolated static func indicatorRange(for range: NSRange, in index: LineIndex) -> NSRange {
            let line = index.position(forUTF16Offset: range.location).line
            let content = index.contentRange(ofLine: line)
            let end = min(NSMaxRange(range), NSMaxRange(content))
            return end > range.location ? NSRange(location: range.location, length: end - range.location) : range
        }

        /// Leaves the view alone when the range is already on screen (collapsing a selection after a note must not
        /// jump); otherwise brings it in and centres its first line, so a jump to a line lands mid-view rather than
        /// pinned to an edge.
        private func reveal(_ range: NSRange, in textView: NSTextView) {
            if let rect = textRect(for: range, in: textView), textView.visibleRect.contains(rect) { return }
            // Centre by asking TextKit to show a window of lines around the target rather than scrolling to a
            // computed offset: positions of lines not laid out yet are estimates, and scrolling to one landed
            // dozens of lines off once real layout replaced the estimate.
            let index = controller.lineIndex
            let line = index.position(forUTF16Offset: range.location).line
            let lineHeight = max(NSLayoutManager().defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)), 1)
            let half = max(0, Int(textView.visibleRect.height / lineHeight / 2) - 1)
            let first = index.range(ofLine: max(1, line - half))
            let last = index.range(ofLine: min(index.lineCount, line + half))
            let window = NSRange(location: first.location, length: max(range.location + range.length, last.location + last.length) - first.location)
            textView.scrollRangeToVisible(window)
            textView.scrollRangeToVisible(range)
            gutter?.needsDisplay = true
            backdrop?.needsDisplay = true
        }

        /// The range's segments in the text view's own coordinates; nil while it is not laid out.
        private func textRect(for range: NSRange, in textView: NSTextView) -> CGRect? {
            guard let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager else { return nil }
            let documentStart = contentManager.documentRange.location
            guard let from = contentManager.location(documentStart, offsetBy: range.location),
                  let to = contentManager.location(documentStart, offsetBy: range.location + range.length),
                  let textRange = NSTextRange(location: from, end: to) else { return nil }
            layoutManager.ensureLayout(for: textRange)
            var union: CGRect?
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                union = union.map { $0.union(frame) } ?? frame
                return true
            }
            return union?.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
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
            backdrop?.entries = controller.drawnHighlights.filter { !$0.isInvalidated }.map {
                HighlightBackdropView.Entry(range: $0.range, color: $0.color, state: $0.state, focused: controller.isFocused($0.id))
            }
            backdrop?.lineChanges = controller.lineChanges
            gutter?.needsDisplay = true
            // The ruler appears with a file's first note and goes with its last.
            ruler?.needsDisplay = true
            ruler?.superview?.needsLayout = true
            controller.noteGeometry.changed()
        }

        /// The validator only runs when a fragment is laid out, so invalidating rendering attributes alone leaves
        /// fragments that are already on screen unchanged; invalidating their layout makes TextKit ask again.
        /// Syntax colours are rendering attributes on layout fragments. TextKit calls the validator only when it
        /// lays a fragment out, and `invalidateRenderingAttributes` clears colours without bringing it back, so
        /// after the highlighter changes the visible fragments are re-coloured directly, and fragments coloured
        /// before a change are re-coloured when they scroll into view. Layout is never invalidated: that
        /// re-estimated line heights and moved the view on every keystroke.
        private func invalidateRendering(_ range: NSRange?) {
            recolorVisibleFragments { _ in true }
        }

        /// The highlighter generation each fragment was last coloured for (weak keys: fragments come and go).
        private let colouredAt = NSMapTable<NSTextLayoutFragment, NSNumber>.weakToStrongObjects()

        private func recolorVisibleIfStale() {
            guard let generation = controller.highlighter?.generation else { return }
            recolorVisibleFragments { [colouredAt] fragment in colouredAt.object(forKey: fragment)?.intValue != generation }
        }

        private func recolorVisibleFragments(where needsColour: (NSTextLayoutFragment) -> Bool) {
            guard let textView, let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager, controller.highlighter != nil else { return }
            let visible = textView.visibleRect
            let inset = textView.textContainerInset
            let top = CGPoint(x: 0, y: max(0, visible.minY - inset.height))
            let start = layoutManager.textLayoutFragment(for: top)?.rangeInElement.location ?? contentManager.documentRange.location
            var changed = false
            layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
                if fragment.layoutFragmentFrame.minY + inset.height > visible.maxY { return false }
                guard needsColour(fragment) else { return true }
                layoutManager.removeRenderingAttribute(.foregroundColor, for: fragment.rangeInElement)
                validateRenderingAttributes(layoutManager, fragment)
                changed = true
                return true
            }
            if changed { textView.needsDisplay = true }
        }

        // MARK: Rendering attributes (note highlights)

        private func validateRenderingAttributes(_ layoutManager: NSTextLayoutManager, _ fragment: NSTextLayoutFragment) {
            guard let contentManager = layoutManager.textContentManager else { return }
            let documentStart = contentManager.documentRange.location
            let fragmentRange = fragment.rangeInElement
            let fragmentStart = contentManager.offset(from: documentStart, to: fragmentRange.location)
            let fragmentEnd = contentManager.offset(from: documentStart, to: fragmentRange.endLocation)
            if let highlighter = controller.highlighter {
                colouredAt.setObject(NSNumber(value: highlighter.generation), forKey: fragment)
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
            controller.dismissPeek()
            guard !isApplyingContent, let textView else { return }
            controller.viewDidChangeText(textView.string)
            gutter?.updateWidth()
            gutter?.needsDisplay = true
            backdrop?.needsDisplay = true
        }

        /// Each editor keeps its own undo history: loading a document clears it, and with the window's shared manager
        /// that wiped unrelated entries such as Undo Delete Note.
        private let textUndoManager = UndoManager()

        public func undoManager(for view: NSTextView) -> UndoManager? { textUndoManager }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !isApplyingContent else { return }
            controller.selection = textView.selectedRange()
            controller.onSelectionChange(textView.selectedRange())
            gutter?.needsDisplay = true
            updateCurrentLine()
        }

        /// The current-line band shows only for a bare caret in the focused editor: a selection marks its own place.
        func updateCurrentLine() {
            guard let textView else { return }
            let range = textView.selectedRange()
            // The click that activates the window moves the caret without a selection notification reaching the
            // delegate; catch the controller (status bar, gutter, Add Note) up when focus arrives.
            if range != controller.selection, !isApplyingContent {
                controller.selection = range
                controller.onSelectionChange(range)
                gutter?.needsDisplay = true
            }
            let focused = textView.window?.isKeyWindow == true && textView.window?.firstResponder === textView
            backdrop?.caretLocation = range.length == 0 && focused ? range.location : nil
            gutter?.showsCurrentLine = range.length == 0 && focused
        }

        // MARK: NSTextStorageDelegate (nonisolated in AppKit; always called on the main thread for a view-owned storage)

        /// Typing changes a line's indentation; its wrapped continuation follows once the edit is done. Not inside the
        /// edit: restyling the whole paragraph there widened the edited range, and the text view put the caret at its
        /// end, so every keystroke jumped to the next line (attributes only, so it never touches undo either).
        public nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                backdrop?.invalidateIndentGuides()
                // A content load styles the whole file itself (`replaceAllText`); a second pass would redo it.
                guard !isApplyingContent else { return }
                RunLoop.main.perform(inModes: [.common]) { [weak self] in
                    MainActor.assumeIsolated { self?.textView?.applyWrapIndents(in: editedRange) }
                }
            }
        }

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
