import Core
import Foundation

/// What the note popover edits: a new note at `anchor`, or an existing one.
struct NoteEditorState: Identifiable {
    /// A fresh id per editor so replacing one new-note state with another re-presents the popover.
    var id = UUID()
    var existingID: NoteID?
    var anchor: Anchor
    var body: String
    var color: NoteColor
    /// Where the popover points, in the viewer's coordinate space.
    var anchorRect: CGRect

    var isNew: Bool { existingID == nil }
}
