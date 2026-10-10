import Foundation
import SwiftUI
import Testing
@testable import Gloss

/// Which letters of a result the Open Quickly panel lights up.
@MainActor
struct QuickOpenHighlightTests {
    private func lit(_ name: String, _ query: String) -> String {
        let text = QuickOpenSheet.highlighted(name, query: query)
        return text.runs.compactMap { run in run.inlinePresentationIntent == .stronglyEmphasized ? String(text[run.range].characters) : nil }.joined()
    }

    @Test func lightsTheQueryLettersInOrder() {
        #expect(lit("trail.swift", "trs") == "trs")
        #expect(lit("README.md", "rdm") == "RDM", "case-insensitive, first occurrences in order")
        #expect(lit("index.html", "") == "", "no query, nothing lit")
        #expect(lit("pace.py", "zz") == "", "a match through the folder path leaves the name plain")
        #expect(lit("a b.txt", "a b") == "ab", "spaces in the query are ignored")
        #expect(lit("Résumé.md", "resume") == "Résumé", "accents are ignored, as the ranking ignores them")
    }

    @Test func aLocationOrAPathLightsTheName() {
        #expect(QuickOpenModel.nameQuery("trail.swift:42", root: "/p") == "trail.swift")
        #expect(QuickOpenModel.nameQuery("src/main", root: "/p") == "main")
        #expect(QuickOpenModel.nameQuery("/p/src/App.swift:3", root: "/p") == "App.swift")
        #expect(lit("trail.swift", QuickOpenModel.nameQuery("trail.swift:42", root: "/p")) == "trail.swift")
    }
}
