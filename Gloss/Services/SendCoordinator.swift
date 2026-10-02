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

    private(set) var targets: [AgentTarget] = []
    private(set) var isDiscovering = false
    private(set) var isSending = false
    private(set) var lastOutcome: String?
    private(set) var lastError: String?
    private(set) var lastTarget: AgentTarget?
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

    /// Asks every transport at once, giving each a few seconds.
    func refreshTargets() async {
        isDiscovering = true
        defer { isDiscovering = false }
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
        targets = found.sorted { ($0.transport.rawValue, $0.label) < ($1.transport.rawValue, $1.label) }
        if lastTarget == nil { lastTarget = await restoreLastTarget() }
    }

    private func restoreLastTarget() async -> AgentTarget? {
        guard let stored = try? await noteStore.setting("send.lastTarget"), let data = stored.data(using: .utf8),
              let target = try? JSONDecoder().decode(AgentTarget.self, from: data) else { return targets.first }
        return targets.first { $0.id == target.id } ?? target
    }

    func rememberTarget(_ target: AgentTarget) {
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
            return
        }
        isSending = true
        defer { isSending = false }
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
            Log.transport.error("send failed: \(error, privacy: .public)")
        }
    }

    /// Builds the packet text for the clipboard without recording a send.
    func packetText(noteIDs: [NoteID]) async throws -> String {
        try await packet(noteIDs: noteIDs).text
    }

    /// The packet for these notes with attachments at their local paths (MCP and hook readers run on this Mac
    /// or read the crops as resources).
    func packet(noteIDs: [NoteID]) async throws -> Packet {
        let (notes, attachments) = try await collect(noteIDs: noteIDs)
        let staged = attachments.map { StagedAttachment(noteID: $0.noteID, agentPath: $0.localPath) }
        return PacketBuilder.build(try await packetNotes(for: notes, target: ClipboardTransport.target, staged: staged))
    }

    /// `UserPromptSubmit` context for the draft notes under `cwd` on a host, fitted to the hook limit, with the ids
    /// it covers. Drafts only: a note the hook already delivered stays reachable through MCP but is not injected
    /// into every later prompt.
    func hookText(hostID: HostID?, cwd: String?) async throws -> (text: String, noteIDs: [NoteID]) {
        let pending = try await noteStore.pendingNotes(hostID: hostID, pathPrefix: cwd).filter { $0.note.state == .draft }
        let (notes, attachments) = try await collect(noteIDs: pending.map(\.note.id))
        let staged = attachments.map { StagedAttachment(noteID: $0.noteID, agentPath: $0.localPath) }
        // Each block costs at least its header lines; when the headers alone cannot fit, the builder will use
        // the summary form, so reading every document (over SFTP, inside the hook's timeout) would be wasted.
        let headersOnly = notes.count * 80 > PacketBuilder.hookDefaultLimit
        let packetNotes = headersOnly
            ? notes.map { PacketNote(noteID: $0.note.id, agentPath: $0.document.path, source: PacketSource(kind: $0.document.kind), anchor: $0.note.anchor, comment: $0.note.body) }
            : try await packetNotes(for: notes, target: ClipboardTransport.target, staged: staged)
        return (PacketBuilder.hookText(packetNotes), notes.map(\.note.id))
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
        var result: [PacketNote] = []
        for (note, document) in notes {
            var excerpt: [String] = []
            if case .text(let anchor) = note.anchor {
                let key = "\(document.hostID.rawValue):\(document.path)"
                if contents[key] == nil {
                    if let open = openTextProvider(document.hostID, document.path) {
                        contents[key] = open
                    } else {
                        contents[key] = try await readText(hostID: document.hostID, path: document.path) ?? ""
                    }
                }
                excerpt = ExcerptExtractor.lines(for: anchor, in: contents[key] ?? "")
            } else if case .pdf(let anchor) = note.anchor, let text = anchor.text {
                excerpt = text.components(separatedBy: "\n")
            }
            // A sub-line span in markdown (typically from the rendered view) gets a `Selected:` line.
            var selectedText: String?
            if document.kind == .markdown, case .text(let anchor) = note.anchor, anchor.isSingleLine,
               let line = excerpt.first, anchor.text != line, !anchor.text.isEmpty, !anchor.text.contains("\n") {
                selectedText = anchor.text
            }
            result.append(PacketNote(
                noteID: note.id, agentPath: document.path, source: PacketSource(kind: document.kind), anchor: note.anchor,
                comment: note.body, excerptLines: excerpt, selectedText: selectedText,
                attachmentAgentPath: staged.first { $0.noteID == note.id }?.agentPath
            ))
        }
        return result
    }

    private func readText(hostID: HostID, path: String) async throws -> String? {
        guard let fileSystem = fileSystemProvider(hostID) else { return nil }
        let data = try await fileSystem.read(path)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func targetJSON(_ target: AgentTarget) -> String {
        (try? JSONEncoder().encode(target)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
