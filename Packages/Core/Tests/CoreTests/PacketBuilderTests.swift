import Foundation
import Testing
@testable import Core

struct PacketBuilderTests {
    let markdownID = NoteID(rawValue: "n_01J9X0000000000000000000")
    let imageID = NoteID(rawValue: "n_01J9Y0000000000000000000")

    func textAnchor(_ start: Int, _ end: Int, text: String = "") -> Anchor {
        .text(TextAnchor(start: .init(line: start, col: 1), end: .init(line: end, col: 9), text: text, before: "", after: ""))
    }

    @Test func matchesTheSkillExampleByteForByte() {
        let notes = [
            PacketNote(
                noteID: markdownID, agentPath: "/home/colin/proj/docs/PLAN.md", source: .markdown,
                anchor: textAnchor(40, 52), comment: "This contradicts the 15 minute TTL in api.md. Pick one and fix both.",
                excerptLines: ["## Auth flow", "The client refreshes tokens every 5 minutes..."]
            ),
            PacketNote(
                noteID: imageID, agentPath: "/home/colin/proj/design/dashboard.png", source: .image,
                anchor: .image(ImageAnchor(x: 1204, y: 312, w: 640, h: 220, imageW: 2880, imageH: 1800)),
                comment: "The legend overlaps the chart here. Move it below.",
                attachmentAgentPath: "/tmp/gloss/a1b2c3/dashboard-region-1.png"
            ),
        ]
        let expected = """
        File: /home/colin/proj/docs/PLAN.md
        Source: markdown

        Lines 40-52
        Excerpt:
        > ## Auth flow
        > The client refreshes tokens every 5 minutes...
        User comment: "This contradicts the 15 minute TTL in api.md. Pick one and fix both."


        File: /home/colin/proj/design/dashboard.png
        Source: image
        Original size: 2880x1800

        Region: x=1204 y=312 w=640 h=220 (crop attached)
        Attachment: /tmp/gloss/a1b2c3/dashboard-region-1.png
        User comment: "The legend overlaps the chart here. Move it below."

        Notes: 2. Mark each resolved with the gloss MCP tool `resolve_note` (ids: n_01J9X0000000000000000000, n_01J9Y0000000000000000000) when done.
        """
        let packet = PacketBuilder.build(notes)
        #expect(packet.text == expected)
        #expect(packet.noteIDs == [markdownID, imageID])
    }

    @Test func singleLineAndSelectedText() {
        let note = PacketNote(
            noteID: markdownID, agentPath: "/p/a.md", source: .markdown, anchor: textAnchor(7, 7),
            comment: "typo", excerptLines: ["Hello *world*"], selectedText: "world"
        )
        let text = PacketBuilder.build([note]).text
        #expect(text.hasPrefix("File: /p/a.md\nSource: markdown\n\nLine 7\nSelected: \"world\"\nExcerpt:\n> Hello *world*\nUser comment: \"typo\"\n\nNotes: 1."))
    }

    @Test func truncatesLongExcerpts() {
        let lines = (1...41).map { "line \($0)" }
        let note = PacketNote(noteID: markdownID, agentPath: "/p/a.txt", source: .text, anchor: textAnchor(1, 41), comment: "c", excerptLines: lines)
        let text = PacketBuilder.build([note]).text
        let quoted = text.components(separatedBy: "\n").filter { $0.hasPrefix("> ") }
        #expect(quoted.count == 41)
        #expect(quoted[19] == "> line 20")
        #expect(quoted[20] == "> ...")
        #expect(quoted[21] == "> line 22")
        #expect(quoted.last == "> line 41")

        let exactly40 = PacketNote(noteID: markdownID, agentPath: "/p/a.txt", source: .text, anchor: textAnchor(1, 40), comment: "c", excerptLines: Array(lines.prefix(40)))
        #expect(!PacketBuilder.build([exactly40]).text.contains("> ..."))
    }

    @Test func pdfPageRegionAndWholeFile() {
        let pdf = PacketNote(
            noteID: markdownID, agentPath: "/p/spec.pdf", source: .pdf,
            anchor: .pdf(PDFAnchor(page: 2, bounds: PDFBounds(x: 72, y: 100.5, w: 300, h: 40), text: "Section 4", pageCount: 12)),
            comment: "Here", excerptLines: ["Section 4"], attachmentAgentPath: "/tmp/gloss/p.png"
        )
        let whole = PacketNote(noteID: imageID, agentPath: "/p/budget.numbers", source: .file, anchor: .wholeFile, comment: "Look at this")
        let text = PacketBuilder.build([pdf, whole]).text
        #expect(text.contains("File: /p/spec.pdf\nSource: pdf\nPages: 12\n\nPage 3\nRegion: x=72 y=100.5 w=300 h=40\nExcerpt:\n> Section 4\nAttachment: /tmp/gloss/p.png\nUser comment: \"Here\""))
        #expect(text.contains("File: /p/budget.numbers\nSource: file\n\nWhole file\nUser comment: \"Look at this\""))

        let wholeThenPage = PacketNote(noteID: imageID, agentPath: "/p/spec.pdf", source: .pdf, anchor: .wholeFile, comment: "all")
        let both = PacketBuilder.build([wholeThenPage, pdf]).text
        #expect(both.hasPrefix("File: /p/spec.pdf\nSource: pdf\nPages: 12\n"), "the header comes from the first note with a pdf anchor")
        let noCrop = PacketNote(noteID: imageID, agentPath: "/p/i.png", source: .image, anchor: .image(ImageAnchor(x: 1, y: 2, w: 3, h: 4, imageW: 9, imageH: 9)), comment: "c")
        #expect(PacketBuilder.build([noCrop]).text.contains("Region: x=1 y=2 w=3 h=4\nUser comment"), "no crop attached without an attachment")
    }

    @Test func escapesCommentsAndSplitsEmbeddedNewlines() {
        #expect(PacketBuilder.escape(#"say "hi"\ now"#) == #"say \"hi\"\\ now"#)
        #expect(PacketBuilder.escape("a\r\nb\nc") == #"a\r\nb\nc"#)
        let note = PacketNote(noteID: markdownID, agentPath: "/p/a.md", source: .markdown, anchor: textAnchor(1, 2), comment: "line1\nline2", excerptLines: ["x\ny"])
        let text = PacketBuilder.build([note]).text
        #expect(text.contains("Excerpt:\n> x\n> y\nUser comment: \"line1\\nline2\""))
    }

    @Test func groupsByFileInFirstSeenOrderAndSortsWithinFile() {
        let a9 = PacketNote(noteID: NoteID(rawValue: "n_a9"), agentPath: "/p/a.md", source: .markdown, anchor: textAnchor(9, 9), comment: "a9")
        let b1 = PacketNote(noteID: NoteID(rawValue: "n_b1"), agentPath: "/p/b.md", source: .markdown, anchor: textAnchor(1, 1), comment: "b1")
        let a2 = PacketNote(noteID: NoteID(rawValue: "n_a2"), agentPath: "/p/a.md", source: .markdown, anchor: textAnchor(2, 2), comment: "a2")
        let packet = PacketBuilder.build([a9, b1, a2])
        #expect(packet.noteIDs.map(\.rawValue) == ["n_a2", "n_a9", "n_b1"])
        let aIndex = packet.text.range(of: "File: /p/a.md")!.lowerBound
        let bIndex = packet.text.range(of: "File: /p/b.md")!.lowerBound
        #expect(aIndex < bIndex)
        #expect(packet.text.contains("User comment: \"a2\"\n\nLine 9\nUser comment: \"a9\"\n\n\nFile: /p/b.md"))
    }

    @Test func emptyPacketIsJustTheClosingLine() {
        #expect(PacketBuilder.build([]).text == "Notes: 0. Mark each resolved with the gloss MCP tool `resolve_note` (ids: ) when done.")
    }

    @Test func summaryLineAndHookFallback() {
        let long = String(repeating: "x", count: 100)
        let note = PacketNote(noteID: markdownID, agentPath: "/p/a.md", source: .markdown, anchor: textAnchor(3, 5), comment: long)
        let summary = PacketBuilder.summaryLine(note)
        #expect(summary == "\(markdownID.rawValue): /p/a.md:3-5 \"\(String(repeating: "x", count: 80))\"")

        let big = (0..<400).map { i in
            PacketNote(noteID: NoteID.new(), agentPath: "/p/f\(i).md", source: .markdown, anchor: textAnchor(1, 3), comment: "comment \(i)", excerptLines: ["one", "two", "three"])
        }
        let full = PacketBuilder.build(big).text
        #expect(full.count > 10_000)
        let hook = PacketBuilder.hookText(big)
        #expect(hook.count <= 10_000)
        #expect(hook.hasPrefix("400 pending notes"))
        #expect(hook.contains("and 360 more via `list_pending_notes`"))
        #expect(hook.contains("`get_note`"))
        #expect(hook.hasSuffix("when done."))
        let small = PacketBuilder.hookText([note])
        #expect(small == PacketBuilder.build([note]).text)
    }

    @Test func excerptExtractorHandlesLineEndingsAndBounds() {
        let content = "one\r\ntwo\nthree\rfour\n"
        #expect(ExcerptExtractor.allLines(content) == ["one", "two", "three", "four"])
        #expect(ExcerptExtractor.allLines("a\u{0C}b\nc") == ["a\u{0C}b", "c"], "form feed is not a line break, matching LineIndex")
        let anchor = TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 3, col: 3), text: "", before: "", after: "")
        #expect(ExcerptExtractor.lines(for: anchor, in: content) == ["two", "three"])
        let toNextLineStart = TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 3, col: 1), text: "", before: "", after: "")
        #expect(ExcerptExtractor.lines(for: toNextLineStart, in: content) == ["two"])
        let beyond = TextAnchor(start: .init(line: 4, col: 1), end: .init(line: 99, col: 1), text: "", before: "", after: "")
        #expect(ExcerptExtractor.lines(for: beyond, in: content) == ["four"])
        #expect(ExcerptExtractor.lines(for: anchor, in: "") == [])
        #expect(ExcerptExtractor.allLines("no newline at end") == ["no newline at end"])
    }
}
