import AppKit
import Core

/// WCAG contrast arithmetic for themes: the editor's warnings and note colors that stay legible on any background.
public nonisolated enum ThemeContrast {
    /// Below this a token gets a warning (never a block).
    public static let tokenMinimum = 3.0
    /// Below this the plain foreground gets a warning.
    public static let foregroundMinimum = 4.5

    typealias RGBA = (red: Double, green: Double, blue: Double, alpha: Double)

    /// WCAG 2 contrast ratio, 1…21. A translucent foreground is composited over the background first, and a
    /// translucent background over white (light) or black (dark).
    public static func ratio(_ foreground: NSColor, _ background: NSColor, in appearance: NSAppearance.Name) -> Double {
        let back = opaque(ThemeColor.components(of: background, in: appearance), in: appearance)
        let front = composite(ThemeColor.components(of: foreground, in: appearance), over: back)
        return ratio(luminance(front), luminance(back))
    }

    static func ratio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// `color` moved toward black or white, whichever gains contrast, until it reaches `minimum` against
    /// `background`. Its hue stays. Unchanged if it's already legible; as close as it gets if it can't be.
    public static func legible(_ color: NSColor, on background: NSColor, minimum: Double = tokenMinimum,
                               in appearance: NSAppearance.Name) -> NSColor {
        let back = opaque(ThemeColor.components(of: background, in: appearance), in: appearance)
        let original = ThemeColor.components(of: color, in: appearance)
        let front = composite(original, over: back)
        guard ratio(luminance(front), luminance(back)) < minimum else { return color }
        let target = luminance(back) > 0.18 ? 0.0 : 1.0   // toward black on a light background
        var best = front
        // Binary search on the mix amount: contrast grows monotonically as the color moves toward the target.
        var low = 0.0, high = 1.0
        for _ in 0 ..< 20 {
            let mid = (low + high) / 2
            let candidate = mix(front, toward: target, amount: mid)
            if ratio(luminance(candidate), luminance(back)) >= minimum {
                best = candidate
                high = mid
            } else {
                low = mid
            }
        }
        if ratio(luminance(best), luminance(back)) < minimum { best = mix(front, toward: target, amount: 1) }
        return NSColor(srgbRed: best.red, green: best.green, blue: best.blue, alpha: 1)
    }

    /// Whether a background reads as dark (so a theme on it is a dark theme).
    public static func isDark(_ color: ThemeColor) -> Bool {
        if color.isSystem { return false }
        return luminance(opaque(color.resolved(in: .aqua), in: .aqua)) < 0.18
    }

    /// How far apart two colors look, roughly: Euclidean distance in sRGB, 0…√3.
    static func distance(_ first: RGBA, _ second: RGBA) -> Double {
        let red = first.red - second.red, green = first.green - second.green, blue = first.blue - second.blue
        return (red * red + green * green + blue * blue).squareRoot()
    }

    static func luminance(_ color: RGBA) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    static func composite(_ top: RGBA, over bottom: RGBA) -> RGBA {
        let alpha = top.alpha
        return (bottom.red + (top.red - bottom.red) * alpha, bottom.green + (top.green - bottom.green) * alpha,
                bottom.blue + (top.blue - bottom.blue) * alpha, 1)
    }

    static func opaque(_ color: RGBA, in appearance: NSAppearance.Name) -> RGBA {
        guard color.alpha < 1 else { return color }
        let page: Double = appearance == .darkAqua ? 0 : 1
        return composite(color, over: (page, page, page, 1))
    }

    private static func mix(_ color: RGBA, toward target: Double, amount: Double) -> RGBA {
        (color.red + (target - color.red) * amount, color.green + (target - color.green) * amount,
         color.blue + (target - color.blue) * amount, 1)
    }
}

public nonisolated struct ContrastIssue: Hashable, Sendable {
    /// A token key, or "foreground".
    public let key: String
    public let appearance: NSAppearance.Name
    public let ratio: Double
    public let minimum: Double
}

nonisolated extension CodeTheme {
    /// The note fill's opacity a selection is compared with (a draft's tint).
    static let noteFillAlpha = 0.28
    /// Under this sRGB distance a selection and a note's fill read as the same thing.
    static let clashDistance = 0.08

    /// Warnings for the theme editor: each token below 3:1 against the background and the foreground below 4.5:1,
    /// in each appearance the theme is drawn in. Sorted by appearance, then key.
    public func contrastIssues() -> [ContrastIssue] {
        var issues: [ContrastIssue] = []
        let background = editor.background.nsColor
        for appearance in appearanceNames {
            let foreground = ThemeContrast.ratio(editor.foreground.nsColor, background, in: appearance)
            if foreground < ThemeContrast.foregroundMinimum {
                issues.append(ContrastIssue(key: "foreground", appearance: appearance, ratio: foreground, minimum: ThemeContrast.foregroundMinimum))
            }
            for key in tokens.keys.sorted() {
                guard let color = tokens[key]?.color else { continue }
                let ratio = ThemeContrast.ratio(color.nsColor, background, in: appearance)
                if ratio < ThemeContrast.tokenMinimum {
                    issues.append(ContrastIssue(key: key, appearance: appearance, ratio: ratio, minimum: ThemeContrast.tokenMinimum))
                }
            }
        }
        return issues
    }

    /// A note color that stays legible as an outline, bar or path on this theme's background (at least 3:1), as a
    /// dynamic color for a theme drawn in both appearances. Build the note tints from it. On a system background
    /// (Gloss, and themes duplicated from it) it is the system color unchanged, so Gloss looks as it always has.
    public func noteColor(_ color: NoteColor) -> NSColor {
        let base = Self.baseColor(for: color)
        guard !editor.background.isSystem else { return base }
        let background = editor.background.nsColor
        let names = appearanceNames
        let variants = Dictionary(uniqueKeysWithValues: names.map { ($0, ThemeContrast.legible(base, on: background, in: $0)) })
        guard names.count > 1 else { return variants[names[0]] ?? base }
        return NSColor(name: nil) { appearance in
            variants[appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .darkAqua : .aqua] ?? base
        }
    }

    /// Note colors whose draft fill can't be told from the selection on this background, in any appearance the
    /// theme is drawn in.
    public func selectionClashes() -> [NoteColor] {
        NoteColor.allCases.filter { noteColor in
            appearanceNames.contains { appearance in
                let back = ThemeContrast.opaque(editor.background.resolved(in: appearance), in: appearance)
                let selection = ThemeContrast.composite(editor.selection.resolved(in: appearance), over: back)
                var fill = ThemeColor.components(of: self.noteColor(noteColor), in: appearance)
                fill.alpha = Self.noteFillAlpha
                return ThemeContrast.distance(selection, ThemeContrast.composite(fill, over: back)) < Self.clashDistance
            }
        }
    }

    /// The same colors as `Theme.color(for:)`.
    static func baseColor(for color: NoteColor) -> NSColor {
        switch color {
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .pink: .systemPink
        case .purple: .systemPurple
        case .orange: .systemOrange
        }
    }
}
