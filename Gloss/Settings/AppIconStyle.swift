import AppKit

/// The app icon styles (`docs/icon`): graphite yellow is the bundled icon; the others are pictures the Dock shows while
/// Gloss runs. macOS has no alternate app icons, so Finder, Launchpad and the Dock while Gloss is closed keep the
/// bundled one.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case graphiteYellow = "graphite-yellow", graphiteGreen = "graphite-green", graphiteBlue = "graphite-blue"
    case graphitePink = "graphite-pink", graphitePurple = "graphite-purple", graphiteOrange = "graphite-orange"
    case frostYellow = "frost-yellow", frostGreen = "frost-green", frostBlue = "frost-blue"
    case frostPink = "frost-pink", frostPurple = "frost-purple", frostOrange = "frost-orange"
    case starburst = "fun-starburst", blueprint = "fun-blueprint", rainbow = "fun-rainbow", pixel = "fun-pixel"

    static let bundled = AppIconStyle.graphiteYellow

    enum Family: CaseIterable {
        case graphite, frost, fun

        var title: String {
            switch self {
            case .graphite: "Graphite"
            case .frost: "Frost"
            case .fun: "Fun"
            }
        }
    }

    var id: String { rawValue }

    var family: Family {
        if rawValue.hasPrefix("graphite") { return .graphite }
        if rawValue.hasPrefix("frost") { return .frost }
        return .fun
    }

    /// "Graphite Yellow", "Starburst".
    var title: String {
        let words = rawValue.split(separator: "-").map { $0.capitalized }
        return family == .fun ? words.dropFirst().joined(separator: " ") : words.joined(separator: " ")
    }

    /// The style as a full-bleed picture, for the picker.
    var thumbnail: NSImage? { NSImage(named: "AppIconStyles/\(rawValue)") }

    /// What the Dock shows: nil for the bundled icon (the system draws it, with your Mac's dark, tinted or clear icon
    /// style); otherwise the picture set into the standard icon grid (824 of 1024 points, with the system's shadow).
    var dockImage: NSImage? {
        // Drawn now into a finished bitmap: a drawing-handler image would redraw later on whatever thread draws it.
        guard self != .bundled, let picture = thumbnail,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        picture.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.addRepresentation(bitmap)
        return image
    }

    @MainActor func apply() {
        NSApplication.shared.applicationIconImage = dockImage
    }
}
