import Core
import Foundation
import Testing
@testable import Remote

struct RemoteSearchParsingTests {
    @Test func parsesRipgrepAndGrepLines() {
        let json = #"{"type":"match","data":{"path":{"text":"/p/a.swift"},"lines":{"text":"let needle = 1\n"},"line_number":12,"absolute_offset":0,"submatches":[]}}"#
        #expect(RemoteSearch.parse(line: Data(json.utf8), ripgrep: true) == RemoteSearchHit(path: "/p/a.swift", line: 12, text: "let needle = 1"))
        #expect(RemoteSearch.parse(line: Data(#"{"type":"begin","data":{}}"#.utf8), ripgrep: true) == nil)
        #expect(RemoteSearch.parse(line: Data("/p/b.md:3:needle: here".utf8), ripgrep: false) == RemoteSearchHit(path: "/p/b.md", line: 3, text: "needle: here"))
        var tools = RemoteTools()
        tools.rg = true
        #expect(RemoteSearch.script(pattern: "it's", root: "/r", tools: tools) == #"rg --json -n --no-messages --max-count 200 --max-filesize 2M -e 'it'\''s' -- '/r'"#)
        tools.rg = false
        #expect(RemoteSearch.script(pattern: "x", root: "/r", tools: tools).hasPrefix("grep -rnI"))
    }
}

struct ExecIntegrationTests {
    @Test(.enabled(if: TestGates.loopback))
    func searchesAndStagesOverLoopback() async throws {
        try await TestGates.withManager { manager, control in
            let host = HostID.new()
            let connection = try await manager.connection(for: host, alias: "localhost")
            let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-exec-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(atPath: "\(root)/sub", withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }
            try "alpha\nneedle one\n".write(toFile: "\(root)/a.txt", atomically: true, encoding: .utf8)
            try "needle two\n".write(toFile: "\(root)/sub/b.md", atomically: true, encoding: .utf8)

            var hits: [RemoteSearchHit] = []
            for try await hit in RemoteSearch.run(pattern: "needle", root: root, over: connection) { hits.append(hit) }
            #expect(Set(hits.map { ($0.path as NSString).lastPathComponent + ":\($0.line)" }) == ["a.txt:2", "b.md:1"])

            let store = NoteStore(database: try AppDatabase.inMemory())
            let hostRow = try await store.upsertHost(name: "localhost-test", kind: .ssh)
            let fileSystem = SFTPFileSystem(hostID: hostRow.id, connection: connection)
            let stager = RemoteAttachmentStager(hostID: hostRow.id, connection: connection, fileSystem: fileSystem, noteStore: store)
            let crop = "\(root)/crop.png"
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: crop))
            let sendID = SendID.new()
            let target = AgentTarget(transport: .tmux, hostID: hostRow.id, label: "t", identityJSON: "{}")
            let staging = try await stager.stage([LocalAttachment(noteID: NoteID.new(), localPath: crop)], for: target, sendID: sendID)
            let remotePath = try #require(staging.attachments.first?.agentPath)
            #expect(remotePath.hasPrefix("/tmp/gloss/\(sendID.rawValue)/"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: remotePath)) == Data([0x89, 0x50, 0x4E, 0x47]))
            #expect(staging.remoteDirectories == ["/tmp/gloss/\(sendID.rawValue)"])
            // The coordinator records the directory once the send row exists; mirror that here.
            let recordedSend = try await store.recordSend(transport: "tmux", targetJSON: "{}", packetText: "p", noteIDs: [], outcome: .delivered)
            try await store.recordStagedFiles(sendID: recordedSend, hostID: hostRow.id, remotePaths: staging.remoteDirectories, expiresAt: Date().addingTimeInterval(7 * 24 * 3600))
            let recorded = try await store.expiredStagedFiles(now: Date().addingTimeInterval(8 * 24 * 3600))
            #expect(recorded.map(\.remotePath) == ["/tmp/gloss/\(sendID.rawValue)"])
            await stager.cleanupExpired(now: Date().addingTimeInterval(8 * 24 * 3600))
            #expect(!FileManager.default.fileExists(atPath: remotePath), "expired staging directory is removed")
            #expect(try await store.expiredStagedFiles(now: Date().addingTimeInterval(8 * 24 * 3600)).isEmpty)
            await fileSystem.channel.close()
        }
    }
}
