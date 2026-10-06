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

    @Test func thePathLeavesTheOutlinesRightEdgeLevelNeverThroughTheNote() throws {
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
            // On the outline's rightmost edge.
            #expect(outline.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 4).contains(start), "\(rects)")
            #expect(abs(start.x - (rects.map(\.maxX).max()! + NoteOutline.padding)) < 0.01, "\(rects)")
            // Heading right from there it is never inside the note.
            for step in stride(from: CGFloat(1), through: 300, by: 2) { #expect(!outline.contains(CGPoint(x: start.x + step, y: start.y)), "\(rects) at +\(step)") }
            // At the middle of the line that reaches furthest right (the one nearest the note's middle when tied).
            let widest = rects.filter { $0.maxX == rects.map(\.maxX).max()! }
            #expect(widest.contains { abs($0.midY - start.y) <= 2 }, "\(rects): \(start)")
        }
    }

    // MARK: Connector

    /// The wireframe in #11: level out of the note, one S, level into the middle of the rail, meeting it square.
    @Test func meetsTheRailsMiddleAtARightAngle() {
        let start = CGPoint(x: 220, y: 216)
        for end in [CGPoint(x: 905, y: 506), CGPoint(x: 905, y: 80), CGPoint(x: 905, y: 220), CGPoint(x: 905, y: 900)] {
            let connector = NoteConnector(from: start, viewerEdge: 700, to: end)
            #expect(connector.bend == CGPoint(x: start.x + NoteConnector.stub(room: end.x - start.x), y: start.y), "a short level stub, then the S")
            #expect(connector.control1.y == start.y && connector.control1.x > connector.bend.x, "leaves level")
            #expect(connector.control2.y == end.y && connector.control2.x < end.x, "arrives level")
            let samples = connector.samples()
            #expect(samples.first == start && samples.last == end)
            // Square to the vertical rail: the curve's own direction at its end is level.
            let near = connector.point(at: 0.999)
            #expect(abs(end.y - near.y) < abs(end.x - near.x) * 0.01, "square to the vertical rail")
            for (a, b) in zip(samples, samples.dropFirst()) { #expect(b.x >= a.x - 0.01, "only ever forward") }
            let ys = samples.map(\.y)
            #expect(ys.min()! >= min(start.y, end.y) - 0.01 && ys.max()! <= max(start.y, end.y) + 0.01, "no overshoot")
        }
    }

    @Test func aHighlightAtTheViewersEdgeStillCurvesForward() {
        // The highlight runs to the viewer's edge and the rail is a few points past it.
        for room in [CGFloat(30), 12, 4] {
            let start = CGPoint(x: 700, y: 216)
            let connector = NoteConnector(from: start, viewerEdge: 700, to: CGPoint(x: 700 + room, y: 400))
            let samples = connector.samples()
            #expect(samples.first == start && samples.last == CGPoint(x: 700 + room, y: 400))
            for (a, b) in zip(samples, samples.dropFirst()) { #expect(b.x >= a.x - 0.01, "room \(room)") }
        }
    }

    @Test func theRibbonCoversItsLineAndStopsAtTheRail() {
        let connector = NoteConnector(from: CGPoint(x: 220, y: 216), viewerEdge: 700, to: CGPoint(x: 905, y: 506))
        let ribbon = connector.ribbon(width: 1.5)
        for point in connector.samples().dropFirst().dropLast() { #expect(ribbon.contains(point)) }
        #expect(abs(ribbon.boundingBoxOfPath.maxX - 905) < 0.01, "flush against the rail, never into it")
    }
}
