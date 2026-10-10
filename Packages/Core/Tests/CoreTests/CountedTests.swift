import Testing
@testable import Core

struct CountedTests {
    @Test func aCountAgreesWithItsNoun() {
        #expect(1.counted("row") == "1 row")
        #expect(0.counted("row") == "0 rows")
        #expect(3.counted("file") == "3 files")
        #expect(2.counted("match", plural: "matches") == "2 matches")
        #expect(100_000.counted("row") == "\(100_000.formatted()) rows", "grouped as the region writes numbers")
    }
}

extension CountedTests {
    @Test func anAgentHearsHowManyLinesTheFileHas() {
        #expect(RelocationError.lineOutOfRange(line: 3, lineCount: 1).errorDescription == "Line 3 is outside the file, which has 1 line.")
        #expect(RelocationError.lineOutOfRange(line: 9, lineCount: 7).errorDescription == "Line 9 is outside the file, which has 7 lines.")
    }
}
