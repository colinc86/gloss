import Core
import Foundation
import Testing
@testable import Remote

struct RemoteSearchParsingTests {
    @Test func smartCaseLooksOnlyAtThePatternsOwnCapitals() {
        #expect(!RemoteSearch.matchesCase("route", regex: false))
        #expect(RemoteSearch.matchesCase("Route", regex: false))
        #expect(!RemoteSearch.matchesCase(#"\Sroute\W"#, regex: true), "escapes are classes")
        #expect(RemoteSearch.matchesCase(#"\sRoute"#, regex: true))
        #expect(RemoteSearch.grepFlags(pattern: #"\bfoo"#, regex: true) == ["-E", "-i"])
    }

    @Test func parsesRipgrepAndGrepLines() {
        let json = #"{"type":"match","data":{"path":{"text":"/p/a.swift"},"lines":{"text":"let needle = 1\n"},"line_number":12,"absolute_offset":0,"submatches":[]}}"#
        #expect(RemoteSearch.parse(line: Data(json.utf8), ripgrep: true) == RemoteSearchHit(path: "/p/a.swift", line: 12, text: "let needle = 1"))
        #expect(RemoteSearch.parse(line: Data(#"{"type":"begin","data":{}}"#.utf8), ripgrep: true) == nil)
        #expect(RemoteSearch.parse(line: Data("/p/b.md\u{0}3:needle: here".utf8), ripgrep: false) == RemoteSearchHit(path: "/p/b.md", line: 3, text: "needle: here"))
        // A line that isn't UTF-8 (café in Latin-1) comes as base64 bytes from rg and as raw bytes from grep.
        let latin1 = Data("caf".utf8) + Data([0xE9]) + Data(" needle".utf8)
        let bytes = #"{"type":"match","data":{"path":{"text":"/p/c.txt"},"lines":{"bytes":"\#(latin1.base64EncodedString())"},"line_number":4}}"#
        #expect(RemoteSearch.parse(line: Data(bytes.utf8), ripgrep: true) == RemoteSearchHit(path: "/p/c.txt", line: 4, text: "café needle"))
        #expect(RemoteSearch.parse(line: Data("/p/c.txt\u{0}4:".utf8) + latin1, ripgrep: false) == RemoteSearchHit(path: "/p/c.txt", line: 4, text: "café needle"))
        #expect(RemoteSearch.parse(line: Data("/p/a:b/notes 10:30.md\u{0}1:needle".utf8), ripgrep: false) == RemoteSearchHit(path: "/p/a:b/notes 10:30.md", line: 1, text: "needle"),
                "grep ends the path with a NUL, so a colon in it is part of the name")
        #expect(RemoteSearch.parse(line: Data("/p/b.md:3:needle".utf8), ripgrep: false) == nil, "a line without the NUL is not a hit")
        var tools = RemoteTools()
        tools.rg = true
        #expect(RemoteSearch.script(pattern: "it's", root: "/r", tools: tools) == #"rg --json -n --no-messages --max-count 200 --max-filesize 2M --fixed-strings --smart-case -e 'it'\''s' -- '/r'"#)
        #expect(RemoteSearch.script(pattern: "a.*b", root: "/r", tools: tools, regex: true).contains("--smart-case -e 'a.*b'"), "regex mode drops --fixed-strings")
        tools.rg = false
        #expect(RemoteSearch.script(pattern: "x", root: "/r", tools: tools).hasPrefix("grep -rnI --null -m 200 --exclude-dir=.git '--exclude=.*' '--exclude-dir=.*' -F -i -e"),
                "grep stops at 200 matches a file, as rg does")
        #expect(RemoteSearch.grepFlags(pattern: "Foo", regex: true) == ["-E"], "a capital letter makes the search case-sensitive")
        // Hidden files follow the explorer: rg leaves them out unless told, grep searches them unless told; never `.git`.
        tools.rg = true
        #expect(RemoteSearch.script(pattern: "x", root: "/r", tools: tools, hidden: true).contains("--smart-case --hidden --glob '!.git' -e"))
        #expect(!RemoteSearch.script(pattern: "x", root: "/r", tools: tools).contains("--hidden"))
        tools.rg = false
        #expect(RemoteSearch.script(pattern: "x", root: "/r", tools: tools).contains("--exclude-dir=.git '--exclude=.*' '--exclude-dir=.*' -F"))
        #expect(RemoteSearch.script(pattern: "x", root: "/r", tools: tools, hidden: true).contains("--exclude-dir=.git -F"))
        #expect(RemoteSearch.grepHiddenFlags(false, root: "/home/me/.config") == ["--exclude=.*"], "a dot-folder searched on purpose is still searched")
    }
}

struct GrepFallbackTests {
    /// The grep script a host without rg runs, run here by this Mac's grep (BSD; GNU takes the same flags): a colon in
    /// a folder or file name stays in the path, and a file stops at the match limit.
    @Test func grepsScriptKeepsColonsInPathsAndCapsMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-grep-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(root)/a:b", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "intro\nneedle: one\n".write(toFile: "\(root)/a:b/notes 10:30.md", atomically: true, encoding: .utf8)
        try String(repeating: "needle\n", count: RemoteSearch.maxMatchesPerFile + 50).write(toFile: "\(root)/many.txt", atomically: true, encoding: .utf8)
        let script = RemoteSearch.script(pattern: "needle", root: root, tools: RemoteTools())
        let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sh", arguments: ["-c", script]))
        let output = await process.collectStdout()
        let hits = output.split(separator: 0x0A).compactMap { RemoteSearch.parse(line: Data($0), ripgrep: false) }
        // Hidden files: left out unless asked for, as the explorer hides them.
        try FileManager.default.createDirectory(atPath: "\(root)/.github", withIntermediateDirectories: true)
        try "needle in a workflow\n".write(toFile: "\(root)/.github/ci.yml", atomically: true, encoding: .utf8)
        func run(hidden: Bool) async throws -> [RemoteSearchHit] {
            let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sh", arguments: ["-c", RemoteSearch.script(pattern: "workflow", root: root, tools: RemoteTools(), hidden: hidden)]))
            return await process.collectStdout().split(separator: 0x0A).compactMap { RemoteSearch.parse(line: Data($0), ripgrep: false) }
        }
        #expect(try await run(hidden: false).isEmpty)
        #expect(try await run(hidden: true).map(\.path) == ["\(root)/.github/ci.yml"])
        let colon = hits.filter { $0.path.hasSuffix("notes 10:30.md") }
        #expect(colon == [RemoteSearchHit(path: "\(root)/a:b/notes 10:30.md", line: 2, text: "needle: one")])
        #expect(hits.filter { $0.path.hasSuffix("many.txt") }.count == RemoteSearch.maxMatchesPerFile)
    }
}

struct ExecIntegrationTests {
    @Test(.enabled(if: TestGates.loopback))
    func searchesAndStagesOverLoopback() async throws {
        try await TestGates.withManager { manager, _ in
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
            let stagingRoot = NSHomeDirectory() + "/.cache/gloss/attachments"
            #expect(remotePath.hasPrefix("\(stagingRoot)/\(sendID.rawValue)/"), "in the user's own home, not a /tmp anyone can pre-create")
            let rootMode = try FileManager.default.attributesOfItem(atPath: stagingRoot)[.posixPermissions] as? Int
            #expect(rootMode == 0o700)
            #expect(try Data(contentsOf: URL(fileURLWithPath: remotePath)) == Data([0x89, 0x50, 0x4E, 0x47]))
            #expect(staging.remoteDirectories == ["\(stagingRoot)/\(sendID.rawValue)"])
            // The coordinator records the directory once the send row exists; mirror that here.
            let recordedSend = try await store.recordSend(transport: "tmux", targetJSON: "{}", packetText: "p", noteIDs: [], outcome: .delivered)
            try await store.recordStagedFiles(sendID: recordedSend, hostID: hostRow.id, remotePaths: staging.remoteDirectories, expiresAt: Date().addingTimeInterval(7 * 24 * 3600))
            let recorded = try await store.expiredStagedFiles(now: Date().addingTimeInterval(8 * 24 * 3600))
            #expect(recorded.map(\.remotePath) == ["\(stagingRoot)/\(sendID.rawValue)"])
            await stager.cleanupExpired(now: Date().addingTimeInterval(8 * 24 * 3600))
            #expect(!FileManager.default.fileExists(atPath: remotePath), "expired staging directory is removed")
            #expect(try await store.expiredStagedFiles(now: Date().addingTimeInterval(8 * 24 * 3600)).isEmpty)
            await fileSystem.channel.close()
        }
    }
}
