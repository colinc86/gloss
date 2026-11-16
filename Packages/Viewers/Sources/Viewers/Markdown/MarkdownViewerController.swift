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
    public var mode: Mode = .rendered {
        // Renders skipped while the source showed are caught up as the page comes back.
        didSet {
            if mode == .source { clearTableSelection() }
            if mode == .rendered, renderOwed || renderedContentVersion != source.contentVersion { rebuildNow() }
        }
    }
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
    /// A render was asked for while the source showed (a picture or diagram arrived, the text changed).
    @ObservationIgnored private var renderOwed = false

    /// The document's folder on this Mac, for relative images; nil for remote documents.
    public var baseURL: URL?
    /// The document's folder on its own host, for relative links; nil where links to files mean nothing (a pull
    /// request's or a ticket's Markdown).
    @ObservationIgnored public var documentDirectory: String?
    /// Opens a relative or file: link's target as a document on the same host.
    /// A link to another document: its path, and the heading its `#fragment` names, if any.
    @ObservationIgnored public var onOpenDocument: (String, String?) -> Void = { _, _ in }
    /// Fetches a relative picture from the document's own host (a remote file system, a ticket's attachments);
    /// nil where images are local or not served. Set it before the first render that needs it.
    @ObservationIgnored public var usesCapturedImages = false
    @ObservationIgnored public var loadImage: (@Sendable (String) async -> Data?)? {
        didSet { if loadImage != nil { rebuildNow() } }
    }
    /// Fetches the web pictures (http and https) a document links to, from this Mac whatever host the document is on.
    @ObservationIgnored public let webImageLoader: WebImageLoader
    @ObservationIgnored private var fetchedImages: [String: NSImage] = [:]
    /// The fetched pictures' bytes, for a region note's crop.
    @ObservationIgnored private var fetchedImageData: [String: Data] = [:]
    @ObservationIgnored private var fetchingImages: Set<String> = []
    /// Fetches under way, cancelled when the document closes so a gone document stops asking its host.
    @ObservationIgnored private var fetchTasks: [UUID: Task<Void, Never>] = [:]
    /// Pictures fetched at once.
    static let fetchWidth = 4
    /// Reduce Motion as of the last render: animated pictures hold still and a `<picture>` draws its reduced-motion
    /// source while it is on.
    @ObservationIgnored private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @ObservationIgnored private var displayOptionsObserver: (any NSObjectProtocol)?
    /// Mermaid diagrams drawn for the document in the current theme (or refused), by their source.
    @ObservationIgnored private var diagrams: [String: MermaidRenderer.Result] = [:]
    @ObservationIgnored private var drawingDiagrams: Set<String> = []
    /// The Mermaid blocks in the document as of the last render, drawn or not.
    @ObservationIgnored private var shownDiagrams: Set<String> = []
    /// Each drawn diagram's source by its occurrence, as of the last render.
    @ObservationIgnored private var diagramSources: [Int: String] = [:]
    /// Whether diagrams are drawn in Mermaid's dark theme: the rendered view says when its appearance changes.
    @ObservationIgnored private var darkDiagrams = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

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

    /// The picture's bytes, for cropping a region note: fetched from the document's host, read beside a local
    /// document, or the PNG of a Mermaid diagram (told apart by `occurrence`).
    public func imageData(for source: String, occurrence: Int = 0) -> Data? {
        if source == EmbedScanner.mermaidSource {
            guard let code = diagramSources[occurrence], case .diagram(_, let png)? = diagrams[code] else { return nil }
            return png
        }
        if let data = fetchedImageData[source] { return data }
        guard !usesCapturedImages, let baseURL else { return nil }
        let decoded = source.removingPercentEncoding ?? source
        let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : baseURL.appending(path: decoded)
        return try? Data(contentsOf: url.standardizedFileURL)
    }

    public init(source: TextEditorController, baseURL: URL? = nil, webImageLoader: WebImageLoader = .shared, usesCapturedImages: Bool = false, capturedImageLoader: (@Sendable (String) async -> Data?)? = nil) {
        self.source = source
        self.baseURL = baseURL
        self.webImageLoader = webImageLoader
        self.usesCapturedImages = usesCapturedImages
        self.loadImage = capturedImageLoader
        rebuildNow()
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.reduceMotion != NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                self.reduceMotion.toggle()
                self.rebuildNow()
            }
        }
        for notification in [ActiveCodeTheme.didChange, Theme.editorSettingsDidChange] {
            codeThemeObservers.append(NotificationCenter.default.addObserver(forName: notification,object: nil,queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.codeThemeChanged() }
            })
        }
        let previous = source.onTextChange
        source.onTextChange = { [weak self] in
            previous()
            self?.scheduleRebuild()
        }
    }

    isolated deinit {
        fetchTasks.values.forEach { $0.cancel() }
        codeThemeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) }
    }

    /// Re-renders immediately when the source was replaced wholesale (reload, merge).
    public func syncWithSourceIfReplaced() {
        if renderedContentVersion != source.contentVersion { rebuildNow() }
    }

    public func toggle() {
        mode = mode == .rendered ? .source : .rendered
    }

    /// Re-renders shortly after the source stops changing. Not while the source shows: typing in a large file
    /// rendered the whole page, unseen, after every pause (two seconds of main thread at 360 KB); it renders once the
    /// page is shown again.
    public func scheduleRebuild() {
        rebuildTask?.cancel()
        guard mode == .rendered else {
            renderOwed = true
            return
        }
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.rebuildNow()
        }
    }

    /// The text column's width, set by the rendered view as it sizes the column (never during a live resize). A
    /// page with tables is laid out for it, so it renders again when it changes, on the next turn of the run loop
    /// rather than after an edit's pause; the view keeps it at its old width until then. Any other page just wraps
    /// anew.
    @ObservationIgnored public var columnWidth: CGFloat? {
        didSet {
            // The first width heard is often the one the page was already laid out for (`defaultPageWidth`).
            guard columnWidth != oldValue, hasTables, columnWidth != renderedColumn.width else { return }
            guard mode == .rendered else { renderOwed = true; return }
            guard !widthRebuildPending else { return }
            widthRebuildPending = true
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.widthRebuildPending else { return }
                    self.widthRebuildPending = false
                    if self.mode == .rendered { self.rebuildNow() } else { self.renderOwed = true }
                }
            }
        }
    }
    @ObservationIgnored private var hasTables = false
    @ObservationIgnored private var widthRebuildPending = false
    /// The column the shown page was laid out for when it has tables, and how far the column is set in from the
    /// container's edges to leave wide ones room to scroll; nil when the page just wraps to its column.
    var laidOutColumn: (width: CGFloat, inset: CGFloat)? { hasTables ? renderedColumn : nil }
    @ObservationIgnored private var renderedColumn: (width: CGFloat, inset: CGFloat) = (0, 0)
    @ObservationIgnored private var codeThemeObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastCodeTheme: CodeTheme?
    @ObservationIgnored private var lastFontSize: CGFloat = 0
    @ObservationIgnored private var themeRebuildPending = false
    private func codeThemeChanged() {
        let appearance = NSAppearance(named: darkDiagrams ? .darkAqua : .aqua) ?? Theme.effectiveAppearance
        let theme = ActiveCodeTheme.theme(for: appearance)
        guard theme != lastCodeTheme || lastFontSize != Theme.fontSize else { return }
        guard mode == .rendered else { renderOwed = true; return }
        guard !themeRebuildPending else { return }
        themeRebuildPending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.themeRebuildPending else { return }
                self.themeRebuildPending = false
                if self.mode == .rendered { self.rebuildNow() }
                else { self.renderOwed = true }
            }
        }
    }
    public func rebuildNow() {
        rebuildTask?.cancel()
        widthRebuildPending = false
        themeRebuildPending = false
        renderOwed = false
        renderedContentVersion = source.contentVersion
        let codeAppearance: NSAppearance.Name = darkDiagrams ? .darkAqua : .aqua
        lastCodeTheme = ActiveCodeTheme.theme(for: NSAppearance(named: codeAppearance) ?? Theme.effectiveAppearance)
        lastFontSize = Theme.fontSize
        let output = MarkdownRenderer.render(source.text, baseURL: usesCapturedImages ? nil : baseURL, images: fetchedImages, diagrams: diagrams, reduceMotion: reduceMotion,
                                             codeAppearance: codeAppearance, columnWidth: columnWidth)
        hasTables = output.hasTables
        renderedColumn = (output.columnWidth, output.inset)
        rendered = output.text
        map = output.map
        tablesChanged(output.tables)
        renderedVersion += 1
        // Diagrams edited away are forgotten (the renderer keeps its own cache).
        shownDiagrams = Set(output.diagramSources.values).union(output.unresolvedDiagrams)
        diagrams = diagrams.filter { shownDiagrams.contains($0.key) }
        drawingDiagrams.formIntersection(shownDiagrams)
        diagramSources = output.diagramSources
        fetch(output.unresolvedImages)
        draw(output.unresolvedDiagrams)
    }

    /// Draws Mermaid blocks shown as code so far, one after another, rendering again as each arrives. A block edited
    /// away or a theme left behind meanwhile is skipped; one the renderer couldn't run for is tried again on the next
    /// render.
    private func draw(_ codes: [String]) {
        let wanted = codes.filter { !drawingDiagrams.contains($0) }
        guard !wanted.isEmpty else { return }
        drawingDiagrams.formUnion(wanted)
        let dark = darkDiagrams
        let id = UUID()
        fetchTasks[id] = Task { [weak self] in
            for code in wanted {
                guard let current = self, current.darkDiagrams == dark, current.shownDiagrams.contains(code) else { continue }
                let result = await MermaidRenderer.shared.render(code, dark: dark)
                guard !Task.isCancelled, let self else { return }
                // Drawn for a theme the view has since left (the change asked for its own), or edited away.
                guard self.darkDiagrams == dark, self.shownDiagrams.contains(code) else { continue }
                self.drawingDiagrams.remove(code)
                if case .unavailable = result { continue }
                self.diagrams[code] = result
                self.scheduleRebuild()
            }
            self?.fetchTasks[id] = nil
        }
    }

    /// The rendered view's appearance: diagrams are drawn again in the matching Mermaid theme, each replacing the
    /// old drawing when it arrives so the page doesn't flash code.
    public func setDarkAppearance(_ dark: Bool) {
        guard dark != darkDiagrams else { return }
        darkDiagrams = dark
        codeThemeChanged()
        let pending = drawingDiagrams
        drawingDiagrams.removeAll()
        draw(Array(Set(diagrams.keys).union(pending)))
    }

    /// A new captured generation can change pictures without changing the Markdown source.
    public func invalidateCapturedImages() {
        guard usesCapturedImages else { return }
        for task in fetchTasks.values { task.cancel() }
        fetchTasks.removeAll(); fetchingImages.removeAll()
        fetchedImages.removeAll(); fetchedImageData.removeAll()
        rebuildNow()
    }

    /// Fetches pictures the render couldn't show, then renders once more with whatever arrived: web pictures from
    /// the web, relative ones from the document's host. A picture that can't be had is asked for once per document,
    /// not on every keystroke.
    private func fetch(_ sources: [String]) {
        let loadImage = loadImage, web = webImageLoader, captured = usesCapturedImages
        let wanted = sources.filter { fetchedImages[$0] == nil && !fetchingImages.contains($0) && (loadImage != nil || WebImageLoader.handles($0)) }
        guard !wanted.isEmpty else { return }
        fetchingImages.formUnion(wanted)
        let id = UUID()
        fetchTasks[id] = Task { [weak self] in
            // A few at a time, each shown as it arrives (renders are coalesced), so one dead host doesn't hold up the rest.
            await withTaskGroup(of: FetchedPicture?.self) { group in
                var pending = wanted[...]
                for _ in 0..<Self.fetchWidth {
                    guard let source = pending.popFirst() else { break }
                    group.addTask { await Self.load(source, web: web, host: loadImage, captured: captured) }
                }
                for await picture in group {
                    guard !Task.isCancelled, let self else {
                        group.cancelAll()
                        return
                    }
                    if let picture {
                        self.fetchedImages[picture.source] = picture.image
                        self.fetchedImageData[picture.source] = picture.data
                        self.scheduleRebuild()
                    }
                    if let source = pending.popFirst() { group.addTask { await Self.load(source, web: web, host: loadImage, captured: captured) } }
                }
            }
            self?.fetchTasks[id] = nil
        }
    }

    /// A picture fetched and decoded away from the main actor.
    nonisolated struct FetchedPicture: @unchecked Sendable {
        // The image is made in the fetching task and handed over once; that task never touches it again.
        let source: String
        let data: Data
        let image: NSImage
    }

    /// Fetches one picture from the web or the document's host and decodes it, refusing one too big to draw.
    @concurrent nonisolated static func load(_ source: String, web: WebImageLoader, host: (@Sendable (String) async -> Data?)?, captured: Bool = false) async -> FetchedPicture? {
        let data = captured ? await host?(source) : (WebImageLoader.handles(source) ? await web.data(for: source) : await host?(source))
        guard let data, !Task.isCancelled, let image = ImageDecoder.checkedImage(data), image.size.width > 0, image.size.height > 0 else { return nil }
        return FetchedPicture(source: source, data: data, image: image)
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

    /// The source lines a span of the rendered text shows; nil when it is generated text with no source (a rule).
    public func sourceLines(forRendered range: NSRange) -> ClosedRange<Int>? {
        guard let mapping = map.sourceRange(forRendered: range) else { return nil }
        let index = source.lineIndex
        let first = index.position(forUTF16Offset: min(mapping.source.location, index.length)).line
        let lastOffset = min(max(mapping.source.location, mapping.source.location + mapping.source.length - 1), index.length)
        return first...max(first, index.position(forUTF16Offset: lastOffset).line)
    }

    /// Source-coordinate highlights projected onto the rendered text. A note on a picture is drawn on the picture
    /// instead, so its embed isn't also tinted, and one on a table's cells on those cells.
    public func renderedHighlights() -> [TextHighlight] {
        let onPictures = imageNoteIDs
        return source.drawnHighlights.filter { !onPictures.contains($0.id) }.flatMap { highlight -> [TextHighlight] in
            let ranges = cellSelections[highlight.id].flatMap { renderedRanges(of: $0, startingAt: highlight.range) } ?? map.renderedRanges(forSource: highlight.range)
            return ranges.map { range in
                var copy = highlight
                copy.range = range
                return copy
            }
        }
    }

    /// The page's tables by id, whose cells, rows and columns can be selected.
    @ObservationIgnored public private(set) var tables: [Int: MarkdownTableLayout] = [:]
    /// Cell and column notes by id, drawn on their cells in the page rather than along their rows' lines.
    @ObservationIgnored public var cellSelections: [NoteID: CellSelection] = [:]

    /// A table's selected cells, rows or columns.
    public struct TableSelection: Equatable, Sendable {
        public let table: Int
        public let selection: GridSelection
    }

    /// What is selected in one of the page's tables, as in the CSV grid; nil when nothing is. It and a text
    /// selection exclude each other.
    public private(set) var tableSelection: TableSelection?
    @ObservationIgnored private var tableSelector = GridSelector()
    @ObservationIgnored private var selectedTable: Int?
    /// The selected table's header row as written, so a render that numbers another table the same lets go.
    @ObservationIgnored private var selectedHeader: String?
    /// The cell the arrow keys move from in the table selection.
    var tableCursor: GridCell? { tableSelector.cursor }
    /// Set by the rendered view: where a table selection is on screen, in top-left window coordinates.
    @ObservationIgnored public var tableSelectionRectProvider: (TableSelection) -> CGRect? = { _ in nil }
    /// Each table cell's text and its pieces in `rendered` (more than one when it wraps), by table, row and column.
    @ObservationIgnored private var cellIndex: [Int: [[CellText]]]?

    struct CellText {
        var text = ""
        var ranges: [NSRange] = []
    }

    /// A click on a table's cell: plain selects it, ⌘ toggles it, ⇧ selects the block from the last one clicked.
    /// A cell in another table starts again there.
    public func selectTableCell(table: Int, row: Int, column: Int, extend: Bool, toggle: Bool) {
        updateTable(table) { $0.click(GridCell(row: row, column: column), extend: extend, toggle: toggle) }
    }

    /// A drag across a table's cells from the one clicked; with ⌘ the block is added to `base`.
    public func dragTableCell(table: Int, row: Int, column: Int, adding base: Set<GridCell> = []) {
        guard table == selectedTable else { return }
        updateTable(table) { $0.drag(to: GridCell(row: row, column: column), adding: base) }
    }

    /// A column's handle: plain selects the column, ⌘ toggles it, ⇧ selects the columns in between.
    public func selectTableColumn(table: Int, column: Int, extend: Bool, toggle: Bool) {
        updateTable(table) { $0.clickColumn(column, extend: extend, toggle: toggle) }
    }

    /// A row's handle: plain selects the row, ⇧ the rows in between, ⌘ adds the row (or takes it away).
    public func selectTableRow(table: Int, row: Int, extend: Bool, toggle: Bool) {
        let columns = tables[table]?.columns ?? 0
        updateTable(table) { selector in
            if toggle { selector.toggleRow(row, columns: columns) } else { selector.clickRow(row, extend: extend) }
        }
    }

    /// Arrow keys over a table selection: the next cell, or with ⇧ a bigger block.
    public func moveTableSelection(rowBy rowDelta: Int, columnBy columnDelta: Int, extend: Bool) {
        guard let table = selectedTable, let layout = tables[table] else { return }
        updateTable(table) { $0.move(rowBy: rowDelta, columnBy: columnDelta, extend: extend, rows: layout.rowLines.count, columns: layout.columns) }
    }

    public func clearTableSelection() {
        guard tableSelection != nil || selectedTable != nil else { return }
        tableSelector.clear()
        selectedTable = nil
        selectedHeader = nil
        tableSelection = nil
    }

    private func updateTable(_ table: Int, _ change: (inout GridSelector) -> Void) {
        guard tables[table] != nil else { return }
        if table != selectedTable {
            tableSelector.clear()
            selectedTable = table
            selectedHeader = headerText(of: tables[table])
        }
        change(&tableSelector)
        let next = tableSelector.selection == .none ? nil : TableSelection(table: table, selection: tableSelector.selection)
        if next != tableSelection { tableSelection = next }
    }

    /// The page rendered again: a selection stays on its table while the table keeps its shape.
    private func tablesChanged(_ new: [Int: MarkdownTableLayout]) {
        if let table = selectedTable, let old = tables[table],
           new[table]?.rowLines.count != old.rowLines.count || new[table]?.columns != old.columns || headerText(of: new[table]) != selectedHeader {
            clearTableSelection()
        }
        tables = new
        cellIndex = nil
    }

    private func headerText(of table: MarkdownTableLayout?) -> String? {
        table.flatMap { $0.rowLines.first }.flatMap { source.text.line($0, index: source.lineIndex) }
    }

    /// The table selection as a note anchor, in source coordinates: whole rows are their lines; cells add their
    /// places to the rows' lines; columns sit on the header row with their names. Nil while the page shows an
    /// older render of the source.
    public func tableSelectionAnchor() -> TextAnchor? {
        guard let selected = tableSelection, let layout = tables[selected.table], renderedContentVersion == source.contentVersion else { return nil }
        let text = source.text
        let index = source.lineIndex
        let hash = Data(text.utf8).sha256Hex
        func lines(_ first: Int, _ last: Int) -> NSRange? {
            guard first >= 0, last < layout.rowLines.count, first <= last else { return nil }
            let start = index.contentRange(ofLine: layout.rowLines[first]).location
            let end = index.contentRange(ofLine: layout.rowLines[last])
            return NSRange(location: start, length: NSMaxRange(end) - start)
        }
        switch selected.selection {
        case .none:
            return nil
        case .rows(let rows):
            guard let range = lines(rows.lowerBound, rows.upperBound) else { return nil }
            return ReAnchorer.make(from: range, in: text, index: index, hash: hash)
        case .columns(let columns):
            guard !columns.isEmpty, let range = lines(0, 0) else { return nil }
            let names = MarkdownTableSource.cells(text.line(layout.rowLines[0], index: index) ?? "")
            var anchor = ReAnchorer.make(from: range, in: text, index: index, hash: hash)
            anchor.cells = CellSelection(columns: Array(columns), headers: columns.map { $0 < names.count ? names[$0] : "" })
            return anchor
        case .cells(let cells):
            guard let first = cells.map(\.row).min(), let last = cells.map(\.row).max(), let range = lines(first, last) else { return nil }
            var anchor = ReAnchorer.make(from: range, in: text, index: index, hash: hash)
            let startLine = layout.rowLines[first]
            anchor.cells = CellSelection(cells: cells.map { CellRef(lineOffset: layout.rowLines[$0.row] - startLine, column: $0.column) })
            return anchor
        }
    }

    /// The table selection as tab-separated text, as the CSV grid copies: whole rows, the columns from the header
    /// down, or for scattered cells the block that holds them with the gaps left empty.
    public func tableSelectionCopyText() -> String? {
        guard let selected = tableSelection, let layout = tables[selected.table], let cells = cellTexts(selected.table) else { return nil }
        func value(_ row: Int, _ column: Int) -> String {
            guard row < cells.count, column < cells[row].count else { return "" }
            return Self.flat(cells[row][column].text)
        }
        let allColumns = 0..<layout.columns
        switch selected.selection {
        case .none:
            return nil
        case .rows(let rows):
            return rows.map { row in allColumns.map { value(row, $0) }.joined(separator: "\t") }.joined(separator: "\n")
        case .columns(let columns):
            return cells.indices.map { row in columns.map { value(row, $0) }.joined(separator: "\t") }.joined(separator: "\n")
        case .cells(let chosen):
            guard let top = chosen.map(\.row).min(), let bottom = chosen.map(\.row).max(),
                  let left = chosen.map(\.column).min(), let right = chosen.map(\.column).max() else { return nil }
            return (top...bottom).map { row in
                (left...right).map { column in chosen.contains(GridCell(row: row, column: column)) ? value(row, column) : "" }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }

    /// A cell's text on one line with no tabs, so it stays one cell where it is pasted; pictures drop out.
    nonisolated static func flat(_ text: String) -> String {
        let kept = text.replacingOccurrences(of: "\u{FFFC}\u{00A0}", with: "").replacingOccurrences(of: "\u{FFFC}", with: "")
        return String(kept.map { $0.isNewline || $0 == "\t" || $0 == "\u{2028}" ? " " : $0 })
    }

    /// Each cell's text in `table`, rows then columns.
    func cellTexts(_ table: Int) -> [[CellText]]? {
        if cellIndex == nil { cellIndex = Self.indexCells(rendered) }
        return cellIndex?[table]
    }

    /// The cells' rendered pieces, read from their `TableCellMark`s; a piece after a wrap carries what joined it.
    nonisolated static func indexCells(_ text: NSAttributedString) -> [Int: [[CellText]]] {
        var result: [Int: [[CellText]]] = [:]
        let string = text.string as NSString
        text.enumerateAttribute(MarkdownRenderer.tableCellKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let mark = value as? TableCellMark, mark.row >= 0 else { return }
            var rows = result[mark.table] ?? []
            while rows.count <= mark.row { rows.append([]) }
            if mark.column >= 0 {
                while rows[mark.row].count <= mark.column { rows[mark.row].append(CellText()) }
                var cell = rows[mark.row][mark.column]
                cell.text += (cell.ranges.isEmpty ? "" : mark.joined) + string.substring(with: range)
                cell.ranges.append(range)
                rows[mark.row][mark.column] = cell
            }
            result[mark.table] = rows
        }
        return result
    }

    /// Where a cell or column note is in the page: its cells' text. Nil when its table isn't on the page as the
    /// note has it, which then shows along its lines.
    func renderedRanges(of cells: CellSelection, startingAt range: NSRange) -> [NSRange]? {
        let startLine = source.lineIndex.position(forUTF16Offset: min(range.location, source.lineIndex.length)).line
        var result: [NSRange] = []
        if cells.isColumns {
            guard let layout = tables.values.first(where: { $0.rowLines.first == startLine }), let texts = cellTexts(layout.id) else { return nil }
            for row in texts {
                for column in cells.columns where column < row.count { result += row[column].ranges }
            }
        } else {
            guard let layout = tables.values.first(where: { $0.rowLines.contains(startLine) }), let texts = cellTexts(layout.id) else { return nil }
            for cell in cells.cells {
                guard let row = layout.rowLines.firstIndex(of: startLine + cell.lineOffset), row < texts.count, cell.column < texts[row].count else { continue }
                result += texts[row][cell.column].ranges
            }
        }
        return result.isEmpty ? nil : result
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
            // Text selected from here (a note revealed, a re-anchor) is what is selected now, not cells.
            if select { clearTableSelection() }
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
