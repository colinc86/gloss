import Core
import Foundation

/// What the user currently has selected in a viewer, in the coordinates notes are stored in.
public enum ViewerSelection: Equatable, Sendable {
    case none
    /// UTF-16 range in the source text.
    case text(NSRange)
    /// A rendered-markdown selection mapped back to source; `exactText` is set when the mapping is exact and single-line.
    case renderedMarkdown(sourceRange: NSRange, exactText: String?)
    /// Rectangle in original pixel space, origin top-left.
    case image(CGRect)
    /// 0-based page, bounds in page points, selected text if any.
    case pdf(page: Int, bounds: CGRect?, text: String?)

    public var isEmpty: Bool {
        switch self {
        case .none: true
        case .text(let range): range.length == 0
        case .renderedMarkdown(let range, _): range.length == 0
        case .image(let rect): rect.isEmpty
        case .pdf(_, let bounds, let text): bounds == nil && (text ?? "").isEmpty
        }
    }
}

/// A note as the viewers draw it.
public struct NoteHighlight: Identifiable, Equatable, Sendable {
    public var id: NoteID
    public var anchor: Anchor
    public var color: NoteColor
    public var state: NoteState
    public var needsReview: Bool

    public init(id: NoteID, anchor: Anchor, color: NoteColor, state: NoteState, needsReview: Bool = false) {
        self.id = id
        self.anchor = anchor
        self.color = color
        self.state = state
        self.needsReview = needsReview
    }
}
