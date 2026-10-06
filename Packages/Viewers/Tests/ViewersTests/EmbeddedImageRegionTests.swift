import AppKit
import Core
import Foundation
import Testing
@testable import Viewers

/// Notes on part of a picture in rendered Markdown: each embed knows its picture and which embed of it it is, and a
/// region maps between the picture's pixels and wherever the picture is drawn, at any fitted width.
struct EmbeddedImageRegionTests {
    @Test func eachEmbedKnowsItsSourceOccurrenceAndPixels() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gloss-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 90, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "chart.png"))
        let source = "![a](chart.png)\n\nText.\n\n![b](chart.png)\n"
        let output = MarkdownRenderer.render(source, baseURL: folder)
        var found: [(String?, Int, CGSize)] = []
        output.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.text.length)) { value, _, _ in
            if let attachment = value as? FittedImageAttachment { found.append((attachment.source, attachment.occurrence, attachment.pixelSize)) }
        }
        #expect(found.count == 2)
        #expect(found.map(\.0) == ["chart.png", "chart.png"])
        #expect(found.map(\.1) == [0, 1], "the second embed of the same picture is occurrence 1")
        #expect(found.allSatisfy { $0.2 == CGSize(width: 160, height: 90) })
    }

    /// An `<img>` is an embed like `![]()`: the renderer and the re-anchorer count both in document order.
    @Test func htmlEmbedsKnowTheirSourceAndOccurrence() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gloss-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 90, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "chart.png"))
        let source = "![a](chart.png)\n\n<p align=\"center\">\n  <img src=\"chart.png\" width=\"80\">\n</p>\n\nInline <img src='chart.png' alt=b> too.\n"
        let output = MarkdownRenderer.render(source, baseURL: folder)
        var found: [(String?, Int, CGSize, Int)] = []
        output.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.text.length)) { value, range, _ in
            if let attachment = value as? FittedImageAttachment { found.append((attachment.source, attachment.occurrence, attachment.naturalSize, range.location)) }
        }
        #expect(found.map(\.0) == ["chart.png", "chart.png", "chart.png"])
        #expect(found.map(\.1) == [0, 1, 2])
        #expect(found[1].2 == CGSize(width: 80, height: 45), "width scales the picture, keeping its shape")
        for (_, occurrence, _, index) in found {
            let embed = try #require(output.map.sourceRange(forRendered: NSRange(location: index, length: 1))).source
            #expect((source as NSString).substring(with: embed).contains("chart.png"))
            #expect(ReAnchorer.embedOccurrence(of: "chart.png", before: embed.location, in: source) == occurrence)
        }
    }

    /// Every picture drawn gets its own occurrence, and the re-anchorer gives its embed the same one, whatever lies
    /// around it: comments, code, quoted `>`, a tag broken over lines, literal Markdown inside HTML.
    @Test func theRendererAndTheReAnchorerAgreeOnOccurrences() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gloss-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 9, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: "a.png"))
        let documents = [
            "<!-- <img src=\"a.png\"> -->\n\n![x](a.png)\n",
            "<p>\n<!-- <img src=\"a.png\"> -->\n<img src=\"a.png\">\n</p>\n\n![x](a.png)\n",
            "<table><tr><td><!-- <img src=\"a.png\"> --><img src=\"a.png\"></td></tr></table>\n\n![x](a.png)\n",
            "```html\n<img src=\"a.png\">\n![f](a.png)\n```\n\nUse `<img src=\"a.png\">` or `![y](a.png)`.\n\n![x](a.png)\n",
            "<img alt=\"a > b\" src=\"a.png\">\n\n![x](a.png)\n",
            "Text <img alt='a > b' src=a.png> inline.\n\n![x](a.png)\n",
            "<p>\n<img\n  src=\"a.png\"\n  alt=\"multi\">\n</p>\n\n![x](a.png)\n",
            "<div>\n![lit](a.png) <img src=\"a.png\">\n</div>\n\n![x](a.png)\n",
            "> <p>\n> <img src=\"a.png\">\n> </p>\n>\n> ![x](a.png)\n",
            "![r][pic] and ![pic]\n\n![x](a.png)\n\n[pic]: a.png\n",
            "Text.\n\n    ![code](a.png)\n\n![x](a.png)\n",
            "- item\n\n    ![in list](a.png)\n\n![x](a.png)\n",
            "<table><tr><td><img src=\"a.png\"></td><td><img src=\"a.png\" width=\"8\"></td></tr></table>\n\n![x](a.png)\n",
            "<ul>\n<li><img src=\"a.png\"></li>\n<li>![lit](a.png) <img src=\"a.png\"></li>\n</ul>\n\n![x](a.png)\n",
            "<blockquote><pre><img src=\"a.png\"></pre></blockquote>\n\n![x](a.png)\n",
        ]
        for source in documents {
            let output = MarkdownRenderer.render(source, baseURL: folder)
            var occurrences: [Int] = []
            output.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.text.length)) { value, range, _ in
                guard let attachment = value as? FittedImageAttachment,
                      let embed = output.map.sourceRange(forRendered: NSRange(location: range.location, length: 1))?.source else { return }
                let text = (source as NSString).substring(with: embed)
                #expect(text.hasPrefix("!") || text.hasPrefix("<img"), "embed \(text) in \(source)")
                #expect(ReAnchorer.embedOccurrence(of: "a.png", before: embed.location, in: source) == attachment.occurrence, "\(text) in \(source)")
                occurrences.append(attachment.occurrence)
            }
            // Distinct and in order; an `<img>` that is shown as source (in a table) still takes its number.
            #expect(!occurrences.isEmpty && occurrences == occurrences.sorted() && Set(occurrences).count == occurrences.count, "\(occurrences) in \(source)")
        }
    }

    @Test func regionsMapBetweenPixelsAndTheFittedFrame() {
        let pixels = CGSize(width: 1600, height: 900)
        let region = CGRect(x: 400, y: 300, width: 800, height: 300)
        for width in [400.0, 760, 1600] {
            let frame = CGRect(x: 20, y: 100, width: width, height: width * 900 / 1600)
            let onScreen = MarkdownViewerController.viewRect(forPixels: region, pixelSize: pixels, in: frame)
            #expect(abs(onScreen.minX - (20 + width / 4)) < 0.01, "at \(width)")
            #expect(abs(onScreen.width - width / 2) < 0.01, "at \(width)")
            let back = MarkdownViewerController.pixels(forViewRect: onScreen, pixelSize: pixels, in: frame)
            #expect(abs(back.minX - region.minX) <= 1 && abs(back.minY - region.minY) <= 1, "at \(width): \(back)")
            #expect(abs(back.width - region.width) <= 1 && abs(back.height - region.height) <= 1, "at \(width): \(back)")
        }
        // A drag that runs off the picture is clipped to it; one that misses it is nothing.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 225)
        #expect(MarkdownViewerController.pixels(forViewRect: CGRect(x: 300, y: 100, width: 300, height: 300), pixelSize: pixels, in: frame)
                == CGRect(x: 1200, y: 400, width: 400, height: 500))
        #expect(MarkdownViewerController.pixels(forViewRect: CGRect(x: 500, y: 0, width: 10, height: 10), pixelSize: pixels, in: frame) == .zero)
    }
}
