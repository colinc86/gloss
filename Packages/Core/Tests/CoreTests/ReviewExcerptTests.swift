import Foundation
import Testing
@testable import Core

/// The lines the review card shows for an anchor: the selection marked, the anchor's context lines around it.
struct ReviewExcerptTests {
    private func text(line: Int, _ selected: String, before: String = "", after: String = "") -> TextAnchor {
        let count = selected.components(separatedBy: "\n").count
        return TextAnchor(start: .init(line: line, col: 1), end: .init(line: line + count - 1, col: 5), text: selected, before: before, after: after)
    }

    @Test func aTextAnchorNumbersItsContextAroundTheSelection() throws {
        let excerpt = try #require(ReviewExcerpt.make(from: .text(text(line: 10, "sel a\nsel b", before: "b1\nb2\nb3", after: "a1\na2"))))
        #expect(excerpt.lines.map(\.number) == [7, 8, 9, 10, 11, 12, 13])
        #expect(excerpt.lines.map(\.selected) == [false, false, false, true, true, false, false])
        #expect(excerpt.lines.map(\.text) == ["b1", "b2", "b3", "sel a", "sel b", "a1", "a2"])
    }

    @Test func emptyContextAddsNoLines() throws {
        let excerpt = try #require(ReviewExcerpt.make(from: .text(text(line: 1, "only"))))
        #expect(excerpt.lines == [ReviewExcerpt.Line(number: 1, text: "only", selected: true)])
    }

    @Test func anElementShowsItsTextWithoutLineNumbers() throws {
        let element = ElementAnchor(selector: "#h", tag: "h1", text: "Hello", html: "<h1>Hello</h1>", rect: ElementRect(x: 0, y: 0, w: 1, h: 1))
        let excerpt = try #require(ReviewExcerpt.make(from: .element(element)))
        #expect(excerpt.lines == [ReviewExcerpt.Line(number: nil, text: "Hello", selected: true)])
    }

    @Test func anEmbeddedImageUsesItsEmbedLine() throws {
        let embed = text(line: 4, "![a](a.png)", before: "p", after: "q")
        let region = ImageAnchor(x: 0, y: 0, w: 1, h: 1, imageW: 1, imageH: 1)
        let excerpt = try #require(ReviewExcerpt.make(from: .embeddedImage(EmbeddedImageAnchor(source: "a.png", occurrence: 0, region: region, embed: embed))))
        #expect(excerpt.lines.map(\.number) == [3, 4, 5])
        #expect(excerpt.lines[1].selected)
    }

    @Test func picturesAndWholeFilesHaveNoLines() {
        #expect(ReviewExcerpt.make(from: .wholeFile) == nil)
        #expect(ReviewExcerpt.make(from: .image(ImageAnchor(x: 0, y: 0, w: 1, h: 1, imageW: 1, imageH: 1))) == nil)
    }
}
