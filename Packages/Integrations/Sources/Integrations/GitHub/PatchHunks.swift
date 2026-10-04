import Core
import Foundation

/// Reads GitHub's per-file `patch` (a unified diff without the file header) into the lines a viewer tints.
public enum PatchHunks {
    public static func parse(_ patch: String) -> LineChanges {
        var added: [Int] = []
        var deletions: [Int] = []
        var newLine = 0
        var deletedRun = 0
        var addedAfterDeletion = false
        func closeDeletion() {
            if deletedRun > 0, !addedAfterDeletion { deletions.append(newLine) }
            deletedRun = 0
            addedAfterDeletion = false
        }
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                closeDeletion()
                // @@ -a,b +c,d @@
                guard let plus = line.range(of: "+") else { continue }
                let after = line[plus.upperBound...]
                let start = after.prefix { $0.isNumber }
                newLine = Int(start) ?? 0
                continue
            }
            guard let first = line.first else { continue }
            switch first {
            case "+":
                if deletedRun > 0 { addedAfterDeletion = true }
                added.append(newLine)
                newLine += 1
            case "-":
                if addedAfterDeletion { closeDeletion() }
                deletedRun += 1
            case "\\":
                continue   // "\ No newline at end of file"
            default:
                closeDeletion()
                newLine += 1
            }
        }
        closeDeletion()
        return LineChanges(added: ranges(of: added), deletions: deletions)
    }

    /// Consecutive lines collapsed into ranges.
    static func ranges(of lines: [Int]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for line in lines {
            if let last = ranges.last, last.upperBound + 1 == line {
                ranges[ranges.count - 1] = last.lowerBound...line
            } else {
                ranges.append(line...line)
            }
        }
        return ranges
    }
}
