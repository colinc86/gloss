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
    /// Which match of `text` on the page a text note is on (`PDFAnchor.occurrence`).
    public var occurrence: Int
    public var color: NoteColor
    public var state: NoteState

    public init(id: NoteID, page: Int, bounds: CGRect?, text: String?, occurrence: Int = 0, color: NoteColor, state: NoteState) {
        self.id = id
        self.page = page
        self.bounds = bounds
        self.text = text
        self.occurrence = occurrence
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
    /// Where this viewer's notes are on screen, for the notes panel's link and paths.
    @ObservationIgnored public let noteGeometry = NoteGeometry()

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
            // Counted on the page a match starts on, as `PDFDocumentTextSource.find` (and so re-anchoring) counts them.
            cached = document.findString(text, withOptions: [.caseInsensitive]).filter { $0.pages.first == pdfPage }
            selectionCache[key] = cached
        }
        return cached.compactMap { $0.copy() as? PDFSelection }
    }

    /// The match a text note is on: its `occurrence`, or the first when the page has fewer (as re-anchoring decides).
    public func selection(matching text: String, onPage page: Int, occurrence: Int) -> PDFSelection? {
        let matches = selections(matching: text, onPage: page)
        return matches.indices.contains(occurrence) ? matches[occurrence] : matches.first
    }

    /// Where a text note's match is, in page space.
    public func textBounds(page: Int, text: String, occurrence: Int) -> CGRect? {
        guard let pdfPage = document.page(at: page) else { return nil }
        return selection(matching: text, onPage: page, occurrence: occurrence)?.bounds(for: pdfPage)
    }

    /// Which of the page's matches of `text` the selection at `bounds` is: the one overlapping it most, else the nearest.
    func occurrence(of text: String, onPage page: Int, at bounds: CGRect) -> Int {
        guard let pdfPage = document.page(at: page) else { return 0 }
        let rects = selections(matching: text, onPage: page).map { $0.bounds(for: pdfPage) }
        guard rects.count > 1 else { return 0 }
        func overlap(_ rect: CGRect) -> CGFloat {
            let shared = rect.intersection(bounds)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        func distance(_ rect: CGRect) -> CGFloat { hypot(rect.midX - bounds.midX, rect.midY - bounds.midY) }
        return rects.indices.max { lhs, rhs in
            let l = overlap(rects[lhs]), r = overlap(rects[rhs])
            return l != r ? l < r : distance(rects[lhs]) > distance(rects[rhs])
        } ?? 0
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

    /// `selectionAnchor` with, for a text selection, which match of its text on the page it is. That takes a search of
    /// the whole document, so it is asked for only when a note is made, never while the selection is being dragged.
    public var noteAnchor: PDFAnchor? {
        guard var anchor = selectionAnchor else { return nil }
        if anchor.bounds == nil, let text = anchor.text, let textSelection {
            anchor.occurrence = occurrence(of: text, onPage: anchor.page, at: textSelection.bounds)
            if anchor.occurrence == 0 { anchor.occurrence = nil }
            anchor.textTop = Double(textSelection.bounds.maxY)
        }
        return anchor
    }

    // MARK: Zoom

    /// The page's scale (1 = actual size), as the view reports it, for the toolbar's readout.
    public internal(set) var magnification: CGFloat = 1
    public private(set) var pendingZoom: ImageViewerController.ZoomCommand?
    public private(set) var pendingZoomVersion = 0

    /// ⌘−, ⌘1, ⌘=, ⌘0 and the toolbar's zoom buttons, as the image viewer has them.
    public func zoom(_ command: ImageViewerController.ZoomCommand) {
        pendingZoom = command
        pendingZoomVersion += 1
    }

    // MARK: Find

    /// The find field over the document is showing (Edit › Find; PDFView has no find bar of its own).
    public var isFinding = false
    public var findText = ""
    public private(set) var findMissed = false
    /// The match found last, which the view selects and scrolls to; the next search starts from it.
    @ObservationIgnored public private(set) var foundSelection: PDFSelection?
    public private(set) var foundVersion = 0

    func perform(_ action: NSTextFinder.Action) {
        switch action {
        case .showFindInterface: isFinding = true
        case .nextMatch: Task { await find(backwards: false) }
        case .previousMatch: Task { await find(backwards: true) }
        case .hideFindInterface: endFind()
        default: break
        }
    }

    public func find(backwards: Bool) async {
        guard !findText.isEmpty else {
            findMissed = false
            return
        }
        let options: NSString.CompareOptions = backwards ? [.caseInsensitive, .backwards] : [.caseInsensitive]
        // From the last match; past the end (or the start, going back) it wraps.
        var found = document.findString(findText, fromSelection: foundSelection, withOptions: options)
        if found == nil, foundSelection != nil { found = document.findString(findText, fromSelection: nil, withOptions: options) }
        findMissed = found == nil
        guard let found else { return }
        foundSelection = found
        foundVersion += 1
    }

    public func endFind() {
        isFinding = false
        findMissed = false
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
    /// `findString` walks every page; one re-anchoring pass asks for the same text once per note on it.
    private final class Found { var byText: [String: [(page: Int, bounds: PDFBounds)]] = [:] }
    private let found = Found()

    public init(document: PDFDocument) {
        self.document = document
    }

    public var pageCount: Int { document.pageCount }

    public func text(ofPage page: Int) -> String? {
        document.page(at: page)?.string
    }

    public func find(_ text: String) -> [(page: Int, bounds: PDFBounds)] {
        if let hit = found.byText[text] { return hit }
        let hits = document.findString(text, withOptions: [.caseInsensitive]).compactMap { selection -> (page: Int, bounds: PDFBounds)? in
            guard let page = selection.pages.first else { return nil }
            return (document.index(for: page), PDFBounds(selection.bounds(for: page)))
        }
        found.byText[text] = hits
        return hits
    }
}

extension PDFViewerController: FindBarModel {}
