import AppKit
import OSLog

/// A TextKit 2 `NSTextView` configured for plain source text.
public final class SourceTextView: NSTextView {
    nonisolated private static let log = Logger(subsystem: "com.cnc.Gloss", category: "viewer")

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
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: self, queue: .main
        ) { _ in
            Self.log.fault("SourceTextView fell back to TextKit 1; highlights will stop working")
        }
    }

    /// Replaces the whole content without touching the undo stack and clears it.
    public func replaceAllText(with string: String) {
        guard let storage = textStorage else { return }
        // Plain characters inherit nothing; give them the view's font and color or they draw black.
        let attributed = NSAttributedString(string: string, attributes: baseAttributes)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: attributed)
        storage.endEditing()
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

    /// An undoable programmatic replacement.
    public func replaceUndoable(_ range: NSRange, with string: String) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
    }
}
