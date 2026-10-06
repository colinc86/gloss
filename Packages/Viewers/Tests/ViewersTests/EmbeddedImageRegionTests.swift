import AppKit
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
