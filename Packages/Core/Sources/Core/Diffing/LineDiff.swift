import Foundation

// swiftlint:disable identifier_name cyclomatic_complexity function_body_length
// Myers' algorithm reads best with its paper's names (n, m, v, d, k).

public enum DiffEdit: Equatable, Sendable {
    case equal(old: Int, new: Int)
    case delete(old: Int)
    case insert(new: Int)
}

/// A changed region: `old[oldRange]` became `new[newRange]`.
public struct DiffHunk: Equatable, Sendable {
    public var oldRange: Range<Int>
    public var newRange: Range<Int>

    public init(oldRange: Range<Int>, newRange: Range<Int>) {
        self.oldRange = oldRange
        self.newRange = newRange
    }
}

/// Myers' O(ND) line diff. Lines both sides begin and end with are matched first, so only the changed middle is
/// searched. Past `maxEditDistance` edits in that middle it gives up and reports the middle as one hunk. The search
/// keeps, for each step d, only the 2d + 1 diagonals backtracking reads, so its memory grows as the square of the
/// edits made (about 64 MB at the limit), never with the files' length.
public enum LineDiff {
    public static let maxEditDistance = 4_000

    public static func diff(old: [String], new: [String]) -> [DiffEdit] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let head = (0..<prefix).map { DiffEdit.equal(old: $0, new: $0) }
        let tail = (0..<suffix).map { DiffEdit.equal(old: old.count - suffix + $0, new: new.count - suffix + $0) }
        let middle = myers(old: Array(old[prefix..<(old.count - suffix)]), new: Array(new[prefix..<(new.count - suffix)])).map { edit -> DiffEdit in
            switch edit {
            case .equal(let o, let n): .equal(old: o + prefix, new: n + prefix)
            case .delete(let o): .delete(old: o + prefix)
            case .insert(let n): .insert(new: n + prefix)
            }
        }
        return head + middle + tail
    }

    static func myers(old: [String], new: [String]) -> [DiffEdit] {
        let n = old.count
        let m = new.count
        if n == 0 { return (0..<m).map { .insert(new: $0) } }
        if m == 0 { return (0..<n).map { .delete(old: $0) } }
        let max = min(n + m, maxEditDistance)
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 2)
        // trace[d] holds v for diagonals -d...d as they stood before step d.
        var trace: [[Int32]] = []
        var found = false
        search: for d in 0...max {
            trace.append(v[(offset - d)...(offset + d)].map { Int32($0) })
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, old[x] == new[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    found = true
                    break search
                }
                k += 2
            }
        }
        guard found else {
            return (0..<n).map { .delete(old: $0) } + (0..<m).map { .insert(new: $0) }
        }
        // Backtrack.
        var edits: [DiffEdit] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            guard d > 0 else {
                // Step 0 is the run of equal lines from the start.
                while x > 0, y > 0 {
                    x -= 1
                    y -= 1
                    edits.append(.equal(old: x, new: y))
                }
                break
            }
            let row = trace[d]
            func at(_ k: Int) -> Int { Int(row[k + d]) }
            let k = x - y
            let previousK = k == -d || (k != d && at(k - 1) < at(k + 1)) ? k + 1 : k - 1
            let previousX = at(previousK)
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                x -= 1
                y -= 1
                edits.append(.equal(old: x, new: y))
            }
            if x == previousX {
                y -= 1
                edits.append(.insert(new: y))
            } else {
                x -= 1
                edits.append(.delete(old: x))
            }
        }
        return edits.reversed()
    }

    /// Changed regions, in order.
    public static func hunks(old: [String], new: [String]) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var oldPos = 0
        var newPos = 0
        var current: DiffHunk?
        for edit in diff(old: old, new: new) {
            switch edit {
            case .equal(let o, let nw):
                if let hunk = current {
                    hunks.append(hunk)
                    current = nil
                }
                oldPos = o + 1
                newPos = nw + 1
            case .delete(let o):
                if current == nil { current = DiffHunk(oldRange: o..<o, newRange: newPos..<newPos) }
                current!.oldRange = current!.oldRange.lowerBound..<(o + 1)
                oldPos = o + 1
            case .insert(let nw):
                if current == nil { current = DiffHunk(oldRange: oldPos..<oldPos, newRange: nw..<nw) }
                current!.newRange = current!.newRange.lowerBound..<(nw + 1)
                newPos = nw + 1
            }
        }
        if let hunk = current { hunks.append(hunk) }
        return hunks
    }
}

/// Result of merging two edits of the same base.
public enum MergeRegion: Equatable, Sendable {
    case unchanged([String])
    case mine([String])
    case theirs([String])
    /// Both sides made the same change.
    case both([String])
    case conflict(mine: [String], theirs: [String])

    public var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }
}

/// diff3-style merge of `mine` (the editor) and `theirs` (the disk) against `base` (what was opened).
public enum ThreeWayMerge {
    public static func merge(base: [String], mine: [String], theirs: [String]) -> [MergeRegion] {
        mergeWithOriginals(base: base, mine: mine, theirs: theirs).map(\.region)
    }

    /// `merge`, each region with the lines of `base` it stands in for (the same lines for `.unchanged`), so a
    /// change that only deletes can show what it deleted.
    public static func mergeWithOriginals(base: [String], mine: [String], theirs: [String]) -> [(region: MergeRegion, original: [String])] {
        let mineHunks = LineDiff.hunks(old: base, new: mine)
        let theirsHunks = LineDiff.hunks(old: base, new: theirs)
        var regions: [(region: MergeRegion, original: [String])] = []
        var pos = 0
        var mi = 0
        var ti = 0
        while mi < mineHunks.count || ti < theirsHunks.count {
            let nextMine = mi < mineHunks.count ? mineHunks[mi] : nil
            let nextTheirs = ti < theirsHunks.count ? theirsHunks[ti] : nil
            let start: Int
            switch (nextMine, nextTheirs) {
            case let (m?, t?): start = min(m.oldRange.lowerBound, t.oldRange.lowerBound)
            case let (m?, nil): start = m.oldRange.lowerBound
            case let (nil, t?): start = t.oldRange.lowerBound
            default: start = base.count
            }
            if start > pos { regions.append((.unchanged(Array(base[pos..<start])), Array(base[pos..<start]))) }

            // Grow the group while hunks from either side overlap the current base span.
            var end = start
            var groupMine: [DiffHunk] = []
            var groupTheirs: [DiffHunk] = []
            var grew = true
            while grew {
                grew = false
                if mi < mineHunks.count, overlaps(mineHunks[mi].oldRange, start..<end, allowTouchingEmpty: groupMine.isEmpty && groupTheirs.isEmpty) {
                    end = max(end, mineHunks[mi].oldRange.upperBound)
                    groupMine.append(mineHunks[mi])
                    mi += 1
                    grew = true
                }
                if ti < theirsHunks.count, overlaps(theirsHunks[ti].oldRange, start..<end, allowTouchingEmpty: groupMine.isEmpty && groupTheirs.isEmpty) {
                    end = max(end, theirsHunks[ti].oldRange.upperBound)
                    groupTheirs.append(theirsHunks[ti])
                    ti += 1
                    grew = true
                }
            }
            let mineLines = apply(groupMine, to: base, span: start..<end, side: mine)
            let theirsLines = apply(groupTheirs, to: base, span: start..<end, side: theirs)
            let original = Array(base[start..<end])
            switch (groupMine.isEmpty, groupTheirs.isEmpty) {
            case (false, true): regions.append((.mine(mineLines), original))
            case (true, false): regions.append((.theirs(theirsLines), original))
            case (false, false): regions.append((mineLines == theirsLines ? .both(mineLines) : .conflict(mine: mineLines, theirs: theirsLines), original))
            case (true, true): break
            }
            pos = end
        }
        if pos < base.count { regions.append((.unchanged(Array(base[pos...])), Array(base[pos...]))) }
        return regions
    }

    /// The merged text when there are no conflicts, else nil.
    public static func resolve(_ regions: [MergeRegion]) -> [String]? {
        var lines: [String] = []
        for region in regions {
            switch region {
            case .unchanged(let l), .mine(let l), .theirs(let l), .both(let l): lines.append(contentsOf: l)
            case .conflict: return nil
            }
        }
        return lines
    }

    private static func overlaps(_ hunk: Range<Int>, _ span: Range<Int>, allowTouchingEmpty: Bool) -> Bool {
        if allowTouchingEmpty { return hunk.lowerBound <= span.upperBound }
        if hunk.isEmpty { return hunk.lowerBound < span.upperBound || (hunk.lowerBound == span.upperBound && span.isEmpty) }
        if span.isEmpty { return hunk.lowerBound <= span.lowerBound && span.lowerBound < hunk.upperBound }
        return hunk.lowerBound < span.upperBound && span.lowerBound < hunk.upperBound
    }

    /// Lines on one side for `span` of the base: base lines with that side's hunks applied.
    private static func apply(_ hunks: [DiffHunk], to base: [String], span: Range<Int>, side: [String]) -> [String] {
        var lines: [String] = []
        var cursor = span.lowerBound
        for hunk in hunks {
            if hunk.oldRange.lowerBound > cursor { lines.append(contentsOf: base[cursor..<hunk.oldRange.lowerBound]) }
            lines.append(contentsOf: side[hunk.newRange])
            cursor = max(cursor, hunk.oldRange.upperBound)
        }
        if cursor < span.upperBound { lines.append(contentsOf: base[cursor..<span.upperBound]) }
        return lines
    }
}
