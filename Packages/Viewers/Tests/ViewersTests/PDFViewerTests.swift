import AppKit
import Core
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import Viewers

struct PDFViewerTests {
    /// Two-page PDF with a line of text on each page.
    func makePDF() -> PDFDocument {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for text in ["Section 4 is here", "Appendix B"] {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)!
    }

    @Test func aTextNoteIsOnTheMatchItWasMadeOn() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Revenue rose, then Revenue fell",
                                                                       attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let controller = PDFViewerController(document: try #require(PDFDocument(data: data as Data)))
        let first = try #require(controller.textBounds(page: 0, text: "Revenue", occurrence: 0))
        let second = try #require(controller.textBounds(page: 0, text: "Revenue", occurrence: 1))
        #expect(second.minX > first.maxX, "the second match is further along the line")
        #expect(controller.textBounds(page: 0, text: "Revenue", occurrence: 5) == first, "past the last match, the first, as re-anchoring falls back")

        controller.textSelection = (0, second, "Revenue")
        #expect(controller.noteAnchor?.occurrence == 1, "noting the second match notes that one")
        #expect(controller.noteAnchor?.textTop == Double(second.maxY), "and where its text is on the page")
        #expect(controller.selectionAnchor?.occurrence == nil, "the selection itself is not searched for while it is dragged")
        controller.textSelection = (0, first, "Revenue")
        #expect(controller.noteAnchor?.occurrence == nil, "the first is stored as notes always were")

        let highlight = PDFHighlight(id: NoteID(rawValue: "n_1"), page: 0, bounds: nil, text: "Revenue", occurrence: 1, color: .blue, state: .draft)
        let page = try #require(controller.document.page(at: 0))
        #expect(controller.selection(matching: "Revenue", onPage: 0, occurrence: highlight.occurrence)?.bounds(for: page) == second)
    }

    /// Edit › Find in a PDF: PDFView takes no find actions, so the viewer answers them with its own bar.
    @Test @MainActor func findStepsThroughMatchesAndWraps() async throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for text in ["Revenue rose, then Revenue fell", "No figures here", "Revenue held"] {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]))
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let controller = PDFViewerController(document: try #require(PDFDocument(data: data as Data)))
        let view = RegionCopyingPDFView()
        view.document = controller.document
        view.regionController = controller
        let item = NSMenuItem(title: "", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        #expect(view.validateMenuItem(item), "Edit › Find is offered on a PDF")
        view.performTextFinderAction(item)
        #expect(controller.isFinding)

        controller.findText = "revenue"
        func step(backwards: Bool = false) async -> (page: Int, x: CGFloat)? {
            await controller.find(backwards: backwards)
            guard let found = controller.foundSelection, let page = found.pages.first else { return nil }
            return (controller.document.index(for: page), found.bounds(for: page).minX)
        }
        let first = try #require(await step())
        let second = try #require(await step())
        let third = try #require(await step())
        let wrapped = try #require(await step())
        #expect(first.page == 0 && second.page == 0 && second.x > first.x, "both matches on the first page, in order")
        #expect(third.page == 2, "the page without one is passed over")
        #expect(wrapped.page == first.page && wrapped.x == first.x, "past the last match it wraps to the first")
        let back = try #require(await step(backwards: true))
        #expect(back.page == 2, "back from the first goes round to the last")
        #expect(!controller.findMissed)
        #expect(controller.foundVersion == 5)

        controller.findText = "nowhere"
        await controller.find(backwards: false)
        #expect(controller.findMissed)
        controller.endFind()
        #expect(!controller.isFinding && !controller.findMissed)
    }

    /// A PDF zooms as a picture does: ⌘=, ⌘−, ⌘1 and ⌘0, and the toolbar shows the scale.
    @Test @MainActor func zoomCommandsScaleTheDocument() async throws {
        let controller = PDFViewerController(document: makePDF())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: PDFViewerView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let pdfView = try #require(find(RegionCopyingPDFView.self, in: hosting))
        // Each command waits until the view has applied it (a fixed wait was too short under a full run).
        func apply(_ command: ImageViewerController.ZoomCommand, until applied: () -> Bool) async throws {
            controller.zoom(command)
            for _ in 0..<100 where !applied() { try await Task.sleep(for: .milliseconds(20)) }
        }
        try await apply(.actualSize) { !pdfView.autoScales && abs(pdfView.scaleFactor - 1) < 0.001 }
        #expect(!pdfView.autoScales && abs(pdfView.scaleFactor - 1) < 0.001)
        #expect(abs(controller.magnification - 1) < 0.001, "the toolbar reads 100%")
        try await apply(.zoomIn) { pdfView.scaleFactor > 1 }
        #expect(pdfView.scaleFactor > 1 && abs(controller.magnification - pdfView.scaleFactor) < 0.001)
        let zoomedIn = pdfView.scaleFactor
        try await apply(.zoomOut) { pdfView.scaleFactor < zoomedIn }
        try await apply(.zoomOut) { pdfView.scaleFactor < 1 }
        #expect(pdfView.scaleFactor < 1)
        try await apply(.fit) { pdfView.autoScales }
        #expect(pdfView.autoScales)
    }

    @Test func textSourceFindsTextAcrossPages() {
        let source = PDFDocumentTextSource(document: makePDF())
        #expect(source.pageCount == 2)
        #expect(source.text(ofPage: 0)?.contains("Section 4") == true)
        let hits = source.find("Appendix B")
        #expect(hits.map(\.page) == [1])
        #expect(hits.first!.bounds.w > 0)
    }

    @Test func rendersRegionAtTwoX() throws {
        let controller = PDFViewerController(document: makePDF())
        let page = controller.document.page(at: 0)!
        let region = CGRect(x: 10, y: 80, width: 150, height: 50)
        let rendered = try #require(controller.renderPNG(page: 0, bounds: region))
        #expect(rendered.width == 300 && rendered.height == 100)
        let image = NSBitmapImageRep(data: rendered.data)!
        var dark = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: image.pixelsWide, by: 2) where (image.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 { dark += 1 }
        }
        #expect(dark > 20, "the rendered region should contain the text's dark pixels")
        let whole = try #require(controller.renderPNG(page: 1, bounds: nil))
        #expect(whole.width == 600 && whole.height == 400)
        page.rotation = 90
        let rotated = try #require(controller.renderPNG(page: 0, bounds: nil))
        #expect(rotated.width == 400 && rotated.height == 600, "a rotated page renders with swapped dimensions")
    }

    @Test func selectionAnchorPrefersRegion() {
        let controller = PDFViewerController(document: makePDF())
        controller.textSelection = (1, CGRect(x: 1, y: 2, width: 3, height: 4), "Appendix B")
        var anchor = controller.selectionAnchor!
        #expect(anchor.page == 1 && anchor.bounds == nil && anchor.text == "Appendix B" && anchor.pageCount == 2)
        controller.region = (0, CGRect(x: 10, y: 80, width: 150, height: 50))
        anchor = controller.selectionAnchor!
        #expect(anchor.page == 0)
        #expect(anchor.bounds?.w == 150)
        #expect(anchor.text?.contains("Section 4") == true, "the region's text comes along when it covers text")
        controller.clearSelection()
        #expect(controller.selectionAnchor == nil)
    }

    @Test func reanchorsThroughTheDocumentSource() {
        let document = makePDF()
        let anchor = PDFAnchor(page: 0, bounds: nil, text: "Appendix B", pageCount: 2)
        guard case .moved(.pdf(let moved)) = ReAnchorer.pdf(anchor, in: PDFDocumentTextSource(document: document)) else {
            Issue.record("expected the text to be found on page 2"); return
        }
        #expect(moved.page == 1)
    }
}
