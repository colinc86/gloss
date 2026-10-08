import Foundation

public enum ShiftResult: Equatable, Sendable {
    /// The edit was entirely before the range; it moved by the edit's length delta.
    case shifted(NSRange)
    /// The edit touched the range; part of it survives.
    case resized(NSRange)
    /// The edit was after the range.
    case unchanged(NSRange)
    /// The edit deleted the whole range and put nothing in its place: the range is a point where the text was, and
    /// the note is saved as a removal.
    case collapsed(NSRange)
    /// The edit replaced the whole range; the note needs re-anchoring from its stored context.
    case invalidated

    public var range: NSRange? {
        switch self {
        case .shifted(let range), .resized(let range), .unchanged(let range), .collapsed(let range): range
        case .invalidated: nil
        }
    }
}

/// Keeps a live anchor range in step with edits as they happen, before any save.
public enum AnchorShifter {
    /// - Parameters:
    ///   - edit: the replaced range in pre-edit coordinates (`editedRange.length - changeInLength` from `NSTextStorage`).
    ///   - replacementLength: the length of the text that replaced it.
    ///   - range: the anchor's range in pre-edit coordinates.
    public static func apply(edit: NSRange, replacementLength: Int, to range: NSRange) -> ShiftResult {
        let delta = replacementLength - edit.length
        let editEnd = edit.location + edit.length
        let rangeEnd = range.location + range.length

        if editEnd <= range.location {
            // Before the anchor (including an insertion exactly at its start).
            return .shifted(NSRange(location: range.location + delta, length: range.length))
        }
        if edit.location >= rangeEnd {
            // After the anchor (including an insertion exactly at its end).
            return .unchanged(range)
        }
        if edit.location <= range.location && editEnd >= rangeEnd {
            // Covers the whole anchor: deleted, or replaced by new text.
            return replacementLength == 0 ? .collapsed(NSRange(location: edit.location, length: 0)) : .invalidated
        }
        if edit.location >= range.location && editEnd <= rangeEnd {
            // Strictly inside: the anchor grows or shrinks.
            return .resized(NSRange(location: range.location, length: range.length + delta))
        }
        if edit.location < range.location {
            // Overlaps the start: the surviving part starts after the replacement.
            let surviving = rangeEnd - editEnd
            return .resized(NSRange(location: edit.location + replacementLength, length: surviving))
        }
        // Overlaps the end: the surviving part is the head.
        return .resized(NSRange(location: range.location, length: edit.location - range.location))
    }
}
