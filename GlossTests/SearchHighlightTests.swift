import Foundation
import SwiftUI
import Testing
@testable import Gloss

/// What a search result row lights up.
@MainActor
struct SearchHighlightTests {
    private func lit(_ line: String, _ pattern: String, regex: Bool = false) -> [String] {
        let text = SearchHitRow.highlighted(line, pattern: (pattern, regex))
        return text.runs.compactMap { run in run.inlinePresentationIntent == .stronglyEmphasized ? String(text[run.range].characters) : nil }
    }

    @Test func plainQueriesUseSmartCaseAndFindEveryOccurrence() {
        #expect(lit("print(Route.total, route)", "route") == ["Route", "route"], "lowercase matches any case")
        #expect(lit("print(Route.total, route)", "Route") == ["Route"], "a capital makes it exact")
        #expect(lit("    enum Route {", "route") == ["Route"], "indentation is trimmed without shifting the highlight")
        #expect(lit("nothing here", "route").isEmpty)
    }

    @Test func regexQueriesHighlightTheirMatches() {
        #expect(lit("let a = 12, b = 345", "[0-9]+", regex: true) == ["12", "345"])
        #expect(lit("abc", "(", regex: true).isEmpty, "an invalid pattern highlights nothing instead of failing")
    }

    @Test func codeKeepsItsColoursAndTheMatchStaysOnTop() {
        let line = SearchHitRow.highlighted("    let climb: Int", pattern: ("climb", false), language: "swift")
        #expect(String(line.characters) == "let climb: Int", "same text, indentation dropped")
        let coloured = line.runs.filter { $0.foregroundColor != nil && $0.backgroundColor == nil }
        #expect(!coloured.isEmpty, "keywords and types keep the editor's colours")
        let match = line.runs.first { $0.backgroundColor != nil }
        #expect(match.map { String(line[$0.range].characters) } == "climb")
    }

    /// A match far along a long line (minified code) is shown, with "…" where the line is cut.
    @Test func aLongLineIsCutAroundItsFirstMatch() {
        let line = String(repeating: "a,", count: 5_000) + "needle" + String(repeating: ",b", count: 5_000)
        let text = SearchHitRow.highlighted(line, pattern: ("needle", false), language: "javascript")
        let shown = String(text.characters)
        #expect(shown.hasPrefix("…") && shown.hasSuffix("…"))
        #expect(shown.count <= SearchHitRow.excerptLength + 2)
        #expect(lit(line, "needle") == ["needle"])
        #expect(shown.distance(from: shown.startIndex, to: shown.range(of: "needle")!.lowerBound) == SearchHitRow.leadIn + 1, "a little context before it")
        let end = String(repeating: "x", count: 1_000) + "tail"
        #expect(String(SearchHitRow.highlighted(end, pattern: ("tail", false)).characters).hasSuffix("xtail"), "a match at the end ends the stretch, uncut")
        #expect(String(SearchHitRow.highlighted("short needle", pattern: ("needle", false)).characters) == "short needle", "a short line is whole")
    }

    @Test func anExcerptNeverSplitsACharacter() {
        let line = String(repeating: "👍🏽", count: 400)
        let shown = SearchHitRow.excerpt(of: line, around: 301)
        #expect(shown.dropFirst().dropLast().allSatisfy { $0 == "👍🏽" })
    }
}
