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
    /// The page thumbnails column, as in Preview's sidebar; off until asked for.
    public var showsThumbnails = false
    /// Bumped on each region copy, for the toolbar's brief "Copied".
    public internal(set) var copyCount = 0
    /// Current region in page points (crop box space) with its page, or nil.
    public var region: (page: Int, bounds: CGRect)?
    /// Current text selection: first page index, bounds on that page, and the text.
    public var textSelection: (page: Int, bounds: CGRect, text: String)?
    public var highlights: [PDFHighlight] = [] {
        didSet { onHighlightsChange() }
    }
    public var selectedNoteID: NoteID? {
        didSet { onHighlightsChange() }
    }
    /// Set by the view; redraws the overlay and text highlights.
    @ObservationIgnored public var onHighlightsChange: () -> Void = {}
    public var currentPage = 0
    public var pendingScroll: (page: Int, bounds: CGRect?)?
    public var pendingScrollVersion = 0
    @ObservationIgnored public var onNoteClick: (NoteID) -> Void = { _ in }
    /// Set by the view: page-space rect → container coordinates.
    @ObservationIgnored public var rectProvider: (Int, CGRect) -> CGRect? = { _, _ in nil }

    /// `findString` walks every page, and the view asks for the same (page, text) on every highlight pass.
    /// `document` is immutable, so nothing here goes stale; a reloaded file gets a new controller and an empty cache.
    @ObservationIgnored private var selectionCache: [SelectionKey: [PDFSelection]] = [:]

    private struct SelectionKey: Hashable {
        var page: Int
        var text: String
    }

    public init(document: PDFDocument) {
        self.document = document
    }

    public var pageCount: Int { document.pageCount }

    /// Case-insensitive matches of `text` on one page, as fresh copies so callers may recolour them freely.
    public func selections(matching text: String, onPage page: Int) -> [PDFSelection] {
        let key = SelectionKey(page: page, text: text)
        let cached: [PDFSelection]
        if let hit = selectionCache[key] {
            cached = hit
        } else {
            guard let pdfPage = document.page(at: page) else { return [] }
            cached = document.findString(text, withOptions: [.caseInsensitive]).filter { $0.pages.contains(pdfPage) }
            selectionCache[key] = cached
        }
        return cached.compactMap { $0.copy() as? PDFSelection }
    }

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
    /// `bounds` are in page space (what selections and `PDFView.convert(_:to:)` give); `draw(with:to:)` applies the
    /// page rotation and moves the box origin to zero, and `transform(for:)` maps page space into that drawn space.
    public func renderPNG(page index: Int, bounds: CGRect?, scale: CGFloat = 2) -> (data: Data, width: Int, height: Int)? {
        guard let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .cropBox)
        let region = (bounds ?? box).intersection(box)
        guard !region.isEmpty else { return nil }
        let drawn = region.applying(page.transform(for: .cropBox)).standardized
        let width = Int((drawn.width * scale).rounded())
        let height = Int((drawn.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -drawn.minX, y: -drawn.minY)
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
