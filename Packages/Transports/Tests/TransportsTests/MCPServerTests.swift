import Core
import Foundation
import NIOHTTP1
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
            hookText: { _, host, cwd in
                let hostID = host == "local" ? HostID.local : nil
                let pending = try await store.pendingNotes(hostID: hostID, pathPrefix: cwd)
                return PacketBuilder.hookText(pending.map { PacketNote(noteID: $0.note.id, agentPath: $0.document.path, source: .markdown, anchor: $0.note.anchor, comment: $0.note.body) })
            },
            createDraft: { _, path, cwd, text in
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

    /// `open_in_viewer` opens on the session's host (from the registration URL) unless the call names another.
    @Test func openInViewerUsesTheSessionHost() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-open-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, _) = try await Self.makeStore(count: 1, attachmentDirectory: directory)
        _ = try await store.upsertHost(name: "asus", kind: .ssh)
        let opened = OpenLog()
        var dependencies = Self.dependencies(store: store)
        dependencies.openDocument = { host, path, line in await opened.record("\(host)|\(path)|\(line.map(String.init) ?? "-")") }
        // The app knows which URLs it has a host for (a pull request); any other http(s) URL is a web page.
        dependencies.resolveURL = { url in url.host() == "github.com" ? ("github", "/o/r/pull/12/Pull request.md") : nil }
        let server = MCPServer(dependencies: dependencies, port: 0, portFileURL: URL(fileURLWithPath: "\(directory)/mcp-port"))
        try await server.start()
        let port = try #require(await server.port)
        defer { Task { await server.stop() } }
        func call(_ base: URL, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
            let initialize = try await Self.rpc(base, session: nil, body: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])
            let session = try #require(initialize.session)
            _ = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "method": "notifications/initialized"])
            let reply = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "open_in_viewer", "arguments": arguments]])
            let result = reply.reply?["result"] as? [String: Any]
            return (((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result?["isError"] as? Bool ?? false)
        }
        let local = URL(string: "http://127.0.0.1:\(port)")!
        let remote = URL(string: "http://127.0.0.1:\(port)/?host=asus")!
        #expect(try await call(local, ["path": "/tmp/a.swift", "line": 12]).text == "showing local:/tmp/a.swift at line 12")
        #expect(try await call(local, ["path": "/tmp/a.swift"]).isError == false)
        #expect(try await call(local, ["path": "relative.swift"]).isError, "relative paths are refused")
        #expect(try await call(local, ["path": "/tmp/a.swift", "line": 0]).isError, "lines are 1-based")
        #expect(try await call(local, ["path": "/tmp/a.swift", "line": 1e300]).isError, "an absurd number is refused, not a crash")
        #expect(try await call(local, ["path": "/tmp/a.swift", "host": "nowhere"]).isError, "unknown hosts are refused")
        // The session URL's host is the default; a host in the call wins.
        #expect(try await call(remote, ["path": "/home/colin/x.py", "line": 3]).text == "showing asus:/home/colin/x.py at line 3")
        #expect(try await call(remote, ["path": "/Users/c/y.md", "host": "local"]).text == "showing local:/Users/c/y.md")
        #expect(try await call(local, ["url": "https://github.com/o/r/pull/12"]).text == "showing github:/o/r/pull/12/Pull request.md")
        #expect(try await call(local, ["url": "https://example.com/docs", "line": 4]).text == "showing web:https://example.com/docs at line 4")
        #expect(try await call(local, ["url": "ftp://example.com/x"]).isError, "a URL with no viewer is refused")
        #expect(try await call(local, [:]).isError, "path or url is required")
        #expect(await opened.lines == ["local|/tmp/a.swift|12", "local|/tmp/a.swift|-", "asus|/home/colin/x.py|3", "local|/Users/c/y.md|-", "github|/o/r/pull/12/Pull request.md|-", "web|https://example.com/docs|4"])
    }

    /// The hook finds notes under a non-ASCII working directory, encoded the way `curl --data-urlencode` sends it.
    @Test func hookFindsNotesUnderNonASCIIDirectories() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/Café Notes/plan.md", kind: .markdown, fingerprint: Fingerprint())
        _ = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "tighten the intro", color: .yellow)
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-hook-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let server = MCPServer(dependencies: Self.dependencies(store: store), port: 0, portFileURL: URL(fileURLWithPath: "\(directory)/mcp-port"))
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.port)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/hook/claude?cwd=%2Ftmp%2FCaf%C3%A9+Notes&host=local"))
        let (data, _) = try await URLSession.shared.data(from: url)
        let hook = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let context = ((hook?["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String) ?? ""
        #expect(context.contains("tighten the intro") && context.contains("/tmp/Café Notes/plan.md"))
    }

    /// A body over the 8 MB cap is refused with 413 and the connection closed, and the server keeps serving.
    @Test func anOversizedBodyIsRefused() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-big-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, _) = try await Self.makeStore(count: 1, attachmentDirectory: directory)
        let server = MCPServer(dependencies: Self.dependencies(store: store), port: 0, portFileURL: URL(fileURLWithPath: "\(directory)/mcp-port"))
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.port)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/plugin/note")!)
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 0x61, count: 9 * 1024 * 1024)
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            URLSession.shared.dataTask(with: request) { _, response, _ in
                continuation.resume(returning: (response as? HTTPURLResponse)?.statusCode ?? -1)
            }.resume()
        }
        // The client may see the 413 or, having its upload cut off, no response at all; it must never be accepted.
        #expect(status == 413 || status == -1, "status \(status)")
        let (_, health) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        #expect((health as? HTTPURLResponse)?.statusCode == 200, "the server still answers")
    }

    /// A web page (a site open in a browser, or one rebinding its name to 127.0.0.1) is refused; agents, hooks and
    /// the plugin, which send no Origin and use a loopback Host, are served.
    @Test func webPagesCannotReachTheNotes() async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "127.0.0.1:47831")
        #expect(HTTPListener.permits(headers))
        headers.replaceOrAdd(name: "Host", value: "localhost")
        #expect(HTTPListener.permits(headers))
        headers.replaceOrAdd(name: "Host", value: "[::1]:47831")
        #expect(HTTPListener.permits(headers))
        headers.replaceOrAdd(name: "Host", value: "evil.example:47831")
        #expect(!HTTPListener.permits(headers), "a rebound name")
        headers.replaceOrAdd(name: "Host", value: "127.0.0.1:47831")
        headers.add(name: "Origin", value: "https://evil.example")
        #expect(!HTTPListener.permits(headers), "a cross-site request")
        headers.replaceOrAdd(name: "Origin", value: "null")
        #expect(!HTTPListener.permits(headers), "a sandboxed frame")

        // End to end: the same hook request with and without an Origin.
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-origin-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, _) = try await Self.makeStore(count: 1, attachmentDirectory: directory)
        let server = MCPServer(dependencies: Self.dependencies(store: store), port: 0, portFileURL: URL(fileURLWithPath: "\(directory)/mcp-port"))
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.port)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let (_, refused) = try await URLSession.shared.data(for: request)
        #expect((refused as? HTTPURLResponse)?.statusCode == 403)
        let (_, served) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        #expect((served as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func registrationURLsCarryTheHostAlias() {
        #expect(MCPServer.url(port: 47831) == "http://127.0.0.1:47831/mcp")
        #expect(MCPServer.url(port: 47831, host: "local") == "http://127.0.0.1:47831/mcp")
        #expect(MCPServer.url(port: 47831, host: "my box") == "http://127.0.0.1:47831/mcp?host=my%20box")
        #expect(MCPServer.snippets(port: 47831, host: "asus").claudeCommand == "claude mcp add -s user --transport http gloss 'http://127.0.0.1:47831/mcp?host=asus'")
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
            #expect(Set(names) == ["list_pending_notes", "get_note", "resolve_note", "list_documents", "open_in_viewer"])

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
            // curl sends "+" for spaces; the path prefix must still match.
            let plusURL = URL(string: "http://127.0.0.1:\(port)/hook/claude?cwd=%2Ftmp%2Fdemo+dir&host=local")!
            let plusDocument = try await store.upsertDocument(hostID: .local, path: "/tmp/demo dir/notes.md", kind: .markdown, fingerprint: Fingerprint())
            _ = try await store.createNote(documentID: plusDocument.id, anchor: .wholeFile, body: "space case", color: .yellow)
            let (plusData, plusResponse) = try await URLSession.shared.data(from: plusURL)
            #expect((plusResponse as? HTTPURLResponse)?.statusCode == 200 && String(decoding: plusData, as: UTF8.self).contains("demo dir/notes.md"), "status \((plusResponse as? HTTPURLResponse)?.statusCode ?? 0) body: \(String(decoding: plusData, as: UTF8.self))")
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
            #expect(stale.status == 404, "an unknown session id tells the client to re-initialize")
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: portFile.path))
    }
}

private actor OpenLog {
    private(set) var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
}
