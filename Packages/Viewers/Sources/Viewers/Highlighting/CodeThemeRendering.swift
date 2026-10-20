import AppKit
import Observation

/// Cached SwiftUI excerpts observe this value; semantic captures can be reused when only their styling changes.
@Observable public final class CodeThemeUpdates {
    public static let shared = CodeThemeUpdates()
    public private(set) var revision = 0
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: ActiveCodeTheme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

extension Theme {
    public static func editorFont(for appearance: NSAppearance) -> NSFont {
        ActiveCodeTheme.theme(for: appearance).font.resolved(defaultSize: fontSize)
    }
    public static func lineSpacing(for appearance: NSAppearance) -> CGFloat {
        CGFloat(ActiveCodeTheme.theme(for: appearance).font.lineSpacing ?? 1)
    }
    public static func selectedColors(for appearance: NSAppearance) -> (background: NSColor, foreground: NSColor) {
        selectedColors(theme: ActiveCodeTheme.theme(for: appearance),in: appearance.name)
    }
    public static func selectedColors(theme: CodeTheme,in appearance: NSAppearance.Name) -> (background: NSColor, foreground: NSColor) {
        if theme.id == "gloss" { return (.selectedTextBackgroundColor,.selectedTextColor) }
        let background = theme.editor.background.nsColor
        var selection = theme.editor.selection.nsColor
        if !theme.selectionClashes().isEmpty {
            selection = ThemeContrast.legible(selection, on: background, minimum: 1.8, in: appearance)
        }
        let components = ThemeColor(selection).resolved(in: appearance)
        let base = ThemeColor(background).resolved(in: appearance)
        let composite = NSColor(srgbRed: base.red + (components.red - base.red) * components.alpha,
                                green: base.green + (components.green - base.green) * components.alpha,
                                blue: base.blue + (components.blue - base.blue) * components.alpha, alpha: 1)
        return (selection, ThemeContrast.legible(theme.editor.foreground.nsColor, on: composite, minimum: 4.5, in: appearance))
    }
}

/// A quote is restyled for text, language, palette and appearance changes without adopting the editor's font size.
public nonisolated struct CodeSnippetKey: Hashable, Sendable {
    private let text: String
    private let language: String?
    private let dark: Bool
    private let revision: Int
    @MainActor public init(_ text: String,language: String?,dark: Bool) {
        self.text = text; self.language = language; self.dark = dark; revision = CodeThemeUpdates.shared.revision
    }
}
