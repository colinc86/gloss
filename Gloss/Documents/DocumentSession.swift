import AppKit
import Core
import Observation
import OSLog
import PDFKit
import Remote
import Viewers

/// One open file: its content, the viewer state, the fingerprint it was read with, and the save protocol.
@MainActor
@Observable
final class DocumentSession: Identifiable {
    enum State {
        case loading
        case text(TextEditorController)
        case image(ImageViewerController)
        case pdf(PDFViewerController)
        case csv(CSVGridController)
        /// QuickLook for everything else (local files only until remote fetching lands).
        case quickLook(URL)
        case unsupported(DocumentKind)
        case failed(String)
    }

    enum Banner: Equatable {
        case externalChange
        case decodedAsLatin1
        case readOnlyLargeFile
        case tooLarge
        case reanchoring
        /// The file is gone from its path (deleted, or moved away) while it is open here.
        case deletedOnDisk
        /// A virtual host's document changed at its source (a new commit on the pull request) and was reloaded.
        case resourceUpdated
    }

    struct ConflictState {
        var regions: [MergeRegion]
        var theirsText: String
        var theirsFingerprint: Fingerprint
        /// The encoding the other side was read in; a merge adopts it along with its text.
        var theirsEncoding: TextEncoding = .utf8
        var canMerge: Bool { ThreeWayMerge.resolve(regions) != nil }
    }

    static let readOnlyThreshold: Int64 = 2 * 1024 * 1024
    static let refuseThreshold: Int64 = 50 * 1024 * 1024
    /// Images and PDFs are decoded whole; past this they are refused rather than read into memory.
    static let mediaThreshold: Int64 = 200 * 1024 * 1024

    var id: String { "\(hostID.rawValue):\(path)" }
    let hostID: HostID
    private(set) var path: String
    /// From the file name at first, then `.text` when an unknown extension turned out to hold text.
    private(set) var kind: DocumentKind
    private let fileSystem: any FileSystemProvider
    private let noteStore: NoteStore
    /// An earlier iteration this session shows read-only from its snapshot (issue #18), with that iteration's notes;
    /// nil for the document as it is.
    let pastIteration: Int?

    private(set) var document: Document?
    private(set) var state: State = .loading {
        didSet { offerAddNoteInMenus() }
    }
    /// Rendered/source toggle for markdown documents; nil for every other kind.
    private(set) var markdown: MarkdownViewerController?
    /// Rendered/source toggle for HTML documents; nil for every other kind.
    private(set) var html: HTMLViewerController? {
        didSet { offerAddNoteInMenus() }
    }

    /// Add Note in each viewer's context menu, offered when the floating button would be (the iteration in progress,
    /// something selected that a note can be on). Text views take theirs from `TextEditorController.onAddNote`.
    private func offerAddNoteInMenus() {
        let hook = pastIteration == nil
            ? AddNoteHook(canAdd: { [weak self] in self?.selectionAffordanceRect != nil }, add: { [weak self] in self?.beginNote() })
            : nil
        pdfController?.addNote = hook
        imageController?.addNote = hook
        csvController?.addNote = hook
        html?.addNote = hook
    }
    /// Whichever rendered view this document has.
    var rendered: (any RenderedDocumentController)? { markdown ?? html }
    private(set) var fingerprintAtOpen: Fingerprint?
    private(set) var attributesAtOpen: FileAttributes?
    /// The text as it was on disk when opened or last saved: the base for three-way merges.
    private(set) var baseText: String?
    /// The encoding the text was read in and is saved in; set only when disk text becomes `baseText`.
    private(set) var textEncoding: TextEncoding = .utf8
    private(set) var isDirty = false
    private(set) var isReadOnly = false
    var banner: Banner?
    var conflict: ConflictState?
    private(set) var isSaving = false
    private(set) var isRelocating = false
    private var externalChangesInFlight = 0
    var lastError: String?

    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var notesObservation: Task<Void, Never>?

    /// Notes of this document, in reading order, kept current by database observation.
    private(set) var notes: [Note] = []
    /// Notes whose last re-anchor was a guess; shown with a review badge until edited or resolved.
    private(set) var needsReview: Set<NoteID> = []
    /// Notes left off the page because the notes panel doesn't list them (`NotesPanelModel.hiddenIDs`). Text notes
    /// stay in the editor's highlights, marked hidden, so their ranges keep moving with edits.
    var hiddenNoteIDs: Set<NoteID> = [] {
        didSet { if hiddenNoteIDs != oldValue { syncHighlights() } }
    }
    /// A note made or changed here, so the notes panel can bring it into its list: the page draws what the list
    /// shows, and a note just written must not vanish under a tab, colour or search.
    @ObservationIgnored var onNoteCommitted: (Note) -> Void = { _ in }
    /// Runs before a new note is written: the first note after every note was resolved may start an iteration.
    @ObservationIgnored var beforeCreatingNote: (DocumentID) async -> Void = { _ in }
    /// After the text was read again from disk: a git commit change may start an iteration.
    @ObservationIgnored var onReloaded: () -> Void = {}
    /// Whether the notes observation has delivered once; a page change before that waits for it.
    @ObservationIgnored private var notesDelivered = false
    @ObservationIgnored private var pendingPageReanchor = false
    /// Set by `open`: the file may have changed while it was closed (an agent edits files Gloss isn't showing), so
    /// its notes are checked against what was read once they arrive, before anyone acts on stale positions.
    @ObservationIgnored private var pendingOpenReanchor: (@MainActor () async -> Void)?
    /// Live ranges of text notes while editing, before they are written back on save.
    @ObservationIgnored private var liveRanges: [NoteID: NSRange] = [:]
    @ObservationIgnored private var invalidatedNotes: Set<NoteID> = []
    /// Anchors this session is writing (live ranges on save, re-anchoring on open or reload), in order, until each
    /// comes back through the notes observation. A stored anchor that changes to anything else (an agent's move,
    /// Restore Original) wins over the note's live range.
    @ObservationIgnored private var anchorsBeingSaved: [NoteID: [Anchor]] = [:]
    /// The note being created or edited in the popover.
    var noteEditor: NoteEditorState?
    /// An orphaned note waiting for the user to select its new range (⌘⇧N then places it).
    var reanchoringNoteID: NoteID?
    var lastUsedColor: NoteColor = .yellow

    /// Where crops and page renders for this session's notes are written.
    let attachmentDirectory: URL

    /// The explorer root holding this file, when one is open; rendered HTML may read files only inside it.
    @ObservationIgnored var resourceRoot: () -> String? = { nil }
    /// Opens another document on this host, for a relative link clicked in rendered Markdown.
    @ObservationIgnored var openLinkedDocument: (String, String?) -> Void = { _, _ in }
    /// For a web page reached through an ssh host's loopback: the tunnels to use. Set before `open`.
    var proxy: WebProxyMap?
    /// The lines a change touched in this document (a pull request's file), asked for on open and after a reload.
    @ObservationIgnored var lineChangesProvider: ((String) async -> LineChanges?)?
    /// Whether the changed lines are unknown (GitHub sent no patch for this file).
    @ObservationIgnored var patchOmittedProvider: ((String) async -> Bool)?
    /// Set when a pull request's file changed but GitHub would not say which lines.
    private(set) var changesUnknown = false
    /// Who changed a pull request, ticket or page, for the banner after a reload ("Updated by Ana Ruiz · version 8").
    @ObservationIgnored var changeSummaryProvider: ((String) async -> String?)?
    /// What the last `resourceUpdated` banner says changed, once known.
    private(set) var resourceUpdateSummary: String?
    @ObservationIgnored private var resourceUpdateGeneration = 0

    init(hostID: HostID, path: String, fileSystem: any FileSystemProvider, noteStore: NoteStore, attachmentDirectory: URL = AttachmentCache.notesRoot,
         pastIteration: Int? = nil) {
        self.hostID = hostID
        self.path = path
        self.kind = DocumentKindDetector.kind(forPath: path)
        self.fileSystem = fileSystem
        self.noteStore = noteStore
        self.attachmentDirectory = attachmentDirectory
        self.pastIteration = pastIteration
    }

    /// The document row: made or refreshed for the file as it is, only read for an earlier iteration's snapshot, whose
    /// bytes must not become the document's fingerprint.
    private func adoptDocument(kind: DocumentKind, fingerprint: Fingerprint) async throws -> Document {
        let path = await documentPath()
        guard pastIteration != nil else { return try await noteStore.upsertDocument(hostID: hostID, path: path, kind: kind, fingerprint: fingerprint) }
        guard let document = try await noteStore.document(hostID: hostID, path: path) else { throw FileSystemError.notFound(path) }
        return document
    }

    /// The path the file's document row has: on this Mac `/tmp/a` and `/private/tmp/a` are one file, and the
    /// spelling its notes were first made under is kept, so opening it under the other never starts a second row
    /// without them.
    private func documentPath() async -> String {
        guard hostID == .local else { return path }
        for spelling in Self.spellings(of: path) where spelling != path {
            if (try? await noteStore.document(hostID: hostID, path: spelling)) != nil { return spelling }
        }
        return path
    }

    /// `path` and its other spelling through `/private` (`/tmp`, `/var`, `/etc`).
    nonisolated static func spellings(of path: String) -> [String] {
        let aliasFree = ExplorerModel.aliasFree(path)
        guard ["/tmp", "/var", "/etc"].contains(where: { aliasFree == $0 || aliasFree.hasPrefix($0 + "/") }) else { return [path] }
        return [path, aliasFree, "/private" + aliasFree]
    }

    var isLoaded: Bool {
        if case .loading = state { return false }
        return true
    }

    var fileName: String { Core.Document.displayName(of: path) }
    /// Why the document cannot be edited here, for the status bar's lock.
    var readOnlyReason: String {
        if let pastIteration { return "Read-only: the file as iteration \(pastIteration) left it" }
        return switch hostID {
        case .github: "Read-only: a pull request's file at its head commit. Ask your agent for changes."
        case .atlassian: "Read-only: the live ticket or page. Ask your agent for changes."
        case .web: "Read-only: the page's current DOM"
        default: "Read-only: the file is too large to edit here"
        }
    }
    /// The page's URL when this document is a live web page.
    var webURL: URL? { kind == .web ? URL(string: path) : nil }

    var textController: TextEditorController? {
        if case .text(let controller) = state { return controller }
        return nil
    }

    var imageController: ImageViewerController? {
        if case .image(let controller) = state { return controller }
        return nil
    }

    var pdfController: PDFViewerController? {
        if case .pdf(let controller) = state { return controller }
        return nil
    }

    var csvController: CSVGridController? {
        if case .csv(let controller) = state { return controller }
        return nil
    }

    /// Where the viewer in front reports its notes' positions, for the notes panel's link and paths; nil where the
    /// page has none to report (Quick Look).
    var noteGeometry: NoteGeometry? {
        if let markdown { return markdown.mode == .rendered ? markdown.noteGeometry : markdown.source.noteGeometry }
        if let html { return html.isShowingRendered ? html.noteGeometry : html.source.noteGeometry }
        return textController?.noteGeometry ?? pdfController?.noteGeometry ?? imageController?.noteGeometry ?? csvController?.noteGeometry
    }

    // MARK: Open and reload

    /// A failed open as a sentence for the viewer, not a Swift error dump.
    /// - virtual: a pull request, ticket or page: its provider's own words say what went wrong (a refused key, a
    ///   repository the token cannot see), not a file's.
    /// Decodes (and hashes) off the main actor: a large photo took the whole UI with it.
    nonisolated static func decodeImage(_ data: Data, fileName: String) async throws -> DecodedImage {
        try await Task.detached(priority: .userInitiated) { try ImageDecoder.decode(data, fileName: fileName) }.value
    }

    nonisolated static func openFailure(_ error: any Error, virtual: Bool = false) -> String {
        if case .tooManyPixels(let width, let height) = error as? ImageDecodeError {
            return "This image is \(width)×\(height) pixels, too large to show. Images up to 100 megapixels open here."
        }
        if virtual {
            switch error as? FileSystemError {
            case .notFound: return "Not found, or your API key can't see it."
            case .permissionDenied(let detail), .io(let detail): return detail
            default: break
            }
        }
        return switch error as? FileSystemError {
        case .notFound: "The file isn't there. It may have been moved, renamed, or deleted."
        case .permissionDenied: "You don't have permission to read this file."
        case .notADirectory: "Part of this path isn't a folder."
        case .io(let detail): "The file couldn't be read: \(detail)"
        default: error.userMessage
        }
    }

    /// Tries again after a failed open (a dropped connection, a file that was briefly missing).
    func retryOpen() async {
        guard case .failed = state else { return }
        state = .loading
        await open()
    }

    func open() async {
        if kind == .web {
            await openWebPage()
            return
        }
        do {
            let attributes = try await fileSystem.stat(path)
            attributesAtOpen = attributes
            // A FIFO, socket or device (or a link to one, such as /dev/zero) never reaches EOF: reading it
            // would block or fill memory. Only regular files are read.
            if attributes.kind == .other {
                throw FileSystemError.io("\(fileName) is not a regular file")
            }
            if (kind == .image || kind == .pdf), attributes.size > Self.mediaThreshold {
                banner = .tooLarge
                state = .unsupported(kind)
                return
            }
            if kind == .image {
                let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
                let decoded = try await Self.decodeImage(data, fileName: fileName)
                fingerprintAtOpen = fingerprint
                document = try await adoptDocument(kind: kind, fingerprint: fingerprint)
                let controller = ImageViewerController(image: decoded)
                controller.onNoteClick = { [weak self] id in
                    guard let self, let note = self.notes.first(where: { $0.id == id }) else { return }
                    self.editNote(note)
                }
                state = .image(controller)
                pendingOpenReanchor = { [weak self] in
                    // What is showing now: a reload may have replaced the image read at open.
                    guard let self, let decoded = self.imageController?.image else { return }
                    for note in self.notes {
                        guard case .image(let anchor) = note.anchor else { continue }
                        try? await self.apply(ReAnchorer.image(anchor, newWidth: decoded.width, newHeight: decoded.height, newHash: decoded.hash), to: note, unchanged: .image(anchor))
                    }
                    self.syncHighlights()
                }
                startWatching()
                observeNotes()
                return
            }
            if kind == .pdf {
                let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
                guard let pdf = PDFDocument(data: data) else { throw FileSystemError.io("not a readable PDF") }
                // PDFKit opens an encrypted file without complaint and draws blank pages.
                guard !pdf.isLocked else { throw FileSystemError.io("it's password-protected. Open it in Preview to read it.") }
                fingerprintAtOpen = fingerprint
                document = try await adoptDocument(kind: kind, fingerprint: fingerprint)
                let controller = PDFViewerController(document: pdf)
                controller.onNoteClick = { [weak self] id in
                    guard let self, let note = self.notes.first(where: { $0.id == id }) else { return }
                    self.editNote(note)
                }
                state = .pdf(controller)
                pendingOpenReanchor = { [weak self] in
                    guard let self, let pdf = self.pdfController?.document else { return }
                    let source = PDFDocumentTextSource(document: pdf)
                    for note in self.notes {
                        guard case .pdf(let anchor) = note.anchor else { continue }
                        try? await self.apply(ReAnchorer.pdf(anchor, in: source), to: note, unchanged: .pdf(anchor))
                    }
                    self.syncHighlights()
                }
                startWatching()
                observeNotes()
                return
            }
            // An extension nobody listed (jsonl, a log rotated to .1, a config with a made-up suffix) is still
            // worth opening as text when its bytes look like text; only files too big to edit go to QuickLook unread.
            var sniffed: (Data, Fingerprint)?
            if kind == .file, attributes.size <= Self.readOnlyThreshold {
                let read = try await fileSystem.readWithFingerprint(path)
                if DocumentKindDetector.looksLikeText(read.0) {
                    kind = .text
                    sniffed = read
                }
            }
            guard kind == .text || kind == .code || kind == .markdown || kind == .csv else {
                document = try await adoptDocument(kind: kind, fingerprint: attributes.fingerprint)
                fingerprintAtOpen = attributes.fingerprint
                // Quick Look reads the file on disk, not an earlier iteration's snapshot.
                state = hostID == .local && pastIteration == nil ? .quickLook(URL(fileURLWithPath: path)) : .unsupported(kind)
                startWatching()
                observeNotes()
                return
            }
            if kind == .csv, attributes.size <= Self.readOnlyThreshold {
                let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
                let controller = CSVGridController(text: TextEncoding.decode(data).text, fileName: fileName)
                if controller.isTooWide {
                    // Thousands of columns: shown as text, which the code below reads from these same bytes.
                    kind = .text
                    sniffed = (data, fingerprint)
                } else {
                    fingerprintAtOpen = fingerprint
                    baseText = adopt(data)
                    document = try await adoptDocument(kind: kind, fingerprint: fingerprint)
                    state = .csv(controller)
                    // Grid anchors hash the text itself (see `CSVGridController.selectionAnchor`). The text is read
                    // when the notes arrive, so a reload in between is what they are checked against.
                    pendingOpenReanchor = { [weak self] in
                        guard let self, let text = self.baseText else { return }
                        await self.reanchorAll(in: text, hash: Data(text.utf8).sha256Hex)
                    }
                    startWatching()
                    observeNotes()
                    return
                }
            }
            if attributes.size > Self.refuseThreshold {
                banner = .tooLarge
                state = .unsupported(.file)
                return
            }
            let (data, fingerprint): (Data, Fingerprint)
            if let sniffed {
                (data, fingerprint) = sniffed
            } else {
                (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
            }
            let text = adopt(data)
            fingerprintAtOpen = fingerprint
            baseText = text
            let tooLarge = attributes.size > Self.readOnlyThreshold
            isReadOnly = tooLarge || hostID.isVirtual || pastIteration != nil
            if tooLarge { banner = .readOnlyLargeFile } else if !textEncoding.isUnicode { banner = .decodedAsLatin1 }
            document = try await adoptDocument(kind: kind, fingerprint: fingerprint)
            // Highlighting stays on for a small read-only file (a pull request's); only size turns it off.
            let controller = TextEditorController(text: text, languageName: tooLarge ? nil : GrammarCatalog.languageName(forPath: path))
            controller.isEditable = !isReadOnly
            // Add Note in the text's context menu, on the iteration in progress only.
            if pastIteration == nil { controller.onAddNote = { [weak self] in self?.beginNote() } }
            controller.onTextChange = { [weak self] in
                self?.isDirty = true
                self?.textChangedUnderChanges()
            }
            controller.onEdit = { [weak self] _, _ in self?.liveRangesDidShift() }
            controller.onGutterClick = { [weak self] line, noteID in self?.gutterClicked(line: line, noteID: noteID) }
            if kind == .markdown {
                let folder = hostID == .local ? URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true) : nil
                markdown = MarkdownViewerController(source: controller, baseURL: folder)
                // Relative links open beside the document: files on a host, and a ticket's or page's attachments.
                if !hostID.isVirtual || hostID == .atlassian { markdown?.documentDirectory = PathUtilities.parent(of: path) }
                if folder == nil {
                    // Pictures that live on the document's host (a remote file's, a ticket's attachments) are read
                    // from it, within the size the image viewer takes.
                    let fileSystem = fileSystem, directory = PathUtilities.parent(of: path), threshold = Self.mediaThreshold
                    markdown?.loadImage = { source in
                        let decoded = source.removingPercentEncoding ?? source
                        let target = decoded.hasPrefix("/") ? decoded : (PathUtilities.join(directory, decoded) as NSString).standardizingPath
                        guard let attributes = try? await fileSystem.stat(target), attributes.kind == .file, attributes.size <= threshold,
                              let data = try? await fileSystem.read(target) else { return nil }
                        return data
                    }
                }
                markdown?.onOpenDocument = { [weak self] target, heading in self?.openLinkedDocument(target, heading) }
            } else if HTMLViewerController.handles(path: path) {
                let fileSystem = fileSystem
                let viewer = HTMLViewerController(source: controller, documentPath: path, resourceRoot: { [weak self] in self?.resourceRoot() }) { resource in
                    // Check the size first: a page's video should not be pulled over SFTP only to be refused.
                    guard try await fileSystem.stat(resource).size <= HTMLViewerController.maximumResourceSize else { throw URLError(.dataLengthExceedsMaximum) }
                    return try await fileSystem.read(resource)
                }
                viewer.isLocal = hostID == .local
                if let sftp = fileSystem as? SFTPFileSystem {
                    viewer.resolveRemotePath = { path in try await sftp.resolvedPath(path) }
                }
                viewer.hostID = hostID
                viewer.onPick = { [weak self] pick in self?.beginNote(element: pick) }
                viewer.onPageChanged = { [weak self] in self?.pageChanged() }
                html = viewer
            }
            state = .text(controller)
            // The disk text as it is when the notes arrive: a reload in between replaced what open read.
            pendingOpenReanchor = { [weak self] in
                guard let self, let text = self.baseText else { return }
                await self.reanchorAll(in: text, hash: self.fingerprintAtOpen?.hash ?? "")
            }
            startWatching()
            observeNotes()
            refreshLineChanges()
        } catch {
            state = .failed(Self.openFailure(error, virtual: hostID.isVirtual))
            Log.viewer.error("open \(self.path, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// A live page: the browser loads it and hands back its DOM as a read-only source, so text notes anchor to
    /// the page's text the way they anchor to a file's. The page is its own watcher: every settled change comes
    /// back through `onPageChanged`.
    private func openWebPage() async {
        guard let url = webURL else {
            state = .failed("That isn't a web address.")
            return
        }
        do {
            document = try await adoptDocument(kind: .web, fingerprint: Fingerprint())
            let viewer = HTMLViewerController(livePage: url, proxy: proxy)
            viewer.hostID = hostID
            viewer.onPick = { [weak self] pick in self?.beginNote(element: pick) }
            viewer.onPageChanged = { [weak self] in self?.pageChanged() }
            isReadOnly = true
            html = viewer
            state = .text(viewer.source)
            observeNotes()
        } catch {
            state = .failed(Self.openFailure(error, virtual: hostID.isVirtual))
        }
    }

    /// The page's text changed (it loaded, a script ran, a route changed): its notes follow the new page. A live
    /// page's text is also its source, so that is refreshed too; a served file's source is the file.
    private func pageChanged() {
        // An earlier iteration's notes stay where they were taken; nothing here writes to the store.
        guard pastIteration == nil, let controller = textController else { return }
        guard notesDelivered else {
            pendingPageReanchor = true
            return
        }
        let text = controller.text
        let hash = Data(text.utf8).sha256Hex
        if kind == .web {
            baseText = text
            fingerprintAtOpen = Fingerprint(mtime: Date(), size: Int64(text.utf8.count), hash: hash)
        }
        // A page without notes has nothing to follow: no database writes and no work on every tick of a busy page.
        guard !notes.isEmpty else { return }
        let fingerprint = fingerprintAtOpen
        // One re-anchoring at a time; a newer page state replaces an older one still under way, whose results
        // would otherwise land after the newer ones.
        pageReanchor?.cancel()
        pageReanchor = Task { [weak self] in
            guard let self else { return }
            if kind == .web, let document, let fingerprint { try? await noteStore.updateFingerprint(document.id, fingerprint) }
            guard !Task.isCancelled else { return }
            if kind == .web { await reanchorAll(in: text, hash: hash) }
            guard !Task.isCancelled else { return }
            await reanchorElements(hash: hash)
        }
    }

    /// The re-anchoring started by the last page change.
    @ObservationIgnored private var pageReanchor: Task<Void, Never>?

    /// Asks the page where each element note's element is now and moves, flags or orphans the notes accordingly.
    private func reanchorElements(hash: String) async {
        guard pastIteration == nil, let html, let resolve = html.resolveElements else { return }
        let items: [(id: NoteID, anchor: ElementAnchor)] = notes.compactMap { note in
            if case .element(let anchor) = note.anchor { (note.id, anchor) } else { nil }
        }
        guard !items.isEmpty else { return }
        let results = await resolve(items)
        guard !Task.isCancelled else { return }
        for (id, anchor) in items {
            guard let note = notes.first(where: { $0.id == id }), var resolution = results[id] else { continue }
            // On a served file each candidate's place in the page maps to a source line, so the note's Line
            // follows its element when lines are added above it.
            if kind != .web {
                resolution.bySelector = resolution.bySelector.map(withSourceLine)
                resolution.byText = resolution.byText.map(withSourceLine)
            }
            do {
                let result = ReAnchorer.element(anchor, resolution: resolution, newHash: hash)
                // Found at its own selector with the same text: only the hash and rect moved, which every page tick
                // on a busy page would otherwise write back.
                if case .moved(.element(let next)) = result, note.state != .orphaned, next.selector == anchor.selector, next.text == anchor.text, next.line == anchor.line {
                    needsReview.remove(id)
                } else {
                    try await apply(result, to: note, unchanged: .element(anchor))
                }
            } catch {
                Log.notes.error("re-anchoring element note \(id.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
        syncHighlights()
    }

    private func withSourceLine(_ candidate: ElementCandidate) -> ElementCandidate {
        var candidate = candidate
        if let offset = candidate.textOffset { candidate.line = sourceLine(forDOMOffset: offset) }
        return candidate
    }

    /// The source line a page-text offset maps to on a served file; nil when the page and source don't align there.
    private func sourceLine(forDOMOffset offset: Int) -> Int? {
        guard let html, let controller = textController, let alignment = html.alignment,
              let projected = alignment.projected(NSRange(location: offset, length: 1)),
              let source = html.projection.sourceRange(forProjected: projected) else { return nil }
        return controller.lineIndex.position(forUTF16Offset: source.location).line
    }

    /// Starts a note on the element the user picked in note mode (the editor opens at the element, no Add Note
    /// pill in between), or on the picture chosen on the page once Add Note is pressed. On a served file the
    /// element's first text maps to its source line.
    func beginNote(element pick: ElementPick) {
        guard let html, let controller = textController else { return }
        html.isNoteMode = false
        html.pendingPick = nil
        let line = kind == .web ? nil : pick.textOffset.flatMap(sourceLine(forDOMOffset:))
        let anchor = ElementAnchor(
            selector: pick.selector, tag: pick.tag, text: pick.text, html: pick.html, rect: pick.pageRect,
            line: line, hash: Data(controller.text.utf8).sha256Hex, region: pick.picture?.region, imageSource: pick.picture?.source
        )
        let rect = pick.picture?.windowRect ?? pick.windowRect ?? html.pageRect ?? CGRect(x: 40, y: 40, width: 1, height: 1)
        noteEditor = NoteEditorState(anchor: .element(anchor), body: "", color: lastUsedColor, anchorRect: rect, pageCrop: pick.picture?.pageRect)
    }

    /// Decodes without changing the encoding the document is saved in (a conflict check's read of the other side).
    private func decode(_ data: Data) -> String {
        TextEncoding.decode(data).text
    }

    /// Decodes text that becomes the document's base, and records its encoding for saving. A read cut off inside
    /// a multibyte character once flipped a UTF-8 file to Latin-1 for good; each read now decides afresh.
    private func adopt(_ data: Data) -> String {
        let (text, encoding) = TextEncoding.decode(data)
        textEncoding = encoding
        return text
    }

    /// Discards unsaved edits and shows what is on disk now.
    /// `discardingEdits: false` is the automatic path behind the watcher: edits that arrived while the read was in
    /// flight win, and the banner offers the reload instead of silently replacing them.
    func reloadFromDisk(discardingEdits: Bool = true) async {
        guard let controller = textController else { return }
        do {
            var (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
            // A watcher read that caught the file mid-write (UTF-8 cut inside a character) is not a new encoding:
            // read once more after the write has had a moment. A Latin-1 file that really ends in é looks the same,
            // so the second read is taken as it is.
            if !discardingEdits, textEncoding.isUnicode, TextEncoding.isUTF8CutShort(data) {
                try? await Task.sleep(for: .milliseconds(300))
                (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
            }
            let (text, encoding) = TextEncoding.decode(data)
            if !discardingEdits, isDirty {
                if text != baseText { banner = .externalChange }
                return
            }
            textEncoding = encoding
            fingerprintAtOpen = fingerprint
            baseText = text
            controller.replaceAll(with: text)
            rendered?.syncWithSourceIfReplaced()
            isDirty = false
            banner = textEncoding.isUnicode ? nil : .decodedAsLatin1
            conflict = nil
            liveRanges = [:]
            invalidatedNotes = []
            try await noteStore.updateFingerprint(document?.id ?? DocumentID.new(), fingerprint)
            await reanchorAll(in: text, hash: fingerprint.hash ?? "")
            refreshLineChanges()
            if hostID.isVirtual, !discardingEdits { showResourceUpdated() }
            onReloaded()
        } catch {
            lastError = "Reload failed: \(error.userMessage)"
        }
    }

    /// Rebuilds the grid from disk and re-anchors its notes, so cell and row notes follow inserted or removed rows
    /// instead of tinting (and sending) whatever record now sits at their old lines.
    private func reloadCSV() async {
        do {
            let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
            let text = adopt(data)
            let controller = CSVGridController(text: text, fileName: fileName)
            // Grown too wide since it opened: keep the grid it had rather than build thousands of columns.
            guard !controller.isTooWide else {
                lastError = "This file now has more than \(CSVGridController.maximumColumns) columns; reopen it to see it as text."
                return
            }
            fingerprintAtOpen = fingerprint
            baseText = text
            state = .csv(controller)
            if let document { try await noteStore.updateFingerprint(document.id, fingerprint) }
            // Grid anchors hash the text itself (see `CSVGridController.selectionAnchor`).
            await reanchorAll(in: text, hash: Data(text.utf8).sha256Hex)
        } catch {
            lastError = "Reload failed: \(error.userMessage)"
        }
    }

    func dismissBanner() {
        banner = nil
    }

    /// "Pull request updated" for a few seconds, long enough to notice, gone before it nags.
    private func showResourceUpdated() {
        banner = .resourceUpdated
        resourceUpdateSummary = nil
        // Each update has its own generation: an older lookup or dismissal never touches a newer banner.
        resourceUpdateGeneration += 1
        let generation = resourceUpdateGeneration
        if let provider = changeSummaryProvider {
            let path = path
            Task { [weak self] in
                let summary = await provider(path)
                guard let self, self.resourceUpdateGeneration == generation, self.banner == .resourceUpdated else { return }
                self.resourceUpdateSummary = summary
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.resourceUpdateGeneration == generation, self.banner == .resourceUpdated else { return }
            self.banner = nil
        }
    }

    // MARK: Save

    /// Saves unless the file changed underneath; then `conflict` is set and the sheet decides.
    func save() async {
        // A save already in flight (⌘S on a slow remote file, then Save All) is waited for, not skipped: skipping
        // left the document dirty and made Save All report it as unsaved a moment before it was.
        for _ in 0..<600 where isSaving { try? await Task.sleep(for: .milliseconds(50)) }
        guard let controller = textController, !isReadOnly, !isSaving, !isRelocating else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let expected = fingerprintAtOpen {
                if case .changed(let current, let fingerprint) = try await fileSystem.checkForChanges(at: path, since: expected) {
                    let (theirs, theirsEncoding) = TextEncoding.decode(current)
                    let regions = ThreeWayMerge.merge(
                        base: ExcerptExtractor.allLines(baseText ?? ""),
                        mine: ExcerptExtractor.allLines(controller.text),
                        theirs: ExcerptExtractor.allLines(theirs)
                    )
                    conflict = ConflictState(regions: regions, theirsText: theirs, theirsFingerprint: fingerprint, theirsEncoding: theirsEncoding)
                    return
                }
            }
            try await write(controller.text)
        } catch FileSystemError.notFound {
            // Deleted since it was opened: the banner offers Save Here, which writes it back on purpose.
            banner = .deletedOnDisk
        } catch let refusal as EncodingRefusal {
            banner = .decodedAsLatin1
            lastError = refusal.message
        } catch {
            lastError = "Save failed: \(Self.openFailure(error))"
            Log.viewer.error("save \(self.path, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// True when the file changed again after the version the conflict sheet shows; the conflict is then rebuilt
    /// against the newest version instead of writing over one the user never saw.
    private func changedSinceConflict(_ conflict: ConflictState) async -> Bool {
        guard case .changed = try? await fileSystem.checkForChanges(at: path, since: conflict.theirsFingerprint) else { return false }
        self.conflict = nil
        await save()
        return true
    }

    /// A save the file's encoding can't hold; the banner's Convert to UTF-8 is the way out.
    struct EncodingRefusal: Error {
        var encoding: TextEncoding
        var message: String {
            "Not saved: this file is \(encoding.displayName), which can't hold some of the characters you typed. Remove them, or choose Convert to UTF-8 above the text to save the whole file as UTF-8."
        }
    }

    /// Saves from now on as UTF-8; the next save rewrites the file in it.
    func convertToUTF8() {
        guard !textEncoding.isUnicode, !isReadOnly else { return }
        textEncoding = .utf8
        isDirty = true
        banner = nil
    }

    /// Conflict resolution: overwrite with the editor's text.
    func keepMine() async {
        guard let controller = textController, let conflict else { return }
        if await changedSinceConflict(conflict) { return }
        self.conflict = nil
        do {
            try await write(controller.text)
        } catch let refusal as EncodingRefusal {
            banner = .decodedAsLatin1
            lastError = refusal.message
        } catch {
            lastError = "Save failed: \(error.userMessage)"
        }
    }

    /// Conflict resolution: drop the edits and take the disk version.
    func takeTheirs() async {
        conflict = nil
        await reloadFromDisk()
    }

    /// Conflict resolution: apply both sides when they do not overlap, then save.
    func mergeAndSave() async {
        guard let conflict, let merged = ThreeWayMerge.resolve(conflict.regions), let controller = textController else { return }
        if await changedSinceConflict(conflict) { return }
        // Merged again on lines that keep their own endings, so CRLF, a missing final newline and U+2028 inside a
        // string literal come through as they were; the sheet's lines (endings stripped) are only for showing.
        let exact = ThreeWayMerge.resolve(ThreeWayMerge.merge(
            base: Self.linesKeepingEndings(baseText ?? ""),
            mine: Self.linesKeepingEndings(controller.text),
            theirs: Self.linesKeepingEndings(conflict.theirsText)
        ))
        let text = exact?.joined() ?? Self.join(merged, like: conflict.theirsText)
        self.conflict = nil
        baseText = conflict.theirsText
        fingerprintAtOpen = conflict.theirsFingerprint
        textEncoding = conflict.theirsEncoding
        controller.replaceAll(with: text)
        rendered?.syncWithSourceIfReplaced()
        liveRanges = [:]
        invalidatedNotes = []
        do { try await write(text) } catch { lastError = "Save failed: \(error.userMessage)" }
        await reanchorAll(in: text, hash: Data(text.utf8).sha256Hex)
    }

    /// Lines split after each LF, each keeping its ending (CRLF included); joined with "" they are the text again.
    static func linesKeepingEndings(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            current.append(scalar)
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { lines.append(String(current)) }
        return lines
    }

    /// Joins ending-less lines with the line ending `reference` uses, ending with one when it does.
    static func join(_ lines: [String], like reference: String) -> String {
        let ending = reference.contains("\r\n") ? "\r\n" : "\n"
        let last = reference.unicodeScalars.last
        return lines.joined(separator: ending) + (last == "\n" || last == "\r" ? ending : "")
    }

    /// Conflict resolution: write the edits somewhere else (local hosts only).
    func saveAs() async {
        guard let controller = textController, hostID == .local else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.directoryURL = URL(fileURLWithPath: PathUtilities.parent(of: path))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(controller.text.utf8).write(to: url, options: .atomic)
            conflict = nil
        } catch {
            lastError = "Save As failed: \(error.userMessage)"
        }
    }

    private func write(_ text: String) async throws {
        guard !isRelocating || isSaving else { throw FileSystemError.io("Finish recovering the rename before saving.") }
        // Written back in the encoding it was read in. A character that encoding can't hold refuses the save rather
        // than switching the whole file to UTF-8, which would garble every non-ASCII byte already in it.
        guard let data = textEncoding.encode(text) else { throw EncodingRefusal(encoding: textEncoding) }
        // Snapshot the anchors that belong to this text; typing during a slow save must not leak into them.
        let rangesSnapshot = liveRanges
        let invalidatedSnapshot = invalidatedNotes
        let attributes = try await fileSystem.writeAtomically(data, to: path, preservingModeFrom: attributesAtOpen)
        let fingerprint = Fingerprint(mtime: attributes.mtime, size: attributes.size, hash: data.sha256Hex)
        fingerprintAtOpen = fingerprint
        attributesAtOpen = attributes
        baseText = text
        isDirty = textController.map { $0.text != text } ?? false
        banner = nil
        if let document {
            try await noteStore.updateFingerprint(document.id, fingerprint)
        }
        await persistLiveAnchors(rangesSnapshot, invalidated: invalidatedSnapshot, in: text, hash: fingerprint.hash ?? "")
    }

    // MARK: Watching

    private func startWatching() {
        // A snapshot never changes.
        guard pastIteration == nil else { return }
        watcher?.cancel()
        let stream = fileSystem.watch(path)
        watcher = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .changed(let paths):
                    // FSEvents names `/private/tmp/a` for a file opened as `/tmp/a` (the tree's spelling), and Foundation's
                    // symlink resolving drops `/private` again, so the two spellings are compared without it.
                    let resolved = URL(fileURLWithPath: self.path).resolvingSymlinksInPath().path
                    let aliasFree = self.hostID == .local ? ExplorerModel.aliasFree(self.path) : self.path
                    guard paths.contains(where: { $0 == self.path || $0 == resolved || (self.hostID == .local && ExplorerModel.aliasFree($0) == aliasFree) }) else { continue }
                    await self.handleExternalChange()
                case .rescan:
                    await self.handleExternalChange()
                }
            }
        }
    }

    func handleExternalChange() async {
        guard !isRelocating, !Task.isCancelled else { return }
        externalChangesInFlight += 1
        defer { externalChangesInFlight -= 1 }
        // A file that vanished says so instead of quietly showing what it held. Editors that save by writing a new
        // file and renaming it over the old one leave the path empty for a moment, so look twice before saying it.
        if await isMissingOnDisk() {
            try? await Task.sleep(for: .milliseconds(300))
            if await isMissingOnDisk() {
                banner = .deletedOnDisk
                return
            }
        }
        if banner == .deletedOnDisk { banner = reanchoringNoteID == nil ? nil : .reanchoring }
        if csvController != nil {
            guard let expected = fingerprintAtOpen, case .changed = try? await fileSystem.checkForChanges(at: path, since: expected) else { return }
            await reloadCSV()
            return
        }
        if case .quickLook = state {
            guard let expected = fingerprintAtOpen, case .changed = try? await fileSystem.checkForChanges(at: path, since: expected) else { return }
            await open()
            return
        }
        if imageController != nil {
            await reloadImage()
            return
        }
        if pdfController != nil {
            await reloadPDF()
            return
        }
        guard textController != nil, let expected = fingerprintAtOpen else { return }
        do {
            guard case .changed = try await fileSystem.checkForChanges(at: path, since: expected) else { return }
            if isDirty {
                banner = .externalChange
            } else {
                await reloadFromDisk(discardingEdits: false)
            }
        } catch {
            Log.viewer.error("external change check failed: \(error, privacy: .public)")
        }
    }

    private func isMissingOnDisk() async -> Bool {
        do {
            _ = try await fileSystem.stat(path)
            return false
        } catch let error as FileSystemError {
            if case .notFound = error { return true }
            return false
        } catch {
            return false
        }
    }

    /// Writes the open text back to the path it was deleted from.
    func putBack() async {
        guard let controller = textController, !isReadOnly else { return }
        // The file may be back already (git checkout, an agent rewrite) before the watcher noticed: then this is
        // an ordinary save, with its conflict check, not a blind write over what came back.
        if !(await isMissingOnDisk()) {
            banner = reanchoringNoteID == nil ? nil : .reanchoring
            await save()
            return
        }
        do {
            try await write(controller.text)
        } catch {
            lastError = "Could not save \(fileName): \(error.userMessage)"
        }
    }

    /// Stop writes and drain existing IO before the filesystem moves. The editor itself stays intact.
    func suspendForRelocation() async throws {
        isRelocating = true
        watcher?.cancel()
        for _ in 0..<600 {
            if !isSaving && externalChangesInFlight == 0 && isLoaded { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FileSystemError.io("The document is still busy. Try renaming again after it finishes loading or saving.")
    }

    func resumeAfterRelocation() {
        isRelocating = false
        startWatching()
    }

    func retarget(to newPath: String) async throws {
        guard newPath != path else { return }
        // A tab that never got a record (too large to show, or failed to load) has no review history to follow.
        if document != nil {
            guard let relocated = try await noteStore.document(hostID: hostID, path: newPath) else {
                throw FileSystemError.io("The renamed document's review record is unavailable.")
            }
            document = relocated
        }
        path = newPath
        if banner == .deletedOnDisk { banner = nil }
        if let markdown {
            markdown.baseURL = hostID == .local ? URL(fileURLWithPath: PathUtilities.parent(of: path), isDirectory: true) : nil
            markdown.documentDirectory = PathUtilities.parent(of: path)
            if hostID != .local {
                let fileSystem = fileSystem, directory = PathUtilities.parent(of: path), threshold = Self.mediaThreshold
                markdown.loadImage = { source in
                    let decoded = source.removingPercentEncoding ?? source
                    let target = decoded.hasPrefix("/") ? decoded : (PathUtilities.join(directory, decoded) as NSString).standardizingPath
                    guard let attrs = try? await fileSystem.stat(target), attrs.kind == .file, attrs.size <= threshold else { return nil }
                    return try? await fileSystem.read(target)
                }
            }
            markdown.rebuildNow()
        }
        html?.retargetFile(to: newPath)
        if case .quickLook = state { state = .quickLook(URL(fileURLWithPath: newPath)) }
    }

    func close() {
        watcher?.cancel()
        watcher = nil
        notesObservation?.cancel()
        notesObservation = nil
        pageReanchor?.cancel()
        pageReanchor = nil
    }

    /// Reloads a changed PDF and re-anchors its notes by page text.
    private func reloadPDF() async {
        guard let expected = fingerprintAtOpen else { return }
        do {
            guard case .changed(let data, let fingerprint) = try await fileSystem.checkForChanges(at: path, since: expected),
                  let pdf = PDFDocument(data: data) else { return }
            // Encrypted since it opened: its pages have no text, so re-anchoring would orphan every note.
            guard !pdf.isLocked else {
                lastError = "This PDF is now password-protected; its notes are left as they were."
                return
            }
            fingerprintAtOpen = fingerprint
            let controller = PDFViewerController(document: pdf)
            controller.onNoteClick = { [weak self] id in
                guard let self, let note = self.notes.first(where: { $0.id == id }) else { return }
                self.editNote(note)
            }
            state = .pdf(controller)
            if let document { try await noteStore.updateFingerprint(document.id, fingerprint) }
            let source = PDFDocumentTextSource(document: pdf)
            for note in notes {
                guard case .pdf(let anchor) = note.anchor else { continue }
                try await apply(ReAnchorer.pdf(anchor, in: source), to: note, unchanged: .pdf(anchor))
            }
            syncHighlights()
        } catch {
            Log.viewer.error("pdf reload failed: \(error, privacy: .public)")
        }
    }

    /// Re-decodes a changed image and re-anchors its region notes.
    private func reloadImage() async {
        guard let expected = fingerprintAtOpen else { return }
        do {
            guard case .changed(let data, let fingerprint) = try await fileSystem.checkForChanges(at: path, since: expected) else { return }
            let decoded = try await Self.decodeImage(data, fileName: fileName)
            fingerprintAtOpen = fingerprint
            let controller = ImageViewerController(image: decoded)
            controller.onNoteClick = { [weak self] id in
                guard let self, let note = self.notes.first(where: { $0.id == id }) else { return }
                self.editNote(note)
            }
            state = .image(controller)
            if let document { try await noteStore.updateFingerprint(document.id, fingerprint) }
            for note in notes {
                guard case .image(let anchor) = note.anchor else { continue }
                try await apply(ReAnchorer.image(anchor, newWidth: decoded.width, newHeight: decoded.height, newHash: decoded.hash), to: note, unchanged: .image(anchor))
            }
            syncHighlights()
        } catch {
            Log.viewer.error("image reload failed: \(error, privacy: .public)")
        }
    }

    // MARK: Notes

    private func observeNotes() {
        guard let document else { return }
        notesObservation?.cancel()
        // An earlier iteration's notes were taken on its snapshot: shown where they were, never re-anchored.
        if pastIteration != nil { pendingOpenReanchor = nil }
        let stream = noteStore.observeNotes(for: document.id, iteration: pastIteration)
        notesObservation = Task { [weak self] in
            do {
                for try await notes in stream {
                    guard let self else { return }
                    self.dropLiveRangesMovedElsewhere(from: self.notes, to: notes)
                    self.notes = notes
                    self.syncHighlights()
                    if !self.notesDelivered {
                        self.notesDelivered = true
                        if let reanchor = self.pendingOpenReanchor {
                            self.pendingOpenReanchor = nil
                            await reanchor()
                        }
                        // A page that settled before its notes arrived still gets its notes looked at once.
                        if self.pendingPageReanchor { self.pendingPageReanchor = false; self.pageChanged() }
                    }
                }
            } catch {
                Log.notes.error("note observation failed: \(error, privacy: .public)")
            }
        }
    }

    /// A note whose stored anchor changed while it had a live range, other than by this session's own save, was moved
    /// by someone else (an agent's relocation, Restore Original): its live range goes, so the editor draws the
    /// new place and the next save can't write the old one back.
    private func dropLiveRangesMovedElsewhere(from old: [Note], to new: [Note]) {
        guard !liveRanges.isEmpty || !invalidatedNotes.isEmpty else { return }
        let before = Dictionary(old.map { ($0.id, $0.anchor) }, uniquingKeysWith: { first, _ in first })
        for note in new where liveRanges[note.id] != nil || invalidatedNotes.contains(note.id) {
            guard let previous = before[note.id], previous != note.anchor else { continue }
            // One of this session's own writes (several can be on the way: an open-time pass and a save). The
            // observation can skip a write, so those written before it are done with too.
            if let pending = anchorsBeingSaved[note.id], let mine = pending.firstIndex(of: note.anchor) {
                anchorsBeingSaved[note.id] = pending.count > mine + 1 ? Array(pending[(mine + 1)...]) : nil
                continue
            }
            liveRanges[note.id] = nil
            invalidatedNotes.remove(note.id)
        }
    }

    /// Pushes note ranges into the editor, preferring live (edited) ranges over stored anchors.
    private func syncHighlights() {
        let hidden = hiddenNoteIDs
        let drawn = notes.filter { !hidden.contains($0.id) }
        if let csv = csvController {
            csv.cellSelections = Dictionary(drawn.compactMap { note -> (NoteID, CellSelection)? in
                guard case .text(let anchor) = note.anchor, let cells = anchor.cells else { return nil }
                return (note.id, cells)
            }, uniquingKeysWith: { first, _ in first })
            csv.highlights = drawn.compactMap { note in
                guard case .text(let anchor) = note.anchor else { return nil }
                return TextHighlight(id: note.id, range: csv.lineIndex.range(for: anchor), color: note.color, state: note.displayState)
            }
            return
        }
        if let pdf = pdfController {
            pdf.highlights = drawn.compactMap { note in
                guard case .pdf(let anchor) = note.anchor else { return nil }
                return PDFHighlight(id: note.id, page: anchor.page, bounds: anchor.bounds?.cgRect, text: anchor.text, occurrence: anchor.occurrence ?? 0,
                                    color: note.color, state: note.displayState)
            }
            return
        }
        if let image = imageController {
            image.highlights = drawn.compactMap { note in
                guard case .image(let anchor) = note.anchor else { return nil }
                return ImageHighlight(id: note.id, rect: CGRect(x: anchor.x, y: anchor.y, width: anchor.w, height: anchor.h), color: note.color, state: note.displayState, needsReview: needsReview.contains(note.id))
            }
            return
        }
        guard let controller = textController else { return }
        if let html {
            html.elementHighlights = drawn.compactMap { note in
                guard case .element(let anchor) = note.anchor else { return nil }
                // An orphan is drawn dashed where its element last was.
                return ElementHighlight(id: note.id, selector: anchor.selector, tag: anchor.tag, text: anchor.text,
                                        color: Theme.color(for: note.color), state: note.displayState, needsReview: needsReview.contains(note.id),
                                        lastRect: note.state == .orphaned ? anchor.rect : nil, region: anchor.region)
            }
        }
        let index = controller.lineIndex
        var highlights: [TextHighlight] = []
        var stillLive: [NoteID: NSRange] = [:]
        var pictures: [MarkdownViewerController.EmbeddedImageHighlight] = []
        for note in notes {
            // A note on an embedded picture: its region on the picture in the rendered view, its embed in the source.
            if case .embeddedImage(let anchor) = note.anchor {
                let region = anchor.region
                if !hidden.contains(note.id) {
                    pictures.append(.init(id: note.id, image: .init(source: anchor.source, occurrence: anchor.occurrence),
                                          region: CGRect(x: region.x, y: region.y, width: region.w, height: region.h),
                                          pixelSize: CGSize(width: region.imageW, height: region.imageH), color: note.color, state: note.displayState))
                }
                if let live = liveRanges[note.id] { stillLive[note.id] = live }
                highlights.append(TextHighlight(id: note.id, range: liveRanges[note.id] ?? index.range(for: anchor.embed), color: note.color, state: note.displayState,
                                                needsReview: needsReview.contains(note.id), isHidden: hidden.contains(note.id)))
                continue
            }
            guard case .text(let anchor) = note.anchor else { continue }
            let range: NSRange
            if let live = liveRanges[note.id] {
                range = live
                stillLive[note.id] = live
            } else {
                range = index.range(for: anchor)
            }
            highlights.append(TextHighlight(
                id: note.id, range: range, color: note.color, state: note.displayState,
                needsReview: needsReview.contains(note.id), isInvalidated: invalidatedNotes.contains(note.id),
                isHidden: hidden.contains(note.id)
            ))
        }
        liveRanges = stillLive
        if let markdown, markdown.imageHighlights != pictures { markdown.imageHighlights = pictures }
        controller.highlights = highlights
    }

    /// After an edit the controller shifted its highlight ranges; remember them until save.
    private func liveRangesDidShift() {
        guard let controller = textController else { return }
        for highlight in controller.highlights {
            liveRanges[highlight.id] = highlight.range
            if highlight.isInvalidated { invalidatedNotes.insert(highlight.id) }
        }
    }

    /// Writes shifted anchors back, saves notes whose text was deleted as removals (a point where it was), and orphans
    /// notes whose text was replaced.
    private func persistLiveAnchors(_ ranges: [NoteID: NSRange], invalidated: Set<NoteID>, in text: String, hash: String) async {
        guard !ranges.isEmpty else { return }
        let index = LineIndex(text)
        for note in notes {
            guard let range = ranges[note.id] else { continue }
            do {
                if case .embeddedImage(var picture) = note.anchor {
                    // The embed moved with the edit; gone, or now embedding another picture, the note is orphaned.
                    let embedText = (text as NSString).substring(with: NSIntersectionRange(range, NSRange(location: 0, length: (text as NSString).length)))
                    if invalidated.contains(note.id) || !embedText.contains(picture.source) {
                        if note.state != .orphaned { try await noteStore.markOrphaned(note.id) }
                    } else {
                        picture.embed = ReAnchorer.make(from: range, in: text, index: index, hash: hash)
                        picture.occurrence = ReAnchorer.embedOccurrence(of: picture.source, before: range.location, in: text)
                        anchorsBeingSaved[note.id, default: []].append(.embeddedImage(picture))
                        try await noteStore.updateAnchor(note.id, anchor: .embeddedImage(picture))
                    }
                    continue
                }
                guard case .text(let current) = note.anchor else { continue }
                if invalidated.contains(note.id) {
                    if note.state != .orphaned { try await noteStore.markOrphaned(note.id) }
                } else if range.length == 0, !current.text.isEmpty {
                    // Deleted while editing, but undo or a paste may have put it back: the saved text decides. Found,
                    // the note follows it; only text that is really gone is a removal, at the point the edit left.
                    let result = ReAnchorer.text(current, in: text, newHash: hash, fileName: fileName)
                    switch result {
                    case .moved(let moved), .movedNeedsReview(let moved):
                        if case .movedNeedsReview = result { needsReview.insert(note.id) }
                        anchorsBeingSaved[note.id, default: []].append(moved)
                        try await noteStore.updateAnchor(note.id, anchor: moved)
                    case .unchanged:
                        // The file is exactly as it was: the stored anchor is still right.
                        break
                    case .removed(let point):
                        anchorsBeingSaved[note.id, default: []].append(point)
                        try await noteStore.applyRelocation(note.id, to: point, removed: true, author: nil)
                    case .orphaned:
                        let point = ReAnchorer.make(from: range, in: text, index: index, hash: hash)
                        anchorsBeingSaved[note.id, default: []].append(.text(point))
                        try await noteStore.applyRelocation(note.id, to: .text(point), removed: true, author: nil)
                    }
                } else {
                    let anchor = ReAnchorer.make(from: range, in: text, index: index, hash: hash)
                    anchorsBeingSaved[note.id, default: []].append(.text(anchor))
                    try await noteStore.updateAnchor(note.id, anchor: .text(anchor))
                }
            } catch {
                Log.notes.error("persisting anchor for \(note.id.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
        if !isDirty {
            liveRanges = [:]
            invalidatedNotes = []
            // Their observations may still be on the way; with no live ranges left, they change nothing.
            anchorsBeingSaved = [:]
        }
    }

    /// Applies one note's re-anchoring result. A note found again takes its new anchor (on changed words, a move its
    /// thread records), and an orphan returns to the
    /// state it had before (`recoverOrphan`); one whose text was removed becomes a point where it was, said in its
    /// thread as Gloss's own finding; a lost one is orphaned, which leaves a resolved note as it is.
    private func apply(_ result: ReAnchorResult, to note: Note, unchanged anchor: Anchor) async throws {
        guard pastIteration == nil else { return }
        switch result {
        case .unchanged:
            // Exactly what it was when the note was made: an orphan's place is back.
            if note.state == .orphaned { try await noteStore.recoverOrphan(note.id, anchor: anchor) }
        case .moved(let moved), .movedNeedsReview(let moved):
            if case .movedNeedsReview = result { needsReview.insert(note.id) } else { needsReview.remove(note.id) }
            // An orphan has its place back; found on changed words, the thread records the move (`applyReanchor`).
            if note.state == .orphaned || moved != anchor {
                // This session's own write: when it comes back after typing has begun (the notes arrived late),
                // it must not be taken for someone else's move and drop the typed shift.
                anchorsBeingSaved[note.id, default: []].append(moved)
                try await noteStore.applyReanchor(note.id, to: moved)
            }
        case .removed(let point):
            needsReview.remove(note.id)
            anchorsBeingSaved[note.id, default: []].append(point)
            try await noteStore.applyRelocation(note.id, to: point, removed: true, author: nil)
        case .orphaned:
            if note.state != .orphaned { try await noteStore.markOrphaned(note.id) }
        }
    }

    /// Re-anchors every text note against new content (reload after an external change, or a file that changed
    /// while it was closed).
    func reanchorAll(in text: String, hash: String) async {
        await reanchor(notes, in: text, hash: hash)
    }

    /// Notes brought back from Recently Deleted, against the text on disk now: the file may have changed while they
    /// were away. A page re-anchors its notes when it next settles.
    func reanchorRestored(_ restored: [Note]) async {
        if isDirty, csvController == nil, let controller = textController {
            // Unsaved edits: the notes are found in the text being edited and held as live ranges, which the next
            // save stores; what is on disk no longer matches what is shown. Held only once the notes are listed here,
            // since drawing drops live ranges of notes it doesn't have.
            let ids = Set(restored.map(\.id))
            for _ in 0..<50 where !ids.isSubset(of: notes.map(\.id)) { try? await Task.sleep(for: .milliseconds(50)) }
            let text = controller.text
            let index = LineIndex(text)
            for note in restored {
                guard case .text(let anchor) = note.anchor else { continue }
                switch ReAnchorer.text(anchor, in: text, newHash: Data(text.utf8).sha256Hex, fileName: fileName) {
                case .unchanged: liveRanges[note.id] = index.range(for: anchor)
                case .moved(.text(let moved)), .movedNeedsReview(.text(let moved)): liveRanges[note.id] = index.range(for: moved)
                default: continue
                }
            }
            syncHighlights()
            return
        }
        guard let text = baseText else { return }
        // The same hash the open-time pass uses: a grid's anchors hash the text itself.
        let hash = csvController != nil ? Data(text.utf8).sha256Hex : fingerprintAtOpen?.hash ?? Data(text.utf8).sha256Hex
        await reanchor(restored, in: text, hash: hash)
    }

    private func reanchor(_ notes: [Note], in text: String, hash: String) async {
        guard pastIteration == nil else { return }
        for note in notes {
            if Task.isCancelled { return }
            do {
                switch note.anchor {
                case .text(let anchor):
                    try await apply(ReAnchorer.text(anchor, in: text, newHash: hash, fileName: fileName), to: note, unchanged: .text(anchor))
                case .embeddedImage(let anchor):
                    try await apply(ReAnchorer.embeddedImage(anchor, in: text, newHash: hash), to: note, unchanged: .embeddedImage(anchor))
                default:
                    continue
                }
            } catch {
                Log.notes.error("re-anchoring \(note.id.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
        syncHighlights()
    }

    /// Where the floating "Add Note" button should sit: the current selection's rect in top-left window
    /// coordinates, or nil when nothing is selected or an editor is already open. Reads the controllers'
    /// observable selection state, so SwiftUI re-evaluates it as the selection changes.
    var selectionAffordanceRect: CGRect? {
        guard pastIteration == nil, noteEditor == nil, reanchoringNoteID == nil, html?.isNoteMode != true else { return nil }
        if let csv = csvController {
            guard csv.hasSelection else { return nil }
            return csv.rectProvider(csv.selection)
        }
        if let pdf = pdfController {
            guard let anchor = pdf.selectionAnchor else { return nil }
            let bounds = anchor.bounds?.cgRect ?? pdf.textSelection?.bounds ?? .zero
            return pdf.rect(forPage: anchor.page, bounds: bounds)
        }
        if let image = imageController {
            guard let selection = image.selection, image.selectionAnchor != nil else { return nil }
            return image.rect(forPixelRect: selection)
        }
        if let markdown, markdown.mode == .rendered, let selection = markdown.imageSelection {
            return markdown.rect(for: selection.image, region: selection.region, pixelSize: selection.pixelSize)
        }
        if let html, html.mode == .rendered, let picked = html.selectedPicture {
            return picked.picture?.windowRect ?? picked.windowRect
        }
        if let controller = textController {
            if let rendered, rendered.isShowingRendered {
                // A caret inside a link or code span maps to the whole span's source; only a real selection counts.
                guard rendered.hasRenderedSelection, let mapping = rendered.renderedSelectionMapping, mapping.source.length > 0 else { return nil }
                return rendered.rect(forSource: mapping.source)
            }
            guard controller.selection.length > 0 else { return nil }
            return controller.rect(for: controller.selection)
        }
        return nil
    }

    /// Starts a note for the current selection (or the whole file when there is no text viewer).
    func beginNote() {
        // Notes are added to the iteration in progress, on the file as it is.
        guard pastIteration == nil else { return }
        if let reanchoring = reanchoringNoteID {
            placeOrphan(reanchoring)
            return
        }
        if let csv = csvController {
            guard let anchor = csv.selectionAnchor() else { return }
            let rect = csv.rectProvider(csv.selection) ?? CGRect(x: 40, y: 40, width: 1, height: 1)
            noteEditor = NoteEditorState(anchor: .text(anchor), body: "", color: lastUsedColor, anchorRect: rect)
            return
        }
        if let pdf = pdfController {
            guard let anchor = pdf.noteAnchor else { return }
            let bounds = anchor.bounds?.cgRect ?? pdf.textSelection?.bounds ?? .zero
            let rect = pdf.rect(forPage: anchor.page, bounds: bounds) ?? CGRect(x: 40, y: 40, width: 1, height: 1)
            noteEditor = NoteEditorState(anchor: .pdf(anchor), body: "", color: lastUsedColor, anchorRect: rect)
            return
        }
        if let image = imageController {
            guard let anchor = image.selectionAnchor else { return }
            let rect = image.rect(forPixelRect: image.selection ?? .zero) ?? CGRect(x: 40, y: 40, width: 1, height: 1)
            noteEditor = NoteEditorState(anchor: .image(anchor), body: "", color: lastUsedColor, anchorRect: rect)
            return
        }
        // A region of a picture in rendered Markdown, or the whole picture.
        if let markdown, markdown.mode == .rendered, let selection = markdown.imageSelection, let controller = textController {
            let data = markdown.imageData(for: selection.image.source, occurrence: selection.image.occurrence)
            let region = ImageAnchor(x: Int(selection.region.minX), y: Int(selection.region.minY), w: Int(selection.region.width), h: Int(selection.region.height),
                                     imageW: Int(selection.pixelSize.width), imageH: Int(selection.pixelSize.height), hash: data?.sha256Hex)
            let embed = ReAnchorer.make(from: selection.embedSource, in: controller.text, index: controller.lineIndex, hash: Data(controller.text.utf8).sha256Hex)
            let anchor = EmbeddedImageAnchor(source: selection.image.source, occurrence: selection.image.occurrence, region: region, embed: embed)
            let rect = markdown.rect(for: selection.image, region: selection.region, pixelSize: selection.pixelSize) ?? CGRect(x: 40, y: 40, width: 1, height: 1)
            noteEditor = NoteEditorState(anchor: .embeddedImage(anchor), body: "", color: lastUsedColor, anchorRect: rect)
            return
        }
        // A picture chosen on a web page, or a region of one.
        if let html, html.mode == .rendered, let picked = html.selectedPicture {
            beginNote(element: picked)
            return
        }
        if let controller = textController {
            var range = controller.selection
            if let rendered, rendered.isShowingRendered {
                guard let mapping = rendered.renderedSelectionMapping else { return }
                range = mapping.source
            }
            if range.length == 0 {
                range = controller.lineIndex.contentRange(ofLine: controller.lineIndex.position(forUTF16Offset: range.location).line)
            }
            guard range.length > 0 else { return }
            let anchor = ReAnchorer.make(from: range, in: controller.text, index: controller.lineIndex, hash: Data(controller.text.utf8).sha256Hex)
            let rect = rendered?.rect(forSource: range) ?? controller.rect(for: range) ?? .zero
            let lineLength = controller.lineIndex.contentRange(ofLine: anchor.start.line).length
            noteEditor = NoteEditorState(anchor: .text(anchor), body: "", color: lastUsedColor, anchorRect: rect,
                                         columns: anchor.partialColumns(lineLength: lineLength))
        } else {
            noteEditor = NoteEditorState(anchor: .wholeFile, body: "", color: lastUsedColor, anchorRect: CGRect(x: 40, y: 40, width: 1, height: 1))
        }
    }

    /// Starts re-anchoring: the viewer jumps near the old position and waits for a new selection.
    func beginReanchor(_ note: Note) {
        reanchoringNoteID = note.id
        banner = .reanchoring
        if let controller = textController, case .text(let anchor) = note.anchor {
            let range = controller.lineIndex.contentRange(ofLine: anchor.start.line)
            if let rendered { rendered.scroll(toSource: range, select: true) } else { controller.scroll(to: range) }
        }
    }

    func cancelReanchor() {
        reanchoringNoteID = nil
        if banner == .reanchoring { banner = nil }
    }

    /// Uses the current selection as the orphan's new anchor and makes it a draft again.
    private func placeOrphan(_ id: NoteID) {
        var newAnchor: Anchor?
        if let controller = textController {
            var range = controller.selection
            if let rendered, rendered.isShowingRendered, let mapping = rendered.renderedSelectionMapping { range = mapping.source }
            if range.length > 0 {
                newAnchor = .text(ReAnchorer.make(from: range, in: controller.text, index: controller.lineIndex, hash: Data(controller.text.utf8).sha256Hex))
            }
        } else if let image = imageController, let anchor = image.selectionAnchor {
            newAnchor = .image(anchor)
        } else if let pdf = pdfController, let anchor = pdf.noteAnchor {
            newAnchor = .pdf(anchor)
        } else if let csv = csvController, let anchor = csv.selectionAnchor() {
            newAnchor = .text(anchor)
        }
        guard let newAnchor else { return }
        cancelReanchor()
        Task {
            do {
                try await noteStore.recoverOrphan(id, anchor: newAnchor)
                needsReview.remove(id)
            } catch {
                lastError = "Re-anchoring failed: \(error.userMessage)"
            }
        }
    }

    /// A PDF note's place on its page: its region, or the match of its text it was made on.
    static func bounds(of anchor: PDFAnchor, in pdf: PDFViewerController) -> CGRect? {
        if let bounds = anchor.bounds { return bounds.cgRect }
        guard let text = anchor.text, !text.isEmpty else { return nil }
        return pdf.textBounds(page: anchor.page, text: text, occurrence: anchor.occurrence ?? 0)
    }

    func editNote(_ note: Note) {
        var rect = CGRect(x: 40, y: 40, width: 1, height: 1)
        if let pdf = pdfController, case .pdf(let anchor) = note.anchor, let bounds = Self.bounds(of: anchor, in: pdf),
           let found = pdf.rect(forPage: anchor.page, bounds: bounds) {
            rect = found
        }
        if let image = imageController, case .image(let anchor) = note.anchor,
           let found = image.rect(forPixelRect: CGRect(x: anchor.x, y: anchor.y, width: anchor.w, height: anchor.h)) {
            rect = found
        }
        if let controller = textController, case .text = note.anchor,
           let range = controller.highlights.first(where: { $0.id == note.id })?.range,
           let found = rendered?.rect(forSource: range) ?? controller.rect(for: range) {
            rect = found
        }
        if let html, case .element = note.anchor, let found = html.elementRects[note.id] ?? html.pageRect {
            rect = found
        }
        if let csv = csvController, case .text = note.anchor, let place = csv.place(of: note.id), let found = csv.rectProvider(place) {
            rect = found
        }
        if case .embeddedImage(let anchor) = note.anchor {
            let region = anchor.region
            let image = MarkdownViewerController.EmbeddedImageRef(source: anchor.source, occurrence: anchor.occurrence)
            if let markdown, markdown.mode == .rendered,
               let found = markdown.rect(for: image, region: CGRect(x: region.x, y: region.y, width: region.w, height: region.h),
                                         pixelSize: CGSize(width: region.imageW, height: region.imageH)) {
                rect = found
            } else if let controller = textController, let range = controller.highlights.first(where: { $0.id == note.id })?.range,
                      let found = rendered?.rect(forSource: range) ?? controller.rect(for: range) {
                rect = found
            }
        }
        var columns: ClosedRange<Int>?
        if let controller = textController, case .text(let anchor) = note.anchor {
            columns = anchor.partialColumns(lineLength: controller.lineIndex.contentRange(ofLine: anchor.start.line).length)
        }
        noteEditor = NoteEditorState(existingID: note.id, anchor: note.anchor, body: note.body, color: note.color, anchorRect: rect, columns: columns)
    }

    func commitNote(_ state: NoteEditorState) async {
        guard let document else { return }
        lastUsedColor = state.color
        do {
            if let existing = state.existingID {
                try await noteStore.updateBody(existing, body: state.body)
                try await noteStore.updateColor(existing, color: state.color)
                if let note = try await noteStore.note(existing) { onNoteCommitted(note) }
            } else {
                // The element's picture is taken before the note exists, so its own outline is not in the crop.
                var elementCrop: (png: Data, width: Int, height: Int)?
                if case .element(let anchor) = state.anchor, let snapshot = html?.snapshotProvider {
                    // A crop is a bonus: a page that moved on, or a view that is gone, must not lose the note.
                    elementCrop = try? await snapshot(state.pageCrop ?? anchor.rect)
                }
                await beforeCreatingNote(document.id)
                let note = try await noteStore.createNote(documentID: document.id, anchor: state.anchor, body: state.body, color: state.color)
                onNoteCommitted(note)
                if case .embeddedImage(let anchor) = state.anchor, let data = markdown?.imageData(for: anchor.source, occurrence: anchor.occurrence) {
                    // A bonus too: a picture that can't be decoded (an SVG, a huge one) still leaves the note.
                    do {
                        try await saveEmbeddedCrop(of: anchor, from: data, for: note.id)
                    } catch {
                        Log.notes.error("crop of \(anchor.fileName, privacy: .public) failed: \(error, privacy: .public)")
                    }
                }
                if case .image(let anchor) = state.anchor, let image = imageController {
                    try await saveCrop(of: anchor, from: image, for: note.id)
                }
                if case .pdf(let anchor) = state.anchor, let pdf = pdfController {
                    try await savePageRender(of: anchor, from: pdf, for: note.id)
                }
                if let elementCrop {
                    try await saveElementCrop(elementCrop, for: note.id)
                }
                clearSelection()
            }
        } catch {
            lastError = "Saving the note failed: \(error.userMessage)"
            // The crop already took the chosen picture's drawing off the page; an Add Note left beside nothing
            // would be stale.
            html?.selectedPicture = nil
        }
        noteEditor = nil
    }

    /// Drops the viewer's selection after a note was made from it, so the Add Note button goes away and the
    /// note's own highlight shows where it sits.
    /// Escape on a document: closes the note composer, or else puts the Add Note button away by clearing the
    /// selection it sits beside. False when neither is showing, so Escape goes on to whatever else wants it.
    func dismissNoteAffordance() -> Bool {
        if noteEditor != nil {
            noteEditor = nil
            return true
        }
        guard selectionAffordanceRect != nil else { return false }
        clearSelection()
        return true
    }

    private func clearSelection() {
        imageController?.selection = nil
        markdown?.imageSelection = nil
        html?.selectedPicture = nil
        pdfController?.clearSelection()
        csvController?.deselectAll()
        if let rendered, rendered.isShowingRendered {
            rendered.collapseRenderedSelection()
        } else {
            textController?.collapseSelection()
        }
    }

    /// Renders the page region (or the whole page for a text selection) at 2x and records it on the note.
    private func savePageRender(of anchor: PDFAnchor, from pdf: PDFViewerController, for noteID: NoteID) async throws {
        guard let rendered = pdf.renderPNG(page: anchor.page, bounds: anchor.bounds?.cgRect) else { return }
        let directory = attachmentDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (fileName as NSString).deletingPathExtension
        let url = directory.appendingPathComponent("\(base)-page\(anchor.page + 1)-\(noteID.rawValue.suffix(6)).png")
        try rendered.data.write(to: url, options: .atomic)
        _ = try await noteStore.addAttachment(noteID: noteID, kind: .pageRender, localPath: url.path, width: rendered.width, height: rendered.height)
    }

    /// Writes the region as a PNG into the attachment cache and records it on the note.
    /// The region of an embedded picture (all of it for a whole-image note), cut from its own bytes, so the agent
    /// sees exactly what the note is about.
    private func saveEmbeddedCrop(of anchor: EmbeddedImageAnchor, from data: Data, for noteID: NoteID) async throws {
        let decoded = try await Self.decodeImage(data, fileName: anchor.fileName)
        let region = anchor.region
        let rect = CGRect(x: region.x, y: region.y, width: region.w, height: region.h)
        guard let crop = ImageDecoder.crop(decoded, to: rect), let png = ImageDecoder.pngData(crop) else { return }
        let directory = attachmentDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(anchor.attachmentBaseName)-\(anchor.isWholeImage ? "image" : "region")-\(noteID.rawValue.suffix(6)).png")
        try png.write(to: url, options: .atomic)
        _ = try await noteStore.addAttachment(noteID: noteID, kind: .crop, localPath: url.path, width: crop.width, height: crop.height)
    }

    private func saveCrop(of anchor: ImageAnchor, from image: ImageViewerController, for noteID: NoteID) async throws {
        let rect = CGRect(x: anchor.x, y: anchor.y, width: anchor.w, height: anchor.h)
        guard let crop = ImageDecoder.crop(image.image, to: rect), let png = ImageDecoder.pngData(crop) else { return }
        let directory = attachmentDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (fileName as NSString).deletingPathExtension
        let url = directory.appendingPathComponent("\(base)-region-\(noteID.rawValue.suffix(6)).png")
        try png.write(to: url, options: .atomic)
        _ = try await noteStore.addAttachment(noteID: noteID, kind: .crop, localPath: url.path, width: crop.width, height: crop.height)
    }

    /// Writes the element's 2x PNG, taken by the browser, so the agent sees what the note points at.
    private func saveElementCrop(_ crop: (png: Data, width: Int, height: Int), for noteID: NoteID) async throws {
        let directory = attachmentDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(base)-element-\(noteID.rawValue.suffix(6)).png")
        try crop.png.write(to: url, options: .atomic)
        _ = try await noteStore.addAttachment(noteID: noteID, kind: .crop, localPath: url.path, width: crop.width, height: crop.height)
    }

    func resolveNote(_ id: NoteID) async {
        do { try await noteStore.resolve(id) } catch { lastError = "Resolving the note failed: \(error.userMessage)" }
        needsReview.remove(id)
    }

    /// Scrolls the viewer to a note and selects its range.
    /// Scrolls to a note. `select` also selects its range and focuses the viewer; browsing from the panel does not.
    func reveal(_ note: Note, select: Bool = true) {
        if let pdf = pdfController, case .pdf(let anchor) = note.anchor {
            pdf.selectedNoteID = note.id
            pdf.scroll(toPage: anchor.page, bounds: Self.bounds(of: anchor, in: pdf))
            return
        }
        if let image = imageController, case .image(let anchor) = note.anchor {
            image.selectedNoteID = note.id
            image.reveal(CGRect(x: anchor.x, y: anchor.y, width: anchor.w, height: anchor.h))
            return
        }
        if let html, case .element(let anchor) = note.anchor {
            if html.mode == .source, let line = anchor.line, let controller = textController {
                controller.scroll(to: controller.lineIndex.contentRange(ofLine: line), select: select)
            } else {
                html.scrollToElement?(anchor.selector)
            }
            return
        }
        if let csv = csvController, case .text = note.anchor {
            // Its cells, columns or records in the grid, which shows no text to select.
            csv.show(note.id)
            return
        }
        guard let controller = textController, let range = controller.highlights.first(where: { $0.id == note.id })?.range else { return }
        switch note.anchor {
        case .text:
            if let rendered { rendered.scroll(toSource: range, select: select) } else { controller.scroll(to: range, select: select) }
        case .embeddedImage:
            // Into view only: selecting the embed would select the picture's text, not its region.
            if let rendered { rendered.scroll(toSource: range, select: false) } else { controller.scroll(to: range, select: false) }
        default:
            break
        }
    }

    // MARK: Stepping through notes (⌘' and ⇧⌘')

    /// The note last reached with Next or Previous Note; the next step goes on from it while it is still where the
    /// caret is.
    private(set) var steppedNoteID: NoteID?
    /// The source editor's selection when the step was taken; once it moves, the next step starts from the caret.
    private var selectionAtStep: NSRange?

    /// This document's open notes in reading order, each with a key for its place: text by offset, PDF by page then
    /// top to bottom, images top to bottom then left to right. Orphans and whole-file notes have no place and are left out,
    /// and so are notes the panel isn't listing, so a step never selects a card that isn't there.
    var steppableNotes: [(id: NoteID, key: Double)] {
        let open = notes.filter {
            $0.state != .resolved && $0.state != .orphaned && !hiddenNoteIDs.contains($0.id)
        }
        let keyed: [(id: NoteID, key: Double)] = open.compactMap { note in
            switch note.anchor {
            case .text:
                if let csv = csvController {
                    // A spreadsheet's notes by their first cell, row then column.
                    guard let cell = csv.firstCell(of: note.id) else { return nil }
                    return (note.id, Double(cell.row) * 10_000 + Double(cell.column))
                }
                guard let range = textController?.highlights.first(where: { $0.id == note.id })?.range else { return nil }
                return (note.id, Double(range.location))
            case .pdf(let anchor):
                // Page space runs up the page, so a higher top comes first; text notes by the match they are on.
                let top = pdfController.flatMap { Self.bounds(of: anchor, in: $0) }?.maxY ?? anchor.bounds?.cgRect.maxY ?? 999_999
                return (note.id, Double(anchor.page) * 1_000_000 - top)
            case .image(let anchor):
                // Top to bottom, then left to right, as a PDF's regions are.
                return (note.id, Double(anchor.y) * 1_000_000 + Double(anchor.x))
            case .element(let anchor):
                return (note.id, anchor.rect.y * 10_000 + anchor.rect.x)
            case .embeddedImage:
                guard let range = textController?.highlights.first(where: { $0.id == note.id })?.range else { return nil }
                return (note.id, Double(range.location))
            case .wholeFile:
                return nil
            }
        }
        return keyed.sorted { $0.key < $1.key }
    }

    /// Where a step goes: on from the note last stepped to, or else from the caret's offset, wrapping at either end.
    nonisolated static func step<ID: Equatable>(from caret: Double?, current: ID?, in ordered: [(id: ID, key: Double)], forward: Bool) -> ID? {
        guard !ordered.isEmpty else { return nil }
        if let current, let index = ordered.firstIndex(where: { $0.id == current }) {
            return ordered[(index + (forward ? 1 : ordered.count - 1)) % ordered.count].id
        }
        guard let caret else { return (forward ? ordered.first : ordered.last)?.id }
        return forward
            ? (ordered.first { $0.key > caret } ?? ordered.first)?.id
            : (ordered.last { $0.key < caret } ?? ordered.last)?.id
    }

    /// The stepped note, until the caret moves (in the source editor, a caret moved elsewhere starts afresh).
    private var currentSteppedNoteID: NoteID? {
        guard let steppedNoteID else { return nil }
        if let controller = textController, rendered == nil {
            return controller.selection == selectionAtStep ? steppedNoteID : nil
        }
        return steppedNoteID
    }

    /// "2 of 5" for the status bar while a stepped-to note is current.
    var stepPosition: (index: Int, count: Int)? {
        guard let id = currentSteppedNoteID else { return nil }
        let ordered = steppableNotes
        return ordered.firstIndex { $0.id == id }.map { ($0 + 1, ordered.count) }
    }

    // MARK: Changed lines (a pull request's file, or an iteration's changes)

    /// The iteration whose snapshot the tinted lines compare against, while Show Changes Since is on (issue #18).
    private(set) var changesSinceIteration: Int?
    /// The provider in place before Show Changes Since (a pull request's), put back when it is turned off.
    @ObservationIgnored private var providerBeforeIterationChanges: ((String) async -> LineChanges?)??

    /// Tints the lines changed since `iteration`, whose content was `snapshot`, as a pull request's changes are
    /// tinted; nil puts back what was tinted before. Text documents only.
    func showChanges(since iteration: Int?, snapshot: String?) {
        if let iteration, let snapshot {
            if providerBeforeIterationChanges == nil { providerBeforeIterationChanges = .some(lineChangesProvider) }
            changesSinceIteration = iteration
            lineChangesProvider = { [weak self] _ in
                guard let text = self?.textController?.text else { return nil }
                return await IterationDiff.computed(from: snapshot, to: text)
            }
        } else {
            changesSinceIteration = nil
            if let previous = providerBeforeIterationChanges { lineChangesProvider = previous }
            providerBeforeIterationChanges = nil
            if lineChangesProvider == nil { textController?.lineChanges = nil }
        }
        refreshLineChanges()
    }

    /// Typing while Show Changes Since is on: the snapshot is compared with the text again once typing pauses, so
    /// the tints stay on the lines that changed rather than on the line numbers they had (a pull request's file is
    /// never edited, so its tints need no such pass).
    private func textChangedUnderChanges() {
        guard changesSinceIteration != nil else { return }
        changesRefreshTask?.cancel()
        changesRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.changesRefreshDelay)
            guard !Task.isCancelled else { return }
            self?.refreshLineChanges()
        }
    }
    @ObservationIgnored private var changesRefreshTask: Task<Void, Never>?
    nonisolated static let changesRefreshDelay: Duration = .milliseconds(300)
    /// Bumped by each refresh; a slower, older diff finishing after a newer one is dropped.
    @ObservationIgnored private var lineChangesGeneration = 0

    /// Asks the provider, when there is one, which lines a change touched; the editor tints and steps through them.
    private func refreshLineChanges() {
        guard let provider = lineChangesProvider, let controller = textController else { return }
        let path = path
        lineChangesGeneration += 1
        let generation = lineChangesGeneration
        Task { [weak self] in
            let changes = await provider(path).map { Self.editorLines(of: $0, in: controller.text, lineIndex: controller.lineIndex) }
            let omitted = changes == nil ? await self?.patchOmittedProvider?(path) ?? false : false
            guard let self, self.textController === controller, generation == self.lineChangesGeneration else { return }
            self.changesUnknown = omitted
            if changes != controller.lineChanges { self.steppedHunk = nil }
            controller.lineChanges = changes
        }
    }

    /// Git's line numbers on the editor's lines. Git ends a line only at "\n"; the editor also breaks at U+2028,
    /// U+2029, U+0085 and a lone "\r", so in a file holding one of those every tint below it would be a row off.
    nonisolated static func editorLines(of changes: LineChanges, in text: String, lineIndex: LineIndex) -> LineChanges {
        // One pass over the UTF-16 units: where each git line starts, and whether anything else breaks lines.
        var starts = [0]
        var offset = 0
        var otherBreaks = false
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if previous == 0x0D, unit != 0x0A { otherBreaks = true }
            if unit == 0x2028 || unit == 0x2029 || unit == 0x85 { otherBreaks = true }
            offset += 1
            if unit == 0x0A { starts.append(offset) }
            previous = unit
        }
        if previous == 0x0D { otherBreaks = true }
        guard otherBreaks else { return changes }
        func editorLine(_ gitLine: Int) -> Int {
            // Past the last line (a deletion at the end of a file without a final newline): after it.
            guard gitLine - 1 < starts.count else { return lineIndex.lineCount + 1 }
            return lineIndex.position(forUTF16Offset: starts[max(gitLine - 1, 0)]).line
        }
        // The last editor row of a git line: just before where the next git line starts.
        func lastEditorLine(_ gitLine: Int) -> Int {
            gitLine < starts.count ? max(editorLine(gitLine), editorLine(gitLine + 1) - 1) : lineIndex.lineCount
        }
        return LineChanges(added: changes.added.map { editorLine($0.lowerBound)...max(editorLine($0.lowerBound), lastEditorLine($0.upperBound)) },
                           deletions: changes.deletions.map(editorLine))
    }

    /// Each hunk in file order, keyed by its first line.
    var changeHunks: [(id: Int, key: Double)] {
        (textController?.lineChanges?.hunks ?? []).enumerated().map { ($0.offset, Double($0.element.lowerBound)) }
    }

    private(set) var steppedHunk: Int?
    /// The selection when the hunk was stepped to; once it moves, the next step starts from the caret again.
    private var selectionAtHunkStep: NSRange?

    private var currentSteppedHunk: Int? {
        guard let steppedHunk, let controller = textController, controller.selection == selectionAtHunkStep,
              let count = controller.lineChanges?.hunks.count, steppedHunk < count else { return nil }
        return steppedHunk
    }

    /// "2 of 7" while a stepped-to hunk is current.
    var changePosition: (index: Int, count: Int)? {
        guard let index = currentSteppedHunk, let lineChanges = textController?.lineChanges else { return nil }
        return (index + 1, lineChanges.hunks.count)
    }

    /// Next or previous hunk, from the one last stepped to, else from the caret's line; wraps at either end.
    @discardableResult
    func stepChange(forward: Bool) -> Bool {
        guard let controller = textController, let changes = controller.lineChanges else { NSSound.beep(); return false }
        let caret = Double(controller.lineIndex.position(forUTF16Offset: controller.selection.location).line)
        // The first Next counts a hunk starting on the caret's own line (on open the caret sits on line 1).
        let from = steppedHunk == nil && selectionAtHunkStep == nil && forward ? caret - 0.5 : caret
        guard let index = Self.step(from: from, current: currentSteppedHunk, in: changeHunks, forward: forward) else { NSSound.beep(); return false }
        steppedHunk = index
        selectionAtHunkStep = controller.selection
        // In the view that is showing: a rendered Markdown file tints its changes too.
        show(line: changes.hunks[index].lowerBound)
        return true
    }

    /// Goes to the next or previous open note in this document; returns it so the notes panel can follow.
    @discardableResult
    func stepNote(forward: Bool) -> Note? {
        let caret: Double? = (textController != nil && rendered == nil) ? Double(textController?.selection.location ?? 0) : nil
        guard let id = Self.step(from: caret, current: currentSteppedNoteID, in: steppableNotes, forward: forward),
              let note = notes.first(where: { $0.id == id }) else {
            NSSound.beep()
            return nil
        }
        steppedNoteID = id
        selectionAtStep = textController?.selection
        // Shown, not selected: selecting would float Add Note over a note that already exists.
        reveal(note, select: false)
        return note
    }

    /// Shows the Go to Line sheet (⌘L).
    var isGoToLinePresented = false

    /// Parses what the Go to Line field takes: `12`, `12:4`, or `12,4` (line, then optional 1-based column).
    nonisolated static func parseGoToLine(_ input: String) -> (line: Int, column: Int?)? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), let line = Int(parts[0]), line > 0 else { return nil }
        if parts.count == 2 {
            guard let column = Int(parts[1]), column > 0 else { return nil }
            return (line, column)
        }
        return (line, nil)
    }

    /// Scrolls to a line, selecting it, or puts the caret at `column` on it. Lines past the end land on the last.
    func goTo(line: Int, column: Int?) {
        guard let controller = textController else { return }
        let index = controller.lineIndex
        let content = index.contentRange(ofLine: line)
        var range = content
        if let column {
            var location = content.location + min(column - 1, content.length)
            // Never between the halves of a surrogate pair or inside a composed character (typing there splits it).
            if location < content.location + content.length {
                location = (controller.text as NSString).rangeOfComposedCharacterSequence(at: location).location
            }
            range = NSRange(location: location, length: 0)
        }
        if let html, html.isShowingRendered {
            html.scroll(toSource: range.length == 0 ? content : range, select: true)
            return
        }
        guard let markdown, markdown.mode == .rendered else {
            if let rendered { rendered.scroll(toSource: range, select: true) } else { controller.scroll(to: range) }
            return
        }
        // A caret maps by the character at it.
        let target = range.length == 0 && range.location < content.location + content.length ? NSRange(location: range.location, length: 1) : range
        markdown.scroll(toSource: Self.renderedTarget(target, fromLine: line, in: markdown, index: index))
    }

    /// The rendered view maps only text that is shown: a blank line, or markup that renders to nothing, maps to no
    /// rendered range, and a jump there did nothing. Then the next line that renders.
    private static func renderedTarget(_ range: NSRange, fromLine line: Int, in markdown: MarkdownViewerController, index: LineIndex) -> NSRange {
        var target = range
        var current = line
        // An empty line maps to a point between paragraphs, not to text: it counts as not rendering.
        while target.length == 0 || markdown.map.renderedRanges(forSource: target).isEmpty, current < index.lineCount {
            current += 1
            target = index.contentRange(ofLine: current)
        }
        return target
    }

    /// Scrolls whichever view is showing to a line, without selecting it: the source editor, a rendered page, or a
    /// rendered Markdown file (at the next line that renders, when this one doesn't).
    private func show(line: Int) {
        guard let controller = textController else { return }
        let content = controller.lineIndex.contentRange(ofLine: line)
        if let html, html.isShowingRendered {
            html.scroll(toSource: content, select: false)
        } else if let markdown, markdown.mode == .rendered {
            markdown.scroll(toSource: Self.renderedTarget(content, fromLine: line, in: markdown, index: controller.lineIndex), select: false)
        } else {
            controller.scroll(to: content, select: false)
        }
    }

    func toggleMarkdownMode() {
        rendered?.toggle()
    }

    private func gutterClicked(line: Int, noteID: NoteID?) {
        if let noteID, let note = notes.first(where: { $0.id == noteID }) {
            editNote(note)
            return
        }
        guard let controller = textController else { return }
        let range = controller.lineIndex.contentRange(ofLine: line)
        controller.selection = range
        controller.scroll(to: range)
        beginNote()
    }
}
