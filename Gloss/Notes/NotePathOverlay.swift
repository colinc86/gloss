import Core
import SwiftUI
import Viewers

/// Linked with paths on: each note on the page gets an outline traced around its highlight and a curve across to
/// the top of its card's colour rail, all in the note's colour, so highlight, path and rail read as one mark.
/// Drawn over the whole window and never hit-tested; it moves with every scroll of the page or the list.
struct NotePathOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let link = model.noteLink
        if link.drawsPaths, model.showNotesPanel, let session = model.activeSession,
           let viewport = link.viewerViewport, let panel = link.panelViewport, !link.viewerRects.isEmpty {
            let notes = Dictionary(session.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let strong: Set<NoteID> = Set([link.hoveredNoteID, model.notesPanel.selectedNoteID].compactMap { $0 })
            // Read here, not in the drawing closure: observation only tracks what the body reads, and scrolling the
            // list alone changes only the cards.
            let cards = link.cardRects
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                Canvas { context, _ in
                    context.translateBy(x: -origin.x, y: -origin.y)
                    // Strong paths last, so they cross over the others.
                    let ordered = link.viewerRects.sorted { (strong.contains($0.key) ? 1 : 0, $0.key.rawValue) < (strong.contains($1.key) ? 1 : 0, $1.key.rawValue) }
                    for (id, lineRects) in ordered {
                        guard let note = notes[id], let card = cards[id],
                              let start = NotePathGeometry.departure(lineRects) else { continue }
                        let end = NotePathGeometry.railTop(of: card)
                        // A card scrolled out of the list has nothing to arrive at.
                        guard panel.minY...panel.maxY ~= end.y else { continue }
                        let isStrong = strong.contains(id)
                        let settled = note.state == .resolved && note.resolveOutcome != .needsInput
                        let color = Color(nsColor: Theme.color(for: note.color))
                        let style = StrokeStyle(lineWidth: isStrong ? 2.5 : 1.5, lineCap: .round, lineJoin: .round)
                        context.drawLayer { layer in
                            layer.opacity = isStrong ? 1 : (settled ? 0.45 : 0.85)
                            if isStrong { layer.addFilter(.shadow(color: color.opacity(0.5), radius: 4)) }
                            var outline = layer
                            outline.clip(to: Path(viewport))
                            outline.stroke(NotePathGeometry.contour(lineRects), with: .color(color), style: style)
                            layer.stroke(NotePathGeometry.connector(from: start, to: end, viewerEdge: viewport.maxX), with: .color(color), style: style)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }
}

/// The shapes the overlay draws, in window coordinates.
enum NotePathGeometry {
    /// Room left between the highlight and its outline.
    static let padding: CGFloat = 1.5

    /// The outline around a highlight: its line rects, each grown by `padding` so lines that touch (or nearly) join,
    /// merged into one shape with rounded corners. One normalising pass for all of them, not a union per line: this
    /// runs for every visible note on every frame of a scroll.
    static func contour(_ lineRects: [CGRect], radius: CGFloat = 3) -> Path {
        guard !lineRects.isEmpty else { return Path() }
        let pieces = CGMutablePath()
        for rect in lineRects {
            let grown = rect.insetBy(dx: -padding, dy: -padding)
            let corner = min(radius, grown.width / 2, grown.height / 2)
            pieces.addRoundedRect(in: grown, cornerWidth: corner, cornerHeight: corner)
        }
        return Path(lineRects.count == 1 ? pieces : pieces.normalized())
    }

    /// Where the path leaves the highlight: the end of its first line, on the outline's lower edge, so the run to
    /// the side sits between lines instead of through the words.
    static func departure(_ lineRects: [CGRect]) -> CGPoint? {
        guard let first = lineRects.min(by: { $0.minY < $1.minY }) else { return nil }
        return CGPoint(x: first.maxX + padding, y: first.maxY + padding)
    }

    /// The top of a card's colour rail: the card's leading padding in, its top padding down (`NoteCard`).
    static func railTop(of card: CGRect) -> CGPoint {
        CGPoint(x: card.minX + DS.Space.xs + 1.5, y: card.minY + DS.Space.s)
    }

    /// Flat from the highlight to the viewer's edge, then an S-curve across to the rail, leaving and arriving level.
    static func connector(from start: CGPoint, to end: CGPoint, viewerEdge: CGFloat) -> Path {
        let bend = min(max(start.x, viewerEdge), end.x)
        let span = end.x - bend
        var path = Path()
        path.move(to: start)
        path.addLine(to: CGPoint(x: bend, y: start.y))
        path.addCurve(to: end, control1: CGPoint(x: bend + span / 2, y: start.y), control2: CGPoint(x: end.x - span / 2, y: end.y))
        return path
    }
}
