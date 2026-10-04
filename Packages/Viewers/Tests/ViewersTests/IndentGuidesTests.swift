import Core
import Foundation
import Testing
@testable import Viewers

struct IndentGuidesTests {
    private let swift = """
    struct Route {
        static let legs = [
            1,

            2,
        ]

        func total() {}
    }
    """

    @Test func eachLineSitsInsideItsIndentLevels() {
        let guides = IndentGuides(text: swift)
        #expect(guides.unit == 4)
        #expect(guides.levels == [0, 1, 2, 2, 2, 1, 1, 1, 0])
    }

    @Test func blankLinesTakeTheShallowerNeighbourSoGuidesRunThroughGaps() {
        let guides = IndentGuides(text: "a\n    b\n\n    c\n\nd")
        #expect(guides.levels == [0, 1, 1, 1, 0, 0])
    }

    @Test func theUnitComesFromTheFileAndTabsCountAsOneStep() {
        #expect(IndentGuides(text: "a:\n  b:\n    c: 1").levels == [0, 1, 2])
        #expect(IndentGuides(text: "a:\n  b:\n    c: 1").unit == 2)
        #expect(IndentGuides(text: "{\n\tx\n\t\ty\n}").levels == [0, 1, 2, 0])
    }

    @Test func linesMapFromOffsetsIncludingAnEmptyLastLine() {
        let guides = IndentGuides(text: "ab\ncd\n")
        #expect(guides.lineStarts == [0, 3, 6])
        #expect(guides.line(at: 0) == 0)
        #expect(guides.line(at: 4) == 1)
        #expect(guides.line(at: 6) == 2)
    }

    @Test func theActiveGuideIsTheCaretsBlock() {
        let guides = IndentGuides(text: swift)
        // Inside the array literal: the second level, across its elements and the gap.
        let inner = guides.activeGuide(aroundLine: 3)
        #expect(inner?.level == 1)
        #expect(inner?.lines == 2...4)
        // On `struct Route {`, the block it opens.
        let opened = guides.activeGuide(aroundLine: 0)
        #expect(opened?.level == 0)
        #expect(opened?.lines == 1...7)
        // On the closing brace, at the top level, nothing.
        #expect(guides.activeGuide(aroundLine: 8) == nil)
    }
}

struct IndentGuidesWindowTests {
    private let text = (0..<45_000).map { i in String(repeating: "    ", count: i % 4) + "line \(i)" + (i % 7 == 0 ? "\n" : "") }.joined(separator: "\n")

    @Test func aWindowMatchesTheWholeFileForItsLines() {
        let index = LineIndex(text)
        let whole = IndentGuides(text: text)
        let window = IndentGuides(window: 20_001...20_400, text: text as NSString, lineIndex: index)
        // Away from the window's edges (blank-line fill looks at neighbours), every level agrees.
        #expect(Array(window.levels[10..<390]) == Array(whole.levels[20_010..<20_390]))
        #expect(window.covers(index.contentRange(ofLine: 20_200).location))
        #expect(!window.covers(index.contentRange(ofLine: 30_000).location))
    }

    @Test func aWindowCostsAFractionOfTheWholeFile() {
        let index = LineIndex(text)
        let ns = text as NSString
        let clock = ContinuousClock()
        let whole = clock.measure { _ = IndentGuides(window: 1...index.lineCount, text: ns, lineIndex: index) }
        let window = clock.measure { _ = IndentGuides(window: 20_001...20_450, text: ns, lineIndex: index) }
        print("GUIDES whole \(whole) window \(window)")
        #expect(window * 20 < whole)
    }
}
