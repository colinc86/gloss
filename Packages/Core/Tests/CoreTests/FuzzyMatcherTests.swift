import Testing
@testable import Core

struct FuzzyMatcherTests {
    let paths = [
        "Gloss/App/AppModel.swift",
        "Gloss/App/AppLaunchOptions.swift",
        "Gloss/Notes/NotesPanelModel.swift",
        "Gloss/Notes/NotesPanel.swift",
        "Packages/Core/Sources/Core/Notes/NoteStore.swift",
        "docs/PRODUCT.md",
        "Packages/Viewers/Sources/Viewers/Highlighting/Highlighter.swift",
    ]

    @Test func requiresEveryCharacterInOrder() {
        #expect(FuzzyMatcher.score(query: "apmod", path: "Gloss/App/AppModel.swift") != nil)
        #expect(FuzzyMatcher.score(query: "zzz", path: "Gloss/App/AppModel.swift") == nil)
        #expect(FuzzyMatcher.score(query: "ledom", path: "AppModel.swift") == nil, "order matters")
        #expect(FuzzyMatcher.score(query: "ab", path: "src/xab_a.swift") != nil, "a later word start must not cost the match")
        #expect(FuzzyMatcher.rank("am", in: ["App/AppModel.swift", "lib/xam_a"]).count == 2)
    }

    @Test func ranksFileNameAndWordStartsFirst() {
        #expect(FuzzyMatcher.rank("appmodel", in: paths).first == "Gloss/App/AppModel.swift")
        #expect(FuzzyMatcher.rank("npm", in: paths).first == "Gloss/Notes/NotesPanelModel.swift", "initials of the file name")
        #expect(FuzzyMatcher.rank("product", in: paths).first == "docs/PRODUCT.md", "case-insensitive")
        #expect(FuzzyMatcher.rank("notespanel", in: paths).prefix(2).contains("Gloss/Notes/NotesPanel.swift"))
        #expect(FuzzyMatcher.rank("hl", in: paths).first == "Packages/Viewers/Sources/Viewers/Highlighting/Highlighter.swift")
    }

    @Test func accentsAreIgnoredBothWays() {
        #expect(FuzzyMatcher.rank("resume", in: ["docs/Résumé.md", "docs/other.md"]) == ["docs/Résumé.md"])
        #expect(FuzzyMatcher.rank("crème", in: ["Creme.txt"]) == ["Creme.txt"])
        #expect(FuzzyMatcher.rank("strasse", in: ["Straße.md"]).isEmpty, "a letter that folds to two stays itself")
        #expect(FuzzyMatcher.rank("straße", in: ["Straße.md"]) == ["Straße.md"])
    }

    @Test func anEmptyQueryListsShortPathsFirst() {
        #expect(FuzzyMatcher.rank("  ", in: paths, limit: 1) == ["docs/PRODUCT.md"])
        #expect(FuzzyMatcher.rank("store", in: paths) == ["Packages/Core/Sources/Core/Notes/NoteStore.swift"])
    }

    @Test func countsEveryMatchBeyondTheLimit() {
        let many = (0..<200).map { "src/File\($0).swift" }
        let ranked = FuzzyMatcher.rankCounted("file", in: many, limit: 50)
        #expect(ranked.paths.count == 50 && ranked.total == 200)
        #expect(FuzzyMatcher.rankCounted("", in: many, limit: 50).total == 200)
        #expect(FuzzyMatcher.rankCounted("zzz", in: many).total == 0)
    }

    @Test func handlesALargeList() {
        let many = (0..<50_000).map { "src/module\($0 % 97)/File\($0).swift" }
        let ranked = FuzzyMatcher.rank("file4242", in: many, limit: 5)
        #expect(ranked.first == "src/module71/File4242.swift")
    }

    /// Every path that contains the query as a subsequence is found, whatever the alignment heuristics prefer.
    @Test func neverMissesASubsequence() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab_/.Ac")
        for _ in 0..<3_000 {
            let path = String((0..<Int.random(in: 1...12, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            let query = String((0..<Int.random(in: 1...4, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            let lowerPath = Array(path.lowercased())
            let lowerQuery = query.lowercased().filter { !$0.isWhitespace }
            var index = 0
            for character in lowerPath where index < lowerQuery.count && character == Array(lowerQuery)[index] { index += 1 }
            let isSubsequence = index == lowerQuery.count
            #expect((FuzzyMatcher.score(query: query, path: path) != nil) == isSubsequence, "\(query) in \(path)")
        }
    }
}
