import AppKit
import Core
import Foundation
import PDFKit
import Testing
@testable import Viewers

/// The review card's windows onto rendered documents: the right size, drawn (not blank), the anchor inside. With
/// `GLOSS_EXCERPT_OUT=<folder>` each one is also written as a PNG there, to be looked at.
@MainActor struct ExcerptRendererTests {
    private let window = ExcerptRenderer.Window(width: 400, height: 160, scale: 2)
    private let tint = NSColor.systemYellow
    private let light = NSAppearance(named: .aqua)!

    private func keep(_ image: CGImage, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["GLOSS_EXCERPT_OUT"], let png = ImageDecoder.pngData(image) else { return }
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    /// Distinct colors in the bitmap: a blank window has one, a drawn one many.
    private func colorCount(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var seen = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4 * 7) {
            seen.insert(UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]))
        }
        return seen.count
    }

    @Test func aMarkdownWindowIsDrawnAroundTheAnchor() throws {
        var lines = ["# Title", "", "Intro paragraph that says little.", "", "```swift", "let x = 1", "```", ""]
        for n in 1...30 { lines.append("Paragraph \(n) with enough words to make a line of text in the page."); lines.append("") }
        lines += ["| a | b |", "|---|---|", "| 1 | 2 |", "", "The end."]
        let source = lines.joined(separator: "\n")
        let anchorLine = lines.firstIndex(of: "Paragraph 20 with enough words to make a line of text in the page.")! + 1
        let anchor = TextAnchor(start: .init(line: anchorLine, col: 1), end: .init(line: anchorLine, col: 13), text: "Paragraph 20", before: "", after: "")
        let image = try #require(ExcerptRenderer.markdown(source, anchor: anchor, baseURL: nil, window: window, tint: tint, appearance: light))
        keep(image, "markdown")
        #expect(image.width == 800 && image.height == 320)
        #expect(colorCount(image) > 8, "text, the tint and the page's background")
    }

    @Test func aMarkdownWindowAtTheTopKeepsItsMargin() throws {
        let anchor = TextAnchor(start: .init(line: 1, col: 1), end: .init(line: 1, col: 8), text: "# Title", before: "", after: "")
        let image = try #require(ExcerptRenderer.markdown("# Title\n\nBody.", anchor: anchor, baseURL: nil, window: window, tint: tint, appearance: light))
        keep(image, "markdown-top")
        #expect(ExcerptRenderer.windowTop(focus: CGRect(x: 0, y: 0, width: 100, height: 20), contentHeight: 60, window: window) == -ExcerptRenderer.margin)
        #expect(colorCount(image) > 4)
    }

    @Test func aPDFWindowCentersOnTheBounds() throws {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 300, height: 600)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        for (index, text) in ["Top of the page", "Middle of the page", "Bottom of the page"].enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 20, y: 560 - CGFloat(index) * 250)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(data: data as Data))
        let image = try #require(ExcerptRenderer.pdf(document, page: 0, bounds: CGRect(x: 20, y: 300, width: 160, height: 24), window: window, tint: tint))
        keep(image, "pdf")
        #expect(image.width == 800 && image.height == 320)
        #expect(colorCount(image) > 4)
        let top = try #require(ExcerptRenderer.pdf(document, page: 0, bounds: nil, window: window, tint: tint))
        keep(top, "pdf-top")
        #expect(colorCount(top) > 2, "no bounds: the page's top")
    }

    @Test func aPictureWindowIsNeverEnlarged() throws {
        let size = 1200
        guard let context = CGContext(data: nil, width: size, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for x in stride(from: 0, to: size, by: 40) {
            context.setFillColor(CGColor(red: CGFloat(x) / CGFloat(size), green: 0.4, blue: 1 - CGFloat(x) / CGFloat(size), alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 40, height: 400))
        }
        let stripes = try #require(context.makeImage())
        let picture = DecodedImage(cgImage: stripes, hash: "h")
        let image = try #require(ExcerptRenderer.image(picture, region: CGRect(x: 600, y: 100, width: 60, height: 40), window: window, tint: tint, appearance: light))
        keep(image, "image")
        #expect(image.width == 800 && image.height == 320)
        #expect(colorCount(image) > 6, "a run of stripes around the region")
        let wide = try #require(ExcerptRenderer.image(picture, region: CGRect(x: 0, y: 0, width: 1200, height: 400), window: window, tint: tint, appearance: light))
        keep(wide, "image-wide")
        #expect(colorCount(wide) > 6, "a region wider than the window zooms out")
    }

    @Test func aWebWindowOutlinesTheElementInTheCapture() throws {
        guard let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let capture = try #require(context.makeImage())
        let png = try #require(ImageDecoder.pngData(capture))
        let captured = ElementRect(x: 100, y: 50, w: 200, h: 100)
        let image = try #require(ExcerptRenderer.web(snapshot: png, captured: captured, element: ElementRect(x: 150, y: 70, w: 50, h: 20), tint: tint))
        keep(image, "web")
        #expect(image.width == 400 && image.height == 200)
        #expect(colorCount(image) >= 2, "the outline on a blank capture")
        let rect = ExcerptRenderer.captureRect(around: ElementRect(x: 500, y: 900, w: 40, h: 10), window: window)
        #expect(rect.w == 400 && rect.h == 160 && rect.x == 320 && rect.y == 825)
    }
}
