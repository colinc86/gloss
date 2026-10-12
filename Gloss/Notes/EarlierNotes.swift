import Core
import Foundation

/// An earlier iteration's note found again in the text as it is now (Show Earlier Notes, 2026-10-11).
nonisolated struct EarlierNote: Equatable, Sendable {
    var note: Note
    var range: NSRange
}

/// Finding earlier iterations' notes in the text as it is now: what Bring Forward does for one note, and Show Earlier
/// Notes for every note of a document. Text anchors only.
nonisolated enum EarlierNotes {
    /// The most earlier notes looked for in one document, newest iteration first.
    static let limit = 300

    /// Where `anchor` is in `text` now: unchanged, or moved; nil when its text is gone.
    static func relocate(_ anchor: TextAnchor, in text: String, hash: String, fileName: String) -> TextAnchor? {
        switch ReAnchorer.text(anchor, in: text, newHash: hash, fileName: fileName) {
        case .unchanged: anchor
        case .moved(let moved), .movedNeedsReview(let moved):
            if case .text(let found) = moved { found } else { nil }
        case .removed, .orphaned: nil
        }
    }

    /// `notes` (earlier iterations', newest first) found again in `text`; ones whose text is gone, and ones that
    /// aren't on text, are left out.
    static func locate(_ notes: [Note], in text: String, fileName: String) -> [EarlierNote] {
        let hash = Data(text.utf8).sha256Hex
        let index = LineIndex(text)
        return notes.prefix(limit).compactMap { note in
            // A newer search replaced this one: stop rather than finish work nobody will draw.
            guard !Task.isCancelled else { return nil }
            guard case .text(let anchor) = note.anchor, anchor.cells == nil,
                  let found = relocate(anchor, in: text, hash: hash, fileName: fileName) else { return nil }
            return EarlierNote(note: note, range: index.range(for: found))
        }
    }

    /// `locate` off the main actor, stopping when the calling task is cancelled.
    @concurrent static func find(_ notes: [Note], in text: String, fileName: String) async -> [EarlierNote] {
        locate(notes, in: text, fileName: fileName)
    }
}
