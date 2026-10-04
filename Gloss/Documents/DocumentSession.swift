import AppKit
import Core
import Observation
import OSLog
import PDFKit
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
    }

    struct ConflictState {
        var regions: [MergeRegion]
        var theirsText: String
        var theirsFingerprint: Fingerprint
        var canMerge: Bool { ThreeWayMerge.resolve(regions) != nil }
    }

    static let readOnlyThreshold: Int64 = 2 * 1024 * 1024
    static let refuseThreshold: Int64 = 50 * 1024 * 1024

    let id: String
    let hostID: HostID
    let path: String
    /// From the file name at first, then `.text` when an unknown extension turned out to hold text.
    private(set) var kind: DocumentKind
    private let fileSystem: any FileSystemProvider
    private let noteStore: NoteStore

    private(set) var document: Document?
    private(set) var state: State = .loading
    /// Rendered/source toggle for markdown documents; nil for every other kind.
    private(set) var markdown: MarkdownViewerController?
    /// Rendered/source toggle for HTML documents; nil for every other kind.
    private(set) var html: HTMLViewerController?
    /// Whichever rendered view this document has.
    var rendered: (any RenderedDocumentController)? { markdown ?? html }
    private(set) var fingerprintAtOpen: Fingerprint?
    private(set) var attributesAtOpen: FileAttributes?
    /// The text as it was on disk when opened or last saved: the base for three-way merges.
    private(set) var baseText: String?
    private(set) var usedLatin1 = false
    private(set) var isDirty = false
    private(set) var isReadOnly = false
    var banner: Banner?
    var conflict: ConflictState?
    private(set) var isSaving = false
    var lastError: String?

    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var notesObservation: Task<Void, Never>?

    /// Notes of this document, in reading order, kept current by database observation.
    private(set) var notes: [Note] = []
    /// Notes whose last re-anchor was a guess; shown with a review badge until edited or resolved.
    private(set) var needsReview: Set<NoteID> = []
    /// Whether the notes observation has delivered once; a page change before that waits for it.
    @ObservationIgnored private var notesDelivered = false
    @ObservationIgnored private var pendingPageReanchor = false
    /// Live ranges of text notes while editing, before they are written back on save.
    @ObservationIgnored private var liveRanges: [NoteID: NSRange] = [:]
    @ObservationIgnored private var invalidatedNotes: Set<NoteID> = []
    /// The note being created or edited in the popover.
    var noteEditor: NoteEditorState?
    /// An orphaned note waiting for the user to select its new range (⌘⇧N then places it).
    var reanchoringNoteID: NoteID?
    var lastUsedColor: NoteColor = .yellow

    /// Where crops and page renders for this session's notes are written.
    let attachmentDirectory: URL

    /// The explorer root holding this file, when one is open; rendered HTML may read files only inside it.
    @ObservationIgnored var resourceRoot: () -> String? = { nil }
    /// For a web page reached through an ssh host's loopback: the tunnels to use. Set before `open`.
    var proxy: WebProxyMap?

    init(hostID: HostID, path: String, fileSystem: any FileSystemProvider, noteStore: NoteStore, attachmentDirectory: URL = AttachmentCache.notesRoot) {
        self.id = "\(hostID.rawValue):\(path)"
        self.hostID = hostID
        self.path = path
        self.kind = DocumentKindDetector.kind(forPath: path)
        self.fileSystem = fileSystem
        self.noteStore = noteStore
        self.attachmentDirectory = attachmentDirectory
    }

    var isLoaded: Bool {
        if case .loading = state { return false }
        return true
    }

    var fileName: String { Core.Document.displayName(of: path) }
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

    // MARK: Open and reload

    /// A failed open as a sentence for the viewer, not a Swift error dump.
    nonisolated static func openFailure(_ error: any Error) -> String {
        switch error as? FileSystemError {
        case .notFound: "The file isn't there. It may have been moved, renamed, or deleted."
        case .permissionDenied: "You don't have permission to read this file."
        case .notADirectory: "Part of this path isn't a folder."
        case .io(let detail): "The file couldn't be read: \(detail)"
        default: error.localizedDescription
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
            if kind == .image {
                let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
                let decoded = try ImageDecoder.decode(data, fileName: fileName)
                fingerprintAtOpen = fingerprint
                document = try await noteStore.upsertDocument(hostID: hostID, path: path, kind: kind, fingerprint: fingerprint)
                let controller = ImageViewerController(image: decoded)
                controller.onNoteClick = { [weak self] id in
                    guard let self, let note = self.notes.first(where: { $0.id == id }) else { return }
                    self.editNote(note)
                }
                state = .image(controller)
                startWatching()
                observeNotes()
                return
            }
            if kind == .pdf {
                let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
                guard let pdf = PDFDocument(data: data) else { throw FileSystemError.io("not a readable PDF") }
                fingerprintAtOpen = fingerprint
                document = try await noteStore.upsertDocument(hostID: hostID, path: path, kind: kind, fingerprint: fingerprint)
                let controller = PDFViewerController(document: pdf)
                controller.onNoteClick = { [weak self] id in
                    guard let self, let note = self.notes.first(where: { $0.id == id }) else { return }
                    self.editNote(note)
                }
                state = .pdf(controller)
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
                document = try await noteStore.upsertDocument(hostID: hostID, path: path, kind: kind, fingerprint: attributes.fingerprint)
                fingerprintAtOpen = attributes.fingerprint
                state = hostID == .local ? .quickLook(URL(fileURLWithPath: path)) : .unsupported(kind)
                startWatching()
                observeNotes()
                return
            }
            if kind == .csv, attributes.size <= Self.readOnlyThreshold {
                let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
                fingerprintAtOpen = fingerprint
                baseText = decode(data)
                document = try await noteStore.upsertDocument(hostID: hostID, path: path, kind: kind, fingerprint: fingerprint)
                let controller = CSVGridController(text: baseText ?? "", fileName: fileName)
                state = .csv(controller)
                startWatching()
                observeNotes()
                return
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
            let text = decode(data)
            fingerprintAtOpen = fingerprint
            baseText = text
            isReadOnly = attributes.size > Self.readOnlyThreshold
            if isReadOnly { banner = .readOnlyLargeFile } else if usedLatin1 { banner = .decodedAsLatin1 }
            document = try await noteStore.upsertDocument(hostID: hostID, path: path, kind: kind, fingerprint: fingerprint)
            let controller = TextEditorController(text: text, languageName: isReadOnly ? nil : GrammarCatalog.languageName(forPath: path))
            controller.isEditable = !isReadOnly
            controller.onTextChange = { [weak self] in self?.isDirty = true }
            controller.onEdit = { [weak self] _, _ in self?.liveRangesDidShift() }
            controller.onGutterClick = { [weak self] line, noteID in self?.gutterClicked(line: line, noteID: noteID) }
            if kind == .markdown {
                let folder = hostID == .local ? URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true) : nil
                markdown = MarkdownViewerController(source: controller, baseURL: folder)
            } else if HTMLViewerController.handles(path: path) {
                let fileSystem = fileSystem
                let viewer = HTMLViewerController(source: controller, documentPath: path, resourceRoot: { [weak self] in self?.resourceRoot() }) { resource in
                    // Check the size first: a page's video should not be pulled over SFTP only to be refused.
                    guard try await fileSystem.stat(resource).size <= HTMLViewerController.maximumResourceSize else { throw URLError(.dataLengthExceedsMaximum) }
                    return try await fileSystem.read(resource)
                }
                viewer.isLocal = hostID == .local
                viewer.hostID = hostID
                viewer.onPick = { [weak self] pick in self?.beginNote(element: pick) }
                viewer.onPageChanged = { [weak self] in self?.pageChanged() }
                html = viewer
            }
            state = .text(controller)
            startWatching()
            observeNotes()
        } catch {
            state = .failed(Self.openFailure(error))
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
            document = try await noteStore.upsertDocument(hostID: hostID, path: path, kind: .web, fingerprint: Fingerprint())
            let viewer = HTMLViewerController(livePage: url, proxy: proxy)
            viewer.hostID = hostID
            viewer.onPick = { [weak self] pick in self?.beginNote(element: pick) }
            viewer.onPageChanged = { [weak self] in self?.pageChanged() }
            isReadOnly = true
            html = viewer
            state = .text(viewer.source)
            observeNotes()
        } catch {
            state = .failed(Self.openFailure(error))
        }
    }

    /// The page's text changed (it loaded, a script ran, a route changed): its notes follow the new page. A live
    /// page's text is also its source, so that is refreshed too; a served file's source is the file.
    private func pageChanged() {
        guard let controller = textController else { return }
        guard notesDelivered else {
            pendingPageReanchor = true
            return
        }
        let text = controller.text
        let hash = Data(text.utf8).sha256Hex
        if kind == .web {
            baseText = text
            let fingerprint = Fingerprint(mtime: Date(), size: Int64(text.utf8.count), hash: hash)
            fingerprintAtOpen = fingerprint
            Task {
                if let document { try? await noteStore.updateFingerprint(document.id, fingerprint) }
                await reanchorAll(in: text, hash: hash)
                await reanchorElements(hash: hash)
            }
        } else {
            Task { await reanchorElements(hash: hash) }
        }
    }

    /// Asks the page where each element note's element is now and moves, flags or orphans the notes accordingly.
    private func reanchorElements(hash: String) async {
        guard let html, let resolve = html.resolveElements else { return }
        let items: [(id: NoteID, anchor: ElementAnchor)] = notes.compactMap { note in
            if case .element(let anchor) = note.anchor { (note.id, anchor) } else { nil }
        }
        guard !items.isEmpty else { return }
        let results = await resolve(items)
        for (id, anchor) in items {
            guard let note = notes.first(where: { $0.id == id }), let resolution = results[id] else { continue }
            do {
                switch ReAnchorer.element(anchor, resolution: resolution, newHash: hash) {
                case .unchanged:
                    // The page is exactly as it was when the note was made: an orphan's element is back.
                    if note.state == .orphaned { try await noteStore.restoreDraft(id, anchor: .element(anchor)) }
                case .moved(let moved):
                    needsReview.remove(id)
                    // Found at its own selector with the same text: only the hash and rect moved, which every
                    // page tick on a busy page would otherwise write back.
                    if case .element(let next) = moved, note.state != .orphaned, next.selector == anchor.selector, next.text == anchor.text { break }
                    try await noteStore.updateAnchor(id, anchor: moved, state: note.state == .orphaned ? .draft : nil)
                case .movedNeedsReview(let moved):
                    needsReview.insert(id)
                    try await noteStore.updateAnchor(id, anchor: moved, state: note.state == .orphaned ? .draft : nil)
                case .orphaned:
                    if note.state != .orphaned { try await noteStore.markOrphaned(id) }
                }
            } catch {
                Log.notes.error("re-anchoring element note \(id.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
        syncHighlights()
    }

    /// Starts a note on the element the user picked in note mode: the editor opens at the element, no Add Note
    /// pill in between. On a served file the element's first text maps to its source line.
    func beginNote(element pick: ElementPick) {
        guard let html, let controller = textController else { return }
        html.isNoteMode = false
        html.pendingPick = nil
        var line: Int?
        if kind != .web, let offset = pick.textOffset, let alignment = html.alignment,
           let projected = alignment.projected(NSRange(location: offset, length: 1)),
           let source = html.projection.sourceRange(forProjected: projected) {
            line = controller.lineIndex.position(forUTF16Offset: source.location).line
        }
        let anchor = ElementAnchor(
            selector: pick.selector, tag: pick.tag, text: pick.text, html: pick.html, rect: pick.pageRect,
            line: line, hash: Data(controller.text.utf8).sha256Hex
        )
        let rect = pick.windowRect ?? html.pageRect ?? CGRect(x: 40, y: 40, width: 1, height: 1)
        noteEditor = NoteEditorState(anchor: .element(anchor), body: "", color: lastUsedColor, anchorRect: rect)
    }

    private func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        usedLatin1 = true
        return String(decoding: data, as: UTF8.self).isEmpty && !data.isEmpty
            ? (String(data: data, encoding: .isoLatin1) ?? "")
            : (String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self))
    }

    /// Discards unsaved edits and shows what is on disk now.
    /// `discardingEdits: false` is the automatic path behind the watcher: edits that arrived while the read was in
    /// flight win, and the banner offers the reload instead of silently replacing them.
    func reloadFromDisk(discardingEdits: Bool = true) async {
        guard let controller = textController else { return }
        do {
            let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
            let text = decode(data)
            if !discardingEdits, isDirty {
                if text != baseText { banner = .externalChange }
                return
            }
            fingerprintAtOpen = fingerprint
            baseText = text
            controller.replaceAll(with: text)
            rendered?.syncWithSourceIfReplaced()
            isDirty = false
            banner = nil
            conflict = nil
            liveRanges = [:]
            invalidatedNotes = []
            try await noteStore.updateFingerprint(document?.id ?? DocumentID.new(), fingerprint)
            await reanchorAll(in: text, hash: fingerprint.hash ?? "")
        } catch {
            lastError = "Reload failed: \(error)"
        }
    }

    /// Rebuilds the grid from disk and re-anchors its notes, so cell and row notes follow inserted or removed rows
    /// instead of tinting (and sending) whatever record now sits at their old lines.
    private func reloadCSV() async {
        do {
            let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
            let text = decode(data)
            fingerprintAtOpen = fingerprint
            baseText = text
            state = .csv(CSVGridController(text: text, fileName: fileName))
            if let document { try await noteStore.updateFingerprint(document.id, fingerprint) }
            // Grid anchors hash the text itself (see `CSVGridController.selectionAnchor`).
            await reanchorAll(in: text, hash: Data(text.utf8).sha256Hex)
        } catch {
            lastError = "Reload failed: \(error)"
        }
    }

    func dismissBanner() {
        banner = nil
    }

    // MARK: Save

    /// Saves unless the file changed underneath; then `conflict` is set and the sheet decides.
    func save() async {
        // A save already in flight (⌘S on a slow remote file, then Save All) is waited for, not skipped: skipping
        // left the document dirty and made Save All report it as unsaved a moment before it was.
        for _ in 0..<600 where isSaving { try? await Task.sleep(for: .milliseconds(50)) }
        guard let controller = textController, !isReadOnly, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let expected = fingerprintAtOpen {
                if case .changed(let current, let fingerprint) = try await fileSystem.checkForChanges(at: path, since: expected) {
                    let theirs = decode(current)
                    let regions = ThreeWayMerge.merge(
                        base: ExcerptExtractor.allLines(baseText ?? ""),
                        mine: ExcerptExtractor.allLines(controller.text),
                        theirs: ExcerptExtractor.allLines(theirs)
                    )
                    conflict = ConflictState(regions: regions, theirsText: theirs, theirsFingerprint: fingerprint)
                    return
                }
            }
            try await write(controller.text)
        } catch FileSystemError.notFound {
            // Deleted since it was opened: the banner offers Save Here, which writes it back on purpose.
            banner = .deletedOnDisk
        } catch {
            lastError = "Save failed: \(Self.openFailure(error))"
            Log.viewer.error("save \(self.path, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    /// Conflict resolution: overwrite with the editor's text.
    func keepMine() async {
        guard let controller = textController else { return }
        conflict = nil
        do { try await write(controller.text) } catch { lastError = "Save failed: \(error)" }
    }

    /// Conflict resolution: drop the edits and take the disk version.
    func takeTheirs() async {
        conflict = nil
        await reloadFromDisk()
    }

    /// Conflict resolution: apply both sides when they do not overlap, then save.
    func mergeAndSave() async {
        guard let conflict, let merged = ThreeWayMerge.resolve(conflict.regions), let controller = textController else { return }
        let text = merged.joined(separator: "\n") + (conflict.theirsText.hasSuffix("\n") ? "\n" : "")
        self.conflict = nil
        baseText = conflict.theirsText
        fingerprintAtOpen = conflict.theirsFingerprint
        controller.replaceAll(with: text)
        rendered?.syncWithSourceIfReplaced()
        liveRanges = [:]
        invalidatedNotes = []
        do { try await write(text) } catch { lastError = "Save failed: \(error)" }
        await reanchorAll(in: text, hash: Data(text.utf8).sha256Hex)
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
            lastError = "Save As failed: \(error)"
        }
    }

    private func write(_ text: String) async throws {
        let data = usedLatin1 ? (text.data(using: .isoLatin1) ?? Data(text.utf8)) : Data(text.utf8)
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
        watcher?.cancel()
        let stream = fileSystem.watch(path)
        watcher = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .changed(let paths):
                    let resolved = URL(fileURLWithPath: self.path).resolvingSymlinksInPath().path
                    guard paths.contains(where: { $0 == self.path || $0 == resolved }) else { continue }
                    await self.handleExternalChange()
                case .rescan:
                    await self.handleExternalChange()
                }
            }
        }
    }

    func handleExternalChange() async {
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
            lastError = "Could not save \(fileName): \(error.localizedDescription)"
        }
    }

    func close() {
        watcher?.cancel()
        watcher = nil
        notesObservation?.cancel()
        notesObservation = nil
    }

    /// Reloads a changed PDF and re-anchors its notes by page text.
    private func reloadPDF() async {
        guard let expected = fingerprintAtOpen else { return }
        do {
            guard case .changed(let data, let fingerprint) = try await fileSystem.checkForChanges(at: path, since: expected),
                  let pdf = PDFDocument(data: data) else { return }
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
                switch ReAnchorer.pdf(anchor, in: source) {
                case .unchanged: break
                case .moved(let moved): try await noteStore.updateAnchor(note.id, anchor: moved)
                case .movedNeedsReview(let moved):
                    needsReview.insert(note.id)
                    try await noteStore.updateAnchor(note.id, anchor: moved)
                case .orphaned: if note.state != .orphaned { try await noteStore.markOrphaned(note.id) }
                }
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
            let decoded = try ImageDecoder.decode(data, fileName: fileName)
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
                switch ReAnchorer.image(anchor, newWidth: decoded.width, newHeight: decoded.height, newHash: decoded.hash) {
                case .unchanged: break
                case .moved(let moved): try await noteStore.updateAnchor(note.id, anchor: moved)
                case .movedNeedsReview(let moved):
                    needsReview.insert(note.id)
                    try await noteStore.updateAnchor(note.id, anchor: moved)
                case .orphaned: if note.state != .orphaned { try await noteStore.markOrphaned(note.id) }
                }
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
        let stream = noteStore.observeNotes(for: document.id)
        notesObservation = Task { [weak self] in
            do {
                for try await notes in stream {
                    guard let self else { return }
                    self.notes = notes
                    self.syncHighlights()
                    if !self.notesDelivered {
                        self.notesDelivered = true
                        // A page that settled before its notes arrived still gets its notes looked at once.
                        if self.pendingPageReanchor { self.pendingPageReanchor = false; self.pageChanged() }
                    }
                }
            } catch {
                Log.notes.error("note observation failed: \(error, privacy: .public)")
            }
        }
    }

    /// Pushes note ranges into the editor, preferring live (edited) ranges over stored anchors.
    private func syncHighlights() {
        if let csv = csvController {
            csv.cellSelections = Dictionary(notes.compactMap { note -> (NoteID, CellSelection)? in
                guard case .text(let anchor) = note.anchor, let cells = anchor.cells else { return nil }
                return (note.id, cells)
            }, uniquingKeysWith: { first, _ in first })
            csv.highlights = notes.compactMap { note in
                guard case .text(let anchor) = note.anchor else { return nil }
                return TextHighlight(id: note.id, range: csv.lineIndex.range(for: anchor), color: note.color, state: note.displayState)
            }
            return
        }
        if let pdf = pdfController {
            pdf.highlights = notes.compactMap { note in
                guard case .pdf(let anchor) = note.anchor else { return nil }
                return PDFHighlight(id: note.id, page: anchor.page, bounds: anchor.bounds?.cgRect, text: anchor.text, color: note.color, state: note.displayState)
            }
            return
        }
        if let image = imageController {
            image.highlights = notes.compactMap { note in
                guard case .image(let anchor) = note.anchor else { return nil }
                return ImageHighlight(id: note.id, rect: CGRect(x: anchor.x, y: anchor.y, width: anchor.w, height: anchor.h), color: note.color, state: note.displayState, needsReview: needsReview.contains(note.id))
            }
            return
        }
        guard let controller = textController else { return }
        if let html {
            html.elementHighlights = notes.compactMap { note in
                guard case .element(let anchor) = note.anchor, note.state != .orphaned else { return nil }
                return ElementHighlight(id: note.id, selector: anchor.selector, tag: anchor.tag, text: anchor.text,
                                        color: Theme.color(for: note.color), state: note.displayState, needsReview: needsReview.contains(note.id))
            }
        }
        let index = controller.lineIndex
        var highlights: [TextHighlight] = []
        var stillLive: [NoteID: NSRange] = [:]
        for note in notes {
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
                needsReview: needsReview.contains(note.id), isInvalidated: invalidatedNotes.contains(note.id)
            ))
        }
        liveRanges = stillLive
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

    /// Writes shifted anchors back and orphans notes whose text was replaced.
    private func persistLiveAnchors(_ ranges: [NoteID: NSRange], invalidated: Set<NoteID>, in text: String, hash: String) async {
        guard !ranges.isEmpty else { return }
        let index = LineIndex(text)
        for note in notes {
            guard case .text = note.anchor, let range = ranges[note.id] else { continue }
            do {
                if invalidated.contains(note.id) {
                    if note.state != .orphaned { try await noteStore.markOrphaned(note.id) }
                } else {
                    let anchor = ReAnchorer.make(from: range, in: text, index: index, hash: hash)
                    try await noteStore.updateAnchor(note.id, anchor: .text(anchor))
                }
            } catch {
                Log.notes.error("persisting anchor for \(note.id.rawValue, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
        if !isDirty {
            liveRanges = [:]
            invalidatedNotes = []
        }
    }

    /// Re-anchors every text note against new content (reload after an external change).
    func reanchorAll(in text: String, hash: String) async {
        for note in notes {
            guard case .text(let anchor) = note.anchor else { continue }
            do {
                switch ReAnchorer.text(anchor, in: text, newHash: hash) {
                case .unchanged:
                    // The file is byte for byte what it was when the note was made: an orphan's text is back.
                    if note.state == .orphaned { try await noteStore.restoreDraft(note.id, anchor: .text(anchor)) }
                case .moved(let moved):
                    needsReview.remove(note.id)
                    try await noteStore.updateAnchor(note.id, anchor: moved, state: note.state == .orphaned ? .draft : nil)
                case .movedNeedsReview(let moved):
                    needsReview.insert(note.id)
                    try await noteStore.updateAnchor(note.id, anchor: moved, state: note.state == .orphaned ? .draft : nil)
                case .orphaned:
                    if note.state != .orphaned { try await noteStore.markOrphaned(note.id) }
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
        guard noteEditor == nil, reanchoringNoteID == nil, html?.isNoteMode != true else { return nil }
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
            guard let anchor = pdf.selectionAnchor else { return }
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
            noteEditor = NoteEditorState(anchor: .text(anchor), body: "", color: lastUsedColor, anchorRect: rect)
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
        } else if let pdf = pdfController, let anchor = pdf.selectionAnchor {
            newAnchor = .pdf(anchor)
        } else if let csv = csvController, let anchor = csv.selectionAnchor() {
            newAnchor = .text(anchor)
        }
        guard let newAnchor else { return }
        cancelReanchor()
        Task {
            do {
                try await noteStore.restoreDraft(id, anchor: newAnchor)
                needsReview.remove(id)
            } catch {
                lastError = "Re-anchoring failed: \(error)"
            }
        }
    }

    func editNote(_ note: Note) {
        var rect = CGRect(x: 40, y: 40, width: 1, height: 1)
        if let pdf = pdfController, case .pdf(let anchor) = note.anchor, let bounds = anchor.bounds?.cgRect,
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
        noteEditor = NoteEditorState(existingID: note.id, anchor: note.anchor, body: note.body, color: note.color, anchorRect: rect)
    }

    func commitNote(_ state: NoteEditorState) async {
        guard let document else { return }
        lastUsedColor = state.color
        do {
            if let existing = state.existingID {
                try await noteStore.updateBody(existing, body: state.body)
                try await noteStore.updateColor(existing, color: state.color)
            } else {
                // The element's picture is taken before the note exists, so its own outline is not in the crop.
                var elementCrop: (png: Data, width: Int, height: Int)?
                if case .element(let anchor) = state.anchor, let snapshot = html?.snapshotProvider {
                    // A crop is a bonus: a page that moved on, or a view that is gone, must not lose the note.
                    elementCrop = try? await snapshot(anchor.rect)
                }
                let note = try await noteStore.createNote(documentID: document.id, anchor: state.anchor, body: state.body, color: state.color)
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
            lastError = "Saving the note failed: \(error)"
        }
        noteEditor = nil
    }

    /// Drops the viewer's selection after a note was made from it, so the Add Note button goes away and the
    /// note's own highlight shows where it sits.
    private func clearSelection() {
        imageController?.selection = nil
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

    func deleteNote(_ id: NoteID) async {
        do { try await noteStore.deleteNote(id) } catch { lastError = "Deleting the note failed: \(error)" }
        noteEditor = nil
    }

    func resolveNote(_ id: NoteID) async {
        do { try await noteStore.resolve(id) } catch { lastError = "Resolving the note failed: \(error)" }
        needsReview.remove(id)
    }

    /// Scrolls the viewer to a note and selects its range.
    /// Scrolls to a note. `select` also selects its range and focuses the viewer; browsing from the panel does not.
    func reveal(_ note: Note, select: Bool = true) {
        if let pdf = pdfController, case .pdf(let anchor) = note.anchor {
            pdf.selectedNoteID = note.id
            pdf.scroll(toPage: anchor.page, bounds: anchor.bounds?.cgRect)
            return
        }
        if let image = imageController, case .image = note.anchor {
            image.selectedNoteID = note.id
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
        guard let controller = textController, case .text = note.anchor,
              let range = controller.highlights.first(where: { $0.id == note.id })?.range else { return }
        if let rendered { rendered.scroll(toSource: range, select: select) } else { controller.scroll(to: range, select: select) }
    }

    // MARK: Stepping through notes (⌘' and ⇧⌘')

    /// The note last reached with Next or Previous Note; the next step goes on from it while it is still where the
    /// caret is.
    private(set) var steppedNoteID: NoteID?
    /// The source editor's selection when the step was taken; once it moves, the next step starts from the caret.
    private var selectionAtStep: NSRange?

    /// This document's open notes in reading order, each with a key for its place: text by offset, PDF by page then
    /// top to bottom, images in the order they were made. Orphans and whole-file notes have no place and are left out.
    var steppableNotes: [(id: NoteID, key: Double)] {
        let open = notes.filter { ($0.state != .resolved || $0.resolveOutcome == .needsInput) && $0.state != .orphaned }
        let keyed: [(id: NoteID, key: Double)] = open.enumerated().compactMap { index, note in
            switch note.anchor {
            case .text:
                guard let range = textController?.highlights.first(where: { $0.id == note.id })?.range else { return nil }
                return (note.id, Double(range.location))
            case .pdf(let anchor):
                return (note.id, Double(anchor.page) * 1_000_000 - (anchor.bounds?.cgRect.maxY ?? 999_999))
            case .image:
                return (note.id, Double(index))
            case .element(let anchor):
                return (note.id, anchor.rect.y * 10_000 + anchor.rect.x)
            case .wholeFile:
                return nil
            }
        }
        return keyed.sorted { $0.key < $1.key }
    }

    /// Where a step goes: on from the note last stepped to, or else from the caret's offset, wrapping at either end.
    nonisolated static func step(from caret: Double?, current: NoteID?, in ordered: [(id: NoteID, key: Double)], forward: Bool) -> NoteID? {
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
        // The rendered view maps only text that is shown: a caret, a blank line, or markup that renders to nothing
        // maps to no rendered range, and the jump did nothing. Use the character at the caret, else the next line
        // that renders.
        var target = range.length == 0 && range.location < content.location + content.length ? NSRange(location: range.location, length: 1) : range
        var current = line
        while markdown.map.renderedRanges(forSource: target).isEmpty, current < index.lineCount {
            current += 1
            target = index.contentRange(ofLine: current)
        }
        markdown.scroll(toSource: target)
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
