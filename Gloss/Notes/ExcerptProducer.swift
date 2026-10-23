import AppKit
import Core
import PDFKit
import Viewers

/// Draws the review card's window onto a document around a note: from the open session when there is one (its
/// live text, decoded picture, PDF or attached browser), otherwise from the file on its host. Used by the card for
/// "now" and by Send for the picture kept as "as sent".
@MainActor
struct ExcerptProducer {
    unowned let model: AppModel
    static let window = ExcerptRenderer.Window()

    /// Whether a note on this document is shown rendered (a picture) rather than as lines of text: everything but
    /// plain text, code and spreadsheets, whose lines are their rendering.
    nonisolated static func isPictured(_ anchor: Anchor, kind: DocumentKind) -> Bool {
        switch anchor {
        case .text: kind == .markdown
        case .image, .pdf, .element, .embeddedImage: true
        case .wholeFile: false
        }
    }

    func render(_ anchor: Anchor, document: Core.Document, tint: NSColor, appearance: NSAppearance, window: ExcerptRenderer.Window = window) async -> CGImage? {
        let session = model.session(hostID: document.hostID, path: document.path)
        switch anchor {
        case .text(let text):
            guard document.kind == .markdown, let source = await markdownSource(document, session) else { return nil }
            let baseURL = session?.markdown?.baseURL ?? (document.hostID == .local ? URL(fileURLWithPath: document.path).deletingLastPathComponent() : nil)
            return ExcerptRenderer.markdown(source, anchor: text, baseURL: baseURL, window: window, tint: tint, appearance: appearance)
        case .image(let region):
            guard let image = await decodedImage(document, session) else { return nil }
            return ExcerptRenderer.image(image, region: CGRect(x: region.x, y: region.y, width: region.w, height: region.h), window: window, tint: tint, appearance: appearance)
        case .pdf(let pdf):
            let bounds: CGRect?
            let pdfDocument: PDFDocument
            if let controller = session?.pdfController {
                pdfDocument = controller.document
                bounds = DocumentSession.bounds(of: pdf, in: controller)
            } else {
                guard let data = await read(document), let opened = PDFDocument(data: data) else { return nil }
                pdfDocument = opened
                bounds = pdf.bounds?.cgRect
            }
            return ExcerptRenderer.pdf(pdfDocument, page: pdf.page, bounds: bounds, window: window, tint: tint)
        case .embeddedImage(let embedded):
            guard let data = await embeddedImageData(embedded, document, session),
                  let image = try? await DocumentSession.decodeImage(data, fileName: embedded.fileName) else { return nil }
            let region = embedded.region
            return ExcerptRenderer.image(image, region: CGRect(x: region.x, y: region.y, width: region.w, height: region.h), window: window, tint: tint, appearance: appearance)
        case .element(let element):
            // Only the page in the browser can be pictured; a closed page shows nothing rather than a stale crop.
            guard let snapshot = session?.html?.windowSnapshotProvider else { return nil }
            guard let taken = try? await snapshot(ExcerptRenderer.captureRect(around: element.rect, window: window)) else { return nil }
            // The browser pads the capture and cuts it to its view: the outline goes by what it really covers.
            return ExcerptRenderer.web(snapshot: taken.png, captured: taken.captured, element: element.rect, tint: tint)
        case .wholeFile:
            return nil
        }
    }

    // MARK: Content

    private func read(_ document: Core.Document) async -> Data? {
        guard let fileSystem = model.fileSystem(for: document.hostID) else { return nil }
        return try? await fileSystem.read(document.path)
    }

    private func markdownSource(_ document: Core.Document, _ session: DocumentSession?) async -> String? {
        if let live = session?.markdown?.source.text ?? session?.textController?.text { return live }
        guard let data = await read(document) else { return nil }
        return TextEncoding.decode(data).text
    }

    private func decodedImage(_ document: Core.Document, _ session: DocumentSession?) async -> DecodedImage? {
        if let live = session?.imageController?.image { return live }
        guard let data = await read(document) else { return nil }
        return try? await DocumentSession.decodeImage(data, fileName: document.fileName)
    }

    private func embeddedImageData(_ anchor: EmbeddedImageAnchor, _ document: Core.Document, _ session: DocumentSession?) async -> Data? {
        if let live = session?.markdown?.imageData(for: anchor.source, occurrence: anchor.occurrence) { return live }
        // A relative source beside the document, read from its host; a URL elsewhere isn't fetched for a card.
        guard !anchor.source.contains("://"), let fileSystem = model.fileSystem(for: document.hostID) else { return nil }
        let folder = (document.path as NSString).deletingLastPathComponent
        let path = anchor.source.hasPrefix("/") ? anchor.source : (folder as NSString).appendingPathComponent(anchor.source)
        return try? await fileSystem.read(path)
    }
}
