import AppKit
import Core
import Foundation
import Testing
@testable import Viewers

/// Mermaid diagrams in rendered Markdown: drawn by the bundled Mermaid, placed as pictures that notes can mark, and
/// counted as embeds the way the re-anchorer counts them.
@MainActor
@Suite(.serialized)
struct MermaidDiagramTests {
    @Test func theBundledMermaidDrawsAFlowchart() async throws {
        let result = await MermaidRenderer.shared.render("flowchart LR\n  A[Start] --> B{Choose}\n  B --> C[Done]\n", dark: false)
        guard case .diagram(let image, let png) = result else {
            Issue.record("no diagram: \(result)")
            return
        }
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(image.size.width > 20 && image.size.height > 10)
        #expect(bitmap.pixelsWide == Int(image.size.width * 2), "drawn at twice its size")
        #expect(FittedImageAttachment.pixelSize(of: image) == CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        // Not a blank page: some pixels differ from the corner's.
        let corner = bitmap.colorAt(x: 0, y: 0)
        var differing = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) where bitmap.colorAt(x: x, y: y) != corner { differing += 1 }
        }
        #expect(differing > 50)
    }

    @Test func aBadDiagramSaysWhy() async {
        let result = await MermaidRenderer.shared.render("flowchart LR\n  A --> \n  ((((\n", dark: true)
        guard case .failed(let message) = result else {
            Issue.record("drew a diagram from nonsense")
            return
        }
        #expect(!message.isEmpty)
        #expect(!message.contains("\n"))
    }

    static let flowchart = "flowchart LR\n  A --> B\n"

    static func diagram(width: Int = 120, height: Int = 60) throws -> MermaidRenderer.Result {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = CGSize(width: width, height: height)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return .diagram(image: image, png: try #require(rep.representation(using: .png, properties: [:])))
    }

    static func pictures(_ output: MarkdownRenderer.Output) -> [(attachment: FittedImageAttachment, index: Int)] {
        var found: [(FittedImageAttachment, Int)] = []
        output.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.text.length)) { value, range, _ in
            if let attachment = value as? FittedImageAttachment { found.append((attachment, range.location)) }
        }
        return found
    }

    @Test func aDrawnDiagramIsAPictureMappedToItsWholeFence() throws {
        let source = "Intro.\n\n```mermaid\n\(Self.flowchart)```\n\nAfter.\n"
        let output = MarkdownRenderer.render(source, diagrams: [Self.flowchart: try Self.diagram()])
        let found = Self.pictures(output)
        try #require(found.count == 1)
        let attachment = found[0].attachment
        #expect(attachment.source == EmbedScanner.mermaidSource && attachment.occurrence == 0)
        #expect(attachment.naturalSize == CGSize(width: 120, height: 60) && attachment.pixelSize == CGSize(width: 240, height: 120))
        let embed = try #require(output.map.sourceRange(forRendered: NSRange(location: found[0].index, length: 1))).source
        #expect((source as NSString).substring(with: embed) == "```mermaid\n\(Self.flowchart)```")
        #expect(!output.text.string.contains("flowchart"), "the diagram replaces its code")
        #expect(output.unresolvedDiagrams.isEmpty && output.diagramSources == [0: Self.flowchart])
    }

    @Test func anUndrawnDiagramIsListedAndShownAsCode() {
        let output = MarkdownRenderer.render("```mermaid\n\(Self.flowchart)```\n\n```Mermaid\n\(Self.flowchart)```\n")
        #expect(output.unresolvedDiagrams == [Self.flowchart], "asked for once")
        #expect(Self.pictures(output).isEmpty)
        #expect(output.text.string.contains("A --> B"))
    }

    @Test func aRefusedDiagramShowsItsCodeAndWhy() {
        let output = MarkdownRenderer.render("```mermaid\n\(Self.flowchart)```\n", diagrams: [Self.flowchart: .failed("Parse error on line 2")])
        #expect(output.unresolvedDiagrams.isEmpty)
        #expect(output.text.string.contains("A --> B"))
        #expect(output.text.string.contains("Mermaid couldn't draw this diagram: Parse error on line 2"))
    }

    /// Diagrams and pictures mixed, in lists and quotes, beside other fences: the renderer numbers each diagram as
    /// the re-anchorer does.
    @Test func theRendererAndTheScannerAgreeOnDiagrams() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gloss-mermaid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 9, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "a.png"))
        let other = "sequenceDiagram\n  A->>B: hi\n"
        let source = """
        ![x](a.png)

        ```mermaid
        \(Self.flowchart)```

        ```text
        ```mermaid
        ```

        - item

          ```mermaid
          \(other.replacingOccurrences(of: "\n  ", with: "\n    "))  ```

        > ~~~mermaid
        > \(Self.flowchart.replacingOccurrences(of: "\n  ", with: "\n>   "))> ~~~

        <img src="a.png">

        - > ```mermaid
          > \(other.replacingOccurrences(of: "\n  ", with: "\n  >   "))  > ```

        > ```mermaid
        > graph TD

        ```mermaid
        \(Self.flowchart)```
        """
        let diagrams = [Self.flowchart: try Self.diagram(), other: try Self.diagram(width: 80, height: 200)]
        let output = MarkdownRenderer.render(source, baseURL: folder, diagrams: diagrams)
        var diagramOccurrences: [Int] = []
        for (attachment, index) in Self.pictures(output) {
            let embed = try #require(output.map.sourceRange(forRendered: NSRange(location: index, length: 1))).source
            let text = (source as NSString).substring(with: embed)
            let name = try #require(attachment.source)
            #expect(ReAnchorer.embedOccurrence(of: name, before: embed.location, in: source) == attachment.occurrence, "\(text)")
            if name == EmbedScanner.mermaidSource {
                #expect(text.contains("mermaid"), "\(text)")
                diagramOccurrences.append(attachment.occurrence)
            }
        }
        #expect(diagramOccurrences == [0, 1, 2, 3, 5], "\(output.text.string)")
        #expect(EmbedScanner.embeds(in: source).filter { $0.source == EmbedScanner.mermaidSource }.count == 6)
    }

    /// The viewer draws its diagrams with the bundled Mermaid and keeps each one's PNG for a region note's crop.
    @Test func theViewerDrawsDiagramsAndKeepsTheirPNGs() async throws {
        let text = "```mermaid\n\(Self.flowchart)```\n\n```mermaid\nflowchart TB\n  One --> Two --> Three\n```\n"
        let markdown = MarkdownViewerController(source: TextEditorController(text: text))
        for _ in 0..<500 where Self.pictures(MarkdownRenderer.Output(text: markdown.rendered, map: markdown.map)).count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let found = Self.pictures(MarkdownRenderer.Output(text: markdown.rendered, map: markdown.map))
        try #require(found.count == 2)
        for (attachment, _) in found {
            let png = try #require(markdown.imageData(for: EmbedScanner.mermaidSource, occurrence: attachment.occurrence))
            let bitmap = try #require(NSBitmapImageRep(data: png))
            #expect(CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh) == attachment.pixelSize)
        }
        #expect(found[0].attachment.pixelSize != found[1].attachment.pixelSize, "each occurrence has its own diagram")
        #expect(markdown.imageData(for: EmbedScanner.mermaidSource, occurrence: 2) == nil)
    }
}
