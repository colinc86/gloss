import AppKit

/// A color in a theme file: `#RGB`, `#RRGGBB`, `#RRGGBBAA` (sRGB), or `system:<name>` for one of a fixed list of
/// macOS colors, which stay dynamic so a theme built on them (Gloss) follows the appearance.
public nonisolated struct ThemeColor: Codable, Hashable, Sendable, CustomStringConvertible {
    enum Value: Hashable, Sendable {
        case rgba(red: Double, green: Double, blue: Double, alpha: Double)
        case system(String)
    }

    let value: Value

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("system:") {
            let name = String(trimmed.dropFirst("system:".count))
            guard Self.systemColors[name] != nil else { return nil }
            value = .system(name)
            return
        }
        guard trimmed.hasPrefix("#") else { return nil }
        var hex = Array(trimmed.dropFirst())
        guard hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if hex.count == 3 || hex.count == 4 { hex = hex.flatMap { [$0, $0] } }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        func channel(_ index: Int) -> Double { Double(Int(String(hex[index * 2 ..< index * 2 + 2]), radix: 16) ?? 0) / 255 }
        value = .rgba(red: channel(0), green: channel(1), blue: channel(2), alpha: hex.count == 8 ? channel(3) : 1)
    }

    /// Components are kept to 8 bits, as the file writes them, so a color reads back equal to what was saved.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func clamp(_ value: Double) -> Double { value.isFinite ? (min(max(value, 0), 1) * 255).rounded() / 255 : 0 }
        value = .rgba(red: clamp(red), green: clamp(green), blue: clamp(blue), alpha: clamp(alpha))
    }

    /// From a color well: resolved to sRGB in the current appearance and written as hex.
    public init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? NSColor.black
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }

    static func system(_ name: String) -> ThemeColor {
        precondition(systemColors[name] != nil, "unknown system color \(name)")
        return ThemeColor(value: .system(name))
    }

    private init(value: Value) { self.value = value }

    public var isSystem: Bool {
        if case .system = value { return true }
        return false
    }

    public var nsColor: NSColor {
        switch value {
        case let .rgba(red, green, blue, alpha): NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        case let .system(name): Self.systemColors[name] ?? .textColor
        }
    }

    public var description: String {
        switch value {
        case let .system(name): return "system:\(name)"
        case let .rgba(red, green, blue, alpha):
            func byte(_ value: Double) -> String { String(format: "%02X", Int((value * 255).rounded())) }
            return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
        }
    }

    /// The sRGB components this color draws with in an appearance (`.aqua` or `.darkAqua`).
    public func resolved(in appearance: NSAppearance.Name) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        if case let .rgba(red, green, blue, alpha) = value { return (red, green, blue, alpha) }
        return Self.components(of: nsColor, in: appearance)
    }

    /// Any color's sRGB components in an appearance; dynamic colors are resolved first.
    static func components(of color: NSColor, in appearance: NSAppearance.Name) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        var result = (red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let resolve = {
            if let srgb = color.usingColorSpace(.sRGB) {
                result = (srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent)
            }
        }
        if let named = NSAppearance(named: appearance) { named.performAsCurrentDrawingAppearance(resolve) } else { resolve() }
        return result
    }

    /// This color at `amount` (0…1) of the way over `base`, opaque. Both resolved in `appearance`.
    func mixed(over base: ThemeColor, amount: Double, in appearance: NSAppearance.Name) -> ThemeColor {
        let top = resolved(in: appearance), bottom = base.resolved(in: appearance)
        return ThemeColor(red: bottom.red + (top.red - bottom.red) * amount,
                          green: bottom.green + (top.green - bottom.green) * amount,
                          blue: bottom.blue + (top.blue - bottom.blue) * amount)
    }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let color = ThemeColor(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a color: \(string)"))
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// The system colors a theme may name. `glossCurrentLine` and `glossGuide` are the tints Gloss draws today.
    nonisolated static let systemColors: [String: NSColor] = [
        "systemRed": .systemRed, "systemOrange": .systemOrange, "systemYellow": .systemYellow, "systemGreen": .systemGreen,
        "systemMint": .systemMint, "systemTeal": .systemTeal, "systemCyan": .systemCyan, "systemBlue": .systemBlue,
        "systemIndigo": .systemIndigo, "systemPurple": .systemPurple, "systemPink": .systemPink, "systemBrown": .systemBrown,
        "systemGray": .systemGray, "labelColor": .labelColor, "secondaryLabelColor": .secondaryLabelColor,
        "tertiaryLabelColor": .tertiaryLabelColor, "quaternaryLabelColor": .quaternaryLabelColor, "textColor": .textColor,
        "textBackgroundColor": .textBackgroundColor, "selectedTextBackgroundColor": .selectedTextBackgroundColor,
        "windowBackgroundColor": .windowBackgroundColor, "quaternarySystemFill": .quaternarySystemFill,
        "controlAccentColor": .controlAccentColor, "linkColor": .linkColor,
        // The caret's own color (the accent, by default), which NSTextView draws when nothing overrides it.
        "textInsertionPointColor": .textInsertionPointColor,
        "glossCurrentLine": NSColor(name: "glossCurrentLine") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.04)
        },
        "glossGuide": NSColor(name: "glossGuide") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07)
        },
    ]
}
