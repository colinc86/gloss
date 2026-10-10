import AppKit
import Core
import Testing
@testable import Viewers

/// A `.diff` or `.patch` file has no grammar: the highlighter colours its lines by their first character, as GitHub
/// does, and keeps them coloured as the file is edited.
@MainActor
struct DiffHighlightTests {
    static let diff = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-old\n+new\n same\n"

    func names(_ highlighter: Highlighter, in source: String) -> [String: String] {
        let text = source as NSString
        return Dictionary(uniqueKeysWithValues: highlighter.captures.map { (text.substring(with: $0.range), $0.name) })
    }

    @Test func linesAreColouredByTheirFirstCharacter() throws {
        #expect(GrammarCatalog.languageName(forPath: "/p/fix.patch") == "diff" && GrammarCatalog.languageName(forPath: "/p/a.diff") == "diff")
        let highlighter = try #require(Highlighter(languageName: "diff", text: Self.diff))
        #expect(names(highlighter, in: Self.diff) == ["diff --git a/x b/x": "diff.header", "index 1..2 100644": "diff.header", "--- a/x": "diff.header",
                                       "+++ b/x": "diff.header", "@@ -1,2 +1,2 @@": "diff.hunk", "-old": "diff.minus", "+new": "diff.plus"])
        #expect(SyntaxTheme.color(forCapture: "diff.plus") == .systemGreen && SyntaxTheme.color(forCapture: "diff.minus") == .systemRed)
        #expect(highlighter.enclosingNodeRange(of: NSRange(location: 40, length: 1)) == nil, "no syntax tree to expand through")
        #expect(highlighter.backgroundRebuild() == nil)
    }

    @Test func editsKeepTheColoursRight() throws {
        let controller = TextEditorController(text: Self.diff, languageName: "diff")
        let highlighter = try #require(controller.highlighter)
        let edited = Self.diff.replacingOccurrences(of: " same\n", with: "-same\n")
        let oldIndex = LineIndex(Self.diff), newIndex = LineIndex(edited)
        let at = (Self.diff as NSString).range(of: " same").location
        highlighter.apply(edit: NSRange(location: at, length: 1), replacementLength: 1, newText: edited, oldIndex: oldIndex, newIndex: newIndex)
        #expect(names(highlighter, in: edited)["-same"] == "diff.minus")
        highlighter.replaceAll(with: "+only\n")
        #expect(names(highlighter, in: "+only\n") == ["+only": "diff.plus"])
    }
}
