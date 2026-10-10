import AppKit
import OSLog

/// A TextKit 2 `NSTextView` configured for plain source text.
public final class SourceTextView: NSTextView {
    nonisolated private static let log = Logger(subsystem: "com.cnc.Gloss", category: "viewer")

    /// Called once the view is in a window and has been sized, for work that needs both (focus, scrolling).
    var onAttachedToWindow: (() -> Void)?
    /// A window resize finished: work put off while it ran (restyling for the new width) happens now.
    var onEndLiveResize: (() -> Void)?

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    /// Files dragged from Finder open in the app instead of pasting their paths into the document: without the
    /// file types the drag falls through to the window, which opens them.
    override public func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes(newTypes.filter { $0 != .fileURL && $0.rawValue != "NSFilenamesPboardType" })
    }
    /// Focus moved to or from the editor, or its window became or stopped being key.
    var onFocusChange: (() -> Void)?
    private var keyObservers: [any NSObjectProtocol] = []

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
        return resigned
    }
    /// The character under the pointer as it moves (nil when it leaves), and the insertion point when the pointer is
    /// within a few points of it, for note peeks.
    var onHoverCharacter: ((_ index: Int?, _ caret: Int?) -> Void)?
    private var hoverTracking: NSTrackingArea?

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override public func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // No peeks while a button is down (selecting) or text is selected.
        guard NSEvent.pressedMouseButtons == 0, selectedRange().length == 0 else {
            onHoverCharacter?(nil, nil)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        // A removal point is a 2 pt caret: within 3 pt of it counts as over it.
        let caret = caretRect(at: index).map { $0.insetBy(dx: -3, dy: 0).contains(point) } == true ? index : nil
        // Insertion points snap to the nearest gap; only report a character the pointer is actually over.
        if index < (string as NSString).length, firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
            .insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
            onHoverCharacter?(index, caret)
        } else if index > 0, firstRect(forCharacterRange: NSRange(location: index - 1, length: 1), actualRange: nil)
            .insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
            onHoverCharacter?(index - 1, caret)
        } else {
            onHoverCharacter?(nil, caret)
        }
    }

    override public func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverCharacter?(nil, nil)
    }

    // A window torn down with the editor still in it frees the view without `viewWillMove(toWindow: nil)`.
    isolated deinit {
        keyObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let newWindow else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocusChange?() }
            })
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Next turn of the run loop: the enclosing views get their frames in the same layout pass.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.onAttachedToWindow?() }
        }
    }

    public static func make() -> SourceTextView {
        let view = SourceTextView(usingTextLayoutManager: true)
        view.configure()
        return view
    }

    private func configure() {
        assert(textLayoutManager != nil, "TextKit 2 expected")
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        font = Theme.editorFont
        textColor = .textColor
        typingAttributes = [.font: Theme.editorFont, .foregroundColor: NSColor.textColor]
        backgroundColor = .textBackgroundColor
        drawsBackground = true
        textContainerInset = NSSize(width: 6, height: 8)
        isVerticallyResizable = true
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        applyWrapping()
        // Selector observers are unregistered automatically when the view is deallocated.
        NotificationCenter.default.addObserver(self, selector: #selector(didSwitchToTextKit1), name: NSTextView.willSwitchToNSLayoutManagerNotification, object: self)
    }

    /// Whether this editor wraps; set from `Theme.wrapsLines` when made and when Settings › Editor changes.
    public private(set) var wrapsLines = Theme.wrapsLines

    private func applyWrapping() {
        if wrapsLines {
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            textContainer?.widthTracksTextView = true
            textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        } else {
            // Long lines run on; the scroll view gets a horizontal scroller.
            isHorizontallyResizable = true
            autoresizingMask = [.width, .height]
            textContainer?.widthTracksTextView = false
            textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    /// Restyles an open editor after Settings › Editor changed: font, wrapping, and the wrapped rows' indents. The line at
    /// the top of the view stays at the top, so a bigger font never loses your place. Attributes only; the text, undo,
    /// and every anchor are untouched.
    public func applyEditorSettings(font newFont: NSFont = Theme.editorFont, wraps: Bool = Theme.wrapsLines) {
        guard let storage = textStorage, let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager else { return }
        let documentStart = contentManager.documentRange.location
        let topOffset = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visibleRect.minY - textContainerInset.height)))
            .map { contentManager.offset(from: documentStart, to: $0.rangeInElement.location) }

        // Only what changed: a guides toggle restyles nothing here, a font step re-measures indents once.
        let fontChanged = font != newFont
        let wrapChanged = wrapsLines != wraps
        guard fontChanged || wrapChanged else { return }
        if fontChanged {
            font = newFont
            typingAttributes[.font] = newFont
        }
        if wrapsLines != wraps {
            wrapsLines = wraps
            applyWrapping()
            if wraps, let width = enclosingScrollView?.contentSize.width {
                setFrameSize(NSSize(width: width, height: frame.height))
            }
        }
        let all = NSRange(location: 0, length: storage.length)
        if wraps {
            applyWrapIndents(in: all)
        } else {
            storage.removeAttribute(.paragraphStyle, range: all)
        }

        guard let topOffset, let location = contentManager.location(documentStart, offsetBy: topOffset) else { return }
        layoutManager.ensureLayout(for: NSTextRange(location: location))
        if let fragment = layoutManager.textLayoutFragment(for: location) {
            scroll(NSPoint(x: 0, y: fragment.layoutFragmentFrame.minY + textContainerInset.height))
        }
    }

    @objc private func didSwitchToTextKit1(_ notification: Notification) {
        Self.log.fault("SourceTextView fell back to TextKit 1; highlights will stop working")
    }

    /// Replaces the whole content without touching the undo stack and clears it.
    public func replaceAllText(with string: String) {
        guard let storage = textStorage else { return }
        // Plain characters inherit nothing; give them the view's font and color or they draw black.
        let attributed = NSAttributedString(string: string, attributes: baseAttributes)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: attributed)
        storage.endEditing()
        // The whole file at once on load; edits restyle their own paragraphs afterwards (`TextEditorView`).
        applyWrapIndents(in: NSRange(location: 0, length: storage.length))
        undoManager?.removeAllActions()
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    public var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? Theme.editorFont, .foregroundColor: textColor ?? NSColor.textColor]
    }

    /// Set by the coordinator; grows the selection to the enclosing syntax node.
    public var structuralExpansion: ((NSRange) -> NSRange?)?
    private var selectionStack: [NSRange] = []

    @objc public func expandSelection(_ sender: Any?) {
        let current = selectedRange()
        guard let larger = structuralExpansion?(current) else { return }
        selectionStack.append(current)
        setSelectedRange(larger)
    }

    @objc public func shrinkSelection(_ sender: Any?) {
        guard let previous = selectionStack.popLast() else { return }
        setSelectedRange(previous)
    }

    override public func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.control, .shift], let key = event.charactersIgnoringModifiers {
            if event.keyCode == 126 || key == "\u{F700}" { expandSelection(nil); return }
            if event.keyCode == 125 || key == "\u{F701}" { shrinkSelection(nil); return }
        }
        super.keyDown(with: event)
    }

    // MARK: Wrapped lines

    /// How far a wrapped line's continuation sits from the margin: the line's own indentation plus one step, as Xcode
    /// and VS Code do, so a wrapped comment or argument list never reads as a new line of code. Capped so deeply nested
    /// lines keep room to wrap into.
    public nonisolated static func wrapIndent(forLine line: some StringProtocol, spaceWidth: CGFloat, tabWidth: CGFloat, limit: CGFloat) -> CGFloat {
        var leading: CGFloat = 0
        for character in line {
            if character == " " {
                leading += spaceWidth
            } else if character == "\t" {
                leading = (floor(leading / tabWidth) + 1) * tabWidth
            } else {
                break
            }
        }
        // A blank or whitespace-only line has nothing to wrap.
        guard line.contains(where: { $0 != " " && $0 != "\t" && !$0.isNewline }) else { return 0 }
        return min(leading + spaceWidth * Self.wrapStep, max(0, limit))
    }

    /// One indent step, in spaces.
    nonisolated static let wrapStep: CGFloat = 4

    /// Gives every paragraph touched by `range` a head indent for its wrapped continuation. Attributes only: the text,
    /// and so every anchor offset, is untouched. Does nothing when lines don't wrap. Pass `insideEdit` from the storage's
    /// `willProcessEditing`, where the change joins the edit in progress instead of starting another.
    public func applyWrapIndents(in range: NSRange, insideEdit: Bool = false) {
        guard wrapsLines, let storage = textStorage, storage.length > 0 else { return }
        let text = storage.string as NSString
        let paragraphs = text.paragraphRange(for: NSRange(location: min(range.location, storage.length), length: min(range.length, storage.length - min(range.location, storage.length))))
        let font = font ?? Theme.editorFont
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let tab = NSParagraphStyle.default.defaultTabInterval
        // Before the view is laid out the container has no width yet; leave the cap off rather than cap at zero.
        let width = textContainer?.size.width ?? 0
        let limit = width > 100 ? width * 0.4 : .greatestFiniteMagnitude
        // Most lines share a handful of indents; one style object each keeps a large file cheap.
        var styles: [CGFloat: NSParagraphStyle] = [:]
        if !insideEdit { storage.beginEditing() }
        text.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            let line = text.substring(with: enclosing)
            let indent = Self.wrapIndent(forLine: line, spaceWidth: space, tabWidth: tab, limit: limit)
            let style = styles[indent] ?? {
                let made = NSMutableParagraphStyle()
                made.headIndent = indent
                styles[indent] = made
                return made
            }()
            storage.addAttribute(.paragraphStyle, value: style, range: enclosing)
        }
        if !insideEdit { storage.endEditing() }
    }

    /// An undoable programmatic replacement.
    public func replaceUndoable(_ range: NSRange, with string: String) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
    }
}
