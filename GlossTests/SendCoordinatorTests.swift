import AppKit
import Core
import Foundation
import Testing
@testable import Gloss

/// Records what it was asked to deliver.
final class FakeTransport: Transport, @unchecked Sendable {
    let kind = TransportKind.tmux
    var delivered: [(Packet, [StagedAttachment], AgentTarget)] = []
    var shouldFail = false
    /// Runs while the packet is being delivered, before the send is recorded.
    var whileDelivering: (@MainActor () async -> Void)?
    static let target = AgentTarget(transport: .tmux, hostID: .local, label: "fake", identityJSON: "{\"pane\":\"0\"}")

    func discoverTargets() async throws -> [AgentTarget] { [Self.target] }

    func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt {
        if shouldFail { throw DeliveryError.failed("boom") }
        if let whileDelivering { await whileDelivering() }
        delivered.append((packet, attachments, target))
        return DeliveryReceipt(detail: "ok")
    }
}

@MainActor
struct SendCoordinatorTests {
    func makeStore() throws -> NoteStore { NoteStore(database: try AppDatabase.inMemory()) }

    @Test func sendsOnePacketAndFlipsDrafts() async throws {
        let store = try makeStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-send-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/PLAN.md"
        try "# Plan\nline two\nline three\n".write(toFile: path, atomically: true, encoding: .utf8)
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 3, col: 11), text: "", before: "", after: "")), body: "Fix \"this\"", color: .yellow)
        let transport = FakeTransport()
        let coordinator = SendCoordinator(noteStore: store, transports: [transport], stagers: [.local: LocalAttachmentStager(cacheRoot: URL(fileURLWithPath: directory))])
        coordinator.fileSystemProvider = { _ in LocalFileSystem(deleteBehavior: .permanent) }
        await coordinator.refreshTargets()
        #expect(coordinator.targets.map(\.label) == ["fake"])
        await coordinator.send(noteIDs: [note.id], to: FakeTransport.target)
        #expect(coordinator.lastError == nil)
        let (packet, _, _) = try #require(transport.delivered.first)
        #expect(packet.text.contains("File: \(path)\nSource: markdown\n\nNote: \(note.id.rawValue)\nLines 2-3\nExcerpt:\n> line two\n> line three\nUser comment: \"Fix \\\"this\\\"\""))
        #expect(try await store.note(note.id)?.state == .sent)
        #expect(try await store.sends(for: note.id).first?.outcome == "delivered")
        #expect(coordinator.lastTarget?.id == FakeTransport.target.id)
    }

    /// A follow-up makes a sent note sendable again: Send All takes it, the packet carries the agent's question and
    /// the answer, the note keeps its id, and the follow-up is stamped sent. get_note's packet shows the whole thread.
    @Test func sendingAFollowUpStampsItAndKeepsTheID() async throws {
        let store = try makeStore()
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/nowhere.txt", kind: .text, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "Poll less often", color: .yellow)
        let quiet = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "Leave this", color: .blue)
        let transport = FakeTransport()
        let coordinator = SendCoordinator(noteStore: store, transports: [transport], stagers: [:])
        await coordinator.send(noteIDs: [note.id, quiet.id], to: FakeTransport.target)
        #expect(try #require(transport.delivered.first).0.text.contains("Earlier") == false)
        #expect(await coordinator.draftNoteIDs(documentID: nil).isEmpty)

        try await store.agentReply(note.id, body: "Every minute, or every five?", asks: true, agent: "claude")
        let followUp = try await store.addFollowUp(note.id, body: "Every five.")
        #expect(await coordinator.draftNoteIDs(documentID: document.id) == [note.id], "only the note with a follow-up is sendable")
        await coordinator.send(noteIDs: await coordinator.draftNoteIDs(documentID: nil), to: FakeTransport.target)
        let packet = try #require(transport.delivered.last).0
        #expect(packet.noteIDs == [note.id])
        #expect(packet.text.contains("Note: \(note.id.rawValue)\nWhole file\nUser comment: \"Poll less often\"\nAgent (claude) asked: \"Every minute, or every five?\"\nUser replied: \"Every five.\"\n"), "\(packet.text)")
        let sent = try #require(try await store.note(note.id))
        #expect(sent.state == .sent && !sent.hasUnsentFollowUps && !sent.waitingOnUser)
        #expect(try await store.messages(for: note.id).first { $0.id == followUp.id }?.isSent == true)

        // get_note: every turn, and nothing the user hasn't sent.
        try await store.addFollowUp(note.id, body: "Not sent yet")
        let whole = try await coordinator.packet(noteIDs: [note.id], wholeThread: true).text
        #expect(whole.contains("User replied: \"Every five.\"") && !whole.contains("Not sent yet"), "\(whole)")
    }

    /// A follow-up written while a send is under way isn't in its packet, so the send leaves it unsent for the next.
    @Test func aFollowUpWrittenDuringASendStaysUnsent() async throws {
        let store = try makeStore()
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/nowhere.txt", kind: .text, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "Poll less often", color: .yellow)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "", noteIDs: [note.id], outcome: .delivered)
        let carried = try await store.addFollowUp(note.id, body: "Every five minutes.")
        let edited = try await store.addFollowUp(note.id, body: "Keep the name.")
        let transport = FakeTransport()
        var late: NoteMessage?
        transport.whileDelivering = {
            late = try? await store.addFollowUp(note.id, body: "And only for severe alerts.")
            // Changed after the packet was built: the agent got the old words, so it isn't marked sent.
            try? await store.updateFollowUp(edited.id, body: "Rename it after all.")
        }
        let coordinator = SendCoordinator(noteStore: store, transports: [transport], stagers: [:])
        await coordinator.send(noteIDs: [note.id], to: FakeTransport.target)
        let packet = try #require(transport.delivered.first).0.text
        #expect(packet.contains("Every five minutes.") && !packet.contains("severe"))
        let messages = try await store.messages(for: note.id)
        #expect(messages.first { $0.id == carried.id }?.isSent == true)
        #expect(messages.first { $0.id == late?.id }?.isSent == false)
        #expect(packet.contains("Keep the name.") && messages.first { $0.id == edited.id }?.isSent == false)
        #expect(try await store.note(note.id)?.hasUnsentFollowUps == true)
    }

    /// Send All takes a sent orphan with an answer the user hasn't sent, as Send does; an orphaned draft stays put.
    @Test func sendAllTakesAnOrphanWithAFollowUp() async throws {
        let store = try makeStore()
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/nowhere.txt", kind: .text, fingerprint: Fingerprint())
        let answered = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "Rename this", color: .yellow)
        let lost = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "Never sent", color: .yellow)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "", noteIDs: [answered.id], outcome: .delivered)
        try await store.markOrphaned(answered.id)
        try await store.markOrphaned(lost.id)
        try await store.addFollowUp(answered.id, body: "It went away; ignore it.")
        let coordinator = SendCoordinator(noteStore: store, transports: [], stagers: [:])
        #expect(await coordinator.draftNoteIDs(documentID: nil) == [answered.id])
    }

    /// The app's move reads a file as an open document does: any encoding it opens, hashed as its text, so the
    /// document's next look at the file finds the note in place. Cell notes can't move.
    @Test func movesReadEveryEncodingTheViewerOpens() throws {
        let content = "# Café\nretry twice\npoll every 300 seconds\n"
        let old = Anchor.text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 12), text: "retry twice", before: "", after: "", hash: nil))
        var utf16 = Data([0xFF, 0xFE]); utf16.append(content.data(using: .utf16LittleEndian)!)
        let encodings: [(String, Data)] = [
            ("UTF-8", Data(content.utf8)),
            ("UTF-8 with a BOM", Data([0xEF, 0xBB, 0xBF]) + Data(content.utf8)),
            ("UTF-16", utf16),
            ("Windows-1252", content.data(using: .windowsCP1252)!),
        ]
        for (name, data) in encodings {
            let moved = try AppModel.relocation(of: old, to: .text(line: 3, endLine: 3, text: "poll every 300 seconds"), data: data)
            guard case .text(let anchor) = moved.anchor else { Issue.record("\(name): not text"); continue }
            #expect(anchor.start.line == 3 && anchor.text == "poll every 300 seconds", "\(name)")
            #expect(anchor.hash == Data(content.utf8).sha256Hex, "\(name): hashed as the text, as a document is")
        }
        let cells = Anchor.text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 4), text: "a,b", before: "", after: "", hash: nil,
                                           cells: CellSelection(cells: [.init(lineOffset: 0, column: 1)])))
        #expect(throws: DeliveryError.failed("This note is on spreadsheet cells; it can't be moved.")) {
            try AppModel.relocation(of: cells, to: .text(line: 2, endLine: 2, text: "a,b"), data: Data("x\na,b\n".utf8))
        }
    }

    /// A note moved in a file with a byte-order mark is where the send expects it: the packet reads the file as the
    /// move did and leaves the anchor alone.
    @Test func aMovedNoteInABOMFileIsNotReanchoredAtSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-bom-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/notes.txt"
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("# Notes\nretry twice\npoll every 300 seconds\n".utf8)
        try data.write(to: URL(fileURLWithPath: path))
        let store = try makeStore()
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .text, fingerprint: Fingerprint())
        let old = Anchor.text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 12), text: "poll every 60 seconds", before: "", after: "", hash: "stale"))
        let note = try await store.createNote(documentID: document.id, anchor: old, body: "Poll less often", color: .yellow)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "", noteIDs: [note.id], outcome: .delivered)
        let moved = try AppModel.relocation(of: old, to: .text(line: 3, endLine: 3, text: "poll every 300 seconds"), data: data)
        try await store.agentReply(note.id, body: "Every five minutes.", asks: false, agent: "claude", relocation: moved)
        let coordinator = SendCoordinator(noteStore: store, transports: [], stagers: [:])
        coordinator.fileSystemProvider = { _ in LocalFileSystem(deleteBehavior: .permanent) }
        let packet = try await coordinator.packet(noteIDs: [note.id]).text
        #expect(packet.contains("Line 3\nExcerpt:\n> poll every 300 seconds"), "\(packet)")
        #expect(try await store.note(note.id)?.anchor == moved.anchor)
        #expect(try await store.messages(for: note.id).filter { $0.kind == .moved }.count == 1)
    }

    /// An agent moves a note (read from the file, as the app's relocate does) before the open document has reloaded
    /// the agent's edit. The stale copy only draws the new anchor; it writes nothing, and its later reload, whose hash
    /// matches the move's, leaves the note where the agent put it.
    @Test func aMoveSurvivesTheOpenDocumentCatchingUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-move-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/config.txt"
        try "# Config\npoll every 60 seconds\nretry twice\n".write(toFile: path, atomically: true, encoding: .utf8)
        let store = try makeStore()
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store)
        await session.open()
        defer { session.close() }
        let document = try #require(session.document)
        let original = TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 22), text: "poll every 60 seconds", before: "# Config", after: "retry twice", hash: nil)
        let note = try await store.createNote(documentID: document.id, anchor: .text(original), body: "Poll less often", color: .yellow)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "", noteIDs: [note.id], outcome: .delivered)
        for _ in 0..<100 where session.notes.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }

        // The agent's edit lands on disk; the open copy hasn't seen it.
        let edited = "# Config\nretry twice\n\npoll every 300 seconds\n"
        try edited.write(toFile: path, atomically: true, encoding: .utf8)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let relocation = try AnchorRelocator.relocate(.text(original), to: .text(line: 4, endLine: 4, text: "poll every 300 seconds"), content: edited, hash: data.sha256Hex)
        try await store.agentReply(note.id, body: "Every five minutes.", asks: false, agent: "claude", relocation: relocation)
        for _ in 0..<100 where session.notes.first?.anchor != relocation.anchor { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(session.notes.first?.anchor == relocation.anchor, "the stale copy draws the new anchor")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(try await store.note(note.id)?.anchor == relocation.anchor, "drawing it against stale text wrote nothing")

        await session.reloadFromDisk(discardingEdits: false)
        let after = try #require(try await store.note(note.id))
        #expect(after.anchor == relocation.anchor && after.state == .sent)
        #expect(try await store.messages(for: note.id).filter { $0.kind == .moved }.count == 1, "the reload added no move of its own")
    }

    @Test func failedDeliveryKeepsDraftsAndRecordsFailure() async throws {
        let store = try makeStore()
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/nowhere.txt", kind: .text, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "b", color: .blue)
        let transport = FakeTransport()
        transport.shouldFail = true
        let coordinator = SendCoordinator(noteStore: store, transports: [transport], stagers: [:])
        await coordinator.send(noteIDs: [note.id], to: FakeTransport.target)
        #expect(coordinator.lastError != nil)
        #expect(try await store.note(note.id)?.state == .draft)
        #expect(try await store.sends(for: note.id).first?.outcome.hasPrefix("failed:") == true)
        // The toast's result names what failed, and Retry sends the same notes to the same agent.
        let failed = try #require(coordinator.lastResult)
        #expect(failed.failure != nil && failed.noteIDs == [note.id] && failed.target.id == FakeTransport.target.id)
        #expect(coordinator.inFlight == nil, "nothing is in flight once the attempt ends")
        transport.shouldFail = false
        await coordinator.retry()
        #expect(coordinator.lastResult?.failure == nil && coordinator.lastResult?.noteIDs == [note.id])
        #expect(try await store.note(note.id)?.state == .sent)
        coordinator.clearResult()
        #expect(coordinator.lastResult == nil)
    }

    /// Issue #5: sending one note of twenty touches only that note; the other nineteen stay drafts where they were.
    @Test func sendingOneNoteChangesOnlyThatNote() async throws {
        let store = try makeStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-one-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/PLAN.md"
        let lines = (1...20).map { "line \($0) of the plan" }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        var notes: [Note] = []
        for (index, line) in lines.enumerated() {
            let anchor = TextAnchor(start: .init(line: index + 1, col: 1), end: .init(line: index + 1, col: line.utf16.count + 1), text: line, before: "", after: "")
            notes.append(try await store.createNote(documentID: document.id, anchor: .text(anchor), body: "note \(index)", color: .yellow))
        }
        let transport = FakeTransport()
        let coordinator = SendCoordinator(noteStore: store, transports: [transport], stagers: [:])
        coordinator.fileSystemProvider = { _ in LocalFileSystem(deleteBehavior: .permanent) }
        await coordinator.send(noteIDs: [notes[7].id], to: FakeTransport.target)
        #expect(transport.delivered.count == 1 && transport.delivered[0].0.noteIDs == [notes[7].id])
        #expect(!transport.delivered[0].0.text.contains("note 8"), "no other note rides along")
        for note in notes {
            let now = try #require(try await store.note(note.id))
            #expect(now.state == (note.id == notes[7].id ? .sent : .draft), "note \(note.body)")
            // In place: the sent note's anchor may gain its context lines and the file's hash as the packet reads the
            // file, but no note moves.
            guard case .text(let was) = note.anchor, case .text(let isNow) = now.anchor else { Issue.record("expected text"); continue }
            #expect(isNow.start == was.start && isNow.end == was.end && isNow.text == was.text, "note \(note.body)")
            if note.id != notes[7].id { #expect(now.anchor == note.anchor, "unsent notes are untouched") }
        }
    }

    /// Copy as Packet puts the notes on the clipboard and leaves them drafts, with nothing recorded as sent.
    @Test func copyingLeavesDrafts() async throws {
        let store = try makeStore()
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/gloss-copy/PLAN.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "tighten this", color: .blue)
        let coordinator = SendCoordinator(noteStore: store, transports: [], stagers: [:])
        var copied: [String] = []
        coordinator.writeClipboard = { copied.append($0) }
        await coordinator.copy(noteIDs: [note.id])
        #expect(copied.count == 1 && copied[0].contains("tighten this"))
        #expect(try await store.note(note.id)?.state == .draft)
        #expect(try await store.sends(for: note.id).isEmpty)
        #expect(coordinator.lastResult?.copied == true && coordinator.lastResult?.noteIDs == [note.id])
    }

    @Test func stagesAttachmentsIntoTheSendDirectory() async throws {
        let store = try makeStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-stage-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let crop = "\(directory)/crop.png"
        try Data([0x89, 0x50]).write(to: URL(fileURLWithPath: crop))
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/img.png", kind: .image, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .image(ImageAnchor(x: 1, y: 2, w: 3, h: 4, imageW: 10, imageH: 10)), body: "legend", color: .pink)
        _ = try await store.addAttachment(noteID: note.id, kind: .crop, localPath: crop, width: 3, height: 4)
        let transport = FakeTransport()
        let coordinator = SendCoordinator(noteStore: store, transports: [transport], stagers: [.local: LocalAttachmentStager(cacheRoot: URL(fileURLWithPath: directory + "/cache"))])
        await coordinator.send(noteIDs: [note.id], to: FakeTransport.target)
        let (packet, staged, _) = try #require(transport.delivered.first)
        let stagedPath = try #require(staged.first?.agentPath)
        #expect(stagedPath.hasPrefix(directory + "/cache/s_"))
        #expect(FileManager.default.fileExists(atPath: stagedPath))
        #expect(packet.text.contains("Original size: 10x10\n\nNote: \(note.id.rawValue)\nRegion: x=1 y=2 w=3 h=4 (crop attached)\nAttachment: \(stagedPath)\n"))
    }

    @Test func clipboardTransportCopiesThePacket() async throws {
        let previous = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let previous { NSPasteboard.general.setString(previous, forType: .string) }
        }
        let packet = PacketBuilder.build([PacketNote(noteID: NoteID.new(), agentPath: "/p/a.md", source: .markdown, anchor: .wholeFile, comment: "c")])
        _ = try await ClipboardTransport().deliver(packet, attachments: [], to: ClipboardTransport.target)
        #expect(NSPasteboard.general.string(forType: .string) == packet.text)
    }

    /// Each folder remembers the agent last chosen in it, across launches, and hands it back only while its
    /// session is live.
    @Test func foldersRememberTheirAgentWhileItIsLive() async throws {
        let store = try makeStore()
        let coordinator = SendCoordinator(noteStore: store, transports: [FakeTransport()], stagers: [:])
        await coordinator.refreshTargets()
        let project = SendCoordinator.folderKey(hostID: .local, path: "/work/project")
        let gone = AgentTarget(transport: .tmux, hostID: .local, label: "closed", identityJSON: "{\"pane\":\"9\"}")
        await coordinator.remember(FakeTransport.target, forFolder: project)
        await coordinator.remember(gone, forFolder: SendCoordinator.folderKey(hostID: .local, path: "/work/other"))
        #expect(await coordinator.preferredTarget(hostID: .local, path: "/work/project")?.id == FakeTransport.target.id)
        #expect(await coordinator.preferredTarget(hostID: .local, path: "/work/other") == nil, "its session is gone")
        #expect(await coordinator.preferredTarget(hostID: .local, path: "/elsewhere") == nil)

        let relaunched = SendCoordinator(noteStore: store, transports: [FakeTransport()], stagers: [:])
        await relaunched.refreshTargets()
        #expect(await relaunched.preferredTarget(hostID: .local, path: "/work/project")?.id == FakeTransport.target.id, "kept in the database")
    }
}
