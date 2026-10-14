import AppKit
import Synchronization

/// The themes code is drawn with now: one for light appearance, one for dark. The app sets them from Settings
/// (through `CodeThemeStore.resolve`), and every viewer draws through them.
public enum ActiveCodeTheme {
    /// Posted on the main actor when either theme changes. Colors from `color(forCapture:)` and `editorColor(_:)`
    /// follow on their own; fonts, bold and italic, and anything cached need restyling.
    public static let didChange = Notification.Name("Viewers.ActiveCodeTheme.didChange")

    nonisolated private struct State: Sendable {
        var light = CodeTheme.gloss
        var dark = CodeTheme.gloss
        /// Dynamic colors handed out, so each capture name costs one object. Cleared when a theme changes, since
        /// whether a capture has a color at all depends on the themes.
        var captureColors: [String: NSColor?] = [:]
    }

    nonisolated private static let state = Mutex(State())

    public static var light: CodeTheme {
        get { snapshot().light }
        set { set(light: newValue, dark: nil) }
    }

    public static var dark: CodeTheme {
        get { snapshot().dark }
        set { set(light: nil, dark: newValue) }
    }

    /// Sets both at once, posting `didChange` once if either changed.
    public static func set(light: CodeTheme?, dark: CodeTheme?) {
        let changed = state.withLock { state in
            let before = (state.light, state.dark)
            if let light { state.light = light }
            if let dark { state.dark = dark }
            guard before != (state.light, state.dark) else { return false }
            state.captureColors = [:]
            return true
        }
        if changed { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    nonisolated public static func snapshot() -> (light: CodeTheme, dark: CodeTheme) {
        state.withLock { ($0.light, $0.dark) }
    }

    /// The theme for an appearance: the dark one for the dark-aqua family, else the light one.
    nonisolated public static func theme(for appearance: NSAppearance) -> CodeTheme {
        let themes = snapshot()
        return isDark(appearance) ? themes.dark : themes.light
    }

    /// A capture's color as a dynamic color that resolves through the current pair whenever it's drawn, so an
    /// appearance switch needs no re-render. Nil only when neither theme styles the capture.
    nonisolated public static func color(forCapture name: String) -> NSColor? {
        state.withLock { state in
            if let cached = state.captureColors[name] { return cached }
            let color: NSColor?
            if state.light.color(forCapture: name) == nil, state.dark.color(forCapture: name) == nil {
                color = nil
            } else {
                color = NSColor(name: nil) { appearance in
                    let theme = theme(for: appearance)
                    return theme.color(forCapture: name) ?? theme.editor.foreground.nsColor
                }
            }
            state.captureColors[name] = color
            return color
        }
    }

    /// An editor color (background, selection, gutter…) as a dynamic color through the current pair.
    nonisolated public static func editorColor(_ key: any KeyPath<EditorColors, ThemeColor> & Sendable) -> NSColor {
        NSColor(name: nil) { appearance in theme(for: appearance).editor[keyPath: key].nsColor }
    }

    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}
