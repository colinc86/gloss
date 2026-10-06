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
}
