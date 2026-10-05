import Core
import CoreGraphics
import SwiftUI
import Testing
@testable import Gloss

/// The notes panel follows the page by the note nearest its middle; paths join each highlight to its card.
@MainActor
struct NoteLinkTests {
    let viewport = CGRect(x: 0, y: 100, width: 600, height: 400)   // middle at y = 300

    @Test func focusIsTheNoteTheMiddleRunsThroughThenTheNearest() {
        let above = NoteID.new(), through = NoteID.new(), below = NoteID.new()
        #expect(NoteLinkModel.focus(visible: [
            above: [CGRect(x: 10, y: 120, width: 100, height: 16)],
            through: [CGRect(x: 10, y: 280, width: 100, height: 16), CGRect(x: 10, y: 296, width: 60, height: 16)],
            below: [CGRect(x: 10, y: 320, width: 100, height: 16)],
        ], viewport: viewport) == through)
        #expect(NoteLinkModel.focus(visible: [
            above: [CGRect(x: 10, y: 120, width: 100, height: 16)],
            below: [CGRect(x: 10, y: 310, width: 100, height: 16)],
        ], viewport: viewport) == below)
        #expect(NoteLinkModel.focus(visible: [:], viewport: viewport) == nil)
    }

    @Test func tiesGoToWhatComesFirstOnThePage() {
        let first = NoteID.new(), second = NoteID.new()
        // Both straddle the middle (one line holds two notes): the one starting higher, then the left one, wins.
        #expect(NoteLinkModel.focus(visible: [
            second: [CGRect(x: 10, y: 292, width: 50, height: 16)],
            first: [CGRect(x: 300, y: 290, width: 50, height: 16)],
        ], viewport: viewport) == first)
    }

    @Test func touchingLinesMakeOneOutline() {
        let lines = [CGRect(x: 100, y: 200, width: 300, height: 16), CGRect(x: 20, y: 216, width: 380, height: 16), CGRect(x: 20, y: 232, width: 120, height: 16)]
        let outline = NotePathGeometry.contour(lines)
        #expect(outline.cgPath.componentsSeparated().count == 1)
        let bounds = outline.boundingRect
        let padding = NotePathGeometry.padding
        #expect(abs(bounds.minX - (20 - padding)) < 0.5 && abs(bounds.maxX - (400 + padding)) < 0.5)
        #expect(abs(bounds.minY - (200 - padding)) < 0.5 && abs(bounds.maxY - (248 + padding)) < 0.5)
        // Cells apart on one row stay apart.
        let cells = [CGRect(x: 0, y: 0, width: 50, height: 20), CGRect(x: 100, y: 0, width: 50, height: 20)]
        #expect(NotePathGeometry.contour(cells).cgPath.componentsSeparated().count == 2)
    }

    @Test func connectorLeavesBetweenLinesRunsToTheEdgeAndArrivesAtTheRail() throws {
        let lines = [CGRect(x: 100, y: 200, width: 120, height: 16), CGRect(x: 20, y: 216, width: 300, height: 16)]
        let start = try #require(NotePathGeometry.departure(lines))
        #expect(start == CGPoint(x: 220 + NotePathGeometry.padding, y: 216 + NotePathGeometry.padding))
        let card = CGRect(x: 900, y: 500, width: 320, height: 90)
        let end = NotePathGeometry.railTop(of: card)
        #expect(end.x > card.minX && end.x < card.minX + 10 && end.y > card.minY && end.y < card.minY + 10)
        let path = NotePathGeometry.connector(from: start, to: end, viewerEdge: 700)
        var points: [CGPoint] = []
        path.forEach { element in
            switch element {
            case .move(let to): points.append(to)
            case .line(let to): points.append(to)
            case .curve(let to, _, _): points.append(to)
            default: break
            }
        }
        #expect(points == [start, CGPoint(x: 700, y: start.y), end])
    }
}
