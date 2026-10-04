import Core
import Foundation
import Testing
@testable import Gloss

@MainActor
struct PullRequestPacketTests {
    @Test func aNoteOnAPullRequestFileNamesThePullRequestAndTheHead() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        // The provider's answer, stood in for: the app has no token in a test.
        model.send.packetResourceProvider = { hostID, path, line in
            guard hostID == .github else { return nil }
            return PacketResource(url: URL(string: "https://github.com/o/r/pull/2")!, details: path.hasSuffix("Conversation.md") ? ["Comment: https://github.com/o/r/pull/2#issuecomment-\(line ?? 0)"] : ["Path: Sources/App.swift at f00d123"])
        }
        let document = try await model.noteStore.upsertDocument(hostID: .github, path: "/o/r/pull/2/changes/Sources/App.swift", kind: .code, fingerprint: Fingerprint())
        let anchor = TextAnchor(start: .init(line: 3, col: 1), end: .init(line: 3, col: 10), text: "let x = 1", before: "", after: "")
        let note = try await model.noteStore.createNote(documentID: document.id, anchor: .text(anchor), body: "Name this", color: .yellow)
        let packet = try await model.send.packet(noteIDs: [note.id])
        #expect(packet.text.hasPrefix("File: /o/r/pull/2/changes/Sources/App.swift\nSource: pull_request\nResource: https://github.com/o/r/pull/2\nPath: Sources/App.swift at f00d123\n\nLine 3\n"), Comment(rawValue: packet.text))

        let conversation = try await model.noteStore.upsertDocument(hostID: .github, path: "/o/r/pull/2/Conversation.md", kind: .markdown, fingerprint: Fingerprint())
        let reply = try await model.noteStore.createNote(documentID: conversation.id, anchor: .text(TextAnchor(start: .init(line: 4, col: 1), end: .init(line: 4, col: 5), text: "Looks", before: "", after: "")), body: "Answer this", color: .blue)
        let second = try await model.send.packet(noteIDs: [reply.id])
        #expect(second.text.contains("Source: pull_request\nResource: https://github.com/o/r/pull/2\nComment: https://github.com/o/r/pull/2#issuecomment-4\n"), Comment(rawValue: second.text))
        await model.shutDown()
    }
}
