import Foundation
import Testing
@testable import Integrations

struct ADFMarkdownTests {
    func render(_ json: String) -> String { ADFMarkdown.markdown(fromJSON: Data(json.utf8)) ?? "<nil>" }

    @Test func paragraphsHeadingsAndMarks() {
        let adf = #"{"type":"doc","version":1,"content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Why"}]},{"type":"paragraph","content":[{"type":"text","text":"Use "},{"type":"text","text":"bold","marks":[{"type":"strong"}]},{"type":"text","text":", "},{"type":"text","text":"code","marks":[{"type":"code"}]},{"type":"text","text":" and "},{"type":"text","text":"a link","marks":[{"type":"link","attrs":{"href":"https://x.test/"}},{"type":"em"}]},{"type":"text","text":"."},{"type":"hardBreak"},{"type":"mention","attrs":{"id":"1","text":"@Sam"}},{"type":"text","text":" "},{"type":"emoji","attrs":{"shortName":":tada:","text":"🎉"}},{"type":"text","text":" "},{"type":"status","attrs":{"text":"DONE"}}]}]}"#
        #expect(render(adf) == "## Why\n\nUse **bold**, `code` and [_a link_](https://x.test/).  \n@Sam 🎉 [DONE]\n")
    }

    @Test func listsTasksQuotesPanelsRulesAndCode() {
        let adf = #"{"type":"doc","content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]},{"type":"orderedList","attrs":{"order":3},"content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"three"}]}]}]}]},{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"two"}]}]}]},{"type":"taskList","content":[{"type":"taskItem","attrs":{"state":"DONE"},"content":[{"type":"text","text":"shipped"}]},{"type":"taskItem","attrs":{"state":"TODO"},"content":[{"type":"text","text":"pending"}]}]},{"type":"blockquote","content":[{"type":"paragraph","content":[{"type":"text","text":"quoted"}]}]},{"type":"panel","attrs":{"panelType":"warning"},"content":[{"type":"paragraph","content":[{"type":"text","text":"careful"}]}]},{"type":"rule"},{"type":"codeBlock","attrs":{"language":"swift"},"content":[{"type":"text","text":"let x = 1\nlet y = 2"}]}]}"#
        #expect(render(adf) == "- one\n  3. three\n- two\n\n- [x] shipped\n- [ ] pending\n\n> quoted\n\n> **Warning.** careful\n\n---\n\n```swift\nlet x = 1\nlet y = 2\n```\n")
    }

    @Test func tablesMediaExpandsAndUnknownNodes() {
        let adf = #"{"type":"doc","content":[{"type":"table","content":[{"type":"tableRow","content":[{"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"Name"}]}]},{"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"A|B"}]}]}]},{"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"x"}]}]},{"type":"tableCell","content":[]}]}]},{"type":"mediaSingle","content":[{"type":"media","attrs":{"id":"abc","alt":"diagram.png"}}]},{"type":"expand","attrs":{"title":"More"},"content":[{"type":"paragraph","content":[{"type":"text","text":"hidden"}]}]},{"type":"somethingNew","content":[{"type":"paragraph","content":[{"type":"text","text":"kept"}]}]},{"type":"paragraph","content":[{"type":"inlineCard","attrs":{"url":"https://x.test/p"}}]}]}"#
        #expect(render(adf) == "| Name | A\\|B |\n| --- | --- |\n| x |  |\n\n[image: diagram.png]\n\n**More**\n\nhidden\n\nkept\n\n<https://x.test/p>\n")
        let rich = #"{"type":"doc","content":[{"type":"table","content":[{"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]},{"type":"paragraph","content":[{"type":"text","text":"b"}]}]}]}]}]}"#
        #expect(render(rich) == "- Row 1: a b\n", "a cell with several paragraphs is listed, not squashed")
        #expect(ADFMarkdown.markdown(fromJSON: Data("nope".utf8)) == nil)
    }

    @Test func renderingIsDeterministic() {
        let adf = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"same"}]}]}"#
        #expect(render(adf) == render(adf))
    }
}
