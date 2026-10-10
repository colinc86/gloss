import AppKit
import Core
import PDFKit
import Testing
@testable import Viewers

/// Add Note heads each viewer's context menu while what is selected takes a note, as it does on text.
@MainActor
struct AddNoteMenuTests {
    private let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!

    private func hook(_ can: Bool, _ added: @escaping () -> Void = {}) -> AddNoteHook { AddNoteHook(canAdd: { can }, add: added) }

    @Test func aPictureOffersAddNoteOnItsRegion() {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = ImageViewerController(image: DecodedImage(cgImage: context.makeImage()!, hash: "h"))
        let canvas = ImageCanvasView(controller: controller)
        var added = 0
        controller.addNote = hook(true) { added += 1 }
        let menu = canvas.menu(for: event)
        #expect(menu?.items.first?.title == "Add Note")
        canvas.addNoteFromMenu(nil)
        #expect(added == 1)
        controller.addNote = hook(false)
        #expect(canvas.menu(for: event)?.items.map(\.title) == ["Copy Image"], "nothing selected: Copy only")
    }

    @Test func theGridOffersAddNoteOnItsSelection() {
        let controller = CSVGridController(text: "a,b\n1,2\n", fileName: "x.csv")
        let table = CSVTableView()
        let coordinator = CSVGridView.Coordinator(controller: controller)
        table.coordinator = coordinator
        controller.addNote = hook(true)
        #expect(table.menu(for: event) == nil, "nothing selected, no menu")
        controller.click(GridCell(row: 0, column: 1), extend: false, toggle: false)
        #expect(table.menu(for: event)?.items.first?.title == "Add Note")
    }

    @Test func aPDFOffersAddNoteOnItsSelection() {
        let controller = PDFViewerController(document: PDFDocument())
        let view = RegionCopyingPDFView()
        view.regionController = controller
        controller.addNote = hook(true)
        #expect(view.menu(for: event)?.items.first?.title == "Add Note")
        controller.addNote = hook(false)
        #expect(view.menu(for: event)?.items.contains { $0.title == "Add Note" } != true)
    }

    /// A region chosen on a picture in rendered Markdown selects no text, but takes a note: the menu offers it.
    @Test func aRenderedPicturesRegionOffersAddNote() {
        let source = TextEditorController(text: "![chart](chart.png)\n", languageName: "markdown")
        source.onAddNote = {}
        let controller = MarkdownViewerController(source: source)
        let textView = RenderedTextView(usingTextLayoutManager: true)
        textView.controller = controller
        // No text to select (a right-click selects the word under the pointer), only the picture.
        #expect(textView.menu(for: event)?.items.contains { $0.title == "Add Note" } != true, "nothing chosen")
        controller.imageSelection = .init(image: .init(source: "chart.png", occurrence: 0), region: CGRect(x: 0, y: 0, width: 10, height: 10),
                                          pixelSize: CGSize(width: 100, height: 100), embedSource: NSRange(location: 0, length: 19))
        #expect(textView.menu(for: event)?.items.first?.title == "Add Note")
    }
}
