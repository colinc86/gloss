import AppKit
import Core
import Foundation
import Observation
import OSLog

/// stage → build → deliver → record. Every transport goes through here so the packet shape never varies.
@MainActor
@Observable
final class SendCoordinator {
    private let noteStore: NoteStore
    private(set) var transports: [any Transport]
    private var stagers: [HostID: any AttachmentStager]
    /// Resolves a host to its file system, for reading excerpts of files that are not open.
    @ObservationIgnored var fileSystemProvider: (HostID) -> (any FileSystemProvider)? = { _ in nil }
    /// Text of open documents, so excerpts reflect unsaved edits.
    @ObservationIgnored var openTextProvider: (HostID, String) -> String? = { _, _ in nil }
    /// Where Copy as Packet puts the text: the general pasteboard (tests swap it so they never touch the user's).
    @ObservationIgnored var writeClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// What a virtual host says a document is (a pull request's URL and file at its head), for the packet header.
    @ObservationIgnored var packetResourceProvider: (HostID, String, Int?) async -> PacketResource? = { _, _, _ in nil }

    /// The packet's `Source:` for a document: a virtual host names the resource kind, a file its document kind.
    nonisolated static func source(for document: Document) -> PacketSource {
        switch document.hostID {
        case .github: .pullRequest
        case .atlassian: document.path.hasPrefix("/confluence/") ? .confluence : .jira
        default: PacketSource(kind: document.kind)
        }
    }

    private(set) var targets: [AgentTarget] = []
    private(set) var isDiscovering = false
    private(set) var isSending = false
    private(set) var lastOutcome: String?
    private(set) var lastError: String?
    private(set) var lastTarget: AgentTarget?
    /// The send in flight (how many notes, to whom), for the panel's progress toast.
    private(set) var inFlight: (count: Int, target: AgentTarget)?
    /// The last send's outcome, for the panel's toast; cleared when the toast goes away.
    private(set) var lastResult: SendResult?

    struct SendResult: Equatable, Identifiable {
        let id = UUID()
        let noteIDs: [NoteID]
        let target: AgentTarget
        /// Nil when delivered.
        let failure: String?
        /// Copied as a packet rather than sent: the notes are still drafts.
        var copied = false

        static func == (lhs: SendResult, rhs: SendResult) -> Bool { lhs.id == rhs.id }
    }

    func clearResult() { lastResult = nil }

    /// Sends the last result's notes to the same target again.
    func retry() async {
        guard let result = lastResult else { return }
        await send(noteIDs: result.noteIDs, to: result.target)
    }
    /// Bumped when a send attempt finishes, delivered or not; note cards refetch their latest send on it.
    private(set) var completedSends = 0
    /// Days before staged remote directories are removed.
    var stagedFileExpiryDays = 7

    init(noteStore: NoteStore, transports: [any Transport], stagers: [HostID: any AttachmentStager]) {
        self.noteStore = noteStore
        self.transports = transports
        self.stagers = stagers
    }

    func register(_ transport: any Transport) {
        transports.append(transport)
    }

    func register(stager: any AttachmentStager, for hostID: HostID) {
        stagers[hostID] = stager
    }

    // MARK: Targets

    /// The folder in front whose agent sends should go to, or nil when nothing should pick one (no folder, follow
    /// mode, or a choice in progress).
    @ObservationIgnored var currentFolder: () -> (hostID: HostID, path: String)? = { nil }
    /// The discovery in flight; a request made meanwhile waits for it and has it look once more.
    @ObservationIgnored private var discovery: Task<Void, Never>?
    @ObservationIgnored private var discoversAgain = false
    /// When discovery last finished, so the picker can skip a refresh it has just had.
    @ObservationIgnored private(set) var discoveredAt: Date?
    /// Set when a folder comes to the front, until its agent is picked from a finished discovery or a target is set
    /// some other way; a refresh at any other time leaves the target alone.
    @ObservationIgnored private var folderPickOwed = false
    /// Bumped whenever the target is set, so a pick that waited on the database yields to one made meanwhile.
    @ObservationIgnored private var targetGeneration = 0

    /// Asks every transport at once, giving each a few seconds, then picks the folder's agent if one is owed.
    func refreshTargets() async {
        if let discovery {
            discoversAgain = true
            return await discovery.value
        }
        let task = Task {
            repeat {
                discoversAgain = false
                await discoverTargets()
            } while discoversAgain
            discovery = nil
        }
        discovery = task
        await task.value
    }

    private func discoverTargets() async {
        isDiscovering = true
        defer {
            isDiscovering = false
            discoveredAt = Date()
        }
        var found: [AgentTarget] = []
        await withTaskGroup(of: [AgentTarget].self) { group in
            for transport in transports {
                group.addTask {
                    await withTaskGroup(of: [AgentTarget]?.self) { race in
                        race.addTask { (try? await transport.discoverTargets()) ?? [] }
                        race.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
                        let first = await race.next() ?? nil
                        race.cancelAll()
                        return first ?? []
                    }
                }
            }
            for await targets in group { found.append(contentsOf: targets) }
        }
        // Transport order is the delivery priority (Herdr first, clipboard last); agents sort by label within one.
        targets = found.sorted { (Self.priority($0.transport), $0.label) < (Self.priority($1.transport), $1.label) }
        // The folder in front beats the target used last, which may belong to another folder.
        await selectFolderTarget()
        if lastTarget == nil {
            let restored = await restoreLastTarget()
            if lastTarget == nil { lastTarget = restored }
        }
    }

    /// The folder in front changed (or opened at launch): pick its agent now if agents have been found, and again
    /// when a discovery under way finishes.
    func folderBecameCurrent() async {
        guard currentFolder() != nil else { return }
        folderPickOwed = true
        guard discoveredAt != nil else { return }
        await selectFolderTarget(settles: discovery == nil)
    }

    /// Switches to the agent `preferredTarget` picks for the folder in front when a pick is owed; otherwise keeps the
    /// current one. `settles` false leaves the pick owed for the discovery under way.
    private func selectFolderTarget(settles: Bool = true) async {
        guard folderPickOwed else { return }
        guard let folder = currentFolder() else {
            folderPickOwed = false
            return
        }
        if settles { folderPickOwed = false }
        let generation = targetGeneration
        guard let preferred = await preferredTarget(hostID: folder.hostID, path: folder.path),
              preferred.id != lastTarget?.id,
              // A target set, or another folder brought forward, while the memory loaded wins.
              generation == targetGeneration, let now = currentFolder(), now == folder else { return }
        setTarget(preferred)
    }

    /// The agent sends from the folder `path` should go to, among the live targets:
    /// 1. the one last chosen in the folder, else a live agent of the same transport working there, so a tmux pane
    ///    that changed directory or command, or a restarted Herdr pane, still matches;
    /// 2. an agent working in the folder or inside it, the folder itself first, then in delivery priority order.
    /// Nil when none is; the clipboard and OpenCode's "New session" rows are never picked unless chosen.
    func preferredTarget(hostID: HostID, path: String) async -> AgentTarget? {
        // Resolving symlinks touches the disk, so not on the main actor.
        let key = await Task.detached { Self.folderKey(hostID: hostID, path: path) }.value
        let folder = String(key.dropFirst(hostID.rawValue.count + 1))
        let working = targets.filter { $0.runs(inHost: hostID, path: path) }
        func best(_ candidates: [AgentTarget]) -> AgentTarget? {
            let standardized = URL(fileURLWithPath: path).standardized.path
            return candidates.first { $0.detail.map { URL(fileURLWithPath: $0).standardized.path } == standardized }
                ?? candidates.first { $0.detail.map { Self.normalizedFolder(hostID: hostID, path: $0) } == folder }
                ?? candidates.first
        }
        if let remembered = await loadFolderTargets()[key] {
            if let live = targets.first(where: { $0.id == remembered.id }) { return live }
            if let same = best(working.filter { $0.transport == remembered.transport }) { return same }
        }
        return best(working)
    }

    private static func priority(_ kind: TransportKind) -> Int {
        TransportKind.allCases.firstIndex(of: kind) ?? TransportKind.allCases.count
    }

    /// The target used last time when it is still around, else the first agent found; the clipboard only when
    /// nothing else is, so the picker never shows "Clipboard" beside a list of live agents.
    private func restoreLastTarget() async -> AgentTarget? {
        let fallback = targets.first { $0.transport != .clipboard } ?? targets.first
        guard let stored = try? await noteStore.setting("send.lastTarget"), let data = stored.data(using: .utf8),
              let target = try? JSONDecoder().decode(AgentTarget.self, from: data) else { return fallback }
        if let live = targets.first(where: { $0.id == target.id }) { return live }
        // A remote agent whose host is not connected yet becomes live after connecting; anything else that
        // discovery no longer sees is gone, and a live agent is a better default than a dead one.
        let awaitingHost = target.hostID != .local && fileSystemProvider(target.hostID) == nil
        return awaitingHost && target.transport != .clipboard ? target : fallback
    }

    /// The agent last chosen in each folder, keyed by `folderKey`, so returning to a folder returns to its agent.
    /// Loaded from the database on first use and saved whenever it changes.
    private var folderTargets: [String: AgentTarget]?
    /// The first load, which every caller waiting on it shares.
    @ObservationIgnored private var folderTargetsLoad: Task<[String: AgentTarget], Never>?

    nonisolated static func folderKey(hostID: HostID, path: String) -> String {
        "\(hostID.rawValue):\(normalizedFolder(hostID: hostID, path: path))"
    }

    /// `path` without `.` or `..` parts or a trailing slash, and on this Mac with symlinks resolved, so every spelling
    /// of a folder finds the same memory.
    nonisolated static func normalizedFolder(hostID: HostID, path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return hostID == .local ? url.resolvingSymlinksInPath().path : url.standardized.path
    }

    /// Records `target` as the one chosen in the folder `key`.
    func remember(_ target: AgentTarget, forFolder key: String) async {
        // Read after the load, with no wait before the write, so another remember isn't lost.
        var map = await loadFolderTargets()
        if let folderTargets { map = folderTargets }
        guard map[key]?.id != target.id else { return }
        map[key] = target
        folderTargets = map
        if let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) {
            try? await noteStore.setSetting("send.folderTargets", json)
        }
    }

    private func loadFolderTargets() async -> [String: AgentTarget] {
        if let folderTargets { return folderTargets }
        let load = folderTargetsLoad ?? Task { await readFolderTargets() }
        folderTargetsLoad = load
        let map = await load.value
        if folderTargets == nil { folderTargets = map }
        return folderTargets ?? map
    }

    private func readFolderTargets() async -> [String: AgentTarget] {
        let stored = (try? await noteStore.setting("send.folderTargets"))?.data(using: .utf8)
        let decoded = stored.flatMap { try? JSONDecoder().decode([String: AgentTarget].self, from: $0) } ?? [:]
        // Keys saved before folders were normalized are rewritten once; a normalized key already there wins.
        var map: [String: AgentTarget] = [:]
        for (key, target) in decoded {
            let normalized = key.range(of: ":/").map { range in
                Self.folderKey(hostID: HostID(rawValue: String(key[..<range.lowerBound])), path: String(key[key.index(after: range.lowerBound)...]))
            } ?? key
            if normalized == key || map[normalized] == nil { map[normalized] = target }
        }
        if map.count != decoded.count || map.keys.contains(where: { decoded[$0] == nil }),
           let data = try? JSONEncoder().encode(map), let json = String(data: data, encoding: .utf8) {
            try? await noteStore.setSetting("send.folderTargets", json)
        }
        return map
    }

    /// The user (or Herdr's focus, in follow mode) set the target: no pending folder pick overrides it.
    func rememberTarget(_ target: AgentTarget) {
        folderPickOwed = false
        setTarget(target)
    }

    private func setTarget(_ target: AgentTarget) {
        targetGeneration += 1
        lastTarget = target
        Task {
            if let data = try? JSONEncoder().encode(target), let json = String(data: data, encoding: .utf8) {
                try? await noteStore.setSetting("send.lastTarget", json)
            }
            _ = try? await noteStore.upsertTarget(hostID: target.hostID, transport: target.transport.rawValue, identityJSON: target.identityJSON, label: target.label, usedAt: Date())
        }
    }

    // MARK: Sending

    /// Delivers one packet with these notes to `target`, recording the send and flipping drafts to sent.
    func send(noteIDs: [NoteID], to target: AgentTarget) async {
        guard !noteIDs.isEmpty, !isSending else { return }
        guard let transport = transports.first(where: { $0.kind == target.transport }) else {
            lastError = "No transport for \(target.transport.displayName)"
            lastResult = SendResult(noteIDs: noteIDs, target: target, failure: lastError)
            return
        }
        isSending = true
        inFlight = (noteIDs.count, target)
        lastResult = nil
        defer {
            isSending = false
            inFlight = nil
            completedSends += 1
        }
        lastError = nil
        let sendID = SendID.new()
        do {
            let (notes, attachments) = try await collect(noteIDs: noteIDs)
            let staging = try await stagers[target.hostID]?.stage(attachments, for: target, sendID: sendID) ?? .empty
            let packetNotes = try await packetNotes(for: notes, target: target, staged: staging.attachments)
            let packet = PacketBuilder.build(packetNotes)
            let expiresAt = Date().addingTimeInterval(TimeInterval(stagedFileExpiryDays) * 24 * 3600)
            do {
                let receipt = try await transport.deliver(packet, attachments: staging.attachments, to: target)
                let recorded = try await noteStore.recordSend(transport: target.transport.rawValue, targetJSON: targetJSON(target), packetText: packet.text, noteIDs: packet.noteIDs, outcome: .delivered)
                if !staging.remoteDirectories.isEmpty {
                    try await noteStore.recordStagedFiles(sendID: recorded, hostID: target.hostID, remotePaths: staging.remoteDirectories, expiresAt: expiresAt)
                }
                lastOutcome = "Sent \(packet.noteIDs.count) note\(packet.noteIDs.count == 1 ? "" : "s") to \(target.label)" + (receipt.detail.map { " (\($0))" } ?? "")
                lastResult = SendResult(noteIDs: packet.noteIDs, target: target, failure: nil)
                rememberTarget(target)
            } catch {
                let recorded = try await noteStore.recordSend(transport: target.transport.rawValue, targetJSON: targetJSON(target), packetText: packet.text, noteIDs: packet.noteIDs, outcome: .failed("\(error)"))
                if !staging.remoteDirectories.isEmpty {
                    try await noteStore.recordStagedFiles(sendID: recorded, hostID: target.hostID, remotePaths: staging.remoteDirectories, expiresAt: expiresAt)
                }
                throw error
            }
        } catch {
            lastError = "Send failed: \(error)"
            lastResult = SendResult(noteIDs: noteIDs, target: target, failure: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            Log.transport.error("send failed: \(error, privacy: .public)")
        }
    }

    /// Puts these notes on the clipboard as one packet without sending them: nothing is recorded and drafts stay
    /// drafts, since a copy may never be pasted anywhere (issue #5). Choosing the Clipboard target and pressing
    /// Send is the explicit way to mark them sent.
    func copy(noteIDs: [NoteID]) async {
        guard !noteIDs.isEmpty else { return }
        lastError = nil
        do {
            let packet = try await packet(noteIDs: noteIDs)
            writeClipboard(packet.text)
            lastResult = SendResult(noteIDs: packet.noteIDs, target: ClipboardTransport.target, failure: nil, copied: true)
        } catch {
            lastError = "Copy failed: \(error)"
            Log.transport.error("copy failed: \(error, privacy: .public)")
        }
    }

    /// Builds the packet text for the clipboard without recording a send.
    func packetText(noteIDs: [NoteID]) async throws -> String {
        try await packet(noteIDs: noteIDs).text
    }

    /// The packet for these notes with attachments at their local paths (for the clipboard, and for MCP readers,
    /// which run on this Mac or read the crops as resources).
    func packet(noteIDs: [NoteID]) async throws -> Packet {
        let (notes, attachments) = try await collect(noteIDs: noteIDs)
        let staged = attachments.map { StagedAttachment(noteID: $0.noteID, agentPath: $0.localPath) }
        return PacketBuilder.build(try await packetNotes(for: notes, target: ClipboardTransport.target, staged: staged))
    }

    func draftNoteIDs(documentID: DocumentID?) async -> [NoteID] {
        let pending = (try? await noteStore.pendingNotes()) ?? []
        return pending.filter { $0.note.state == .draft && (documentID == nil || $0.document.id == documentID) }.map(\.note.id)
    }

    // MARK: Packet assembly

    private func collect(noteIDs: [NoteID]) async throws -> (notes: [(note: Note, document: Document)], attachments: [LocalAttachment]) {
        var notes: [(Note, Document)] = []
        var attachments: [LocalAttachment] = []
        for id in noteIDs {
            guard let note = try await noteStore.note(id), let document = try await noteStore.document(note.documentID) else { continue }
            notes.append((note, document))
            for attachment in try await noteStore.attachments(for: id) {
                attachments.append(LocalAttachment(noteID: id, localPath: attachment.localPath))
            }
        }
        return (notes.map { (note: $0.0, document: $0.1) }, attachments)
    }

    private func packetNotes(for notes: [(note: Note, document: Document)], target: AgentTarget, staged: [StagedAttachment]) async throws -> [PacketNote] {
        var contents: [String: String] = [:]
        /// Hashes of files read from disk here (not open), to tell whether a note's anchor still describes them.
        var hashes: [String: String] = [:]
        var result: [PacketNote] = []
        for (original, document) in notes {
            var note = original
            var excerpt: [String] = []
            var excerptOverride: [String]?
            var cellDescription: String?
            if case .text(let anchor) = note.anchor, document.kind == .web {
                // A page's source is its DOM on one long line; the selection is the excerpt that means something.
                excerpt = anchor.text.components(separatedBy: "\n")
            } else if case .text(var anchor) = note.anchor {
                let key = "\(document.hostID.rawValue):\(document.path)"
                if contents[key] == nil {
                    if let open = openTextProvider(document.hostID, document.path) {
                        contents[key] = open
                    } else if document.kind == .web {
                        // A page that is not open has no text to read; the anchor's own text still travels.
                        contents[key] = ""
                    } else {
                        let read = try await readText(hostID: document.hostID, path: document.path)
                        contents[key] = read?.text ?? ""
                        hashes[key] = read?.hash
                    }
                }
                // A file that changed since the note was made (an agent edited it while it wasn't open): find the
                // note's text again, so the excerpt and the line numbers describe the file as it is now.
                // Only an anchor that records what it was made on (its file's hash and text) can be looked for.
                if let hash = hashes[key], let made = anchor.hash, made != hash, !anchor.text.isEmpty, let content = contents[key] {
                    switch ReAnchorer.text(anchor, in: content, newHash: hash) {
                    case .moved(let moved), .movedNeedsReview(let moved):
                        note.anchor = moved
                        try? await noteStore.updateAnchor(note.id, anchor: moved)
                    case .orphaned:
                        // Its text is gone from the file: quote what the note was made on rather than whatever now
                        // sits at its old lines. The session marks it orphaned when the document opens.
                        excerptOverride = anchor.text.components(separatedBy: "\n")
                    case .unchanged:
                        break
                    }
                }
                if case .text(let current) = note.anchor { anchor = current }
                if let cells = anchor.cells {
                    let made = CellExcerpt.make(anchor: anchor, cells: cells, content: contents[key] ?? "", fileName: (document.path as NSString).lastPathComponent)
                    excerpt = made.lines
                    cellDescription = made.description
                } else {
                    excerpt = excerptOverride ?? ExcerptExtractor.lines(for: anchor, in: contents[key] ?? "")
                }
            } else if case .embeddedImage(let anchor) = note.anchor, let made = anchor.embed.hash,
                      openTextProvider(document.hostID, document.path) == nil,
                      let read = (try? await readText(hostID: document.hostID, path: document.path)) ?? nil, read.hash != made {
                // Changed while it wasn't open: the packet names the embed's line as it is now (an open document
                // keeps its own notes in step).
                switch ReAnchorer.embeddedImage(anchor, in: read.text, newHash: read.hash) {
                case .moved(let moved), .movedNeedsReview(let moved):
                    note.anchor = moved
                    try? await noteStore.updateAnchor(note.id, anchor: moved)
                case .orphaned, .unchanged:
                    break
                }
            } else if case .pdf(let anchor) = note.anchor, let text = anchor.text {
                excerpt = text.components(separatedBy: "\n")
            }
            // A sub-line span in markdown (typically from the rendered view) gets a `Selected:` line.
            var selectedText: String?
            if document.kind == .markdown, case .text(let anchor) = note.anchor, anchor.isSingleLine,
               let line = excerpt.first, anchor.text != line, !anchor.text.isEmpty, !anchor.text.contains("\n") {
                selectedText = anchor.text
            }
            var firstLine: Int?
            if case .text(let anchor) = note.anchor { firstLine = anchor.start.line }
            let resource = document.hostID.isVirtual ? await packetResourceProvider(document.hostID, document.path, firstLine) : nil
            result.append(PacketNote(
                noteID: note.id, agentPath: document.path, source: Self.source(for: document), anchor: note.anchor,
                comment: note.body, excerptLines: excerpt, selectedText: selectedText,
                attachmentAgentPath: staged.first { $0.noteID == note.id }?.agentPath, cellDescription: cellDescription,
                resource: resource?.url.absoluteString, resourceDetails: resource?.details ?? []
            ))
        }
        return result
    }

    private func readText(hostID: HostID, path: String) async throws -> (text: String, hash: String)? {
        guard let fileSystem = fileSystemProvider(hostID) else { return nil }
        let data = try await fileSystem.read(path)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return (text, data.sha256Hex)
    }

    private func targetJSON(_ target: AgentTarget) -> String {
        (try? JSONEncoder().encode(target)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension AgentTarget {
    /// Whether the agent works in `path` on `hostID`: its directory is the folder or inside it. A parent folder does
    /// not count; an agent started in `~` would otherwise match every project. Only transports that report a
    /// directory match.
    nonisolated func runs(inHost hostID: HostID, path: String) -> Bool {
        guard self.hostID == hostID, transport == .herdr || transport == .tmux || transport == .opencode,
              let directory = detail, directory.hasPrefix("/") else { return false }
        func contains(_ outer: String, _ inner: String) -> Bool {
            let outer = outer.count > 1 && outer.hasSuffix("/") ? String(outer.dropLast()) : outer
            let inner = inner.count > 1 && inner.hasSuffix("/") ? String(inner.dropLast()) : inner
            return inner == outer || inner.hasPrefix(outer == "/" ? "/" : outer + "/")
        }
        if contains(path, directory) { return true }
        // Local folders can be reached through symlinks (`/tmp` is `/private/tmp`).
        guard hostID == .local else { return false }
        let resolvedDirectory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return contains(resolvedPath, resolvedDirectory)
    }
}
