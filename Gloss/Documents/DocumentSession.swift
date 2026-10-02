import AppKit
import Core
import Observation
import OSLog
import Viewers

/// One open file: its content, the viewer state, the fingerprint it was read with, and the save protocol.
@MainActor
@Observable
final class DocumentSession: Identifiable {
    enum State {
        case loading
        case text(TextEditorController)
        /// Viewers for these kinds arrive in later steps; the raw bytes are kept for them.
        case unsupported(DocumentKind)
        case failed(String)
    }

    enum Banner: Equatable {
        case externalChange
        case decodedAsLatin1
        case readOnlyLargeFile
        case tooLarge
        case nonAtomicSave
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
    private(set) var lastError: String?

    /// Called after a reload replaced the text, so notes can be re-anchored (step 9).
    @ObservationIgnored var onReloaded: () -> Void = {}
    @ObservationIgnored private var watcher: Task<Void, Never>?

    init(hostID: HostID, path: String, fileSystem: any FileSystemProvider, noteStore: NoteStore) {
        self.id = "\(hostID.rawValue):\(path)"
        self.hostID = hostID
        self.path = path
        self.kind = DocumentKindDetector.kind(forPath: path)
        self.fileSystem = fileSystem
        self.noteStore = noteStore
    }

    var fileName: String { PathUtilities.name(of: path) }

    var textController: TextEditorController? {
        if case .text(let controller) = state { return controller }
        return nil
    }

    // MARK: Open and reload

    func open() async {
        do {
            let attributes = try await fileSystem.stat(path)
            attributesAtOpen = attributes
            guard kind == .text || kind == .code || kind == .markdown || kind == .csv else {
                document = try await noteStore.upsertDocument(hostID: hostID, path: path, kind: kind, fingerprint: attributes.fingerprint)
                state = .unsupported(kind)
                startWatching()
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
            state = .text(controller)
            startWatching()
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
    func reloadFromDisk() async {
        guard let controller = textController else { return }
        do {
            let (data, fingerprint) = try await fileSystem.readWithFingerprint(path)
            let text = decode(data)
            fingerprintAtOpen = fingerprint
            baseText = text
            controller.replaceAll(with: text)
            isDirty = false
            banner = nil
            conflict = nil
            try await noteStore.updateFingerprint(document?.id ?? DocumentID.new(), fingerprint)
            onReloaded()
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
        do { try await write(text) } catch { lastError = "Save failed: \(error)" }
        onReloaded()
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
        let attributes = try await fileSystem.writeAtomically(data, to: path, preservingModeFrom: attributesAtOpen)
        let fingerprint = Fingerprint(mtime: attributes.mtime, size: attributes.size, hash: data.sha256Hex)
        fingerprintAtOpen = fingerprint
        attributesAtOpen = attributes
        baseText = text
        isDirty = false
        banner = nil
        if let document {
            try await noteStore.updateFingerprint(document.id, fingerprint)
        }
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
        guard textController != nil, let expected = fingerprintAtOpen else { return }
        do {
            guard case .changed = try await fileSystem.checkForChanges(at: path, since: expected) else { return }
            if isDirty {
                banner = .externalChange
            } else {
                await reloadFromDisk()
            }
        } catch {
            Log.viewer.error("external change check failed: \(error, privacy: .public)")
        }
    }

    func close() {
        watcher?.cancel()
        watcher = nil
    }
}
