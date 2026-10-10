import AppKit
import Core
import Foundation
import Observation

/// What the rendered page reports about its selection: DOM text offsets, the text, and where it is on screen.
public struct HTMLSelection: Equatable, Sendable {
    public var dom: NSRange
    public var text: String
    /// Top-left window coordinates.
    public var rect: CGRect?
}

/// The part of a picture chosen on a page: all of it after a click, a region after a drag.
public struct PicturePick: Equatable, Sendable {
    /// In the picture's own pixels (its natural size; an svg's displayed size).
    public var region: ImageAnchor
    /// The picture's address as the page loaded it; nil for an inline svg or a canvas.
    public var source: String?
    /// Where the chosen part is on screen, in top-left window coordinates.
    public var windowRect: CGRect?
    /// Where it is on the page, in CSS pixels from the page's top-left: what the note's crop is taken of.
    public var pageRect: ElementRect

    public init(region: ImageAnchor, source: String?, windowRect: CGRect?, pageRect: ElementRect) {
        self.region = region
        self.source = source
        self.windowRect = windowRect
        self.pageRect = pageRect
    }
}

/// An element the user picked in note mode, or a picture chosen on the page, as the page's bridge described it.
public struct ElementPick: Equatable, Sendable {
    public var selector: String
    public var tag: String
    public var text: String
    public var html: String
    /// Where the element is on screen, in top-left window coordinates.
    public var windowRect: CGRect?
    /// Where the element is on the page, in CSS pixels from the page's top-left.
    public var pageRect: ElementRect
    /// DOM text offset of the element's first non-blank text node, for mapping to a source line.
    public var textOffset: Int?
    /// When the element is a picture: the part of it chosen.
    public var picture: PicturePick?

    public init(selector: String, tag: String, text: String, html: String, windowRect: CGRect?, pageRect: ElementRect, textOffset: Int?, picture: PicturePick? = nil) {
        self.selector = selector
        self.tag = tag
        self.text = text
        self.html = html
        self.windowRect = windowRect
        self.pageRect = pageRect
        self.textOffset = textOffset
        self.picture = picture
    }
}

/// An element note to draw on the page.
public struct ElementHighlight: Equatable {
    public var id: NoteID
    public var selector: String
    public var tag: String
    public var text: String
    public var color: NSColor
    public var state: NoteState
    public var needsReview: Bool
    /// Where the element last was (page CSS pixels): an orphaned note is drawn there, dashed.
    public var lastRect: ElementRect?
    /// On a picture, the part of it the note is about (its own pixels): the box is drawn over that part.
    public var region: ImageAnchor?

    public init(id: NoteID, selector: String, tag: String, text: String, color: NSColor, state: NoteState, needsReview: Bool, lastRect: ElementRect? = nil, region: ImageAnchor? = nil) {
        self.lastRect = lastRect
        self.region = region
        self.id = id
        self.selector = selector
        self.tag = tag
        self.text = text
        self.color = color
        self.state = state
        self.needsReview = needsReview
    }
}

/// Rendered and source views of one HTML document. The page is served from memory, so unsaved edits render;
/// its relative resources come from `loadResource` (local disk or the remote host), limited to `resourceRoot`.
/// Page scripts run, so the view re-aligns its text map whenever they change the page.
@Observable
public final class HTMLViewerController: RenderedDocumentController {
    public enum Mode: String, CaseIterable, Sendable {
        case rendered
        case source
    }

    public static let fileExtensions: Set<String> = ["html", "htm", "xhtml"]
    /// Largest file a page may load (images, video, scripts).
    nonisolated public static let maximumResourceSize = 50 * 1024 * 1024

    public static func handles(path: String) -> Bool {
        fileExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public let source: TextEditorController
    public var mode: Mode = .rendered {
        // Element notes are picked on the rendered page; the source view has its own selection and Add Note.
        didSet { if mode != oldValue { isNoteMode = false; selectedPicture = nil } }
    }
    /// What the view shows: a served file or a live page.
    public private(set) var page: BrowserPage
    /// The served file's path, or a live page's document key (its normalised URL).
    public private(set) var documentPath: String
    /// The tunnels of the page's remote host, for pages opened "via" an ssh host; nil on this Mac and on the web.
    public var proxy: WebProxyMap?
    /// The only folder the page may read from (the explorer root holding the document, else its folder). Scripts
    /// run, so without this a page could fetch any file on the host and send it over the network. Asked on every
    /// request: the explorer may open the document's root after the document itself.
    public var resourceRoot: String { rootProvider() ?? (documentPath as NSString).deletingLastPathComponent }
    @ObservationIgnored private let rootProvider: () -> String?
    /// Reads a file the page refers to, by absolute path on the document's host.
    @ObservationIgnored public let loadResource: @Sendable (String) async throws -> Data
    public private(set) var projection: HTMLTextProjection
    /// The anchor the page's first load scrolls to, when a link on another page named one; used once.
    @ObservationIgnored public var pendingFragment: String?
    /// Bumped when the page must reload with new source text.
    public private(set) var renderedVersion = 0
    /// The page's own `<title>`, once it has loaded one.
    public internal(set) var pageTitle: String?
    /// 0…1 while the page loads; nil when it is idle.
    public internal(set) var loadProgress: Double?
    /// Set by the view as the page's selection changes.
    /// Add Note in this viewer's context menu; set by the app.
    @ObservationIgnored public var addNote: AddNoteHook?

    public var selection: HTMLSelection?
    /// Set by the view after each load.
    @ObservationIgnored public var alignment: HTMLTextProjection.Alignment?
    /// Set by the view: a fallback rect (top of the page) for notes when no selection rect is known.
    @ObservationIgnored public var pageRect: CGRect?

    /// Note mode: hovering outlines elements and a click picks one. The browser applies it to the page.
    public var isNoteMode = false
    /// The element the user just clicked in note mode; the session turns it into a note and clears it.
    public var pendingPick: ElementPick?
    /// A picture, or a region of one, chosen on the page outside note mode (a click or a drag). Like a text
    /// selection it waits for Add Note; the session clears it once the note is made, and the browser then takes the
    /// page's drawing of it away.
    public var selectedPicture: ElementPick?
    /// Element notes to draw; set by the session from its notes.
    public var elementHighlights: [ElementHighlight] = [] {
        didSet { elementHighlightsVersion += 1 }
    }
    public private(set) var elementHighlightsVersion = 0
    /// Where each drawn element note is on screen (top-left window coordinates), after the last layout; the page
    /// reports them again as it scrolls.
    public internal(set) var elementRects: [NoteID: CGRect] = [:]
    /// Where the rendered page's element notes are on screen, for the notes panel's link and paths (text notes on a
    /// rendered page have no live position yet; in source mode the source editor's `noteGeometry` applies).
    @ObservationIgnored public let noteGeometry = NoteGeometry()
    /// A cheap hash of the page's text as last seen, so unchanged pages are not re-serialised.
    public internal(set) var textHash: String?
    /// The page's text changed (a load, a script, a route) and its notes should be looked at again: text notes
    /// against `source.text`, element notes through `resolveElements`.
    @ObservationIgnored public var onPageChanged: @MainActor () -> Void = {}
    /// The user picked an element in note mode (also left in `pendingPick`).
    @ObservationIgnored public var onPick: @MainActor (ElementPick) -> Void = { _ in }
    /// A PNG of a page rect (CSS pixels from the page's top-left), scrolled into view first; nil while no page is
    /// shown. Set by the browser while this page is current.
    @ObservationIgnored public var snapshotProvider: (@MainActor (ElementRect) async throws -> (png: Data, width: Int, height: Int)?)?
    /// Where each element note's element is now, by selector and by text. Set by the browser while current.
    @ObservationIgnored public var resolveElements: (@MainActor ([(id: NoteID, anchor: ElementAnchor)]) async -> [NoteID: ElementResolution])?
    /// Scrolls the page to an element note's element. Set by the browser while current.
    @ObservationIgnored public var scrollToElement: (@MainActor (String) -> Void)?

    /// A source range to scroll the page to, resolved by the view once the page has loaded.
    public internal(set) var pendingScroll: (range: NSRange, select: Bool)?
    public private(set) var pendingScrollVersion = 0
    public private(set) var collapseVersion = 0

    @ObservationIgnored private var renderedContentVersion = -1
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?

    public func retargetFile(to path: String) {
        guard case .file = page else { return }
        documentPath = path
        page = .file(path: path)
        renderedVersion += 1
    }

    public init(source: TextEditorController, documentPath: String, resourceRoot: @escaping () -> String? = { nil }, loadResource: @escaping @Sendable (String) async throws -> Data) {
        self.source = source
        page = .file(path: documentPath)
        self.documentPath = documentPath
        rootProvider = resourceRoot
        self.loadResource = loadResource
        projection = HTMLTextProjection(source.text)
        renderedContentVersion = source.contentVersion
        let previous = source.onTextChange
        source.onTextChange = { [weak self] in
            previous()
            self?.scheduleRebuild()
        }
    }

    /// A live page. Its source is the page's current DOM, read-only, filled in by the browser as the page loads.
    public init(livePage url: URL, proxy: WebProxyMap? = nil) {
        let source = TextEditorController(text: "", languageName: "html")
        source.isEditable = false
        self.source = source
        page = .live(url)
        documentPath = WebDocumentKey.normalize(url)
        self.proxy = proxy
        rootProvider = { nil }
        loadResource = { _ in throw URLError(.noPermissionsToReadFile) }
        projection = HTMLTextProjection("")
        renderedContentVersion = source.contentVersion
    }

    public var isShowingRendered: Bool { mode == .rendered }

    /// Whether the page may load `path`: inside `root` after resolving `..` (and symlinks on this Mac), and with
    /// no hidden component such as `.ssh`, `.git`, or `.env`.
    nonisolated public static func allowsResource(_ path: String, root: String, local: Bool) -> Bool {
        var resolved = (path as NSString).standardizingPath
        var base = (root as NSString).standardizingPath
        if local {
            resolved = URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
            base = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        }
        guard resolved.hasPrefix(base == "/" ? "/" : base + "/") else { return false }
        let relative = resolved.dropFirst(base == "/" ? 1 : base.count + 1)
        return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Set by the session: whether the document's host is this Mac (symlinks can then be resolved).
    @ObservationIgnored public var isLocal = false
    /// Set by the session for a remote host: where a path really is there, links followed. Without it a link
    /// inside the root (to /etc, to ~/.ssh) would let the page's scripts read whatever it points at.
    @ObservationIgnored public var resolveRemotePath: (@Sendable (String) async throws -> String)?
    /// Set by the session: the host the page's document belongs to, so a file the browser returns to (Back from a
    /// site) can be opened on the right machine.
    @ObservationIgnored public var hostID: HostID?

    public func toggle() {
        mode = mode == .rendered ? .source : .rendered
    }

    public func syncWithSourceIfReplaced() {
        if renderedContentVersion != source.contentVersion { rebuildNow() }
    }

    /// Re-renders shortly after typing stops; a page reload is heavier than re-laying out markdown.
    public func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.rebuildNow()
        }
    }

    public func rebuildNow() {
        renderedContentVersion = source.contentVersion
        projection = HTMLTextProjection(source.text)
        alignment = nil
        selection = nil
        renderedVersion += 1
    }

    /// Largest live-page serialisation the source view takes; beyond it the view says so and text notes still map
    /// through the projection of what was kept.
    public static let liveSourceLimit = 8 * 1024 * 1024

    /// Takes the live page's current DOM as the source: the editor shows it, and the projection maps its text.
    /// Never bumps `renderedVersion`: the page is already showing.
    func adoptLivePage(html: String, textHash: String) {
        let kept = html.utf8.count <= Self.liveSourceLimit ? html : "<!-- The page's DOM is larger than 8 MB; the source view shows nothing. -->"
        source.replaceAll(with: kept)
        projection = HTMLTextProjection(kept)
        renderedContentVersion = source.contentVersion
        self.textHash = textHash
    }

    // MARK: Selection and notes

    public var hasRenderedSelection: Bool { (selection?.dom.length ?? 0) > 0 }

    public var renderedSelectionMapping: RenderedSourceMap.Mapping? {
        guard let selection, selection.dom.length > 0, let alignment else { return nil }
        let text = projection.text as NSString
        var projected = alignment.projected(selection.dom)
        // Trust the mapped range only when it holds the selected text; otherwise take the occurrence of that text
        // nearest to where the map pointed, and give up (no Add Note) when the source does not contain it.
        if let candidate = projected, text.substring(with: candidate) != selection.text {
            projected = Self.nearest(selection.text, in: text, to: candidate.location)
        } else if projected == nil {
            projected = Self.nearest(selection.text, in: text, to: selection.dom.location)
        }
        guard let projected, let range = projection.sourceRange(forProjected: projected) else { return nil }
        let exact = (source.text as NSString).substring(with: range) == selection.text
        return RenderedSourceMap.Mapping(source: range, exact: exact)
    }

    static func nearest(_ needle: String, in haystack: NSString, to location: Int) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        var best: NSRange?
        var search = NSRange(location: 0, length: haystack.length)
        while search.length > 0 {
            let found = haystack.range(of: needle, options: [.literal], range: search)
            guard found.location != NSNotFound else { break }
            if best.map({ abs($0.location - location) > abs(found.location - location) }) ?? true { best = found }
            search = NSRange(location: found.location + 1, length: haystack.length - found.location - 1)
        }
        return best
    }

    public func rect(forSource range: NSRange) -> CGRect? {
        guard mode == .rendered else { return source.rect(for: range) }
        return selection?.rect ?? pageRect
    }

    public func scroll(toSource range: NSRange, select: Bool = true) {
        switch mode {
        case .source:
            source.scroll(to: range, select: select)
        case .rendered:
            pendingScroll = (range, select)
            pendingScrollVersion += 1
        }
    }

    /// The DOM range showing a source range, once the page has loaded.
    public func domRange(forSource range: NSRange) -> NSRange? {
        guard let alignment, let projected = projection.projectedRange(forSource: range) else { return nil }
        return alignment.dom(projected)
    }

    public func collapseRenderedSelection() {
        guard hasRenderedSelection else { return }
        selection = nil
        collapseVersion += 1
    }
}
