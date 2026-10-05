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

    /// Where the path leaves the outline, heading right: on the outline itself, in the gap between the first two
    /// lines of the top shape (below its line when it has one), at the right end of the outline's straight edge
    /// there, so the path continues that edge and never runs through words or the note.
    static func departure(_ shapes: [Shape]) -> CGPoint? {
        guard let shape = shapes.first, let first = shape.lines.first else { return nil }
        let points = polygon(shape)
        if shape.lines.count >= 2 {
            let second = shape.lines[1]
            let y = first.bottom
            let wide = max(first.maxX, second.maxX)
            guard abs(first.maxX - second.maxX) > 0.5, let corner = points.firstIndex(where: { abs($0.x - wide) < 0.01 && abs($0.y - y) < 0.01 }) else {
                return CGPoint(x: wide, y: y)   // no step: straight out of the right side
            }
            return CGPoint(x: wide - cornerRadius(at: corner, in: points), y: y)
        }
        guard let corner = points.firstIndex(where: { abs($0.x - first.maxX) < 0.01 && abs($0.y - first.bottom) < 0.01 }) else { return nil }
        return CGPoint(x: first.maxX - cornerRadius(at: corner, in: points), y: first.bottom)
    }
}

/// The curve from a note's outline to its card: along the gap it left by, an S-curve across that leaves and lands
/// level, then a quarter turn down into the top of the card's colour rail, so it carries on as the rail, like a pipe
/// bending into it, whether the card is above the note or below.
nonisolated struct NoteConnector: Equatable {
    var start: CGPoint
    /// Where the straight run ends and the S-curve begins.
    var bend: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    /// Where the S-curve lands, level, just above and before the rail; the quarter turn starts here.
    var approach: CGPoint
    var end: CGPoint
    var turnRadius: CGFloat

    /// The curve starts this far before the viewer's edge, so the bend reads as one motion across it; further back
    /// the more it has to climb or drop, so a tall sweep leans out instead of standing up straight.
    static func lead(rise: CGFloat) -> CGFloat {
        min(max(abs(rise) * 0.25, 24), 72)
    }
    static let turn: CGFloat = 10

    init(from start: CGPoint, viewerEdge: CGFloat, to end: CGPoint) {
        self.start = start
        self.end = end
        // A highlight reaching the viewer's edge leaves little room before the rail: the turn tightens so the curve
        // still only ever moves forward (the start stays on the outline; further back would be inside the note).
        let room = max(end.x - start.x, 0)
        turnRadius = min(max(room / 3, 2), Self.turn)
        approach = CGPoint(x: end.x - turnRadius, y: end.y - turnRadius)
        let bendX = min(max(start.x, viewerEdge - Self.lead(rise: approach.y - start.y)), approach.x - 20)
        bend = CGPoint(x: min(max(start.x, bendX), approach.x), y: start.y)
        // Long, level handles: generous curvature, the steepest part in the middle of the span.
        let reach = max(approach.x - bend.x, 1) * 0.55
        control1 = CGPoint(x: bend.x + reach, y: start.y)
        control2 = CGPoint(x: approach.x - reach, y: approach.y)
    }

    /// A point on the S-curve, `t` from the bend (0) to the approach (1).
    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * bend.x + b * control1.x + c * control2.x + d * approach.x,
                       y: a * bend.y + b * control1.y + c * control2.y + d * approach.y)
    }

    /// The centre line as points: the straight run, the S-curve, then the quarter turn into the rail.
    func samples(_ count: Int = 32) -> [CGPoint] {
        var points = [start]
        if bend.x - start.x > 0.5 { points.append(bend) }
        for step in 1...count { points.append(point(at: CGFloat(step) / CGFloat(count))) }
        // Centred below the approach: heading right there, heading down at the rail's top.
        let centre = CGPoint(x: approach.x, y: end.y)
        for step in 1...8 {
            let angle = -CGFloat.pi / 2 + CGFloat.pi / 2 * CGFloat(step) / 8
            points.append(CGPoint(x: centre.x + cos(angle) * turnRadius, y: centre.y + sin(angle) * turnRadius))
        }
        points[points.count - 1] = end
        return points
    }

    /// The path as a filled ribbon: `width` wide for most of its length, then easing out to `endWidth` (the rail's
    /// width) over the last 30 %, with a round start and a square end tucked into the rail's rounded top.
    func ribbon(width: CGFloat, endWidth: CGFloat) -> CGPath {
        var points = samples()
        // Into the rail by half its width, so the ribbon covers the capsule's rounded top.
        points.append(CGPoint(x: end.x, y: end.y + endWidth / 2))
        var lengths: [CGFloat] = [0]
        for index in 1..<points.count {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        let total = max(lengths.last ?? 1, 1)
        var left: [CGPoint] = [], right: [CGPoint] = []
        for index in points.indices {
            let previous = points[max(index - 1, 0)], next = points[min(index + 1, points.count - 1)]
            var dx = next.x - previous.x, dy = next.y - previous.y
            let length = max(hypot(dx, dy), 0.0001)
            dx /= length
            dy /= length
            let half = Self.width(at: lengths[index] / total, from: width, to: endWidth) / 2
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

    /// The ribbon's width a fraction `u` of the way along: steady, then a smoothstep to the rail's width.
    static func width(at u: CGFloat, from width: CGFloat, to endWidth: CGFloat) -> CGFloat {
        guard u > 0.7 else { return width }
        let t = min((u - 0.7) / 0.3, 1)
        return width + (endWidth - width) * t * t * (3 - 2 * t)
    }
}
