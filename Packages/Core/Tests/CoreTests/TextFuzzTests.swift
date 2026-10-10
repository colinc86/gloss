import Foundation
import Testing
@testable import Core

/// Random text (quotes, tabs, CRLF, emoji with modifiers, Markdown and path characters) through the parsers and
/// anchors that read files agents write: none may trap, whatever a file holds.
struct TextFuzzTests {
    @Test func randomTextNeverTraps() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("ab,;\t\"\n\r é👍🏽#|-*_`[]()<>:/.~\\")
        func random(_ max: Int) -> String { String((0..<Int.random(in: 0...max, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }) }
        for _ in 0..<3000 {
            let text = random(60)
            let table = CSVParser.parse(text, delimiter: CSVParser.delimiter(for: text, fileName: "x.csv"))
            _ = table.columnCount
            let index = LineIndex(text)
            for line in 0...(index.lineCount + 2) { _ = index.contentRange(ofLine: line) }
            _ = index.position(forUTF16Offset: Int.random(in: 0...((text as NSString).length + 3), using: &rng))
            _ = PathUtilities.lexicallyNormalized("/" + random(20))
            _ = PathUtilities.relative("/" + random(10), to: "/" + random(5))
            let length = (text as NSString).length
            if length > 0 {
                let start = Int.random(in: 0..<length, using: &rng)
                let range = NSRange(location: start, length: Int.random(in: 0...(length - start), using: &rng))
                let anchor = ReAnchorer.make(from: range, in: text, index: index, hash: "h")
                _ = ReAnchorer.text(anchor, in: random(60), newHash: "h2")
                var cells = anchor
                cells.cells = CellSelection(columns: [Int.random(in: 0...4, using: &rng)], headers: [random(4)])
                _ = ReAnchorer.text(cells, in: random(60), newHash: "h3", fileName: "x.tsv")
                let other = random(60)
                _ = ExcerptExtractor.lines(for: anchor, in: other)
                var picked = anchor
                picked.cells = CellSelection(cells: [CellRef(lineOffset: Int.random(in: 0...3, using: &rng), column: Int.random(in: 0...4, using: &rng))])
                _ = CellExcerpt.make(anchor: picked, cells: picked.cells!, content: other, fileName: "x.csv")
                _ = CellExcerpt.make(anchor: cells, cells: cells.cells!, content: other, fileName: "x.csv")
            }
        }
    }
}
