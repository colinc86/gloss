import AppKit
import Core
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import Viewers
@testable import Gloss

@MainActor
struct MediaNotesTests {
    func makeDirectory() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-media-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    func makeSession(path: String) throws -> (DocumentSession, NoteStore) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let attachments = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent).appendingPathComponent("attachments")
        return (DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store, attachmentDirectory: attachments), store)
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func imageNoteStoresRegionAndCrop() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let png = try #require(ImageDecoder.pngData(context.makeImage()!))
        let path = "\(directory)/shot.png"
        try png.write(to: URL(fileURLWithPath: path))
        let (session, store) = try makeSession(path: path)
        await session.open()
        let image = try #require(session.imageController)
        #expect(image.image.width == 40 && image.image.height == 30)
        image.selection = CGRect(x: 5, y: 6, width: 10, height: 8)
        session.beginNote()
        var editor = try #require(session.noteEditor)
        guard case .image(let anchor) = editor.anchor else { Issue.record("expected image anchor"); return }
        #expect(anchor.x == 5 && anchor.y == 6 && anchor.w == 10 && anchor.h == 8 && anchor.imageW == 40)
        editor.body = "Move the legend"
        await session.commitNote(editor)
        await waitUntil { session.notes.count == 1 }
        let note = try #require(session.notes.first)
        let attachments = try await store.attachments(for: note.id)
        #expect(attachments.count == 1)
        #expect(attachments.first?.width == 10 && attachments.first?.height == 8)
        #expect(FileManager.default.fileExists(atPath: attachments.first?.localPath ?? ""))
        await waitUntil { image.highlights.count == 1 }
        #expect(image.highlights.first?.rect == CGRect(x: 5, y: 6, width: 10, height: 8))
        #expect(attachments.first?.localPath.hasPrefix(directory) == true, "attachments stay inside the injected directory")
        session.close()
    }

    @Test func pdfNoteStoresPageRegionAndRender() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello PDF", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        context.textPosition = CGPoint(x: 10, y: 50)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let path = "\(directory)/spec.pdf"
        try (data as Data).write(to: URL(fileURLWithPath: path))
        let (session, store) = try makeSession(path: path)
        await session.open()
        let pdf = try #require(session.pdfController)
        pdf.region = (0, CGRect(x: 5, y: 40, width: 100, height: 30))
        session.beginNote()
        var editor = try #require(session.noteEditor)
        guard case .pdf(let anchor) = editor.anchor else { Issue.record("expected pdf anchor"); return }
        #expect(anchor.page == 0 && anchor.pageCount == 1 && anchor.bounds?.w == 100)
        editor.body = "Check this region"
        await session.commitNote(editor)
        await waitUntil { session.notes.count == 1 }
        let note = try #require(session.notes.first)
        let attachments = try await store.attachments(for: note.id)
        #expect(attachments.first?.kind == .pageRender)
        #expect(attachments.first?.width == 200 && attachments.first?.height == 60, "2x render of a 100×30 pt region")
        session.close()
    }
}
