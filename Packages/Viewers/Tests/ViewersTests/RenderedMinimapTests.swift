import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

struct RenderedMinimapTests {
    @Test func aShortPageSitsAtTheTopWithNoSlider() {
        let layout = MinimapView.PageLayout(contentHeight: 120, viewHeight: 600, visible: nil)
        #expect(layout.offset == 0)
        #expect(layout.slider == nil)
        #expect(layout.contentY(atViewY: 500) == 120, "a click below the page lands at its end")
    }

    /// The slider sits exactly over the part on screen wherever the page is scrolled to.
    @Test func theSliderCoversTheVisibleSpan() {
        for top: CGFloat in [0, 700, 1400] {
            let layout = MinimapView.PageLayout(contentHeight: 1500, viewHeight: 500, visible: top...(top + 100))
            let slider = try! #require(layout.slider)
            #expect(abs(slider.y - (top - layout.offset)) < 0.001)
            #expect(slider.height == 100)
            #expect(abs(layout.spanTop(forFraction: layout.fraction) - top) < 0.001)
            #expect(abs(layout.contentY(atViewY: slider.y) - top) < 0.001)
        }
        #expect(MinimapView.PageLayout(contentHeight: 1500, viewHeight: 500, visible: 1400...1500).offset == 1000)
    }

    @MainActor
    @Test func thePageIsLaidOutWholeWithItsBlocks() throws {
        var source = "# Title\n\nFirst paragraph.\n\nSecond paragraph, with a note.\n\n```swift\nlet x = 1\n```\n\n"
        for index in 1...40 { source += "Paragraph \(index) of filler.\n\n" }
        let text = MarkdownRenderer.render(source).text
        let page = RenderedPage(text: text, key: .init(version: 0, width: 600, appearance: .aqua, backingScale: 2), thumbnailWidth: 92,
                                appearance: NSAppearance(named: .aqua)!)
        // Laid out to the end, not just near a viewport.
        let last = try #require(page.lineSpan(at: text.length - 1))
        #expect(last.upperBound > 1000 && abs(page.height - last.upperBound) < 40)
        let starts = ["First", "Second", "Paragraph 20", "Paragraph 40"].map { (text.string as NSString).range(of: $0).location }
        let tops = starts.map { page.lineSpan(at: $0)?.lowerBound ?? -1 }
        #expect(tops == tops.sorted() && Set(tops).count == tops.count, "further down the text is further down the page")
        #expect(page.characterIndex(atY: tops[2] + 1) == starts[2])
        #expect(!page.rects(for: NSRange(location: starts[1], length: 6)).isEmpty)

        let picture = try #require(page.picture)
        #expect(picture.size.width == 92 && abs(picture.size.height - page.height * 92 / 600) < 1)
        // Pixel rows of the picture covering a span of the page.
        func rows(_ span: ClosedRange<CGFloat>) -> ClosedRange<Int> {
            let perPoint = CGFloat(picture.pixelsHigh) / page.height
            return Int(span.lowerBound * perPoint)...min(picture.pixelsHigh - 1, Int(span.upperBound * perPoint))
        }
        func inked(_ row: Int, above alpha: CGFloat) -> Int {
            (0..<picture.pixelsWide).filter { (picture.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > alpha }.count
        }
        let first = try #require(page.lineSpan(at: starts[0]))
        #expect(rows(first).contains { inked($0, above: 0.3) > 0 }, "the text is drawn")
        // The code block's border runs across the column, far past its one short line of code.
        let code = try #require(page.lineSpan(at: (text.string as NSString).range(of: "let x").location))
        #expect(rows((code.lowerBound - 12)...(code.upperBound + 12)).contains { inked($0, above: 0.02) > picture.pixelsWide * 3 / 4 },
                "code-block chrome is drawn")
    }

    @MainActor
    @Test func theRenderedViewHasAMinimap() async throws {
        var markdown = ""
        for index in 1...60 { markdown += "Paragraph \(index).\n\n" }
        let controller = MarkdownViewerController(source: TextEditorController(text: markdown, languageName: "markdown"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MarkdownViewerView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let minimap = try #require(find(RenderedMinimapView.self, in: hosting))
        #expect(minimap.frame.width == MinimapView.width && !minimap.isHidden)
        // The first page is built on the next turn, out of drawing: a suspension lets that task run (a run loop
        // nested in this main-actor test never did, and the check below passed on the separator alone).
        // Waits for it, up to a few seconds: under a full test run the turn can come late.
        func drawn() throws -> Bool {
            minimap.display()
            let rep = try #require(minimap.bitmapImageRepForCachingDisplay(in: minimap.bounds))
            minimap.cacheDisplay(in: minimap.bounds, to: rep)
            let background = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 2)
            // Right of the separator hairline at the left edge.
            let firstColumn = Int(2 * CGFloat(rep.pixelsWide) / minimap.bounds.width)
            return (0..<rep.pixelsHigh / 2).contains { y in (firstColumn..<rep.pixelsWide).contains { rep.colorAt(x: $0, y: y) != background } }
        }
        var differs = false
        for _ in 0..<30 where !differs {
            try await Task.sleep(for: .milliseconds(100))
            differs = try drawn()
        }
        #expect(differs, "the page is drawn in it")
    }
}
