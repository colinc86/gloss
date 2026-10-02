import Core
import Foundation
import Remote
import Testing
@testable import Transports

/// Mechanical versions of the remote acceptance checks, gated on `GLOSS_REMOTE_HOST`. They use a stand-in agent pane
/// in the host's Herdr and curl on the host, never a real agent session, and remove everything they create.
struct AcceptanceRemoteTests {
    static func connect() async throws -> (SSHConnectionManager, SSHConnection, HostID, String, RemoteTools) {
        let alias = try #require(TestGates.remoteHost)
        let control = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manager = SSHConnectionManager(controlDirectory: control)
        let hostID = HostID.new()
        let connection = try await manager.connection(for: hostID, alias: alias)
        return (manager, connection, hostID, control, try await connection.tools())
    }

    /// Check 4: a crop is staged on the host and the packet naming it reaches a Herdr pane there, with the file present.
    @Test(.enabled(if: TestGates.remoteHost != nil))
    func stagedCropReachesARemoteHerdrPane() async throws {
        let (manager, connection, hostID, control, tools) = try await Self.connect()
        defer { try? FileManager.default.removeItem(atPath: control) }
        guard tools.herdr else { await manager.disconnectAll(); return }
        let compiler = try await connection.exec("command -v cc || command -v gcc || command -v clang").stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compiler.isEmpty else { await manager.disconnectAll(); return }

        let registry = ConnectionRegistry()
        await registry.register(connection, alias: connection.alias, for: hostID)
        let transport = HerdrTransport(registry: registry, localSocketPath: "/nonexistent/herdr.sock", forwardDirectory: control)
        let socket = try #require(await transport.socketPath(for: hostID))
        let client = HerdrClient(socketPath: socket)
        let workspace = (try? await client.agentList())?.first?.workspaceID
        let standInDir = PathUtilities.join(tools.tmpdir, "gloss-standin-\(UUID().uuidString.prefix(6))")
        var paneID: String?
        var stagedDirectories: [String] = []
        do {
            let built = try await connection.exec("mkdir -p \(ShellQuote.single(standInDir)) && printf '#include <stdio.h>\\nint main(void){int c;while((c=getchar())!=EOF){putchar(c);fflush(stdout);}return 0;}\\n' > \(ShellQuote.single(standInDir))/claude.c && \(compiler) -o \(ShellQuote.single(standInDir))/claude \(ShellQuote.single(standInDir))/claude.c")
            #expect(built.exitStatus == 0, "\(built.stderrText)")
            var params: [String: any Sendable] = ["direction": "down", "cwd": tools.tmpdir, "ratio": 0.2]
            if let workspace { params["workspace_id"] = workspace }
            let split = try await client.call("pane.split", params: params)
            let pane = try #require((split["pane"] as? [String: Any])?["pane_id"] as? String)
            paneID = pane
            try await Task.sleep(for: .seconds(1))
            _ = try await client.call("pane.send_text", params: ["pane_id": pane, "text": "exec \(standInDir)/claude\n"])
            var detected = false
            for _ in 0..<24 {
                try await Task.sleep(for: .milliseconds(250))
                if let info = try? await client.paneGet(pane), info.agent == "claude" { detected = true; break }
            }
            #expect(detected)

            // Stage a PNG crop the way the send coordinator does, then deliver a packet that names it.
            let store = NoteStore(database: try AppDatabase.inMemory())
            let host = try await store.upsertHost(name: connection.alias, kind: .ssh)
            let fileSystem = SFTPFileSystem(hostID: host.id, connection: connection)
            let stager = RemoteAttachmentStager(hostID: host.id, connection: connection, fileSystem: fileSystem, noteStore: store)
            let crop = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-crop-\(UUID().uuidString.prefix(6)).png")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: URL(fileURLWithPath: crop))
            defer { try? FileManager.default.removeItem(atPath: crop) }
            let noteID = NoteID.new()
            let targets = try await transport.discoverTargets()
            let target = try #require(targets.first { HerdrTransport.identity(from: $0)?.paneID == pane })
            let staging = try await stager.stage([LocalAttachment(noteID: noteID, localPath: crop)], for: target, sendID: SendID.new())
            stagedDirectories = staging.remoteDirectories
            let agentPath = try #require(staging.attachments.first?.agentPath)
            let anchor = Anchor.image(ImageAnchor(x: 10, y: 20, w: 300, h: 120, imageW: 1280, imageH: 800))
            let packet = PacketBuilder.build([PacketNote(noteID: noteID, agentPath: PathUtilities.join(tools.home, "design/dashboard.png"), source: .image, anchor: anchor, comment: "The legend overlaps the chart.", attachmentAgentPath: agentPath)])
            _ = try await transport.deliver(packet, attachments: staging.attachments, to: target)
            var text = ""
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                text = try await client.paneRead(pane, source: "visible", lines: 60)
                if text.contains("resolve_note") { break }
            }
            #expect(text.contains("Attachment: \(agentPath)") && text.contains("Region: x=10 y=20 w=300 h=120"), "\(text)")
            let present = try await connection.exec("test -s \(ShellQuote.single(agentPath)) && echo yes")
            #expect(present.stdoutText == "yes\n", "the crop exists on the host at the path the packet names")
        } catch {
            if let paneID { _ = try? await client.call("pane.close", params: ["pane_id": paneID]) }
            _ = try? await connection.exec("rm -rf -- \(ShellQuote.single(standInDir)) \(stagedDirectories.map(ShellQuote.single).joined(separator: " "))")
            await manager.disconnectAll()
            throw error
        }
        if let paneID { _ = try? await client.call("pane.close", params: ["pane_id": paneID]) }
        let cleaned = try await connection.exec("rm -rf -- \(ShellQuote.single(standInDir)) \(stagedDirectories.map(ShellQuote.single).joined(separator: " ")); echo done")
        #expect(cleaned.stdoutText == "done\n")
        await manager.disconnectAll()
        #expect(!(await connection.check()))
    }

    /// Check 6: three notes across two files resolve through the MCP server reached from the host over the tunnel.
    @Test(.enabled(if: TestGates.remoteHost != nil))
    func threeNotesAcrossTwoFilesResolveFromTheHost() async throws {
        let (manager, connection, _, control, _) = try await Self.connect()
        defer { try? FileManager.default.removeItem(atPath: control) }
        let store = NoteStore(database: try AppDatabase.inMemory())
        let readme = try await store.upsertDocument(hostID: .local, path: "/tmp/demo/README.md", kind: .markdown, fingerprint: Fingerprint())
        let main = try await store.upsertDocument(hostID: .local, path: "/tmp/demo/main.swift", kind: .code, fingerprint: Fingerprint())
        var ids: [NoteID] = []
        for (document, body) in [(readme, "intro repeats"), (readme, "broken link"), (main, "rename this")] {
            ids.append(try await store.createNote(documentID: document.id, anchor: .wholeFile, body: body, color: .yellow).id)
        }
        let server = MCPServer(dependencies: MCPServerTests.dependencies(store: store), port: 0, portFileURL: nil)
        try await server.start()
        let port = try #require(await server.port)
        do {
            let forward = try await connection.forwardRemotePort(UInt16(port))
            // One shell script on the host plays the agent: initialize, list, resolve each id.
            let script = """
            set -e
            H='-H Content-Type:application/json -H Accept:application/json,text/event-stream -H MCP-Protocol-Version:2025-06-18'
            U=http://127.0.0.1:\(port)/mcp
            S=$(curl -s -D - $H -X POST $U -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"acceptance","version":"1"}}}' -o /dev/null | tr -d '\\r' | awk 'tolower($1)=="mcp-session-id:"{print $2}')
            curl -s $H -H "Mcp-Session-Id: $S" -X POST $U -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
            curl -s $H -H "Mcp-Session-Id: $S" -X POST $U -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_pending_notes","arguments":{}}}' | grep -o 'n_[A-Z0-9]*' | sort -u | wc -l
            n=3; for id in \(ids.map(\.rawValue).joined(separator: " ")); do curl -s $H -H "Mcp-Session-Id: $S" -X POST $U -d "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$n,\\"method\\":\\"tools/call\\",\\"params\\":{\\"name\\":\\"resolve_note\\",\\"arguments\\":{\\"id\\":\\"$id\\",\\"outcome\\":\\"done\\"}}}" | grep -o "resolved $id" ; n=$((n+1)); done
            """
            let result = try await connection.exec(script, timeout: .seconds(60))
            #expect(result.exitStatus == 0, "\(result.stderrText)")
            let lines = result.stdoutText.split(separator: "\n").map(String.init)
            #expect(lines.first?.trimmingCharacters(in: .whitespaces) == "3", "all three ids were listed: \(result.stdoutText)")
            #expect(lines.dropFirst().count == 3 && lines.dropFirst().allSatisfy { $0.hasPrefix("resolved ") })
            for id in ids {
                let note = try await store.note(id)
                #expect(note?.state == .resolved && note?.resolveOutcome == .done)
            }
            #expect(try await store.pendingNotes().isEmpty)
            await connection.cancel(forward)
        } catch {
            await manager.disconnectAll()
            await server.stop()
            throw error
        }
        await manager.disconnectAll()
        await server.stop()
    }
}
