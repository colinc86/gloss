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
}
