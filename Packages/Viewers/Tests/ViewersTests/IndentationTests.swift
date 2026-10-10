import AppKit
import Testing
@testable import Viewers

/// Return keeps the line's indent, and Tab indents as the file does.
@MainActor
struct IndentationTests {
    @Test func theFilesIndentIsRead() {
        #expect(SourceTextView.indentUnit(for: "func a() {\n\tb()\n\tif c {\n\t\td()\n\t}\n}\n") == "\t")
        #expect(SourceTextView.indentUnit(for: "a:\n  b: 1\n  c:\n    d: 2\n") == "  ")
        #expect(SourceTextView.indentUnit(for: "func a() {\n    b()\n}\n") == "    ")
        #expect(SourceTextView.indentUnit(for: "plain text\nno indent\n") == "\t", "a tab, as before, when the file has said nothing")
        #expect(SourceTextView.indentUnit(for: "x\n * a doc comment\n    y\n") == "    ", "a lone space is not an indent")
    }

    @Test func leadingWhitespaceStopsAtTheCaret() {
        let text = "a\n    let x = 1\n\t\ty\n" as NSString
        #expect(SourceTextView.leadingWhitespace(ofLineAt: 10, in: text) == "    ")
        #expect(SourceTextView.leadingWhitespace(ofLineAt: 4, in: text) == "  ", "only as far as the caret")
        #expect(SourceTextView.leadingWhitespace(ofLineAt: 18, in: text) == "\t\t")
    }

    @Test func returnAndTabInAnEditor() {
        let view = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.isEditable = true
        view.string = "func a() {\n    b()\n}\n"
        view.setSelectedRange(NSRange(location: 18, length: 0))   // after "    b()"
        view.insertNewline(nil)
        #expect(view.string == "func a() {\n    b()\n    \n}\n")
        view.insertTab(nil)
        #expect(view.string == "func a() {\n    b()\n        \n}\n", "spaces to the next stop, not a tab")
        view.undoManager?.undo()
        view.isEditable = false
        let before = view.string
        view.insertTab(nil)
        view.insertNewline(nil)
        #expect(view.string == before, "a read-only view gains nothing")
    }

    @Test func linesShiftByOneIndent() {
        #expect(SourceTextView.shift("a\n\nb", by: "  ", outdent: false) == "  a\n\n  b", "empty lines stay empty")
        #expect(SourceTextView.shift("    a\n  b\nc", by: "    ", outdent: true) == "a\nb\nc", "only as many spaces as there are")
        #expect(SourceTextView.shift("\t\ta\n    b", by: "\t", outdent: true) == "\ta\nb")
    }

    @Test func tabOverSelectedLinesIndentsThem() {
        let view = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.isEditable = true
        view.string = "func a() {\n    b()\n    c()\n}\n"
        view.setSelectedRange(NSRange(location: 13, length: 12))   // from inside "b()" to inside "c()"
        view.insertTab(nil)
        #expect(view.string == "func a() {\n        b()\n        c()\n}\n", "the lines are indented, not replaced")
        #expect(view.selectedRange() == NSRange(location: 11, length: 23), "and stay selected")
        view.insertBacktab(nil)
        view.insertBacktab(nil)
        #expect(view.string == "func a() {\nb()\nc()\n}\n")
        view.string = "func a() {\n    b()\n    c()\n}\n"

        view.setSelectedRange(NSRange(location: 11, length: 8))   // "    b()\n": the next line is not taken
        view.insertTab(nil)
        #expect(view.string == "func a() {\n        b()\n    c()\n}\n")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertBacktab(nil)
        #expect(view.string == "func a() {\n        b()\n    c()\n}\n", "nothing to outdent")
        view.setSelectedRange(NSRange(location: 15, length: 0))
        view.insertTab(nil)
        #expect(view.string == "func a() {\n            b()\n    c()\n}\n", "a caret still types to the next stop")
    }
}
