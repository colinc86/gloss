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
        var generator = SeededGenerator(seed: 42)
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

    /// An unterminated block comment typed mid-file comments out what follows, but what comes before keeps its
    /// colours (seen in the app: every line went plain).
    @Test func anOpenBlockCommentKeepsTheLinesAbove() throws {
        var text = "import Foundation\n\nfunc a() {\n    let x = 1\n}\n\nfunc b(y: Int) {\n    print(y)\n}\n"
        let highlighter = try #require(Highlighter(languageName: "swift", text: text))
        let before = highlighter.captures.count
        let firstFunc = (text as NSString).range(of: "func a")
        #expect(highlighter.captures(in: firstFunc).contains { $0.name.hasPrefix("keyword") })
        let location = (text as NSString).range(of: "func b").location
        let oldIndex = LineIndex(text)
        text = (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "/*")
        highlighter.apply(edit: NSRange(location: location, length: 0), replacementLength: 2, newText: text, oldIndex: oldIndex, newIndex: LineIndex(text))
        let fresh = try #require(Highlighter(languageName: "swift", text: text))
        #expect(highlighter.captures.count == fresh.captures.count && before > 0)
        #expect(!highlighter.captures.isEmpty, "the query must not fail on an unterminated comment")
        #expect(highlighter.captures(in: firstFunc).contains { $0.name.hasPrefix("keyword") }, "lines above the comment keep their keywords")
    }

    /// Re-highlighting re-queries only what an edit invalidated; on a 4,000-line file a keystroke took 340 ms in a
    /// debug build when the whole document was queried each time (11 ms after).
    @Test func aKeystrokeInALargeFileStaysCheap() throws {
        let block = "func f(_ x: Int) -> Int {\n    let y = x * 2 // double\n    return y + \"s\".count\n}\n"
        var text = String(repeating: block, count: 1_000)
        let highlighter = try #require(Highlighter(languageName: "swift", text: text))
        var slowest = 0.0
        for i in 0..<5 {
            let oldIndex = LineIndex(text)
            let location = text.utf16.count / 2 + i
            text = (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "x")
            let started = Date()
            highlighter.apply(edit: NSRange(location: location, length: 0), replacementLength: 1, newText: text, oldIndex: oldIndex, newIndex: LineIndex(text))
            slowest = max(slowest, Date().timeIntervalSince(started))
        }
        #expect(slowest < 0.1, "slowest keystroke \(slowest)s")
    }

    /// Harsher than the random edits above: comment and string delimiters that change the meaning of far-away
    /// text, multi-line inserts and deletes, and markdown with an injected code block.
    static let samples: [String: String] = [
        "swift": "import Foundation\n\n/// Docs\nfunc a() -> String {\n    let s = \"x\" // c\n    return s\n}\n\nstruct B { var c = 1 }\n",
        "markdown": "# Title\n\nSome *text* and `code`.\n\n```swift\nlet x = 1\nfunc f() {}\n```\n\n- item\n",
        "python": "import os\n\ndef a(x):\n    \"\"\"Doc.\"\"\"\n    s = 'y'  # c\n    return s + str(x)\n\nclass B:\n    c = 1\n",
        "javascript": "import x from 'y';\n\n/** Docs */\nfunction a() {\n  const s = `t ${x}`; // c\n  return s;\n}\n",
        "json": "{\n  \"a\": [1, true, null],\n  \"b\": {\"c\": \"d\"}\n}\n",
        "rust": "fn main() {\n    let v = vec![1, 2];\n    println!(\"{} {}\", v[0], \"s\"); // c\n}\nmacro_rules! m { ($x:expr) => { $x } }\n",
    ]

    @Test(arguments: ["swift", "markdown", "python", "javascript", "json", "rust"])
    func incrementalEditsMatchAFreshParse(language: String) throws {
        var text = try #require(Self.samples[language])
        let highlighter = try #require(Highlighter(languageName: language, text: text))
        var generator = SeededGenerator(seed: UInt64(language.utf8.reduce(0) { $0 &* 31 &+ UInt64($1) } % 1_000))
        let pieces = ["", "x", "/*", "*/", "\"", "'", "\n", "// ", "# ", "func g() {\n}\n", "```\n", "`", "*", "let y = \"q\"\n", "\"\"\"", "{", "}", "[", ",", "!", "println!(\"x\")", "---\n", "<b>", "\n\n"]
        for step in 0..<150 {
            let oldIndex = LineIndex(text)
            let count = text.utf16.count
            let location = Int.random(in: 0...count, using: &generator)
            let length = Int.random(in: 0...max(0, min(12, count - location)), using: &generator)
            let replacement = pieces.randomElement(using: &generator)!
            text = (text as NSString).replacingCharacters(in: NSRange(location: location, length: length), with: replacement)
            highlighter.apply(edit: NSRange(location: location, length: length), replacementLength: replacement.utf16.count, newText: text, oldIndex: oldIndex, newIndex: LineIndex(text))
            // What the user ends up seeing: embedded languages are corrected by the rebuild that follows a pause.
            if let job = highlighter.backgroundRebuild(), let rebuild = job() { highlighter.adopt(rebuild) }
            let fresh = try #require(Highlighter(languageName: language, text: text))
            let incremental = highlighter.captures.map { "\($0.name)@\($0.range)" }
            let expected = fresh.captures.map { "\($0.name)@\($0.range)" }
            #expect(incremental == expected, "step \(step), after editing to: \(text)")
            if incremental != expected {
                print("DIFF edit loc \(location) len \(length) repl \(replacement.debugDescription)")
                print("DIFF only incremental: \(Set(incremental).subtracting(expected).sorted())")
                print("DIFF only fresh: \(Set(expected).subtracting(incremental).sorted())")
                print("DIFF counts \(incremental.count) vs \(expected.count)")
                if let i = zip(incremental, expected).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                    print("DIFF first mismatch at \(i): inc \(incremental[max(0,i-2)..<min(incremental.count,i+3)]) fresh \(expected[max(0,i-2)..<min(expected.count,i+3)])")
                }
                print("DIFF text: \(text.debugDescription)")
                break
            }
        }
    }

    /// A long capture that starts before the queried lines (a code block's background) must be found even though
    /// shorter captures between them end earlier.
    @Test func lookupFindsLongCapturesThatStartEarlier() throws {
        let text = "# T\n\n```swift\nlet x = 1\nlet y = 2\nlet z = 3\n```\n"
        let highlighter = try #require(Highlighter(languageName: "markdown", text: text))
        let index = LineIndex(text)
        for line in 4...7 {
            let range = index.contentRange(ofLine: line)
            let scan = highlighter.captures.filter { NSIntersectionRange($0.range, range).length > 0 }
            #expect(Set(highlighter.captures(in: range)) == Set(scan), "line \(line)")
        }
    }

    /// Large documents with embedded languages keep keystrokes cheap: embedded highlighting is off above
    /// `embeddedLanguageLimit` (the reviewer measured 500 ms per keystroke on 115 KB of markdown before).
    @Test(arguments: ["markdown", "rust"])
    func embeddedLanguagesKeepKeystrokesCheap(language: String) throws {
        let block = language == "markdown"
            ? "## Section\n\nSome *emphasis*, `code`, and a [link](https://x).\n\n```swift\nlet x = 1\n```\n\n"
            : "fn f(x: i32) -> i32 {\n    println!(\"{}\", x);\n    let v = vec![x, 2];\n    v[0]\n}\n"
        var text = String(repeating: block, count: language == "markdown" ? 1_400 : 1_200)
        let highlighter = try #require(Highlighter(languageName: language, text: text))
        var slowest = 0.0
        for i in 0..<5 {
            let oldIndex = LineIndex(text)
            let location = text.utf16.count / 2 + i
            text = (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "x")
            let started = Date()
            highlighter.apply(edit: NSRange(location: location, length: 0), replacementLength: 1, newText: text, oldIndex: oldIndex, newIndex: LineIndex(text))
            slowest = max(slowest, Date().timeIntervalSince(started))
        }
        // These edits put an `x` before `fn`, a syntax error. Tree-sitter's error recovery then re-parses far more
        // than the edited line (about 250 ms for this Rust text with unoptimised debug C; 7 ms for a valid edit, and
        // the bare parser's incremental re-parse is 3 ms), so debug builds get a looser budget.
        // The debug budget also allows for a machine busy with a parallel build (0.84 s was measured then).
        #if DEBUG
        let budget = 1.5
        #else
        let budget = 0.15
        #endif
        #expect(slowest < budget, "slowest keystroke \(slowest)s on \(text.utf16.count) units")
        #expect(!highlighter.mayBeStale, "no embedded languages, so nothing to rebuild")
    }

    @Test func smallMarkdownStillHighlightsInlineAndCodeBlocks() throws {
        let text = "# T\n\nSome *emphasis*.\n\n```swift\nlet x = 1\n```\n"
        let highlighter = try #require(Highlighter(languageName: "markdown", text: text))
        #expect(highlighter.captures(in: (text as NSString).range(of: "*emphasis*")).contains { $0.name.contains("emphasis") })
        #expect(highlighter.captures(in: (text as NSString).range(of: "let")).contains { $0.name.hasPrefix("keyword") })
    }

    /// A background rebuild started before a later edit is refused: it describes text that no longer exists.
    @Test func anOutdatedRebuildIsNotAdopted() throws {
        var text = "# T\n\nSome *text*.\n"
        let highlighter = try #require(Highlighter(languageName: "markdown", text: text))
        func edit(_ insert: String, at offset: Int) {
            let oldIndex = LineIndex(text)
            text = (text as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: insert)
            highlighter.apply(edit: NSRange(location: offset, length: 0), replacementLength: insert.utf16.count, newText: text, oldIndex: oldIndex, newIndex: LineIndex(text))
        }
        edit("x", at: 6)
        #expect(highlighter.mayBeStale)
        let early = try #require(highlighter.backgroundRebuild()?())
        edit("y", at: 7)
        #expect(!highlighter.adopt(early), "text changed after the rebuild started")
        let current = try #require(highlighter.backgroundRebuild()?())
        #expect(highlighter.adopt(current) && !highlighter.mayBeStale)
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

/// Deterministic generator so a failing edit sequence can be reproduced.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
