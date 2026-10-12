import Foundation
import Observation

/// Settings › General › Layout: whether the window takes the compact layout.
nonisolated enum LayoutMode: String, CaseIterable, Identifiable {
    case automatic, compact, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .compact: "Compact"
        case .full: "Full"
        }
    }
}

/// The compact layout (2026-10-11): below a width the three panes don't fit, the explorer slides over the document
/// on request and the notes become a tray under it, so Gloss sits beside a terminal. Nothing else changes: the
/// document, the reading position, the selection and the filters are the same in either layout.
@MainActor
@Observable
final class LayoutModel {
    /// How far past the threshold the window must widen to leave compact, so a window resting at the edge doesn't flap.
    nonisolated static let hysteresis: Double = 40

    /// The window's content width, as last measured; 0 until it is.
    private(set) var width: Double = 0
    /// The window's content height, for the most the notes tray may take.
    var height: Double = 0
    private(set) var isCompact = false
    /// The explorer, slid over the document while compact.
    var isExplorerShown = false

    /// Whether the window is compact for `mode` at `width`, given whether it was: Automatic goes compact below the
    /// threshold and back to full only once `hysteresis` past it.
    nonisolated static func compact(mode: LayoutMode, width: Double, threshold: Double, wasCompact: Bool) -> Bool {
        switch mode {
        case .compact: return true
        case .full: return false
        case .automatic:
            guard width > 0 else { return wasCompact }
            return wasCompact ? width < threshold + hysteresis : width < threshold
        }
    }

    func update(width: Double? = nil, mode: LayoutMode, threshold: Double) {
        if let width { self.width = width }
        let compact = Self.compact(mode: mode, width: self.width, threshold: threshold, wasCompact: isCompact)
        guard compact != isCompact else { return }
        isCompact = compact
        if !compact { isExplorerShown = false }
    }
}
