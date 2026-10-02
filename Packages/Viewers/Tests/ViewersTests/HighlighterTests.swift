import Core
import Foundation
import Testing
@testable import Viewers

struct HighlighterTests {
    @Test func grammarsLoadUnderSwiftTest() {
        #expect(GrammarCatalog.supportedLanguageNames().count == 14)
        for name in GrammarCatalog.supportedLanguageNames() {
            #expect(GrammarCatalog.configuration(forLanguage: name) != nil, "\(name) queries should be found")
        }
        #expect(GrammarCatalog.languageName(forPath: "/a/main.rs") == "rust")
        #expect(GrammarCatalog.languageName(forPath: "/a/App.tsx") == "tsx")
        #expect(GrammarCatalog.languageName(forPath: "/a/.zshrc") == "bash")
        #expect(GrammarCatalog.languageName(forPath: "/a/b.swift") == "swift")
        #expect(GrammarCatalog.languageName(forPath: "/a/README.md") == "markdown")
        #expect(GrammarCatalog.languageName(forPath: "/a/x.unknown") == nil)
    }

    @Test func swiftKeywordsAreCaptured() throws {
        let source = "import Foundation\n\nfunc greet(name: String) -> String {\n    return \"hi \\(name)\" // comment\n}\n"
        let highlighter = try #require(Highlighter(languageName: "swift", text: source))
        let funcRange = (source as NSString).range(of: "func")
        let names = highlighter.captures(in: funcRange).map(\.name)
        #expect(names.contains { $0.hasPrefix("keyword") }, "func should be a keyword capture, got \(names)")
        let commentRange = (source as NSString).range(of: "// comment")
        #expect(highlighter.captures(in: commentRange).contains { $0.name.hasPrefix("comment") })
        let stringRange = (source as NSString).range(of: "\"hi ")
        #expect(highlighter.captures(in: stringRange).contains { $0.name.hasPrefix("string") })
    }

    @Test func markdownInjectsInlineAndCode() throws {
        let source = "# Title\n\nSome *emphasis* here.\n\n```swift\nlet x = 1\n```\n"
        let highlighter = try #require(Highlighter(languageName: "markdown", text: source))
        let titleRange = (source as NSString).range(of: "# Title")
        #expect(!highlighter.captures(in: titleRange).isEmpty, "heading should be captured")
        let letRange = (source as NSString).range(of: "let")
        #expect(highlighter.captures(in: letRange).contains { $0.name.hasPrefix("keyword") }, "fenced swift code should be highlighted through injection")
    }

    @Test func incrementalEditMatchesFreshParse() throws {
        var text = "func a() {}\nfunc b() {}\n"
        let highlighter = try #require(Highlighter(languageName: "swift", text: text))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<30 {
            let oldIndex = LineIndex(text)
            let location = Int.random(in: 0...text.utf16.count, using: &generator)
            let length = Int.random(in: 0...max(0, min(4, text.utf16.count - location)), using: &generator)
            let replacement = ["", "x", "func c() {}\n", "\"s\"", "// c\n"].randomElement(using: &generator)!
            let ns = text as NSString
            text = ns.replacingCharacters(in: NSRange(location: location, length: length), with: replacement)
            highlighter.apply(edit: NSRange(location: location, length: length), replacementLength: replacement.utf16.count, newText: text, oldIndex: oldIndex, newIndex: LineIndex(text))
            let fresh = try #require(Highlighter(languageName: "swift", text: text))
            #expect(highlighter.captures.map { "\($0.name)@\($0.range)" } == fresh.captures.map { "\($0.name)@\($0.range)" }, "after editing to: \(text)")
        }
    }

    @Test func structuralExpansionGrows() throws {
        let source = "func a() {\n    let x = (1 + 2)\n}\n"
        let highlighter = try #require(Highlighter(languageName: "swift", text: source))
        let one = (source as NSString).range(of: "1")
        let first = try #require(highlighter.enclosingNodeRange(of: one))
        #expect(first.length > one.length)
        #expect(NSIntersectionRange(first, one) == one)
    }

    @Test func everyGrammarHighlightsSomething() throws {
        let samples: [String: String] = [
            "json": "{\"a\": [1, true, null]}",
            "bash": "if [ -f x ]; then echo \"hi\"; fi",
            "python": "def f(x):\n    return x + 1  # c\n",
            "c": "int main(void) { return 0; }",
            "javascript": "function f(a) { return `x${a}`; }",
            "typescript": "const f = (a: number): string => `${a}`;",
            "tsx": "const A = () => <div className=\"x\">hi</div>;",
            "yaml": "key: value\nlist:\n  - a\n",
            "toml": "[table]\nkey = \"value\"\n",
            "rust": "fn main() { let x: u32 = 1; }",
            "go": "package main\nfunc main() { x := 1 }\n",
        ]
        for (language, source) in samples {
            let highlighter = try #require(Highlighter(languageName: language, text: source), "\(language) grammar missing")
            #expect(!highlighter.captures.isEmpty, "\(language) produced no captures")
        }
    }

    @Test func themeFallsBackToPrefix() {
        #expect(SyntaxTheme.color(forCapture: "function.call.weird") != nil)
        #expect(SyntaxTheme.color(forCapture: "nonexistent") == nil)
    }
}
