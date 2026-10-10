import Testing
@testable import Core

struct CountedTests {
    @Test func aCountAgreesWithItsNoun() {
        #expect(1.counted("row") == "1 row")
        #expect(0.counted("row") == "0 rows")
        #expect(3.counted("file") == "3 files")
        #expect(2.counted("match", plural: "matches") == "2 matches")
    }
}
