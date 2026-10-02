import AppKit
import Core
import Foundation
import Observation
import PDFKit

/// A note drawn on a PDF page: a region in page points, or a text selection rebuilt from its bounds.
public struct PDFHighlight: Identifiable, Equatable, Sendable {
    public var id: NoteID
    public var page: Int
    public var bounds: CGRect?
    public var text: String?
    public var color: NoteColor
    public var state: NoteState

    public init(id: NoteID, page: Int, bounds: CGRect?, text: String?, color: NoteColor, state: NoteState) {
        self.id = id
        self.page = page
        self.bounds = bounds
        self.text = text
        self.color = color
        self.state = state
    }
}

@Observable
public final class PDFViewerController {
    public let document: PDFDocument
    /// Draw rectangles instead of selecting text.
    public var regionMode = false
    /// Current region in page points (crop box space) with its page, or nil.
    public var region: (page: Int, bounds: CGRect)?
    /// Current text selection: first page index, bounds on that page, and the text.
    public var textSelection: (page: Int, bounds: CGRect, text: String)?
    public var highlights: [PDFHighlight] = []
    public var selectedNoteID: NoteID?
    public var currentPage = 0
    public var pendingScroll: (page: Int, bounds: CGRect?)?
    public var pendingScrollVersion = 0
    @ObservationIgnored public var onNoteClick: (NoteID) -> Void = { _ in }
    /// Set by the view: page-space rect → container coordinates.
    @ObservationIgnored public var rectProvider: (Int, CGRect) -> CGRect? = { _, _ in nil }

    public init(document: PDFDocument) {
        self.document = document
    }

    public var pageCount: Int { document.pageCount }

    /// The anchor for whatever is selected: a drawn region first, else a text selection.
    public var selectionAnchor: PDFAnchor? {
        if let region {
            let text = document.page(at: region.page)?.selection(for: region.bounds)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PDFAnchor(page: region.page, bounds: PDFBounds(region.bounds), text: (text?.isEmpty ?? true) ? nil : text, pageCount: pageCount)
        }
        if let textSelection, !textSelection.text.isEmpty {
            return PDFAnchor(page: textSelection.page, bounds: nil, text: textSelection.text, pageCount: pageCount)
        }
        return nil
    }

    public func clearSelection() {
        region = nil
        textSelection = nil
    }

    public func scroll(toPage page: Int, bounds: CGRect?) {
        pendingScroll = (page, bounds)
        pendingScrollVersion += 1
    }

    public func rect(forPage page: Int, bounds: CGRect) -> CGRect? {
        rectProvider(page, bounds)
    }

    /// Renders a page region (or the whole page) at 2x as PNG, for the packet attachment.
    public func renderPNG(page index: Int, bounds: CGRect?, scale: CGFloat = 2) -> (data: Data, width: Int, height: Int)? {
        guard let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .cropBox)
        let region = (bounds ?? box).intersection(box)
        guard !region.isEmpty else { return nil }
        let width = Int((region.width * scale).rounded())
        let height = Int((region.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage(), let data = ImageDecoder.pngData(image) else { return nil }
        return (data, width, height)
    }
}

extension PDFBounds {
    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// Core's re-anchoring sees the PDF through this.
public struct PDFDocumentTextSource: PDFTextSource {
    public let document: PDFDocument

    public init(document: PDFDocument) {
        self.document = document
    }

    public var pageCount: Int { document.pageCount }

    public func text(ofPage page: Int) -> String? {
        document.page(at: page)?.string
    }

    public func find(_ text: String) -> [(page: Int, bounds: PDFBounds)] {
        document.findString(text, withOptions: [.caseInsensitive]).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            return (document.index(for: page), PDFBounds(selection.bounds(for: page)))
        }
    }
}
