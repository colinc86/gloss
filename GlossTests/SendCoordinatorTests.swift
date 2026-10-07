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
    static let target = AgentTarget(transport: .tmux, hostID: .local, label: "fake", identityJSON: "{\"pane\":\"0\"}")

    func discoverTargets() async throws -> [AgentTarget] { [Self.target] }

    func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt {
        if shouldFail { throw DeliveryError.failed("boom") }
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
