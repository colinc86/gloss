import AppKit
import Core
import Observation

/// Shared state between a `DocumentSession` and the AppKit text view that shows it.
/// SwiftUI never diffs the text itself: the controller pushes content with a version number.
@Observable
public final class TextEditorController {
    /// The full text as last seen by the controller. The view updates it on every edit.
    public private(set) var text: String
    /// Bumped by `replaceAll`; the view reloads only when it changes.
    public private(set) var contentVersion = 0
    public var isEditable = true
    public var selection = NSRange(location: 0, length: 0)
    public private(set) var lineIndex: LineIndex
    public var highlights: [TextHighlight] = [] {
        didSet { highlightsVersion += 1 }
    }
    public private(set) var highlightsVersion = 0
    /// Where to scroll next; the view consumes it.
    public var pendingScroll: NSRange?
    public var pendingScrollVersion = 0
    /// Syntax highlighting, when a grammar exists for the document's language.
    @ObservationIgnored public private(set) var highlighter: Highlighter?
    /// Set by the view; invalidates rendering attributes for a range (nil = everything).
    @ObservationIgnored public var onRenderingInvalidation: (NSRange?) -> Void = { _ in }

    /// Called after the text storage processed an edit, in pre-edit coordinates.
    public var onEdit: (_ edit: NSRange, _ replacementLength: Int) -> Void = { _, _ in }
    public var onTextChange: () -> Void = {}
    public var onSelectionChange: (NSRange) -> Void = { _ in }
    /// A click in the gutter: the 1-based line, and whether a note marker was hit.
    public var onGutterClick: (_ line: Int, _ noteID: NoteID?) -> Void = { _, _ in }

    public init(text: String, languageName: String? = nil) {
        self.text = text
        lineIndex = LineIndex(text)
        if let languageName { highlighter = Highlighter(languageName: languageName, text: text) }
    }

    /// Replaces the whole text (open, reload). Resets the undo stack in the view.
    public func replaceAll(with newText: String) {
        text = newText
        lineIndex = LineIndex(newText)
        highlighter?.replaceAll(with: newText)
        contentVersion += 1
    }

    /// Grows the selection to the enclosing syntax node; nil when nothing larger exists.
    public func structuralExpansion(of range: NSRange) -> NSRange? {
        highlighter?.enclosingNodeRange(of: range)
    }

    /// Called by the view after the user edited.
    func viewDidChangeText(_ newText: String) {
        text = newText
        lineIndex = LineIndex(newText)
        onTextChange()
    }

    func viewDidProcessEdit(edit: NSRange, replacementLength: Int, newText: String) {
        let oldIndex = lineIndex
        let newIndex = LineIndex(newText)
        highlighter?.apply(edit: edit, replacementLength: replacementLength, newText: newText, oldIndex: oldIndex, newIndex: newIndex)
        highlights = highlights.compactMap { highlight in
            var updated = highlight
            switch AnchorShifter.apply(edit: edit, replacementLength: replacementLength, to: highlight.range) {
            case .shifted(let range), .resized(let range), .unchanged(let range):
                updated.range = range
                return updated
            case .invalidated:
                updated.range = NSRange(location: edit.location + replacementLength, length: 0)
                updated.isInvalidated = true
                return updated
            }
        }
        onEdit(edit, replacementLength)
        if highlighter != nil { onRenderingInvalidation(nil) }
    }

    public func scroll(to range: NSRange) {
        pendingScroll = range
        pendingScrollVersion += 1
    }

    public var selectionPosition: (start: TextPosition, end: TextPosition) {
        lineIndex.positions(for: selection)
    }
}

/// A note highlight resolved to a live UTF-16 range.
public struct TextHighlight: Identifiable, Equatable, Sendable {
    public var id: NoteID
    public var range: NSRange
    public var color: NoteColor
    public var state: NoteState
    public var needsReview: Bool
    /// The text under the anchor was replaced; drawn as a marker only until re-anchored.
    public var isInvalidated = false

    public init(id: NoteID, range: NSRange, color: NoteColor, state: NoteState, needsReview: Bool = false, isInvalidated: Bool = false) {
        self.id = id
        self.range = range
        self.color = color
        self.state = state
        self.needsReview = needsReview
        self.isInvalidated = isInvalidated
    }

    public var highlight: NoteHighlight {
        NoteHighlight(id: id, anchor: .wholeFile, color: color, state: state, needsReview: needsReview)
    }
}
