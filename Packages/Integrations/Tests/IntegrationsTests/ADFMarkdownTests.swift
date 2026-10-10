import Foundation
import Testing
@testable import Integrations

struct ADFMarkdownTests {
    func render(_ json: String) -> String { ADFMarkdown.markdown(fromJSON: Data(json.utf8)) ?? "<nil>" }

    @Test func paragraphsHeadingsAndMarks() {
        let adf = #"{"type":"doc","version":1,"content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Why"}]},{"type":"paragraph","content":[{"type":"text","text":"Use "},{"type":"text","text":"bold","marks":[{"type":"strong"}]},{"type":"text","text":", "},{"type":"text","text":"code","marks":[{"type":"code"}]},{"type":"text","text":" and "},{"type":"text","text":"a link","marks":[{"type":"link","attrs":{"href":"https://x.test/"}},{"type":"em"}]},{"type":"text","text":"."},{"type":"hardBreak"},{"type":"mention","attrs":{"id":"1","text":"@Sam"}},{"type":"text","text":" "},{"type":"emoji","attrs":{"shortName":":tada:","text":"🎉"}},{"type":"text","text":" "},{"type":"status","attrs":{"text":"DONE"}}]}]}"#
        #expect(render(adf) == "## Why\n\nUse **bold**, `code` and [*a link*](https://x.test/).  \n@Sam 🎉 \\[DONE\\]\n")
    }

    @Test func listsTasksQuotesPanelsRulesAndCode() {
        let adf = #"{"type":"doc","content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]},{"type":"orderedList","attrs":{"order":3},"content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"three"}]}]}]}]},{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"two"}]}]}]},{"type":"taskList","content":[{"type":"taskItem","attrs":{"state":"DONE"},"content":[{"type":"text","text":"shipped"}]},{"type":"taskItem","attrs":{"state":"TODO"},"content":[{"type":"text","text":"pending"}]}]},{"type":"blockquote","content":[{"type":"paragraph","content":[{"type":"text","text":"quoted"}]}]},{"type":"panel","attrs":{"panelType":"warning"},"content":[{"type":"paragraph","content":[{"type":"text","text":"careful"}]}]},{"type":"rule"},{"type":"codeBlock","attrs":{"language":"swift"},"content":[{"type":"text","text":"let x = 1\nlet y = 2"}]}]}"#
        #expect(render(adf) == "- one\n  3. three\n- two\n\n- [x] shipped\n- [ ] pending\n\n> quoted\n\n> **Warning.** careful\n\n---\n\n```swift\nlet x = 1\nlet y = 2\n```\n")
    }

    @Test func tablesMediaExpandsAndUnknownNodes() {
        let adf = #"{"type":"doc","content":[{"type":"table","content":[{"type":"tableRow","content":[{"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"Name"}]}]},{"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"A|B"}]}]}]},{"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"x"}]}]},{"type":"tableCell","content":[]}]}]},{"type":"mediaSingle","content":[{"type":"media","attrs":{"id":"abc","alt":"diagram.png"}}]},{"type":"expand","attrs":{"title":"More"},"content":[{"type":"paragraph","content":[{"type":"text","text":"hidden"}]}]},{"type":"somethingNew","content":[{"type":"paragraph","content":[{"type":"text","text":"kept"}]}]},{"type":"paragraph","content":[{"type":"inlineCard","attrs":{"url":"https://x.test/p"}}]}]}"#
        #expect(render(adf) == "| Name | A\\|B |\n| --- | --- |\n| x |  |\n\n\\[image: diagram.png\\]\n\n**More**\n\nhidden\n\nkept\n\n<https://x.test/p>\n")
        let rich = #"{"type":"doc","content":[{"type":"table","content":[{"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]},{"type":"paragraph","content":[{"type":"text","text":"b"}]}]}]}]}]}"#
        #expect(render(rich) == "- Row 1:\n  - a\n    \n    b\n", "a cell with several paragraphs is listed, not squashed")
        #expect(ADFMarkdown.markdown(fromJSON: Data("nope".utf8)) == nil)
    }

    @Test func nodesThatUsedToVanish() {
        let card = #"{"type":"doc","content":[{"type":"blockCard","attrs":{"url":"https://x.test/board"}},{"type":"extension","attrs":{"extensionKey":"toc"}},{"type":"paragraph","content":[{"type":"text","text":"see "},{"type":"mediaInline","attrs":{"name":"spec.pdf"}},{"type":"text","text":" "},{"type":"status","attrs":{"text":"IN REVIEW"}}]},{"type":"decisionList","content":[{"type":"decisionItem","attrs":{"state":"DECIDED"},"content":[{"type":"text","text":"Ship"}]},{"type":"decisionItem","attrs":{"state":"UNDECIDED"},"content":[{"type":"text","text":"Name"}]}]}]}"#
        #expect(render(card) == "<https://x.test/board>\n\n[macro: toc]\n\nsee \\[file: spec.pdf\\] \\[IN REVIEW\\]\n\n- ✓ Ship\n- ○ Name\n")
        // A list in a table cell keeps its items apart.
        let listCell = #"{"type":"doc","content":[{"type":"table","content":[{"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"a"}]}]},{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"b"}]}]}]}]}]}]}]}"#
        #expect(render(listCell) == "- Row 1:\n  - - a\n    - b\n")
        // Nested task lists are indented.
        let tasks = #"{"type":"doc","content":[{"type":"taskList","content":[{"type":"taskItem","attrs":{"state":"TODO"},"content":[{"type":"text","text":"parent"}]},{"type":"taskList","content":[{"type":"taskItem","attrs":{"state":"DONE"},"content":[{"type":"text","text":"child"}]}]}]}]}"#
        #expect(render(tasks) == "- [ ] parent\n  - [x] child\n")
    }

    @Test func textCannotBecomeMarkdownOrScript() {
        let tricky = ##"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"# not a heading"}]},{"type":"paragraph","content":[{"type":"text","text":"1. not a list, *not bold*, <b>not html</b>"}]},{"type":"paragraph","content":[{"type":"text","text":"click","marks":[{"type":"link","attrs":{"href":"javascript:alert(1)"}}]},{"type":"text","text":" "},{"type":"text","text":"wiki","marks":[{"type":"link","attrs":{"href":"https://x.test/a_(b)"}}]},{"type":"text","text":" "},{"type":"text","text":"under","marks":[{"type":"underline"}]}]},{"type":"codeBlock","content":[{"type":"text","text":"```inner```"}]}]}"##
        #expect(render(tricky) == "\\# not a heading\n\n1\\. not a list, \\*not bold\\*, \\<b>not html\\</b>\n\nclick [wiki](https://x.test/a_%28b%29) under\n\n````\n```inner```\n````\n")
    }

    @Test func everyLineOfAParagraphStaysText() {
        let adf = ##"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"first"},{"type":"hardBreak"},{"type":"text","text":"# also not a heading"},{"type":"hardBreak"},{"type":"text","text":"---"}]},{"type":"paragraph","content":[{"type":"text","text":"~~~"}]},{"type":"paragraph","content":[{"type":"text","text":"    four spaces"}]},{"type":"paragraph","content":[{"type":"status","attrs":{"text":"x"}},{"type":"text","text":"(javascript:alert(1)) & more"}]},{"type":"paragraph","content":[{"type":"inlineCard","attrs":{"url":"file:///etc/passwd"}}]}]}"##
        #expect(render(adf) == "first  \n\\# also not a heading  \n\\---\n\n\\~~~\n\nfour spaces\n\n\\[x\\](javascript:alert(1)) \\& more\n", Comment(rawValue: render(adf)))
        // A code block as a list item's first part stays inside the item.
        let list = #"{"type":"doc","content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"codeBlock","content":[{"type":"text","text":"a\nb"}]}]}]}]}"#
        #expect(render(list) == "- ```\n  a\n  b\n  ```\n")
    }

    /// Emphasis that renders: spaces a mark covers go outside its delimiters, and italics work inside a word.
    @Test func emphasisDelimitersHugTheirWords() {
        let adf = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Ship "},{"type":"text","text":"today ","marks":[{"type":"strong"}]},{"type":"text","text":"un"},{"type":"text","text":"believ","marks":[{"type":"em"}]},{"type":"text","text":"able, "},{"type":"text","text":" ","marks":[{"type":"em"}]},{"type":"text","text":"done."}]}]}"#
        #expect(render(adf) == "Ship **today** un*believ*able,  done.\n")
    }

    /// A heading stays one line, and a `#` at its end is text rather than a closing sequence.
    @Test func headingsKeepTheirWholeText() {
        let adf = #"{"type":"doc","content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Plan"},{"type":"hardBreak"},{"type":"text","text":"for Q4"}]},{"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"Fix issue #"}]}]}"#
        #expect(render(adf) == "## Plan for Q4\n\n### Fix issue \\#\n")
    }

    @Test func renderingIsDeterministic() {
        let adf = #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"same"}]}]}"#
        #expect(render(adf) == render(adf))
    }
}
