import Core
import Foundation
import MCP
import NIOHTTP1
import Testing
@testable import Transports

struct MCPServerTests {
    /// A store with `count` sent notes on one local file, the first with a PNG attachment, plus one draft the agent
    /// must never see.
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
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "", noteIDs: ids, outcome: .delivered)
        let secret = try await store.upsertDocument(hostID: .local, path: "/tmp/demo/DRAFTS.md", kind: .markdown, fingerprint: Fingerprint())
        _ = try await store.createNote(documentID: secret.id, anchor: .wholeFile, body: "unsent draft", color: .yellow)
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
        dependencies.openDocument = { host, path, line, end in await opened.record("\(host)|\(path)|\(line.map(String.init) ?? "-")" + (end.map { "-\($0)" } ?? "")) }
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
        #expect(try await call(local, ["path": "/tmp/a.swift", "line": 3, "end_line": 9]).text == "showing local:/tmp/a.swift at lines 3-9")
        #expect(try await call(local, ["path": "/tmp/a.swift", "line": 9, "end_line": 3]).isError, "a range must not run backwards")
        #expect(try await call(local, ["path": "/tmp/a.swift", "end_line": 3]).isError, "end_line needs line")
        #expect(try await call(local, [:]).isError, "path or url is required")
        #expect(await opened.lines == ["local|/tmp/a.swift|12", "local|/tmp/a.swift|-", "asus|/home/colin/x.py|3", "local|/Users/c/y.md|-", "github|/o/r/pull/12/Pull request.md|-", "web|https://example.com/docs|4", "local|/tmp/a.swift|3-9"])
    }

    /// Drafts stay in the app until the user sends them: no tool lists, reads or resolves one, and the old hook
    /// routes are gone.
    @Test func agentsNeverSeeDrafts() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-drafts-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, ids) = try await Self.makeStore(count: 2, attachmentDirectory: directory)
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/demo/README.md", kind: .markdown, fingerprint: Fingerprint())
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "not yet", color: .yellow)
        let dependencies = Self.dependencies(store: store)
        func call(_ name: String, _ arguments: [String: Value] = [:]) async throws -> (text: String, isError: Bool) {
            let result = try await MCPServer.callTool(.init(name: name, arguments: arguments), dependencies: dependencies)
            let text = result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined(separator: "\n")
            return (text, result.isError ?? false)
        }
        let listing = try await call("list_pending_notes")
        #expect(listing.text.contains(ids[0].rawValue) && !listing.text.contains(draft.id.rawValue) && !listing.text.contains("unsent draft"))
        #expect(try await call("get_note", ["id": .string(draft.id.rawValue)]).isError)
        #expect(try await call("resolve_note", ["id": .string(draft.id.rawValue)]).isError)
        #expect(try await store.note(draft.id)?.state == .draft)
        let documents = try await call("list_documents")
        #expect(!documents.text.contains("DRAFTS.md") && !documents.text.contains("draft="), "\(documents.text)")
        // A note sent and then put back to a draft (#13) is still readable (the agent had it) but can't be resolved.
        try await store.unsend(ids[1])
        #expect(try await call("get_note", ["id": .string(ids[1].rawValue)]).isError == false)
        #expect(try await call("resolve_note", ["id": .string(ids[1].rawValue)]).isError)
        // An orphaned draft, or one resolved by hand, was never given to an agent either.
        try await store.markOrphaned(draft.id)
        #expect(try await call("get_note", ["id": .string(draft.id.rawValue)]).isError)
        let secret = try await store.pendingNotes(states: [.draft]).first { $0.document.path.hasSuffix("DRAFTS.md") }!.note
        try await store.resolve(secret.id)
        #expect(try await call("get_note", ["id": .string(secret.id.rawValue)]).isError)
        #expect(!(try await call("list_documents").text.contains("DRAFTS.md")))
        let resources = try await MCPServer.resources(dependencies: dependencies)
        #expect(resources.allSatisfy { !$0.uri.contains(draft.id.rawValue) })

        let server = MCPServer(dependencies: dependencies, port: 0, portFileURL: URL(fileURLWithPath: "\(directory)/mcp-port"))
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.port)
        for flavour in ["claude", "codex", "text"] {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/hook/\(flavour)?cwd=%2Ftmp%2Fdemo")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 404, "/hook/\(flavour) is gone")
        }
    }

    /// A sent note the user deleted (it is in Recently Deleted, issue #15) is named as deleted, not unknown, and is
    /// left out of the listings.
    @Test func agentsAreToldANoteWasDeleted() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-trash-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, ids) = try await Self.makeStore(count: 2, attachmentDirectory: directory)
        let dependencies = Self.dependencies(store: store)
        func call(_ name: String, _ arguments: [String: Value] = [:]) async throws -> (text: String, isError: Bool) {
            let result = try await MCPServer.callTool(.init(name: name, arguments: arguments), dependencies: dependencies)
            let text = result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined(separator: "\n")
            return (text, result.isError ?? false)
        }
        try await store.trashNotes([ids[0]])
        let deleted = "Note \(ids[0].rawValue) was deleted by the user."
        for tool in ["get_note", "resolve_note"] {
            let result = try await call(tool, ["id": .string(ids[0].rawValue)])
            #expect(result.isError && result.text == deleted, "\(tool): \(result.text)")
        }
        let reply = try await call("reply_to_note", ["id": .string(ids[0].rawValue), "message": .string("Done?")])
        #expect(reply.isError && reply.text == deleted, "\(reply.text)")
        #expect(try await call("get_note", ["id": .string(NoteID.new().rawValue)]).text == "unknown note id", "an id never seen is still unknown")
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/demo/README.md", kind: .markdown, fingerprint: Fingerprint())
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "never sent", color: .yellow)
        try await store.trashNotes([draft.id])
        #expect(try await call("get_note", ["id": .string(draft.id.rawValue)]).text == "unknown note id", "a deleted draft no agent had stays unknown")
        let listing = try await call("list_pending_notes")
        #expect(!listing.text.contains(ids[0].rawValue) && listing.text.contains(ids[1].rawValue), "\(listing.text)")
        #expect(try await call("list_documents").text.contains("sent=1"))
        #expect(try await MCPServer.resources(dependencies: dependencies).isEmpty, "the deleted note's attachment is no longer offered")

        try await store.untrashNotes([ids[0]])
        #expect(try await call("get_note", ["id": .string(ids[0].rawValue)]).isError == false, "restored, it is the agent's again")
    }

    /// A sent note whose text the agent removed (as the note asked) is still listed, marked as gone, and can be
    /// resolved; one taken back to a draft before its text went can't.
    @Test func agentsResolveNotesWhoseTextIsGone() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-orphans-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, ids) = try await Self.makeStore(count: 2, attachmentDirectory: directory)
        let dependencies = Self.dependencies(store: store)
        func call(_ name: String, _ arguments: [String: Value] = [:]) async throws -> (text: String, isError: Bool) {
            let result = try await MCPServer.callTool(.init(name: name, arguments: arguments), dependencies: dependencies)
            let text = result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined(separator: "\n")
            return (text, result.isError ?? false)
        }
        try await store.markOrphaned(ids[0])
        try await store.unsend(ids[1])
        try await store.markOrphaned(ids[1])
        let listing = try await call("list_pending_notes")
        #expect(listing.text.contains(ids[0].rawValue) && listing.text.contains("(text no longer found)"), "\(listing.text)")
        #expect(!listing.text.contains(ids[1].rawValue))
        let resolved = try await call("resolve_note", ["id": .string(ids[0].rawValue), "message": .string("Removed.")])
        #expect(!resolved.isError, "\(resolved.text)")
        #expect(try await store.note(ids[0])?.state == .resolved)
        // The reply is headed with the client that resolved it, not the target the note went to.
        #expect(try await store.note(ids[0])?.resolveAgent == "agent")
        let again = try await call("resolve_note", ["id": .string(ids[0].rawValue)])
        #expect(again.isError && again.text.contains("already resolved"))
        let unsent = try await call("resolve_note", ["id": .string(ids[1].rawValue)])
        #expect(unsent.isError && unsent.text.contains("hasn't sent it again"), "\(unsent.text)")
        #expect(try await store.note(ids[1])?.state == .orphaned)
        let documents = try await call("list_documents")
        #expect(documents.text.contains("orphaned=0"), "\(documents.text)")
    }

    /// Threads: an agent replies or asks without resolving, moves a note to its new text or marks the text removed,
    /// and is refused a move it describes wrongly (with nothing written) or a resolve while the user has an unsent
    /// follow-up. `needs_input` still asks.
    @Test func agentsReplyAskAndMoveNotes() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-threads-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/demo/config.md", kind: .markdown, fingerprint: Fingerprint())
        let content = "# Config\npoll every 60 seconds\nretry twice\n"
        let edited = "# Config\nretry twice\npoll every 300 seconds, severe alerts only\n"
        func note(_ line: Int, _ text: String) async throws -> NoteID {
            let index = LineIndex(content)
            let range = (content as NSString).range(of: text)
            precondition(index.position(forUTF16Offset: range.location).line == line)
            return try await store.createNote(documentID: document.id, anchor: .text(ReAnchorer.make(from: range, in: content, index: index, hash: nil)), body: "Poll less often", color: .yellow).id
        }
        let polled = try await note(2, "poll every 60 seconds")
        let retried = try await note(3, "retry twice")
        let other = try await note(1, "# Config")
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "", noteIDs: [polled, retried, other], outcome: .delivered)
        var dependencies = Self.dependencies(store: store)
        dependencies.relocate = { id, target in
            let note = try #require(try await store.note(id))
            return try AnchorRelocator.relocate(note.anchor, to: target, content: edited, hash: nil)
        }
        func call(_ name: String, _ arguments: [String: Value]) async throws -> (text: String, isError: Bool) {
            let result = try await MCPServer.callTool(.init(name: name, arguments: arguments), dependencies: dependencies, agentName: "claude")
            return (result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined(separator: "\n"), result.isError ?? false)
        }

        // A question keeps the note open and waiting on the user; a reply adds to the thread.
        let asked = try await call("reply_to_note", ["id": .string(polled.rawValue), "message": .string("One minute for all alerts, or only severe ones?"), "asks": .bool(true)])
        #expect(asked == ("asked the user on note \(polled.rawValue); the answer comes back when they send it", false))
        let waiting = try await store.note(polled)
        #expect(waiting?.state == .sent && waiting?.waitingOnUser == true)
        #expect(try await call("reply_to_note", ["id": .string(other.rawValue), "message": .string("Looked; nothing to change yet.")]) == ("replied on note \(other.rawValue)", false))
        #expect(try await call("reply_to_note", ["id": .string(other.rawValue), "message": .string("  ")]).isError, "a reply needs words")
        let listing = try await call("list_pending_notes", [:]).text
        #expect(listing.contains("\(polled.rawValue)\t") && listing.contains("waiting=user\tmessages=1"), "\(listing)")
        #expect(listing.contains("waiting=agent\tmessages=0"), "\(listing)")
        #expect(try await call("list_documents", [:]).text.contains("waiting_on_user=1"))

        // The user answers in a follow-up they haven't sent: the agent can't resolve over it.
        try await store.addFollowUp(polled, body: "Only severe ones.")
        let early = try await call("resolve_note", ["id": .string(polled.rawValue)])
        #expect(early.isError && early.text.contains("follow-up"), "\(early.text)")
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "", noteIDs: [polled], outcome: .delivered)
        #expect(try await store.note(polled)?.waitingOnUser == false)

        // A move described wrongly is refused and nothing is written, so a retry is clean.
        let before = try await store.messages(for: polled).count
        let wrong = try await call("resolve_note", ["id": .string(polled.rawValue), "message": .string("Done."), "location": ["line": 2, "text": "poll every 30 seconds"]])
        #expect(wrong.isError && wrong.text.contains("nothing was written") && wrong.text.contains("poll every 30 seconds"), "\(wrong.text)")
        let untouched = try await store.note(polled), after = try await store.messages(for: polled).count
        #expect(untouched?.state == .sent && after == before)
        #expect(try await call("resolve_note", ["id": .string(polled.rawValue), "location": ["text": "x"]]).isError, "a location needs its line")
        #expect(try await call("resolve_note", ["id": .string(polled.rawValue), "location": "line 3"]).isError, "a location is an object")
        #expect(try await call("resolve_note", ["id": .string(polled.rawValue), "location": ["selector": "#poll"]]).isError, "a text note takes lines, not a selector")

        // Resolving with where the change now is moves the note there, in the same write.
        let resolved = try await call("resolve_note", ["id": .string(polled.rawValue), "message": .string("Every five minutes, severe only."),
                                                      "location": ["line": 3, "end_line": 3, "text": "poll every 300 seconds, severe alerts only"]])
        #expect(resolved == ("resolved \(polled.rawValue); moved it to line 3", false))
        let moved = try #require(try await store.note(polled))
        guard case .text(let anchor) = moved.anchor else { Issue.record("not text"); return }
        #expect(moved.state == .resolved && anchor.start.line == 3 && anchor.text == "poll every 300 seconds, severe alerts only")
        #expect(try await store.messages(for: polled).map(\.kind) == [.question, .comment, .moved, .reply])
        let closed = try await call("reply_to_note", ["id": .string(polled.rawValue), "message": .string("One more thing")])
        #expect(closed.isError && closed.text.contains("reopens it with a follow-up"), "\(closed.text)")

        // The text was removed: the note becomes a point where it was.
        let removed = try await call("reply_to_note", ["id": .string(retried.rawValue), "message": .string("Dropped the retry."), "location": ["removed": true, "line": 3]])
        #expect(removed == ("replied on note \(retried.rawValue); marked its text removed at line 3", false), "the start of the line the agent gave: \(removed.text)")
        let point = try #require(try await store.messages(for: retried).first { $0.kind == .moved }?.move)
        #expect(point.removed && point.to != point.from)

        // needs_input, from agents with older instructions, asks rather than resolves.
        let legacy = try await call("resolve_note", ["id": .string(other.rawValue), "outcome": .string("needs_input"), "message": .string("Rename the heading?")])
        #expect(legacy == ("asked the user (note \(other.rawValue)); the answer comes back when they send it", false))
        let asking = try await store.note(other)
        #expect(asking?.state == .sent && asking?.waitingOnUser == true)

        // A bare acknowledgement adds no reply: the resolved state already says it.
        #expect(try await call("resolve_note", ["id": .string(retried.rawValue), "message": .string(" Done. ")]) == ("resolved \(retried.rawValue)", false))
        let acknowledged = try await store.note(retried)
        #expect(acknowledged?.state == .resolved && acknowledged?.resolveMessage == nil)
        #expect(try await store.messages(for: retried).filter { $0.kind == .reply }.map(\.body) == ["Dropped the retry."])
        #expect(["done", "Done.", "FIXED!", "ok", "Okay", "resolved."].allSatisfy(MCPServer.isBareAcknowledgement))
        #expect(!MCPServer.isBareAcknowledgement("Done; kept the old name for the API.") && !MCPServer.isBareAcknowledgement("not done"))

        // needs_input is a question, so it needs words; a null location is no location; a selector goes alone.
        #expect(try await call("resolve_note", ["id": .string(other.rawValue), "outcome": .string("needs_input"), "message": .string(" ")]).isError)
        #expect(try await call("reply_to_note", ["id": .string(other.rawValue), "message": .string("Still thinking."), "location": .null]) == ("replied on note \(other.rawValue)", false))
        let mixed = try await call("reply_to_note", ["id": .string(other.rawValue), "message": .string("x"), "location": ["selector": "#a", "line": 1]])
        #expect(mixed.isError && mixed.text.contains("not both"), "\(mixed.text)")

        // A resolved note can't be replied to.
        #expect(try await call("reply_to_note", ["id": .string(retried.rawValue), "message": .string("hi")]).isError)
        // Nor can a draft.
        try await store.unsend(other)
        #expect(try await call("reply_to_note", ["id": .string(other.rawValue), "message": .string("hi")]).isError)
        // The instructions tell agents when to reply, ask, resolve, and pass a location.
        #expect(MCPServer.instructions.contains("reply_to_note") && MCPServer.instructions.contains("location"))
        #expect(MCPServer.toolSchemas.contains { $0.name == "reply_to_note" })
    }

    /// Issue #4: an agent asks the user about lines it wrote, keeps a folder at hand, and reads the favorites back.
    /// The question carries the agent's name from its client, and the session's host as the default.
    @Test func agentsAskAndKeepFavorites() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-ask-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, _) = try await Self.makeStore(count: 1, attachmentDirectory: directory)
        _ = try await store.upsertHost(name: "asus", kind: .ssh)
        let asked = QuestionLog()
        var dependencies = Self.dependencies(store: store)
        dependencies.askUser = { question in
            await asked.record(question)
            return NoteID.new()
        }
        dependencies.addFavorite = { host, path in
            let hostID = host == "local" ? HostID.local : try await store.hosts().first { $0.name == host }!.id
            let root = try await store.recordRootOpened(hostID: hostID, path: path)
            guard !root.pinned else { return false }
            try await store.setRootPinned(root.id, true)
            return true
        }
        func call(_ name: String, _ arguments: [String: Value], agentHost: String = "local", agentName: String = "claude") async throws -> (text: String, isError: Bool) {
            let result = try await MCPServer.callTool(.init(name: name, arguments: arguments), dependencies: dependencies, agentHost: agentHost, agentName: agentName)
            return (result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined(separator: "\n"), result.isError ?? false)
        }
        let ok = try await call("ask_user", ["path": .string("/tmp/demo/README.md"), "question": .string("Does this intro read right?"), "line": .int(2), "end_line": .int(4)])
        #expect(!ok.isError && ok.text.hasPrefix("asked the user"), "\(ok.text)")
        _ = try await call("ask_user", ["path": .string("/home/me/x.md"), "question": .string("Keep this?"), "text": .string("keep me")], agentHost: "asus", agentName: "codex")
        #expect(await asked.questions == [
            AgentQuestion(host: "local", path: "/tmp/demo/README.md", question: "Does this intro read right?", line: 2, endLine: 4, agent: "claude"),
            AgentQuestion(host: "asus", path: "/home/me/x.md", question: "Keep this?", text: "keep me", agent: "codex"),
        ])
        #expect(try await call("ask_user", ["path": .string("/tmp/a.md"), "question": .string("  ")]).isError, "a question is required")
        #expect(try await call("ask_user", ["path": .string("a.md"), "question": .string("q")]).isError, "paths are absolute")
        #expect(try await call("ask_user", ["path": .string("/a.md"), "question": .string("q"), "host": .string("nowhere")]).isError)

        #expect(try await call("add_favorite", ["path": .string("/Users/me/proj")]).text == "added local:/Users/me/proj to the favorites")
        #expect(try await call("add_favorite", ["path": .string("/Users/me/proj")]).text == "local:/Users/me/proj is already a favorite")
        _ = try await call("add_favorite", ["path": .string("/home/me/app")], agentHost: "asus")
        let favorites = try await call("list_favorites", [:]).text
        #expect(favorites.contains("local:/Users/me/proj") && favorites.contains("asus:/home/me/app"), "\(favorites)")

        #expect(MCPServer.agentName(client: "claude-code") == "claude" && MCPServer.agentName(client: "codex-mcp-client") == "codex")
        #expect(MCPServer.agentName(client: nil) == "agent")
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

    /// Without the token a request is refused on its first line, before any of its body is held.
    @Test func aCallerWithoutTheTokenIsRefusedBeforeItsBody() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-early-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, _) = try await Self.makeStore(count: 1, attachmentDirectory: directory)
        let server = MCPServer(dependencies: Self.dependencies(store: store), port: 0, portFileURL: URL(fileURLWithPath: "\(directory)/mcp-port"), token: String(repeating: "ab", count: 32))
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.port)
        // Claims 7 MB and sends a few bytes: refused at once rather than waited on.
        let reply = try await Self.rawExchange(port: port, "POST /plugin/note HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 7000000\r\n\r\nabc")
        #expect(reply.hasPrefix("HTTP/1.1 401"), "\(reply)")
    }

    /// A connection that never finishes its request is closed at the deadline, and the connection cap holds.
    @Test func slowAndExcessConnectionsAreClosed() async throws {
        var limits = HTTPListener.Limits()
        limits.requestTimeout = .milliseconds(300)
        limits.maximumConnections = 2
        let listener = try await HTTPListener.start(port: 0, limits: limits) { _, _ in .data(Data("ok".utf8), headers: [:]) }
        defer { Task { await listener.stop() } }
        let started = ContinuousClock.now
        let slow = try await Self.rawExchange(port: listener.port, "POST /x HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 10\r\n\r\nab")
        #expect(slow.isEmpty, "closed without an answer: \(slow)")
        #expect(ContinuousClock.now - started < .seconds(5))

        let first = try Self.openSocket(port: listener.port)
        let second = try Self.openSocket(port: listener.port)
        defer { close(first); close(second) }
        // The server counts connections on two event loops, not in accept order: give it the first two before the
        // third arrives, or the second may be the one turned away (inside the 300 ms deadline that would close them).
        try await Task.sleep(for: .milliseconds(100))
        let third = try await Self.rawExchange(port: listener.port, "GET /x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(third.isEmpty, "a third connection is closed on accept: \(third)")
    }

    static func openSocket(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    /// Sends `request` raw and reads until the server closes (or 5 s pass); returns what came back.
    static func rawExchange(port: Int, _ request: String) async throws -> String {
        let fd = try openSocket(port: port)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = request.utf8CString.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count - 1, 0) }
        return await Task.detached {
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(fd, &buffer, buffer.count, 0)
                if count <= 0 { break }
                received.append(contentsOf: buffer[0..<count])
            }
            return String(decoding: received, as: UTF8.self)
        }.value
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

        // End to end: the same request with and without an Origin.
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

    /// With a token, every route but /health needs it, by header or query.
    @Test func theServerAnswersOnlyWithItsToken() async throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-mcp-token-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (store, _) = try await Self.makeStore(count: 1, attachmentDirectory: directory)
        let token = String(repeating: "ef", count: 32)
        let server = MCPServer(dependencies: Self.dependencies(store: store), port: 0, portFileURL: URL(fileURLWithPath: "\(directory)/mcp-port"), token: token)
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.port)
        func status(_ path: String, bearer: String? = nil) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        }
        #expect(try await status("/plugin/open") == 401, "someone else on the host, without the token")
        #expect(try await status("/plugin/open", bearer: "wrong") == 401)
        #expect(try await status("/mcp", bearer: token) == 400, "past the token: the route answers (send initialize first)")
        #expect(try await status("/mcp?token=\(token)") == 400, "as the registered MCP URL carries it")
        #expect(try await status("/health") == 200)
        #expect(try String(contentsOfFile: "\(directory)/mcp-port", encoding: .utf8) == "\(port)\n\(token)\n")
    }

    @Test func registrationURLsCarryTheHostAlias() {
        #expect(MCPServer.url(port: 47831) == "http://127.0.0.1:47831/mcp")
        #expect(MCPServer.url(port: 47831, host: "local") == "http://127.0.0.1:47831/mcp")
        #expect(MCPServer.url(port: 47831, host: "my box") == "http://127.0.0.1:47831/mcp?host=my%20box")
        #expect(MCPServer.snippets(port: 47831, host: "asus").claudeCommand == "claude mcp add -s user --transport http gloss 'http://127.0.0.1:47831/mcp?host=asus'")
    }

    /// The copy for any other agent: the endpoint and header apart, and a generic mcpServers entry that authorises
    /// by header rather than query string.
    @Test func genericSnippetsAuthoriseByHeader() {
        let snippets = MCPServer.snippets(port: 47831, token: "abc123")
        #expect(snippets.endpoint == "http://127.0.0.1:47831/mcp")
        #expect(snippets.header == "Authorization: Bearer abc123")
        #expect(snippets.mcpJSON == #"{ "mcpServers": { "gloss": { "type": "http", "url": "http://127.0.0.1:47831/mcp", "headers": { "Authorization": "Bearer abc123" } } } }"#)
        #expect(snippets.claudeCommand.contains("token=abc123"), "the agent commands still carry it in the URL, as installs do")
        let remote = MCPServer.snippets(port: 47831, host: "my box", token: "abc123")
        #expect(remote.endpoint == "http://127.0.0.1:47831/mcp?host=my%20box")
        #expect(MCPServer.snippets(port: 47831).header.isEmpty)
    }

    @Test func servesToolsAndResourcesOverHTTP() async throws {
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
            // initialize: a session id comes back; no Origin header is sent, as curl and agents' clients do.
            let initialize = try await Self.rpc(base, session: nil, body: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])
            let session = try #require(initialize.session)
            #expect(initialize.status == 200)
            #expect(((initialize.reply?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String == "gloss")
            _ = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "method": "notifications/initialized"])

            let tools = try await Self.rpc(base, session: session, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
            let names = ((tools.reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            #expect(Set(names) == ["list_pending_notes", "get_note", "resolve_note", "reply_to_note", "list_documents", "open_in_viewer", "ask_user", "add_favorite", "list_favorites"])

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

private actor QuestionLog {
    private(set) var questions: [AgentQuestion] = []
    func record(_ question: AgentQuestion) { questions.append(question) }
}
