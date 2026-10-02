import Foundation
import Testing
@testable import Core

struct CSVParserTests {
    @Test func parsesQuotesEscapesAndEmbeddedNewlines() {
        let text = "name,price,note\nwidget,\"1,50\",\"says \"\"hi\"\"\"\ngadget,2,\"multi\nline\"\nlast,3,\n"
        let table = CSVParser.parse(text, delimiter: ",")
        #expect(table.header == ["name", "price", "note"])
        #expect(table.rows.count == 3)
        #expect(table.rows[0].fields == ["widget", "1,50", "says \"hi\""])
        #expect(table.rows[0].firstLine == 2 && table.rows[0].lastLine == 2)
        #expect(table.rows[1].fields == ["gadget", "2", "multi\nline"])
        #expect(table.rows[1].firstLine == 3 && table.rows[1].lastLine == 4, "a quoted newline spans two source lines")
        #expect(table.rows[2].fields == ["last", "3", ""])
        #expect(table.rows[2].firstLine == 5)
    }

    @Test func handlesCRLFAndTabs() {
        let text = "a\tb\r\n1\t2\r\n"
        let table = CSVParser.parse(text, delimiter: "\t")
        #expect(table.header == ["a", "b"])
        #expect(table.rows == [CSVRow(fields: ["1", "2"], firstLine: 2, lastLine: 2)])
        #expect(CSVParser.delimiter(for: text, fileName: "x.csv") == "\t")
        #expect(CSVParser.delimiter(for: "a;b;c\n", fileName: "x.csv") == ";")
        #expect(CSVParser.delimiter(for: "plain\n", fileName: "x.tsv") == "\t")
        #expect(CSVParser.delimiter(for: "plain\n", fileName: "x.csv") == ",")
    }

    @Test func emptyAndHeaderless() {
        #expect(CSVParser.parse("", delimiter: ",").rows.isEmpty)
        let table = CSVParser.parse("1,2\n3,4", delimiter: ",", hasHeader: false)
        #expect(table.header.isEmpty)
        #expect(table.rows.map(\.fields) == [["1", "2"], ["3", "4"]])
        #expect(table.columnCount == 2)
    }
}
