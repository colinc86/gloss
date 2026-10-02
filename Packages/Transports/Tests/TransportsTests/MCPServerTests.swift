import Core
import Foundation
import Testing
@testable import Transports

struct MCPServerTests {
    /// A store with `count` pending notes on one local file, the first with a PNG attachment.
    static func makeStore(count: Int, attachmentDirectory: String) async throws -> (NoteStore, [NoteID]) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/demo/README.md", kind: .markdown, fingerprint: Fingerprint())
        var ids: [NoteID] = []
        for index in 0..<count {
            let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "note \(index): please tighten this paragraph, it repeats the intro", color: .yellow)
            ids.append(note.id)
        }
        let png = "\(attachmentDirectory)/crop.png"
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: URL(fileURLWithPath: png))
        _ = try await store.addAttachment(noteID: ids[0], kind: .crop, localPath: png, width: 4, height: 4)
        return (store, ids)
    }

    static func dependencies(store: NoteStore) -> MCPDependencies {
        MCPDependencies(
            noteStore: store,
            packet: { ids in
                var notes: [PacketNote] = []
                for id in ids {
                    guard let note = try await store.note(id), let document = try await store.document(note.documentID) else { continue }
                    notes.append(PacketNote(noteID: id, agentPath: document.path, source: .markdown, anchor: note.anchor, comment: note.body))
                }
                return PacketBuilder.build(notes)
            },
            hookText: { host, cwd in
                let hostID = host == "local" ? HostID.local : nil
                let pending = try await store.pendingNotes(hostID: hostID, pathPrefix: cwd)
                return PacketBuilder.hookText(pending.map { PacketNote(noteID: $0.note.id, agentPath: $0.document.path, source: .markdown, anchor: $0.note.anchor, comment: $0.note.body) })
            },
            createDraft: { _, path, cwd, _, text in
                let document = try await store.upsertDocument(hostID: .local, path: path ?? "\(cwd ?? "/tmp")/.gloss-inbox.md", kind: .markdown, fingerprint: Fingerprint())
                return try await store.createNote(documentID: document.id, anchor: .wholeFile, body: text, color: .yellow).id
            },
            appVersion: "test"
        )
    }

    /// Sends one JSON-RPC message and returns the decoded reply, whether the server answered as JSON or SSE.
    static func rpc(_ base: URL, session: String?, body: [String: Any]) async throws -> (reply: [String: Any]?, session: String?, status: Int) {
        var request = URLRequest(url: base.appendingPathComponent("mcp"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let text = String(decoding: data, as: UTF8.self)
        var payload: Data? = nil
        if (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            for line in text.components(separatedBy: "\n") where line.hasPrefix("data:") {
                payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
            }
        } else if !data.isEmpty {
            payload = data
        }
        let reply = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (reply, http?.value(forHTTPHeaderField: "Mcp-Session-Id"), http?.statusCode ?? 0)
    }

    @Test func servesToolsResourcesAndHooksOverHTTP() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, ids) = try await Self.makeStore(count: 50, attachmentDirectory: directory)
        let portFile = URL(fileURLWithPath: "\(directory)/mcp-port")
        let server = MCPServer(dependencies: Self.dependencies(store: store), port: 0, portFileURL: portFile)
        try await server.start()
        let port = try #require(await server.port)
        #expect(try String(contentsOf: portFile, encoding: .utf8) == "\(port)\n")
        let base = URL(string: "http://127.0.0.1:\(port)")!
        do {
            // initialize: a session id comes back; no Origin header is sent, as curl and the hook script do.
            let initialize = try await Self.rpc(base, session: nil, body: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])
            let session = try #require(initialize.session)
            #expect(initialize.status == 200)
            #expect(((initialize.reply?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String == "gloss")
            _ = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "method": "notifications/initialized"])

            let tools = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
            let names = ((tools.reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            #expect(Set(names) == ["list_pending_notes", "get_note", "resolve_note", "list_documents"])

            let pending = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_pending_notes", "arguments": ["host": "local", "path": "/tmp/demo"]]])
            let listing = (((pending.reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            #expect(listing.components(separatedBy: "\n").count == 50 && listing.contains(ids[0].rawValue))

            let one = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "get_note", "arguments": ["id": ids[0].rawValue]]])
            let packet = (((one.reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            #expect(packet.hasPrefix("File: /tmp/demo/README.md") && packet.contains("Attachments: note://\(ids[0].rawValue)/attachment/0"))

            let resolved = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "resolve_note", "arguments": ["id": ids[1].rawValue, "outcome": "done", "message": "tightened"]]])
            #expect((((resolved.reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) == "resolved \(ids[1].rawValue)")
            let note = try await store.note(ids[1])
            #expect(note?.state == .resolved && note?.resolveOutcome == .done && note?.resolveMessage == "tightened")
            let again = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "resolve_note", "arguments": ["id": ids[1].rawValue]]])
            #expect((again.reply?["result"] as? [String: Any])?["isError"] as? Bool == true)

            let resources = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 7, "method": "resources/list", "params": [:]])
            let uris = ((resources.reply?["result"] as? [String: Any])?["resources"] as? [[String: Any]])?.compactMap { $0["uri"] as? String } ?? []
            #expect(uris == ["note://\(ids[0].rawValue)/attachment/0"])
            let read = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 8, "method": "resources/read", "params": ["uri": uris[0]]])
            let blob = (((read.reply?["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.first?["blob"] as? String) ?? ""
            #expect(Data(base64Encoded: blob)?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

            let documents = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "list_documents", "arguments": [:]]])
            let table = (((documents.reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            #expect(table.contains("local:/tmp/demo/README.md") && table.contains("resolved=1"))

            // The hook endpoint fits 49 pending notes into the 10,000 character cap.
            let (hookData, hookResponse) = try await URLSession.shared.data(from: base.appendingPathComponent("hook/claude").appending(queryItems: [URLQueryItem(name: "cwd", value: "/tmp/demo"), URLQueryItem(name: "host", value: "local")]))
            #expect((hookResponse as? HTTPURLResponse)?.statusCode == 200)
            let hook = try JSONSerialization.jsonObject(with: hookData) as? [String: Any]
            let context = ((hook?["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String) ?? ""
            #expect(!context.isEmpty && context.count <= 10_000 && (hook?["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String == "UserPromptSubmit")
            let (emptyData, emptyHook) = try await URLSession.shared.data(from: base.appendingPathComponent("hook/codex").appending(queryItems: [URLQueryItem(name: "cwd", value: "/nowhere")]))
            #expect((emptyHook as? HTTPURLResponse)?.statusCode == 200 && emptyData.isEmpty, "no notes: empty body so the hook script prints nothing")

            // The plugin endpoint creates a draft.
            var plugin = URLRequest(url: base.appendingPathComponent("plugin/note"))
            plugin.httpMethod = "POST"
            plugin.httpBody = try JSONSerialization.data(withJSONObject: ["host": "local", "cwd": "/tmp/demo", "text": "from the plugin"])
            let (pluginData, pluginResponse) = try await URLSession.shared.data(for: plugin)
            #expect((pluginResponse as? HTTPURLResponse)?.statusCode == 200)
            let created = (try JSONSerialization.jsonObject(with: pluginData) as? [String: Any])?["note_id"] as? String
            let pendingAfterPlugin = try await store.pendingNotes()
            #expect(created != nil && pendingAfterPlugin.contains { $0.note.id.rawValue == created })

            // DELETE ends the session; the id is unknown afterwards.
            var delete = URLRequest(url: base.appendingPathComponent("mcp"))
            delete.httpMethod = "DELETE"
            delete.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
            let (_, deleted) = try await URLSession.shared.data(for: delete)
            #expect((deleted as? HTTPURLResponse)?.statusCode == 200)
            let stale = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 10, "method": "tools/list", "params": [:]])
            #expect(stale.status == 400)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: portFile.path))
    }
}
