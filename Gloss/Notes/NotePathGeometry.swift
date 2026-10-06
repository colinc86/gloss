import CoreGraphics
import Foundation

/// The outline drawn around a note's highlight, in window coordinates (top-left origin, y down).
///
/// Built, not merged: the highlight's rects become one span per line (cells, inline code and styled runs on a line
/// are pieces of one span), wrapped lines join into one staircase, and its corners are rounded, convex and concave,
/// the way macOS draws a multi-line selection. Nothing of the inside is ever stroked.
nonisolated enum NoteOutline {
    /// Room between the highlight and its outline.
    static let padding: CGFloat = 1.5
    static let radius: CGFloat = 3

    struct Line: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        var top: CGFloat
        var bottom: CGFloat

        var height: CGFloat { bottom - top }
    }

    /// One closed outline: its lines top to bottom, padded, each meeting the next.
    struct Shape: Equatable {
        var lines: [Line]
    }

    /// The highlight's rects as lines: rects overlapping vertically by more than half the smaller one's height
    /// share a line, which spans all of them.
    static func lines(_ rects: [CGRect]) -> [Line] {
        var lines: [Line] = []
        for rect in rects.filter({ $0.height > 0 }).sorted(by: { $0.midY < $1.midY }) {
            if let last = lines.last {
                let overlap = min(last.bottom, rect.maxY) - max(last.top, rect.minY)
                if overlap > min(last.height, rect.height) / 2 {
                    lines[lines.count - 1] = Line(minX: min(last.minX, rect.minX), maxX: max(last.maxX, rect.maxX),
                                                  top: min(last.top, rect.minY), bottom: max(last.bottom, rect.maxY))
                    continue
                }
            }
            lines.append(Line(minX: rect.minX, maxX: rect.maxX, top: rect.minY, bottom: rect.maxY))
        }
        return lines
    }

    /// Lines joined into shapes: the next line joins when the gap is no more than 0.6 of a line (wrapping,
    /// paragraph spacing) and the two overlap side to side; they then meet halfway across the gap. Padded last.
    static func shapes(_ rects: [CGRect]) -> [Shape] {
        var shapes: [[Line]] = []
        for line in lines(rects) {
            if var current = shapes.last, let previous = current.last {
                let gap = line.top - previous.bottom
                let overlapsSideways = line.minX < previous.maxX && line.maxX > previous.minX
                if gap <= 0.6 * min(previous.height, line.height), overlapsSideways {
                    let meet = (previous.bottom + line.top) / 2
                    current[current.count - 1].bottom = meet
                    var joined = line
                    joined.top = meet
                    current.append(joined)
                    shapes[shapes.count - 1] = current
                    continue
                }
            }
            shapes.append([line])
        }
        return shapes.map { lines in
            var padded = lines.map { Line(minX: $0.minX - padding, maxX: $0.maxX + padding, top: $0.top, bottom: $0.bottom) }
            padded[0].top -= padding
            padded[padded.count - 1].bottom += padding
            return Shape(lines: padded)
        }
    }

    /// The staircase around a shape, clockwise on screen from its top-left corner, without repeated or collinear
    /// points.
    static func polygon(_ shape: Shape) -> [CGPoint] {
        let lines = shape.lines
        var points: [CGPoint] = [CGPoint(x: lines[0].minX, y: lines[0].top)]
        for line in lines {
            points.append(CGPoint(x: line.maxX, y: line.top))
            points.append(CGPoint(x: line.maxX, y: line.bottom))
        }
        for line in lines.reversed() {
            points.append(CGPoint(x: line.minX, y: line.bottom))
            points.append(CGPoint(x: line.minX, y: line.top))
        }
        return simplified(points)
    }

    private static func simplified(_ input: [CGPoint]) -> [CGPoint] {
        var points: [CGPoint] = []
        for point in input where points.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.01 }) ?? true {
            points.append(point)
        }
        if points.count > 1, let first = points.first, let last = points.last, hypot(first.x - last.x, first.y - last.y) <= 0.01 {
            points.removeLast()
        }
        // Collinear runs (two lines of the same width) leave a vertex in the middle of a straight edge.
        var changed = true
        while changed, points.count > 3 {
            changed = false
            for index in points.indices {
                let previous = points[(index + points.count - 1) % points.count], point = points[index], next = points[(index + 1) % points.count]
                let cross = (point.x - previous.x) * (next.y - point.y) - (point.y - previous.y) * (next.x - point.x)
                if abs(cross) < 0.01 {
                    points.remove(at: index)
                    changed = true
                    break
                }
            }
        }
        return points
    }

    /// The corner radius at `index`: `radius`, or less where an edge beside the corner is too short for it.
    static func cornerRadius(at index: Int, in points: [CGPoint]) -> CGFloat {
        let previous = points[(index + points.count - 1) % points.count], point = points[index], next = points[(index + 1) % points.count]
        return min(radius, hypot(point.x - previous.x, point.y - previous.y) / 2, hypot(next.x - point.x, next.y - point.y) / 2)
    }

    /// The outlines of all the shapes, every corner rounded.
    static func path(_ shapes: [Shape]) -> CGPath {
        let path = CGMutablePath()
        for shape in shapes {
            let points = polygon(shape)
            guard points.count >= 3 else { continue }
            let last = points[points.count - 1]
            path.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
            for index in points.indices {
                path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % points.count], radius: cornerRadius(at: index, in: points))
            }
            path.closeSubpath()
        }
        return path
    }

    /// Where the path leaves the outline, heading right: the middle of the outline's rightmost edge (on the line that
    /// reaches furthest right, the one nearest the note's middle when several do), so the path starts level and
    /// nothing of the note lies beyond it. With several shapes (cells in columns), the rightmost shape's.
    static func departure(_ shapes: [Shape]) -> CGPoint? {
        guard let shape = shapes.max(by: { ($0.lines.map(\.maxX).max() ?? 0) < ($1.lines.map(\.maxX).max() ?? 0) }),
              let right = shape.lines.map(\.maxX).max(),
              let top = shape.lines.first?.top, let bottom = shape.lines.last?.bottom else { return nil }
        let middle = (top + bottom) / 2
        let widest = shape.lines.filter { abs($0.maxX - right) < 0.5 }
        guard let line = widest.min(by: { abs(($0.top + $0.bottom) / 2 - middle) < abs(($1.top + $1.bottom) / 2 - middle) }) else { return nil }
        return CGPoint(x: right, y: (line.top + line.bottom) / 2)
    }
}

/// The curve from a note's outline to its card, as the user drew it (#11): level out of the outline's right edge,
/// one S across, and level again into the middle of the card's colour rail, meeting the rail at a right angle.
nonisolated struct NoteConnector: Equatable {
    var start: CGPoint
    /// Where the level run ends and the S begins.
    var bend: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    /// The rail's side at its vertical middle.
    var end: CGPoint

    /// The short level stub out of the outline before the S begins: a few points, so the path visibly leaves the
    /// note's edge square, then the S takes the whole rest of the way, gentle however far it has to climb or drop.
    static func stub(room: CGFloat) -> CGFloat {
        min(max(room * 0.08, 8), 40)
    }

    /// `viewerEdge` is kept for the callers; the S no longer waits for it (#11: it spreads across the whole way).
    init(from start: CGPoint, viewerEdge: CGFloat, to end: CGPoint) {
        self.start = start
        self.end = end
        let room = max(end.x - start.x, 0)
        bend = CGPoint(x: start.x + min(Self.stub(room: room), room / 2), y: start.y)
        // Level handles at both ends, half the span long: it leaves level and arrives level, steepest in the middle.
        let reach = max(end.x - bend.x, 1) * 0.5
        control1 = CGPoint(x: bend.x + reach, y: start.y)
        control2 = CGPoint(x: end.x - reach, y: end.y)
    }

    /// A point on the S, `t` from the bend (0) to the rail (1).
    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * bend.x + b * control1.x + c * control2.x + d * end.x,
                       y: a * bend.y + b * control1.y + c * control2.y + d * end.y)
    }

    /// The centre line as points: the level run, then the S.
    func samples(_ count: Int = 40) -> [CGPoint] {
        var points = [start]
        if bend.x - start.x > 0.5 { points.append(bend) }
        for step in 1...count { points.append(point(at: CGFloat(step) / CGFloat(count))) }
        return points
    }

    /// The path as a filled ribbon `width` wide, with a round start and a square end flush against the rail.
    func ribbon(width: CGFloat) -> CGPath {
        let points = samples()
        var left: [CGPoint] = [], right: [CGPoint] = []
        for index in points.indices {
            let previous = points[max(index - 1, 0)], next = points[min(index + 1, points.count - 1)]
            var dx = next.x - previous.x, dy = next.y - previous.y
            let length = max(hypot(dx, dy), 0.0001)
            dx /= length
            dy /= length
            // Both ends are level by construction: square them exactly, so the end sits flush against the rail.
            if index == 0 || index == points.count - 1 { (dx, dy) = (1, 0) }
            let half = width / 2
            left.append(CGPoint(x: points[index].x - dy * half, y: points[index].y + dx * half))
            right.append(CGPoint(x: points[index].x + dy * half, y: points[index].y - dx * half))
        }
        let path = CGMutablePath()
        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        for point in right.reversed() { path.addLine(to: point) }
        // A round start: half a circle behind the first point, from the right edge round to the left one, as part
        // of the same outline (a separate circle would cancel out where it overlaps under some fill rules).
        let heading = atan2(points[1].y - points[0].y, points[1].x - points[0].x)
        for step in 1..<8 {
            let angle = heading - .pi / 2 - .pi * CGFloat(step) / 8
            path.addLine(to: CGPoint(x: start.x + cos(angle) * width / 2, y: start.y + sin(angle) * width / 2))
        }
        path.closeSubpath()
        return path
    }
}
