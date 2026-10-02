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
        switch highlight.state {
        case .draft: return base.withAlphaComponent(0.28)
        case .sent: return base.withAlphaComponent(0.18)
        case .resolved: return base.withAlphaComponent(0.08)
        case .orphaned: return NSColor.clear
        }
    }

    public static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    }

    public static var gutterFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    }
}
