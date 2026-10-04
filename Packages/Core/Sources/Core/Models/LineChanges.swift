import Foundation

/// Which lines of a file a change touched, as a viewer tints them: lines added or rewritten (1-based ranges on the
/// new side) and the lines just after a pure deletion, where a marker says something was taken out.
public struct LineChanges: Sendable, Equatable, Codable {
    public var added: [ClosedRange<Int>]
    public var deletions: [Int]

    public init(added: [ClosedRange<Int>] = [], deletions: [Int] = []) {
        self.added = added
        self.deletions = deletions
    }

    public var isEmpty: Bool { added.isEmpty && deletions.isEmpty }

    /// Every hunk in file order: an added range, or a deletion point as a one-line range, keyed by its first line.
    public var hunks: [ClosedRange<Int>] {
        (added + deletions.map { $0...$0 }).sorted { $0.lowerBound < $1.lowerBound }
    }

    public func contains(line: Int) -> Bool { added.contains { $0.contains(line) } }
}
