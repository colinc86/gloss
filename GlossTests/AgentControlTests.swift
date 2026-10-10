import Core
import Foundation
import Testing
@testable import Gloss

/// Issue #4: where an agent's question lands in the file it names.
struct AgentControlTests {
    @Test func aQuotedTextIsFoundNearestTheGivenLine() {
        let text = "intro\nTODO: decide\nmiddle\nmore\nTODO: decide\nend\n"
        let index = LineIndex(text)
        let near = AppModel.occurrence(of: "TODO: decide", in: text, index: index, nearLine: 5)
        #expect(near.map { index.position(forUTF16Offset: $0.location).line } == 5)
        let first = AppModel.occurrence(of: "TODO: decide", in: text, index: index, nearLine: nil)
        #expect(first.map { index.position(forUTF16Offset: $0.location).line } == 2)
        #expect(AppModel.occurrence(of: "absent", in: text, index: index, nearLine: 1) == nil)
    }

    /// Agents quote lines joined by "\n"; a Windows file joins them with "\r\n", and the quote still finds them.
    @Test func aQuoteOfSeveralLinesIsFoundInACRLFFile() {
        let text = "intro\r\nfirst line\r\nsecond line\r\nend\r\n"
        let index = LineIndex(text)
        let found = AppModel.occurrence(of: "first line\nsecond line", in: text, index: index, nearLine: nil)
        #expect(found.map { (text as NSString).substring(with: $0) } == "first line\r\nsecond line")
        #expect(found.map { index.position(forUTF16Offset: $0.location).line } == 2)
    }
}
