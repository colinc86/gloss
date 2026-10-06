import AppKit
import Core
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Viewers

/// Animated pictures in rendered Markdown play, hold still under Reduce Motion, and a `<picture>` draws its
/// reduced-motion source then, numbered as the re-anchorer numbers it.
struct AnimatedPictureTests {
    /// A small picture of `frames` frames, as a GIF or a PNG (an APNG when more than one).
    static func picture(_ type: UTType, frames: Int, sizes: [CGSize]? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
        for index in 0..<frames {
            let size = sizes?[index] ?? CGSize(width: 40, height: 20)
            let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(frames), green: 0.4, blue: 0.2, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let properties: [CFString: Any] = type == .tiff ? [:] : type == .gif ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
                                                           : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]]
            CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gloss-anim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "media"), withIntermediateDirectories: true)
        try picture(.gif, frames: 3).write(to: folder.appending(path: "media/hero.gif"))
        try picture(.png, frames: 3).write(to: folder.appending(path: "media/moving.png"))
        try picture(.png, frames: 1).write(to: folder.appending(path: "media/hero.png"))
        return folder
    }

    static func attachments(_ output: MarkdownRenderer.Output) -> [(attachment: FittedImageAttachment, index: Int)] {
        var found: [(FittedImageAttachment, Int)] = []
        output.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.text.length)) { value, range, _ in
            if let attachment = value as? FittedImageAttachment { found.append((attachment, range.location)) }
        }
        return found
    }

    @Test func animatedPicturesPlayUnlessMotionIsReduced() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = "![gif](media/hero.gif) <img src=\"media/moving.png\"> ![still](media/hero.png)\n"
        let moving = Self.attachments(MarkdownRenderer.render(source, baseURL: folder)).map(\.attachment)
        #expect(moving.map(\.isAnimated) == [true, true, false], "GIF and APNG are animated; a still PNG is not")
        #expect(moving.map(\.plays) == [true, true, false])
        let still = Self.attachments(MarkdownRenderer.render(source, baseURL: folder, reduceMotion: true)).map(\.attachment)
        #expect(still.map(\.isAnimated) == [true, true, false] && still.allSatisfy { !$0.plays })
    }

    @Test func aPictureDrawsItsReducedMotionSourceOnlyWhenAsked() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let block = """
        <p align="center">
          <picture>
            <source media="(prefers-reduced-motion: reduce)" srcset="media/hero.png">
            <img src="media/hero.gif" width="80" alt="The app at work">
          </picture>
        </p>

        Inline: <picture><source media="(prefers-reduced-motion: reduce)" srcset="media/hero.png 1x"><img src="media/hero.gif"></picture>

        <picture><source media="(prefers-color-scheme: dark)" srcset="media/hero.png"><img src="media/hero.gif"></picture>

        ![again](media/hero.png) ![and](media/hero.gif)
        """
        for reduceMotion in [false, true] {
            let output = MarkdownRenderer.render(block, baseURL: folder, reduceMotion: reduceMotion)
            let found = Self.attachments(output)
            let expected = reduceMotion ? ["media/hero.png", "media/hero.png", "media/hero.gif", "media/hero.png", "media/hero.gif"]
                                        : ["media/hero.gif", "media/hero.gif", "media/hero.gif", "media/hero.png", "media/hero.gif"]
            #expect(found.map(\.attachment.source) == expected, "reduce motion \(reduceMotion)")
            #expect(found[0].attachment.naturalSize.width == 80, "the img's size applies to the chosen source")
            for (attachment, index) in found {
                let embed = try #require(output.map.sourceRange(forRendered: NSRange(location: index, length: 1))).source
                let text = (block as NSString).substring(with: embed)
                let source = try #require(attachment.source)
                #expect(text.contains(source) && (text.hasPrefix("<img") || text.hasPrefix("<source") || text.hasPrefix("!")), "\(text)")
                #expect(ReAnchorer.embedOccurrence(of: source, before: embed.location, in: block) == attachment.occurrence, "\(text), reduce motion \(reduceMotion)")
            }
        }
    }

    @Test func mediaQueriesFollowReduceMotionOnly() {
        #expect(MarkdownHTML.mediaMatches(nil, reduceMotion: false) && MarkdownHTML.mediaMatches("screen", reduceMotion: true))
        #expect(MarkdownHTML.mediaMatches("( prefers-reduced-motion : reduce )", reduceMotion: true))
        #expect(!MarkdownHTML.mediaMatches("(prefers-reduced-motion: reduce)", reduceMotion: false))
        #expect(MarkdownHTML.mediaMatches("(prefers-reduced-motion: no-preference)", reduceMotion: false))
        #expect(!MarkdownHTML.mediaMatches("(prefers-color-scheme: dark)", reduceMotion: false))
    }

    /// The rendered view lays a playing image view over the picture's frame, under the notes overlay, and clicks
    /// still reach the text view.
    @Test func aPlayingViewLiesOverThePicture() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = MarkdownRenderer.render("Intro.\n\n![gif](media/hero.gif)\n", baseURL: folder)
        let textView = RenderedTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.textLayoutManager?.delegate = MarkdownLayoutDelegate()
        textView.textStorage?.setAttributedString(output.text)
        let pictures = AnimatedPicturesView(frame: textView.bounds)
        pictures.textView = textView
        textView.addSubview(pictures)
        pictures.textChanged()
        let index = try #require(Self.attachments(output).first?.index)
        let attachment = try #require(Self.attachments(output).first?.attachment)
        let expected = RenderedTextView.pictureFrame(try #require(textView.frame(ofCharacterAt: index)), attachment: attachment)
        let playing = pictures.subviews.compactMap { $0 as? PlayingPictureView }
        #expect(playing.count == 1 && playing.first?.frame == expected, "\(playing.map(\.frame)) vs \(expected)")
        #expect(pictures.hitTest(NSPoint(x: expected.midX, y: expected.midY)) == nil)
        #expect(textView.picture(at: NSPoint(x: expected.midX, y: expected.midY))?.index == index, "hit-testing still finds the picture")
    }

    /// Every image in a file is measured, not just the first; a file of several pages shows (and crops) its first.
    @Test func everyPageAndFrameIsMeasured() throws {
        let pages = Self.picture(.tiff, frames: 2, sizes: [CGSize(width: 2, height: 2), CGSize(width: 20, height: 20)])
        #expect(ImageDecoder.checkedImage(pages, maximumPixels: 100) == nil, "a big second page is refused")
        let image = try #require(ImageDecoder.checkedImage(pages))
        #expect(FittedImageAttachment.pixelSize(of: image) == CGSize(width: 2, height: 2), "the first page, as a crop is cut from it")
        #expect(try ImageDecoder.decode(pages, fileName: "pages.tiff").cgImage.width == 2)
        let gif = try #require(ImageDecoder.checkedImage(Self.picture(.gif, frames: 3)))
        #expect(FittedImageAttachment.isAnimated(gif), "an animation keeps its frames")
        let endless = Self.picture(.gif, frames: ImageDecoder.maximumFrames + 1, sizes: Array(repeating: CGSize(width: 1, height: 1), count: ImageDecoder.maximumFrames + 1))
        #expect(ImageDecoder.checkedImage(endless) == nil, "too many frames")
        let heavy = Self.picture(.gif, frames: 5, sizes: Array(repeating: CGSize(width: 10, height: 10), count: 5))
        #expect(ImageDecoder.checkedImage(heavy, maximumPixels: 100) == nil && ImageDecoder.checkedImage(heavy, maximumPixels: 200) != nil,
                "frames all told stay within the budget")
    }

    /// An embed's own width and height size the playing view and the picture's frame, as they size the attachment.
    @Test func aPlayingPictureTakesItsEmbedsSize() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.picture(.gif, frames: 3, sizes: Array(repeating: CGSize(width: 80, height: 60), count: 3)).write(to: folder.appending(path: "media/demo.gif"))
        let output = MarkdownRenderer.render("<img src=\"media/demo.gif\" width=\"40\" height=\"10\">\n\nNext line.\n", baseURL: folder)
        let textView = RenderedTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.textStorage?.setAttributedString(output.text)
        let pictures = AnimatedPicturesView(frame: textView.bounds)
        pictures.textView = textView
        textView.addSubview(pictures)
        pictures.textChanged()
        let playing = try #require(pictures.subviews.compactMap { $0 as? PlayingPictureView }.first)
        #expect(playing.frame.size == CGSize(width: 40, height: 10), "\(playing.frame)")
        let ref = MarkdownViewerController.EmbeddedImageRef(source: "media/demo.gif", occurrence: 0)
        #expect(textView.frame(of: ref)?.size == CGSize(width: 40, height: 10), "region notes are placed on the same frame")
    }
}
