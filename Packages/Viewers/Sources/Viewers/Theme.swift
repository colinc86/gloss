import AppKit
import Core

/// Colors and fonts shared by every viewer.
public enum Theme {
    public static func color(for noteColor: NoteColor) -> NSColor {
        switch noteColor {
        case .yellow: NSColor.systemYellow
        case .green: NSColor.systemGreen
        case .blue: NSColor.systemBlue
        case .pink: NSColor.systemPink
        case .purple: NSColor.systemPurple
        case .orange: NSColor.systemOrange
        }
    }

    /// Background tint for a note's range in text.
    public static func highlightBackground(for highlight: NoteHighlight) -> NSColor {
        let base = color(for: highlight.color)
        let alpha: CGFloat
        switch highlight.state {
        case .draft: alpha = 0.28
        case .sent: alpha = 0.18
        case .resolved: alpha = 0.08
        case .orphaned: return NSColor.clear
        }
        // Over a dark page a light tint mixes toward mud (yellow turns olive); a stronger one keeps its hue.
        return NSColor(name: nil) { appearance in
            base.withAlphaComponent(alpha * (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkBoost : 1))
        }
    }

    /// How a note marks content in its state (#12). Drafts are the open work and fill their text; once sent a note
    /// steps back to an underline, resolved to a faint dotted one, and an orphan keeps its dashed one. A note in focus
    /// (its card selected, or under the pointer) fills again whatever its state, so it can always be found.
    public enum NoteMark: Equatable, Sendable {
        case fill, underline, dottedUnderline, dashedUnderline
    }

    public static func mark(for state: NoteState, focused: Bool) -> NoteMark {
        if state == .orphaned { return .dashedUnderline }
        if focused || state == .draft { return .fill }
        return state == .sent ? .underline : .dottedUnderline
    }

    /// One ladder for every surface that shows a note's state (gutter bars, the ruler, regions, rows, page boxes):
    /// open work at full strength, then each step back quieter.
    public static func strength(for state: NoteState) -> CGFloat {
        switch state {
        case .draft: 1
        case .sent: 0.55
        case .resolved: 0.3
        case .orphaned: 0.8
        }
    }

    /// The fill a note's text gets when it fills: a draft's tint, whatever the state of a note in focus.
    public static func highlightFill(for noteColor: NoteColor) -> NSColor {
        let base = color(for: noteColor)
        return NSColor(name: nil) { appearance in
            base.withAlphaComponent(0.28 * (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkBoost : 1))
        }
    }

    /// How much stronger note tints are in dark appearance.
    public static let darkBoost: CGFloat = 1.3

    /// A row a change added or rewrote: quieter than a resolved note, so a green note on an added line still reads.
    public static let changeAddedBackground = NSColor(name: nil) { appearance in
        NSColor.systemGreen.withAlphaComponent(0.10 * (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkBoost : 1))
    }
    /// The gutter's strip beside an added row, and the ruler's mark for a hunk.
    public static let changeBar = NSColor.systemGreen.withAlphaComponent(0.85)
    /// The hairline where a change took lines out.
    public static let changeDeletedMarker = NSColor.systemRed.withAlphaComponent(0.9)

    /// Settings > Editor. Open editors restyle as soon as one changes (`editorSettingsDidChange`), so a setting is
    /// seen while it is being adjusted.
    public static var editorFontSize: CGFloat = 12.5 {
        didSet { if oldValue != editorFontSize { announceEditorSettings() } }
    }
    public static var wrapsLines = true {
        didSet { if oldValue != wrapsLines { announceEditorSettings() } }
    }
    public static var showsIndentGuides = true {
        didSet { if oldValue != showsIndentGuides { announceEditorSettings() } }
    }

    public static let editorSettingsDidChange = Notification.Name("Viewers.editorSettingsDidChange")

    private static func announceEditorSettings() {
        NotificationCenter.default.post(name: editorSettingsDidChange, object: nil)
    }

    public static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    }

    public static var gutterFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    }
}
