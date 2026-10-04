import AppKit
import Testing
@testable import Viewers

struct CodeBlockLabelTests {
    @Test func fencesAreNamedAsPeopleNameTheirLanguages() {
        #expect(MarkdownBlockDecoration.languageName("swift") == "Swift")
        #expect(MarkdownBlockDecoration.languageName("py") == "Python")
        #expect(MarkdownBlockDecoration.languageName("bash") == "Shell")
        #expect(MarkdownBlockDecoration.languageName("ts {title=x}") == "TypeScript", "only the first word of the info string")
        #expect(MarkdownBlockDecoration.languageName("elixir") == "elixir", "unknown names as written")
        #expect(MarkdownBlockDecoration.languageName("") == nil)
        #expect(MarkdownBlockDecoration.languageName(nil) == nil)
    }

    @Test func aFencedBlockCarriesItsLabelAndABareOneDoesNot() {
        let output = MarkdownRenderer.render("```swift\nlet x = 1\n```\n\n```\nplain\n```\n")
        var labels: [String?] = []
        output.text.enumerateAttribute(MarkdownRenderer.blockKey, in: NSRange(location: 0, length: output.text.length)) { value, _, _ in
            if let decoration = value as? MarkdownBlockDecoration, decoration.kind == .codeBlock { labels.append(decoration.label) }
        }
        #expect(labels == ["Swift", nil])
    }
}

struct MarkdownImageTests {
    @Test func photosGetSoftCornersAndIconsBarelyAny() {
        #expect(FittedImageAttachment.cornerRadius(for: CGSize(width: 600, height: 400)) == 8)
        #expect(FittedImageAttachment.cornerRadius(for: CGSize(width: 24, height: 24)) == 3)
        #expect(FittedImageAttachment.cornerRadius(for: CGSize(width: 6, height: 6)) == 0)
    }

    @Test func theImageIsDrawnAtItsLaidOutSize() throws {
        let attachment = FittedImageAttachment()
        attachment.image = NSImage(size: CGSize(width: 800, height: 600), flipped: false) { rect in
            NSColor.systemGreen.setFill(); rect.fill(); return true
        }
        let container = NSTextContainer(size: CGSize(width: 400, height: 1000))
        let content = NSTextContentStorage()
        content.attributedString = NSAttributedString(string: "\u{FFFC}")
        let drawn = try #require(attachment.image(for: CGRect(x: 0, y: 0, width: 400, height: 300), attributes: [:],
                                                  location: content.documentRange.location, textContainer: container))
        #expect(drawn.size == CGSize(width: 400, height: 300))
    }
}

struct ImageCanvasTests {
    private func image(alpha: CGImageAlphaInfo) -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue)!
        return context.makeImage()!
    }

    @Test func onlyPicturesWithTransparencyGetTheCheckerboard() {
        #expect(ImageCanvasView.hasAlpha(image(alpha: .premultipliedLast)))
        #expect(!ImageCanvasView.hasAlpha(image(alpha: .noneSkipLast)))
    }
}

@MainActor
struct SnippetHighlightingTests {
    @Test func aQuotedLineKeepsTheEditorsColours() throws {
        let coloured = try #require(SyntaxTheme.highlighted("let climb: Int = 40", language: "swift"))
        #expect(String(coloured.characters) == "let climb: Int = 40", "colour only, never different text")
        let tinted = coloured.runs.filter { $0.appKit.foregroundColor != nil }
        #expect(!tinted.isEmpty)
    }

    @Test func proseAndUnknownLanguagesStayPlain() {
        #expect(SyntaxTheme.highlighted("Tighten this wording", language: nil) == nil)
        #expect(SyntaxTheme.highlighted("x", language: "no-such-language") == nil)
    }
}
