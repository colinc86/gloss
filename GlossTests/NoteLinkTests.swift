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

    // MARK: Outline

    @Test func piecesOfOneLineMakeOneSpan() {
        // A table row's cells, or inline code in another font, are pieces of one line.
        let pieces = [CGRect(x: 10, y: 100, width: 60, height: 16), CGRect(x: 74, y: 101, width: 40, height: 15), CGRect(x: 120, y: 100, width: 80, height: 17)]
        let lines = NoteOutline.lines(pieces)
        #expect(lines.count == 1)
        #expect(lines.first == NoteOutline.Line(minX: 10, maxX: 200, top: 100, bottom: 117))
    }

    @Test func wrappedLinesAndAParagraphGapMakeOneStaircase() {
        let rects = [CGRect(x: 120, y: 100, width: 280, height: 16),   // starts mid-line
                     CGRect(x: 20, y: 116, width: 400, height: 16),    // wider: wraps to the edge
                     CGRect(x: 20, y: 140, width: 150, height: 16)]    // next paragraph, 8 pt below
        let shapes = NoteOutline.shapes(rects)
        #expect(shapes.count == 1)
        let points = NoteOutline.polygon(shapes[0])
        // A staircase: every edge horizontal or vertical, and every vertex on the outline's boundary, none inside.
        for (index, point) in points.enumerated() {
            let next = points[(index + 1) % points.count]
            #expect(abs(point.x - next.x) < 0.01 || abs(point.y - next.y) < 0.01)
        }
        let path = NoteOutline.path(shapes)
        #expect(path.componentsSeparated().count == 1)
        let padding = NoteOutline.padding
        let bounds = path.boundingBoxOfPath
        #expect(abs(bounds.minX - (20 - padding)) < 0.5 && abs(bounds.maxX - (420 + padding)) < 0.5)
        #expect(abs(bounds.minY - (100 - padding)) < 0.5 && abs(bounds.maxY - (156 + padding)) < 0.5)
        // Inside the note, between its lines, is inside the outline, not on an edge.
        #expect(path.contains(CGPoint(x: 200, y: 116)))
        #expect(!path.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 4).contains(CGPoint(x: 200, y: 116)))
    }

    @Test func linesThatDoNotOverlapSidewaysAreSeparateAndCellsApartStayApart() {
        // A note from the end of one line to the start of the next.
        let rects = [CGRect(x: 300, y: 100, width: 100, height: 16), CGRect(x: 20, y: 116, width: 80, height: 16)]
        #expect(NoteOutline.shapes(rects).count == 2)
        let column = [CGRect(x: 0, y: 0, width: 50, height: 20), CGRect(x: 0, y: 20, width: 50, height: 20)]
        #expect(NoteOutline.shapes(column).count == 1)
    }

    @Test func cornersNeverOutgrowTheirEdges() {
        // A one-point step between two lines.
        let shapes = NoteOutline.shapes([CGRect(x: 20, y: 100, width: 300, height: 16), CGRect(x: 20, y: 116, width: 301, height: 16)])
        let points = NoteOutline.polygon(shapes[0])
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count], point = points[index], next = points[(index + 1) % points.count]
            let shortest = min(hypot(point.x - previous.x, point.y - previous.y), hypot(next.x - point.x, next.y - point.y))
            #expect(NoteOutline.cornerRadius(at: index, in: points) <= shortest / 2 + 0.001)
        }
    }

    // MARK: Departure

    @Test func thePathLeavesFromTheOutlineIntoTheGapNeverThroughTheNote() throws {
        let cases: [[CGRect]] = [
            [CGRect(x: 100, y: 200, width: 120, height: 16)],                                                   // one line, mid-line
            [CGRect(x: 100, y: 200, width: 120, height: 16), CGRect(x: 20, y: 216, width: 300, height: 16)],    // second line wider
            [CGRect(x: 20, y: 200, width: 300, height: 16), CGRect(x: 20, y: 216, width: 90, height: 16)],      // first line wider
            [CGRect(x: 20, y: 200, width: 300, height: 16), CGRect(x: 20, y: 216, width: 300, height: 16)],     // same width
        ]
        for rects in cases {
            let shapes = NoteOutline.shapes(rects)
            let outline = NoteOutline.path(shapes)
            let start = try #require(NoteOutline.departure(shapes))
            // On the outline itself.
            #expect(outline.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 4).contains(start), "\(rects)")
            // Heading right from there, never inside the note.
            for step in stride(from: CGFloat(2), through: 300, by: 2) {
                #expect(!outline.contains(CGPoint(x: start.x + step, y: start.y)) || outline.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 4).contains(CGPoint(x: start.x + step, y: start.y)), "\(rects) at +\(step)")
            }
            // In a gap between lines of text: at a line's lower edge, not through its middle.
            let edges = rects.map(\.maxY) + rects.map(\.minY)
            #expect(edges.contains { abs($0 - start.y) <= NoteOutline.padding + 0.01 })
        }
    }

    // MARK: Connector

    @Test func theCurveRunsOnLevelAndTurnsDownIntoTheRail() {
        let start = CGPoint(x: 220, y: 216)
        for end in [CGPoint(x: 905, y: 506), CGPoint(x: 905, y: 80), CGPoint(x: 905, y: 220)] {
            let connector = NoteConnector(from: start, viewerEdge: 700, to: end)
            let lead = NoteConnector.lead(rise: connector.approach.y - start.y)
            #expect(lead >= 24 && lead <= 72)
            #expect(connector.bend == CGPoint(x: 700 - lead, y: start.y))
            // Smooth where the run meets the curve, and where the curve meets the turn: level at both ends.
            #expect(connector.control1.y == start.y && connector.control1.x > connector.bend.x)
            #expect(connector.control2.y == connector.approach.y && connector.control2.x < connector.approach.x)
            #expect(connector.point(at: 1) == connector.approach)
            // The turn: from heading right just above the rail to heading down at its top, never past it.
            let samples = connector.samples()
            #expect(samples.last == end)
            let last = samples[samples.count - 1], before = samples[samples.count - 2]
            #expect(abs(last.x - before.x) < 0.5 && last.y > before.y)
            #expect(samples.allSatisfy { $0.x <= end.x + 0.01 })
            #expect(samples.suffix(9).allSatisfy { $0.y >= end.y - NoteConnector.turn - 0.01 })
        }
    }

    @Test func aHighlightAtTheViewersEdgeStillCurvesForward() {
        // The highlight runs to the viewer's edge and the rail is a few points past it.
        for room in [CGFloat(30), 12, 4] {
            let start = CGPoint(x: 700, y: 216)
            let connector = NoteConnector(from: start, viewerEdge: 700, to: CGPoint(x: 700 + room, y: 400))
            let samples = connector.samples()
            #expect(samples.first == start)
            for (a, b) in zip(samples, samples.dropFirst()) { #expect(b.x >= a.x - 0.01, "room \(room)") }
        }
    }

    @Test func theRibbonBecomesTheRail() {
        #expect(NoteConnector.width(at: 0, from: 1.5, to: 3) == 1.5)
        #expect(NoteConnector.width(at: 0.69, from: 1.5, to: 3) == 1.5)
        #expect(NoteConnector.width(at: 1, from: 1.5, to: 3) == 3)
        let mid = NoteConnector.width(at: 0.85, from: 1.5, to: 3)
        #expect(mid > 1.5 && mid < 3)
        let connector = NoteConnector(from: CGPoint(x: 220, y: 216), viewerEdge: 700, to: CGPoint(x: 905, y: 506))
        let ribbon = connector.ribbon(width: 1.5, endWidth: 3)
        // It covers its own centre line and reaches into the rail.
        for point in connector.samples() { #expect(ribbon.contains(point)) }
        #expect(ribbon.boundingBoxOfPath.maxY >= 506 + 1.4)
    }
}
