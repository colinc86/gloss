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
        case nonAtomicSave
        case reanchoring
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
    let kind: DocumentKind
    private let fileSystem: any FileSystemProvider
    private let noteStore: NoteStore

    private(set) var document: Document?
    private(set) var state: State = .loading
    /// Rendered/source toggle for markdown documents; nil for every other kind.
    private(set) var markdown: MarkdownViewerController?
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

    var fileName: String { PathUtilities.name(of: path) }

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

    func open() async {
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
            let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
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
            if kind == .markdown { markdown = MarkdownViewerController(source: controller) }
            state = .text(controller)
            startWatching()
            observeNotes()
        } catch {
            state = .failed("\(error)")
            Log.viewer.error("open \(self.path, privacy: .public) failed: \(error, privacy: .public)")
        }
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
            markdown?.syncWithSourceIfReplaced()
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

    func dismissBanner() {
        banner = nil
    }

    // MARK: Save

    /// Saves unless the file changed underneath; then `conflict` is set and the sheet decides.
    func save() async {
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
        } catch {
            lastError = "Save failed: \(error)"
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
        markdown?.syncWithSourceIfReplaced()
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
        if csvController != nil || { if case .quickLook = state { return true } else { return false } }() {
            // Rebuild the grid or preview from disk; notes re-anchor through the text path on the next open.
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
                }
            } catch {
                Log.notes.error("note observation failed: \(error, privacy: .public)")
            }
        }
    }

    /// Pushes note ranges into the editor, preferring live (edited) ranges over stored anchors.
    private func syncHighlights() {
        if let csv = csvController {
            csv.highlights = notes.compactMap { note in
                guard case .text(let anchor) = note.anchor else { return nil }
                return TextHighlight(id: note.id, range: csv.lineIndex.range(for: anchor), color: note.color, state: note.state)
            }
            return
        }
        if let pdf = pdfController {
            pdf.highlights = notes.compactMap { note in
                guard case .pdf(let anchor) = note.anchor else { return nil }
                return PDFHighlight(id: note.id, page: anchor.page, bounds: anchor.bounds?.cgRect, text: anchor.text, color: note.color, state: note.state)
            }
            return
        }
        if let image = imageController {
            image.highlights = notes.compactMap { note in
                guard case .image(let anchor) = note.anchor else { return nil }
                return ImageHighlight(id: note.id, rect: CGRect(x: anchor.x, y: anchor.y, width: anchor.w, height: anchor.h), color: note.color, state: note.state, needsReview: needsReview.contains(note.id))
            }
            return
        }
        guard let controller = textController else { return }
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
                id: note.id, range: range, color: note.color, state: note.state,
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
                    break
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

    /// Starts a note for the current selection (or the whole file when there is no text viewer).
    func beginNote() {
        if let reanchoring = reanchoringNoteID {
            placeOrphan(reanchoring)
            return
        }
        if let csv = csvController {
            guard let range = csv.selectionRange else { return }
            let anchor = ReAnchorer.make(from: range, in: csv.text, index: csv.lineIndex, hash: Data(csv.text.utf8).sha256Hex)
            let rect = csv.rectProvider(csv.selectedRows) ?? CGRect(x: 40, y: 40, width: 1, height: 1)
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
            if let markdown, markdown.mode == .rendered {
                guard let mapping = markdown.renderedSelectionMapping else { return }
                range = mapping.source
            }
            if range.length == 0 {
                range = controller.lineIndex.contentRange(ofLine: controller.lineIndex.position(forUTF16Offset: range.location).line)
            }
            guard range.length > 0 else { return }
            let anchor = ReAnchorer.make(from: range, in: controller.text, index: controller.lineIndex, hash: Data(controller.text.utf8).sha256Hex)
            let rect = markdown?.rect(forSource: range) ?? controller.rect(for: range) ?? .zero
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
            if let markdown { markdown.scroll(toSource: range) } else { controller.scroll(to: range) }
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
            if let markdown, markdown.mode == .rendered, let mapping = markdown.renderedSelectionMapping { range = mapping.source }
            if range.length > 0 {
                newAnchor = .text(ReAnchorer.make(from: range, in: controller.text, index: controller.lineIndex, hash: Data(controller.text.utf8).sha256Hex))
            }
        } else if let image = imageController, let anchor = image.selectionAnchor {
            newAnchor = .image(anchor)
        } else if let pdf = pdfController, let anchor = pdf.selectionAnchor {
            newAnchor = .pdf(anchor)
        } else if let csv = csvController, let range = csv.selectionRange {
            newAnchor = .text(ReAnchorer.make(from: range, in: csv.text, index: csv.lineIndex, hash: Data(csv.text.utf8).sha256Hex))
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
           let found = markdown?.rect(forSource: range) ?? controller.rect(for: range) {
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
                let note = try await noteStore.createNote(documentID: document.id, anchor: state.anchor, body: state.body, color: state.color)
                if case .image(let anchor) = state.anchor, let image = imageController {
                    try await saveCrop(of: anchor, from: image, for: note.id)
                }
                if case .pdf(let anchor) = state.anchor, let pdf = pdfController {
                    try await savePageRender(of: anchor, from: pdf, for: note.id)
                }
                imageController?.selection = nil
                pdfController?.clearSelection()
            }
        } catch {
            lastError = "Saving the note failed: \(error)"
        }
        noteEditor = nil
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

    func deleteNote(_ id: NoteID) async {
        do { try await noteStore.deleteNote(id) } catch { lastError = "Deleting the note failed: \(error)" }
        noteEditor = nil
    }

    func resolveNote(_ id: NoteID) async {
        do { try await noteStore.resolve(id) } catch { lastError = "Resolving the note failed: \(error)" }
        needsReview.remove(id)
    }

    /// Scrolls the viewer to a note and selects its range.
    func reveal(_ note: Note) {
        if let pdf = pdfController, case .pdf(let anchor) = note.anchor {
            pdf.selectedNoteID = note.id
            pdf.scroll(toPage: anchor.page, bounds: anchor.bounds?.cgRect)
            return
        }
        if let image = imageController, case .image = note.anchor {
            image.selectedNoteID = note.id
            return
        }
        guard let controller = textController, case .text = note.anchor,
              let range = controller.highlights.first(where: { $0.id == note.id })?.range else { return }
        if let markdown { markdown.scroll(toSource: range) } else { controller.scroll(to: range) }
    }

    func toggleMarkdownMode() {
        markdown?.toggle()
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
