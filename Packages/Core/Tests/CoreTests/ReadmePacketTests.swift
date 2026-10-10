import Foundation
import Testing
@testable import Core

/// The README shows what an agent receives; it is built here by the packet builder, so the two can't drift apart.
struct ReadmePacketTests {
    @Test func theReadmesPacketIsWhatTheBuilderWrites() throws {
        let readme = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../README.md").standardized, encoding: .utf8)
        let start = try #require(readme.range(of: "```text\n"))
        let end = try #require(readme.range(of: "\n```", range: start.upperBound..<readme.endIndex))
        let shown = String(readme[start.upperBound..<end.lowerBound])

        let path = "/home/me/acme-weather/docs/PLAN.md"
        let sentence = "We should cache the forecast results for ten minutes at most, and less for severe-weather alerts."
        let text = PacketNote(noteID: NoteID(rawValue: "n_01J9XQ4M2T8V6K3R5W7Y9ZB1CD"), agentPath: path, source: .markdown,
                              anchor: .text(TextAnchor(start: .init(line: 8, col: 1), end: .init(line: 8, col: sentence.count), text: sentence, before: "", after: "")),
                              comment: "Alerts can't wait ten minutes. Give them their own TTL, at most one minute.", excerptLines: [sentence])
        let picture = EmbeddedImageAnchor(source: "dashboard.png", occurrence: 0, region: ImageAnchor(x: 1004, y: 96, w: 400, h: 220, imageW: 1440, imageH: 880),
                                          embed: TextAnchor(start: .init(line: 20, col: 1), end: .init(line: 20, col: 30), text: "![Dashboard](dashboard.png)", before: "", after: ""))
        let image = PacketNote(noteID: NoteID(rawValue: "n_01J9XQ7B8R2N4P6S8T0VA3K7QM"), agentPath: path, source: .markdown, anchor: .embeddedImage(picture),
                               comment: "The legend overlaps the chart here. Move it below.",
                               attachmentAgentPath: "/home/me/.cache/gloss/attachments/s_01J9XQ9C4H6M8P0R2T4V6X8Z0B/1-dashboard-region-A3K7QM.png")
        let built = PacketBuilder.build([text, image]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(built == shown, "README:\n\(shown)\n\nbuilt:\n\(built)")
    }
}
