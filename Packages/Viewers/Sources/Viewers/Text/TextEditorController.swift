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
        didSet {
            highlightsVersion += 1
            for observer in highlightObservers.values { observer() }
            // A peek on a note that's no longer drawn (the notes panel stopped listing it) has nothing under it.
            if let peek, !highlights.contains(where: { $0.id == peek.id && !$0.isHidden }) { dismissPeek() }
        }
    }
    public private(set) var highlightsVersion = 0
    /// The highlights drawn and hit: every one but those the notes panel isn't listing. Hidden ones stay in
    /// `highlights` so their ranges keep moving with edits.
    public var drawnHighlights: [TextHighlight] { highlights.filter { !$0.isHidden } }
    /// The note drawn at full strength whatever its state (#12): its card is selected in the notes panel.
    public var focusedNoteID: NoteID? {
        didSet {
            guard focusedNoteID != oldValue else { return }
            highlightsVersion += 1
            for observer in highlightObservers.values { observer() }
        }
    }

    /// In focus: the selected card's note, or the one under the pointer.
    public func isFocused(_ id: NoteID) -> Bool { id == focusedNoteID || id == peek?.id }
    /// Lines a change touched (a pull request's file at its head): tinted, marked and stepped through. Static: such
    /// files are never editable, so nothing shifts them.
    public var lineChanges: LineChanges? {
        didSet {
            guard lineChanges != oldValue else { return }
            highlightsVersion += 1
            for observer in highlightObservers.values { observer() }
        }
    }
    /// Views register here to redraw when highlights change; SwiftUI does not track reads inside AppKit updates.
    @ObservationIgnored private var highlightObservers: [UUID: () -> Void] = [:]

    @discardableResult
    public func addHighlightObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        highlightObservers[token] = observer
        return token
    }

    public func removeHighlightObserver(_ token: UUID) {
        highlightObservers[token] = nil
    }
    /// Where to scroll next; the view consumes it.
    public var pendingScroll: NSRange?
    public var pendingScrollVersion = 0
    /// Whether the pending scroll also selects the range and focuses the editor. Browsing notes from the panel
    /// passes false so the list keeps the keyboard and no Add Note button pops up over an existing note.
    public private(set) var pendingScrollSelects = true
    /// The pending scroll puts its line at the top of the view (resuming where reading stopped) rather than in sight.
    public private(set) var pendingScrollAtTop = false
    /// Set by the view: the character at the top of what is on screen.
    @ObservationIgnored public var topVisibleLocationProvider: () -> Int? = { nil }
    public var topVisibleLocation: Int? { topVisibleLocationProvider() }
    /// Syntax highlighting, when a grammar exists for the document's language.
    @ObservationIgnored public private(set) var highlighter: Highlighter?
    /// Set by the view; invalidates rendering attributes for a range (nil = everything).
    @ObservationIgnored public var onRenderingInvalidation: (NSRange?) -> Void = { _ in }
    /// Set by the view; the on-screen rectangle of a range in the editor container's coordinates.
    @ObservationIgnored public var rectProvider: (NSRange) -> CGRect? = { _ in nil }

    public func rect(for range: NSRange) -> CGRect? {
        rectProvider(range)
    }

    /// Where this editor's notes are on screen, for the notes panel's link and paths.
    @ObservationIgnored public let noteGeometry = NoteGeometry()

    // MARK: Note peek

    /// The note under the pointer, shown as a peek card after a short rest; nil when none.
    public private(set) var peek: TextHighlight? {
        didSet {
            // The note under the pointer comes up to full strength while it is there (#12).
            guard peek?.id != oldValue?.id else { return }
            for observer in highlightObservers.values { observer() }
        }
    }
    /// Whether the pointer is on the peek card itself (it stays while it is).
    @ObservationIgnored public var isPeekHovered = false {
        didSet { if !isPeekHovered { schedulePeekHide() } else { peekTask?.cancel() } }
    }
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var hoveredNoteID: NoteID?
    /// Rest before a peek appears, so skimming over highlights does not flash cards.
    static let peekDelay: Duration = .milliseconds(450)

    /// The pointer is over `index` (nil: over nothing). Shows the note there after a rest, hides when it leaves.
    public func hover(at index: Int?) {
        let highlight = index.flatMap { index in
            drawnHighlights.last { !$0.isInvalidated && $0.state != .orphaned && NSLocationInRange(index, $0.range) }
        }
        guard highlight?.id != hoveredNoteID else { return }
        hoveredNoteID = highlight?.id
        peekTask?.cancel()
        guard let highlight else {
            schedulePeekHide()
            return
        }
        peekTask = Task { [weak self] in
            // Moving from one note straight to another switches at once; a fresh hover waits.
            if self?.peek == nil { try? await Task.sleep(for: Self.peekDelay) }
            guard !Task.isCancelled else { return }
            self?.peek = highlight
        }
    }

    public func dismissPeek() {
        peekTask?.cancel()
        hoveredNoteID = nil
        peek = nil
    }

    private func schedulePeekHide() {
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, !self.isPeekHovered, self.hoveredNoteID == nil else { return }
            self.peek = nil
        }
    }

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

    /// Called by the view after the user edited (public so tests can drive the controller without a view).
    public func viewDidChangeText(_ newText: String) {
        if text != newText {
            text = newText
            lineIndex = LineIndex(newText)
        }
        onTextChange()
    }

    public func viewDidProcessEdit(edit: NSRange, replacementLength: Int, newText: String) {
        let oldIndex = lineIndex
        let newIndex = LineIndex(newText)
        text = newText
        lineIndex = newIndex
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
        if highlighter?.mayBeStale == true { scheduleHighlightRebuild() }
    }

    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    /// Once typing pauses, rebuilds embedded-language highlighting off the main actor and adopts it when the text
    /// has not changed meanwhile (see `Highlighter.backgroundRebuild`).
    private func scheduleHighlightRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let highlighter = self.highlighter, let job = highlighter.backgroundRebuild() else { return }
            let rebuild = await Task.detached(priority: .utility) { job() }.value
            guard !Task.isCancelled, let rebuild, highlighter.adopt(rebuild) else { return }
            self.onRenderingInvalidation(nil)
        }
    }

    public func scroll(to range: NSRange, select: Bool = true, atTop: Bool = false) {
        pendingScroll = range
        pendingScrollSelects = select
        pendingScrollAtTop = atTop
        pendingScrollVersion += 1
    }

    /// Collapses the selection to its end. The view applies it through the scroll request (the range is on screen,
    /// so nothing moves) and reports the new selection back.
    public func collapseSelection() {
        guard selection.length > 0 else { return }
        let end = NSRange(location: selection.location + selection.length, length: 0)
        selection = end
        scroll(to: end)
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
    /// Not listed in the notes panel (another tab, colour or search, or a resolved note while those are hidden): not
    /// drawn, but still carried through edits.
    public var isHidden = false

    public init(id: NoteID, range: NSRange, color: NoteColor, state: NoteState, needsReview: Bool = false, isInvalidated: Bool = false,
                isHidden: Bool = false) {
        self.id = id
        self.range = range
        self.color = color
        self.state = state
        self.needsReview = needsReview
        self.isInvalidated = isInvalidated
        self.isHidden = isHidden
    }

    public var highlight: NoteHighlight {
        NoteHighlight(id: id, anchor: .wholeFile, color: color, state: state, needsReview: needsReview)
    }
}
