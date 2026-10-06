import AppKit
import Core
import Foundation
import Observation

/// Rendered and source views of one markdown document. Notes live in source coordinates; the rendered view maps
/// selections back through `RenderedSourceMap`.
@Observable
public final class MarkdownViewerController {
    public enum Mode: String, CaseIterable, Sendable {
        case rendered
        case source
    }

    public let source: TextEditorController
    public var mode: Mode = .rendered
    public private(set) var rendered: NSAttributedString = NSAttributedString()
    public private(set) var map = RenderedSourceMap(spans: [], blocks: [])
    public private(set) var renderedVersion = 0
    /// "412 words · 2 min read", counted on the rendered text (no markup), refreshed with each render.
    public var readingSummary: String {
        if summaryVersion != renderedVersion {
            summaryVersion = renderedVersion
            cachedSummary = Self.readingSummary(for: rendered.string)
        }
        return cachedSummary
    }
    @ObservationIgnored private var summaryVersion = -1
    @ObservationIgnored private var cachedSummary = ""

    nonisolated static func readingSummary(for text: String) -> String {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let minutes = max(1, Int((Double(words) / 230).rounded()))
        return "\(words.formatted()) word\(words == 1 ? "" : "s") · \(minutes) min read"
    }
    public var renderedSelection = NSRange(location: 0, length: 0)
    /// Set by the rendered view: on-screen rectangle of a rendered range.
    @ObservationIgnored public var renderedRectProvider: (NSRange) -> CGRect? = { _ in nil }
    /// Where the rendered view's notes are on screen; in source mode the source editor's `noteGeometry` applies.
    @ObservationIgnored public let noteGeometry = NoteGeometry()
    public var pendingRenderedScroll: NSRange?
    public var pendingRenderedScrollVersion = 0
    /// See `TextEditorController.pendingScrollSelects`.
    public private(set) var pendingRenderedScrollSelects = true
    public private(set) var pendingRenderedScrollAtTop = false
    /// Set by the rendered view: the rendered character at the top of what is on screen.
    @ObservationIgnored public var topVisibleRenderedLocationProvider: () -> Int? = { nil }

    /// The source location at the top of whichever view is showing (#9): where reading stopped.
    public var topVisibleSourceLocation: Int? {
        switch mode {
        case .source:
            return source.topVisibleLocation
        case .rendered:
            guard let top = topVisibleRenderedLocationProvider(), top < rendered.length else { return nil }
            // Generated text (a list marker, a rule) maps to no source: the next character that does.
            for location in top..<min(top + 400, rendered.length) {
                if let mapping = map.sourceRange(forRendered: NSRange(location: location, length: 1)) { return mapping.source.location }
            }
            return nil
        }
    }
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    @ObservationIgnored private var renderedContentVersion = -1

    /// The document's folder on this Mac, for relative images; nil for remote documents.
    public let baseURL: URL?
    /// The document's folder on its own host, for relative links; nil where links to files mean nothing (a pull
    /// request's or a ticket's Markdown).
    @ObservationIgnored public var documentDirectory: String?
    /// Opens a relative or file: link's target as a document on the same host.
    @ObservationIgnored public var onOpenDocument: (String) -> Void = { _ in }
    /// Fetches a relative picture from the document's own host (a remote file system, a ticket's attachments);
    /// nil where images are local or not served. Set it before the first render that needs it.
    @ObservationIgnored public var loadImage: ((String) async -> Data?)? {
        didSet { if loadImage != nil { rebuildNow() } }
    }
    @ObservationIgnored private var fetchedImages: [String: NSImage] = [:]
    /// The fetched pictures' bytes, for a region note's crop.
    @ObservationIgnored private var fetchedImageData: [String: Data] = [:]
    @ObservationIgnored private var fetchingImages: Set<String> = []

    // MARK: Notes on embedded pictures

    /// One embed of a picture in the document: its source as written and which embed of it (0 for the first).
    public struct EmbeddedImageRef: Hashable, Sendable {
        public var source: String
        public var occurrence: Int
        public init(source: String, occurrence: Int) {
            self.source = source
            self.occurrence = occurrence
        }
    }

    /// A region of a picture chosen in the rendered view (the whole picture after a click), in its own pixels.
    public struct ImageRegionSelection: Equatable, Sendable {
        public var image: EmbeddedImageRef
        public var region: CGRect
        public var pixelSize: CGSize
        /// The `![alt](src)` that embeds the picture, in source coordinates.
        public var embedSource: NSRange
    }

    /// A note's region on a picture, drawn over the picture in the rendered view.
    public struct EmbeddedImageHighlight: Equatable, Sendable {
        public var id: NoteID
        public var image: EmbeddedImageRef
        public var region: CGRect
        public var pixelSize: CGSize
        public var color: NoteColor
        public var state: NoteState
        public init(id: NoteID, image: EmbeddedImageRef, region: CGRect, pixelSize: CGSize, color: NoteColor, state: NoteState) {
            self.id = id
            self.image = image
            self.region = region
            self.pixelSize = pixelSize
            self.color = color
            self.state = state
        }
    }

    /// The picture region being chosen; nil when none. Clearing a text selection doesn't clear it, nor the reverse.
    public var imageSelection: ImageRegionSelection?
    public var imageHighlights: [EmbeddedImageHighlight] = []
    /// Notes drawn as regions on pictures, which the rendered text then doesn't also tint.
    public var imageNoteIDs: Set<NoteID> { Set(imageHighlights.map(\.id)) }
    /// Set by the rendered view: a picture's frame in top-left window coordinates, when it is laid out.
    @ObservationIgnored public var imageFrameProvider: (EmbeddedImageRef) -> CGRect? = { _ in nil }

    /// Where a region of a picture is on screen (top-left window coordinates).
    public func rect(for image: EmbeddedImageRef, region: CGRect, pixelSize: CGSize) -> CGRect? {
        guard let frame = imageFrameProvider(image), pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return Self.viewRect(forPixels: region, pixelSize: pixelSize, in: frame)
    }

    /// Pixels in a picture to the rect they occupy in its frame on screen, and back.
    nonisolated public static func viewRect(forPixels region: CGRect, pixelSize: CGSize, in frame: CGRect) -> CGRect {
        let sx = frame.width / pixelSize.width, sy = frame.height / pixelSize.height
        return CGRect(x: frame.minX + region.minX * sx, y: frame.minY + region.minY * sy, width: region.width * sx, height: region.height * sy)
    }

    nonisolated public static func pixels(forViewRect rect: CGRect, pixelSize: CGSize, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let sx = pixelSize.width / frame.width, sy = pixelSize.height / frame.height
        let clipped = rect.intersection(frame)
        guard !clipped.isNull else { return .zero }
        return CGRect(x: ((clipped.minX - frame.minX) * sx).rounded(.down), y: ((clipped.minY - frame.minY) * sy).rounded(.down),
                      width: (clipped.width * sx).rounded(), height: (clipped.height * sy).rounded())
    }

    /// The picture's bytes, for cropping a region note: fetched from the document's host, or read beside a local
    /// document.
    public func imageData(for source: String) -> Data? {
        if let data = fetchedImageData[source] { return data }
        guard let baseURL else { return nil }
        let decoded = source.removingPercentEncoding ?? source
        let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : baseURL.appending(path: decoded)
        return try? Data(contentsOf: url.standardizedFileURL)
    }

    public init(source: TextEditorController, baseURL: URL? = nil) {
        self.source = source
        self.baseURL = baseURL
        rebuildNow()
        let previous = source.onTextChange
        source.onTextChange = { [weak self] in
            previous()
            self?.scheduleRebuild()
        }
    }

    /// Re-renders immediately when the source was replaced wholesale (reload, merge).
    public func syncWithSourceIfReplaced() {
        if renderedContentVersion != source.contentVersion { rebuildNow() }
    }

    public func toggle() {
        mode = mode == .rendered ? .source : .rendered
    }

    /// Re-renders shortly after the source stops changing.
    public func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.rebuildNow()
        }
    }

    public func rebuildNow() {
        renderedContentVersion = source.contentVersion
        let output = MarkdownRenderer.render(source.text, baseURL: baseURL, images: fetchedImages)
        rendered = output.text
        map = output.map
        renderedVersion += 1
        fetch(output.unresolvedImages)
    }

    /// Fetches pictures the render couldn't show, then renders once more with whatever arrived. A picture that
    /// can't be had is asked for once per document, not on every keystroke.
    private func fetch(_ sources: [String]) {
        guard let loadImage else { return }
        let wanted = sources.filter { fetchedImages[$0] == nil && !fetchingImages.contains($0) }
        guard !wanted.isEmpty else { return }
        fetchingImages.formUnion(wanted)
        Task { [weak self] in
            var arrived = false
            for source in wanted {
                if let data = await loadImage(source), let image = NSImage(data: data), image.size.width > 0 {
                    self?.fetchedImages[source] = image
                    self?.fetchedImageData[source] = data
                    arrived = true
                }
            }
            if arrived { self?.rebuildNow() }
        }
    }

    /// Collapses the rendered view's selection to its end. The view ignores its own delegate while applying a
    /// scroll, so the controller's copy is updated here as well.
    public func collapseRenderedSelection() {
        guard renderedSelection.length > 0 else { return }
        let end = NSRange(location: renderedSelection.location + renderedSelection.length, length: 0)
        renderedSelection = end
        pendingRenderedScroll = end
        pendingRenderedScrollSelects = true
        pendingRenderedScrollAtTop = false
        pendingRenderedScrollVersion += 1
    }

    /// The rendered selection in source coordinates, with the exact text when the mapping is exact.
    public var renderedSelectionMapping: RenderedSourceMap.Mapping? {
        map.sourceRange(forRendered: renderedSelection)
    }

    /// Source-coordinate highlights projected onto the rendered text. A note on a picture is drawn on the picture
    /// instead, so its embed isn't also tinted.
    public func renderedHighlights() -> [TextHighlight] {
        let onPictures = imageNoteIDs
        return source.highlights.filter { !onPictures.contains($0.id) }.flatMap { highlight -> [TextHighlight] in
            map.renderedRanges(forSource: highlight.range).map { range in
                var copy = highlight
                copy.range = range
                return copy
            }
        }
    }

    /// Scrolls whichever view is showing to a source range.
    public func scroll(toSource range: NSRange, select: Bool = true) {
        scroll(toSource: range, select: select, atTop: false)
    }

    public func scroll(toSource range: NSRange, select: Bool, atTop: Bool) {
        switch mode {
        case .source:
            source.scroll(to: range, select: select, atTop: atTop)
        case .rendered:
            if let first = map.renderedRanges(forSource: range).first {
                pendingRenderedScroll = first
                pendingRenderedScrollSelects = select
                pendingRenderedScrollAtTop = atTop
                pendingRenderedScrollVersion += 1
            }
        }
    }

    public func rect(forSource range: NSRange) -> CGRect? {
        switch mode {
        case .source: source.rect(for: range)
        case .rendered: map.renderedRanges(forSource: range).first.flatMap { renderedRectProvider($0) }
        }
    }
}
