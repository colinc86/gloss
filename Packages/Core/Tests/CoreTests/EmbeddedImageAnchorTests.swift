import Foundation
import Testing
@testable import Core

/// A note on a picture embedded in a document: a region of it, or all of it.
struct EmbeddedImageAnchorTests {
    static let doc = "# CP-7: Fix the chart\n\nThe legend overlaps:\n\n![chart.png](CP-7%20attachments/chart.png)\n\nMore text.\n"

    static func anchor(region: ImageAnchor = ImageAnchor(x: 10, y: 20, w: 300, h: 120, imageW: 1600, imageH: 900)) -> EmbeddedImageAnchor {
        let range = (doc as NSString).range(of: "![chart.png](CP-7%20attachments/chart.png)")
        let embed = ReAnchorer.make(from: range, in: doc, index: LineIndex(doc), hash: "old")
        return EmbeddedImageAnchor(source: "CP-7%20attachments/chart.png", occurrence: 0, region: region, embed: embed)
    }

    @Test func roundTripsAndDescribesItself() throws {
        let anchor = Anchor.embeddedImage(Self.anchor())
        #expect(try Anchor(type: anchor.type, json: anchor.encodedJSON()) == anchor)
        #expect(anchor.type.rawValue == "embedded-image")
        #expect(anchor.summary == "Image chart.png, region 300×120")
        let whole = Self.anchor(region: ImageAnchor(x: 0, y: 0, w: 1600, h: 900, imageW: 1600, imageH: 900))
        #expect(Anchor.embeddedImage(whole).summary == "Image chart.png")
        #expect(Anchor.embeddedImage(whole).sortKey.primary == 5)
    }

    @Test func thePacketNamesThePictureItsLineAndTheRegion() {
        let note = PacketNote(noteID: NoteID.new(), agentPath: "/jira/CP/CP-7.md", source: .jira, anchor: .embeddedImage(Self.anchor()),
                              comment: "The legend overlaps here", attachmentAgentPath: "/tmp/crop.png")
        let text = PacketBuilder.build([note]).text
        #expect(text.contains("Line 5\nImage: CP-7%20attachments/chart.png (1600x900)\nRegion: x=10 y=20 w=300 h=120 (crop attached)\nAttachment: /tmp/crop.png"), "\(text)")
    }

    @Test func followsItsEmbedAndIsOrphanedWithoutIt() {
        let anchor = Self.anchor()
        let moved = "Intro added.\n\n" + Self.doc
        guard case .moved(.embeddedImage(let next)) = ReAnchorer.embeddedImage(anchor, in: moved, newHash: "new") else { Issue.record("expected moved"); return }
        #expect(next.embed.start.line == 7 && next.region == anchor.region)
        let gone = Self.doc.replacingOccurrences(of: "![chart.png](CP-7%20attachments/chart.png)", with: "No picture now.")
        #expect(ReAnchorer.embeddedImage(anchor, in: gone, newHash: "new") == .orphaned)
        let swapped = Self.doc.replacingOccurrences(of: "chart.png)", with: "other.png)")
        #expect(ReAnchorer.embeddedImage(anchor, in: swapped, newHash: "new") == .orphaned, "another picture there now")
    }

    /// The rendered view finds a picture by which embed of it a note is on: embeds of the same picture added or
    /// removed above the note's change that number.
    @Test func theOccurrenceFollowsEmbedsAddedAndRemovedAbove() {
        let doc = "# Before\n\nFirst look:\n\n![a](shot.png)\n\n# After\n\nSecond look, after the fix:\n\n![b](shot.png)\n\nEnd.\n"
        let range = (doc as NSString).range(of: "![b](shot.png)")
        let region = ImageAnchor(x: 0, y: 0, w: 10, h: 10, imageW: 100, imageH: 100)
        let anchor = EmbeddedImageAnchor(source: "shot.png", occurrence: 1, region: region,
                                         embed: ReAnchorer.make(from: range, in: doc, index: LineIndex(doc), hash: "old"))
        #expect(ReAnchorer.embedOccurrence(of: "shot.png", before: range.location, in: doc) == 1)
        let firstGone = doc.replacingOccurrences(of: "First look:\n\n![a](shot.png)\n\n", with: "")
        guard case .moved(.embeddedImage(let fewer)) = ReAnchorer.embeddedImage(anchor, in: firstGone, newHash: "new") else { Issue.record("expected moved"); return }
        #expect(fewer.occurrence == 0)
        let added = "![top](shot.png)\n\n" + doc
        guard case .moved(.embeddedImage(let more)) = ReAnchorer.embeddedImage(anchor, in: added, newHash: "new") else { Issue.record("expected moved"); return }
        #expect(more.occurrence == 2)
        #expect(ReAnchorer.embedOccurrence(of: "shot.png", before: 1000, in: "[link](shot.png) ![x](shot.png.bak)") == 0, "links and other files don't count")
    }

    /// HTML pictures count with Markdown ones, however their `src` is quoted.
    @Test func occurrencesCountHTMLAndMarkdownEmbedsTogether() {
        let doc = "<img src=\"shot.png\" width=\"80\">\n\n![a](shot.png)\n\n<IMG alt='x' SRC='shot.png'>\n\n<img src=shot.png>\n\n![b](shot.png)\n"
        let last = (doc as NSString).range(of: "![b](shot.png)")
        #expect(ReAnchorer.embedOccurrence(of: "shot.png", before: last.location, in: doc) == 4)
        let third = (doc as NSString).range(of: "<IMG")
        #expect(ReAnchorer.embedOccurrence(of: "shot.png", before: third.location, in: doc) == 2)
        let others = "<img data-src=\"shot.png\"> <img src=\"shot.png.bak\"> <a href=\"shot.png\">x</a> <img src=shot.pngx>"
        #expect(ReAnchorer.embedOccurrence(of: "shot.png", before: 1000, in: others) == 0, "other attributes and files don't count")
    }

    /// What is never drawn as a picture is never an embed: code, comments, Markdown syntax inside HTML.
    @Test func theScannerSkipsWhatIsNeverDrawn() {
        let doc = """
        <!-- <img src="a.png"> -->
        ```html
        <img src="a.png">
        ```

            ![indented](a.png)

        Use `<img src="a.png">` and \\![escaped](a.png).

        <div>
        ![literal](a.png) <img alt="a > b" src="a.png">
        </div>

        <p><img
          src="b.png"></p>

        ![one](a.png "title") ![ref][pic] ![<x>](<c d.png>)

        [pic]: d.png
        """
        let embeds = EmbedScanner.embeds(in: doc)
        let ns = doc as NSString
        #expect(embeds.map(\.source) == ["a.png", "b.png", "a.png", "d.png", "c d.png"], "\(embeds)")
        #expect(embeds.map { ns.substring(with: $0.range) } == [
            "<img alt=\"a > b\" src=\"a.png\">", "<img\n  src=\"b.png\">", "![one](a.png \"title\")", "![ref][pic]", "![<x>](<c d.png>)",
        ])
    }

    /// A `<picture>`'s sources count as embeds, drawn or not, so the numbering never depends on Reduce Motion.
    @Test func pictureSourcesCountAsEmbeds() {
        let doc = """
        <picture>
          <source media="(prefers-reduced-motion: reduce)" srcset=" hero.png 1x, hero@2x.png 2x">
          <img src="hero.gif">
        </picture>
        """
        #expect(EmbedScanner.embeds(in: doc).map(\.source) == ["hero.png", "hero.gif"])
        #expect(EmbedScanner.firstCandidate(inSrcset: "a.png, b.png 2x") == "a.png")
        #expect(EmbedScanner.embeds(in: "<source src=\"clip.mp4\">\n").isEmpty, "a source without srcset names no picture")
    }

    /// A ```` ```mermaid ```` block is drawn as a picture, so it is an embed of `mermaid` covering the whole fence;
    /// other fences, and a Mermaid fence's contents, are not.
    @Test func mermaidFencesAreEmbeds() {
        let doc = """
        ![a](a.png)

        ```mermaid
        flowchart LR
          A --> B
        ```

        ```swift
        let x = "![b](a.png)"
        ```

        - ~~~ Mermaid {theme: dark}
          sequenceDiagram
          ~~~

        > ```mermaid
        > graph TD
        """
        let embeds = EmbedScanner.embeds(in: doc)
        #expect(embeds.map(\.source) == ["a.png", "mermaid:", "mermaid:", "mermaid:"])
        #expect(embeds.map(\.range.location) == embeds.map(\.range.location).sorted(), "in document order")
        let ns = doc as NSString
        #expect(ns.substring(with: embeds[1].range) == "```mermaid\nflowchart LR\n  A --> B\n```")
        #expect(ns.substring(with: embeds[2].range).hasPrefix("~~~ Mermaid") && ns.substring(with: embeds[2].range).hasSuffix("~~~"))
        #expect(ns.substring(with: embeds[3].range) == "```mermaid\n> graph TD", "an unclosed fence runs to the end")
        #expect(ReAnchorer.embedOccurrence(of: "mermaid:", before: embeds[3].range.location, in: doc) == 2)
        #expect(EmbedScanner.embeds(in: "```mermaidx\nA\n```\n\n`mermaid`\n").isEmpty)
    }

    /// A note on a diagram follows its fence, and the packet calls it a Mermaid diagram rather than naming a file.
    @Test func aDiagramNoteFollowsItsFenceAndNamesItself() {
        let doc = "# Flow\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\nText.\n"
        let range = (doc as NSString).range(of: "```mermaid\nflowchart LR\n  A --> B\n```")
        let anchor = EmbeddedImageAnchor(source: EmbedScanner.mermaidSource, occurrence: 0, region: ImageAnchor(x: 4, y: 6, w: 80, h: 40, imageW: 400, imageH: 120),
                                         embed: ReAnchorer.make(from: range, in: doc, index: LineIndex(doc), hash: "old"))
        #expect(anchor.isMermaidDiagram && anchor.fileName == "Mermaid diagram")
        #expect(anchor.attachmentBaseName == "mermaid-diagram", "a crop's file name has no space")
        #expect(Self.anchor().attachmentBaseName == "chart")
        let note = PacketNote(noteID: NoteID.new(), agentPath: "/repo/flow.md", source: .markdown, anchor: .embeddedImage(anchor),
                              comment: "Swap these", attachmentAgentPath: "/tmp/crop.png")
        let text = PacketBuilder.build([note]).text
        #expect(text.contains("Line 3\nImage: Mermaid diagram (400x120)\nRegion: x=4 y=6 w=80 h=40 (crop attached)"), "\(text)")
        let moved = "Intro.\n\n```mermaid\nflowchart TB\n  Z --> Y\n```\n\n" + doc
        guard case .moved(.embeddedImage(let next)) = ReAnchorer.embeddedImage(anchor, in: moved, newHash: "new") else { Issue.record("expected moved"); return }
        #expect(next.embed.start.line == 10 && next.occurrence == 1, "a diagram added above makes this the second")
        let notADiagram = doc.replacingOccurrences(of: "```mermaid", with: "```text")
        #expect(ReAnchorer.embeddedImage(anchor, in: "Intro.\n\n" + notADiagram, newHash: "new") == .orphaned, "the fence is no longer Mermaid")
    }

    /// A fence ends with the quote or list item that holds it, closed or not, so a diagram after it is counted.
    @Test func aDiagramFenceEndsWithItsContainer() {
        let quoted = "> ```mermaid\n> graph TD\n\n```mermaid\nflowchart LR\n```\n"
        let inQuote = EmbedScanner.embeds(in: quoted)
        #expect(inQuote.map(\.source) == ["mermaid:", "mermaid:"])
        #expect((quoted as NSString).substring(with: inQuote[0].range) == "```mermaid\n> graph TD")
        #expect(inQuote[1].range.location == (quoted as NSString).range(of: "```mermaid\nflowchart").location)

        let listed = "- item\n\n  ```mermaid\n  graph TD\n- next\n\n```mermaid\nflowchart LR\n```\n"
        let inList = EmbedScanner.embeds(in: listed)
        #expect(inList.count == 2)
        #expect((listed as NSString).substring(with: inList[0].range) == "```mermaid\n  graph TD")

        let quoteInList = "- > ```mermaid\n  > graph TD\n  > ```\n\n```mermaid\nflowchart LR\n```\n"
        let both = EmbedScanner.embeds(in: quoteInList)
        #expect(both.count == 2)
        #expect((quoteInList as NSString).substring(with: both[0].range) == "```mermaid\n  > graph TD\n  > ```")
    }
}
