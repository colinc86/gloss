import Core
import Foundation
import Security
import MCP
import Remote
import Synchronization

/// What the app provides: note storage plus packets built with the app's excerpt logic.
public struct MCPDependencies: Sendable {
    public var noteStore: NoteStore
    public var packet: @Sendable ([NoteID]) async throws -> Packet
    /// A whole-file draft note from the Herdr plugin on a host where `open` cannot reach the app.
    public var createDraft: @Sendable (_ host: String, _ path: String?, _ cwd: String?, _ text: String) async throws -> NoteID
    /// Opens a file on a host, scrolled to a 1-based line when one is given and selecting through `endLine` when that
    /// is given too; for `open_in_viewer` and the plugin's link handler on a host.
    public var openDocument: @Sendable (_ host: String, _ path: String, _ line: Int?, _ endLine: Int?) async throws -> Void = { _, _, _, _ in }
    /// Makes a folder a favourite in the explorer and opens it; true when it was not one already (`add_favorite`).
    public var addFavorite: @Sendable (_ host: String, _ path: String) async throws -> Bool = { _, _ in false }
    /// An agent's question to the user about a place in a file (`ask_user`); the new note's id.
    public var askUser: @Sendable (AgentQuestion) async throws -> NoteID = { _ in throw MCPError.internalError("asking is not available") }
    /// A resource URL (a GitHub pull request) as the host and path it opens under; nil when the app has no host for it.
    public var resolveURL: (@Sendable (URL) -> (host: String, path: String)?) = { _ in nil }
    public var appVersion: String

    public init(noteStore: NoteStore, packet: @escaping @Sendable ([NoteID]) async throws -> Packet, createDraft: @escaping @Sendable (String, String?, String?, String) async throws -> NoteID, appVersion: String) {
        self.noteStore = noteStore
        self.packet = packet
        self.createDraft = createDraft
        self.appVersion = appVersion
    }
}

/// What `ask_user` hands the app: where, what, and who asks.
public struct AgentQuestion: Sendable, Equatable {
    public var host: String
    public var path: String
    public var question: String
    /// 1-based lines the question is about; both nil for the whole file.
    public var line: Int?
    public var endLine: Int?
    /// Exact text in the file the question is about, preferred over the lines when found.
    public var text: String?
    /// The asking agent's name as its client reported it ("claude", "codex", "opencode").
    public var agent: String

    public init(host: String, path: String, question: String, line: Int? = nil, endLine: Int? = nil, text: String? = nil, agent: String) {
        self.host = host
        self.path = path
        self.question = question
        self.line = line
        self.endLine = endLine
        self.text = text
        self.agent = agent
    }
}

/// Config lines shown in Settings so each agent can be pointed at the server.
public struct MCPConfigSnippets: Sendable, Equatable {
    public var claudeCommand: String
    public var codexCommand: String
    public var opencodeJSON: String
    /// The generic `mcpServers` entry, authorised by a header so it works in clients that drop query strings.
    public var mcpJSON: String
    /// The endpoint without the token, for clients that take the URL and the header separately.
    public var endpoint: String
    /// `Authorization: Bearer <token>`; empty without a token.
    public var header: String
}

/// The app's MCP server over streamable HTTP on the loopback interface, plus the plain endpoints the Herdr plugin
/// calls. Agents see only notes the user has sent: a draft never leaves the app until the user presses Send. One MCP `Server` per session, as the SDK's stateful transport requires.
public actor MCPServer {
    public static let defaultPort = 47831
    public static let serverName = "gloss"

    private let dependencies: MCPDependencies
    private let requestedPort: Int
    private let portFileURL: URL?
    /// What every caller but /health must present (`Authorization: Bearer`, or `token=` in the query). The port is
    /// reverse-forwarded to remote hosts, where anyone else logged in can reach that host's loopback; the token,
    /// kept in 0600 files, is what tells this user's agents and hooks from theirs. Nil only in tests.
    public nonisolated let token: String?
    private var listener: HTTPListener?
    private var sessions: [String: Session] = [:]
    private var sweeper: Task<Void, Never>?
    /// Sessions idle this long are closed; agents rarely send DELETE, so this is what bounds the table.
    public static let sessionIdleLimit: TimeInterval = 3600

    private struct Session {
        var server: Server
        var transport: StatefulHTTPServerTransport
        var lastUsed: Date
    }

    public init(dependencies: MCPDependencies, port: Int = MCPServer.defaultPort, portFileURL: URL? = MCPServer.defaultPortFileURL, token: String? = nil) {
        self.dependencies = dependencies
        self.requestedPort = port
        self.portFileURL = portFileURL
        self.token = token
    }

    public static var defaultTokenFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gloss/mcp-token")
    }

    /// The server's token, kept across launches (agents store the URL that carries it), made on first use.
    public static func loadOrCreateToken(at url: URL = MCPServer.defaultTokenFileURL) -> String? {
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        return token
    }

    /// What the port file holds: the port, and on the next line the token, for the hook script and the plugin.
    public static func portFileContents(port: Int, token: String?) -> Data {
        Data(("\(port)\n" + (token.map { "\($0)\n" } ?? "")).utf8)
    }

    /// Whether a request carries the token, compared in constant time.
    nonisolated static func authorized(_ request: HTTPRequest, query: [String: String], token: String?) -> Bool {
        guard let token else { return true }
        let header = request.headers.first { $0.key.lowercased() == "authorization" }?.value
        let given = header.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil } ?? query["token"] ?? ""
        guard given.utf8.count == token.utf8.count else { return false }
        return zip(given.utf8, token.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static var defaultPortFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gloss/mcp-port")
    }

    public var port: Int? { listener?.port }

    public var endpointURL: URL? {
        listener.map { URL(string: "http://127.0.0.1:\($0.port)/mcp")! }
    }

    /// The registration URL. A remote host's agents carry `?host=<alias>`, so tools that take a path know which
    /// machine it is on without the agent having to say.
    public static func url(port: Int, host: String? = nil, token: String? = nil) -> String {
        let base = "http://127.0.0.1:\(port)/mcp"
        var items: [URLQueryItem] = []
        if let host, !host.isEmpty, host != "local" { items.append(URLQueryItem(name: "host", value: host)) }
        if let token { items.append(URLQueryItem(name: "token", value: token)) }
        guard !items.isEmpty else { return base }
        var components = URLComponents()
        components.queryItems = items
        return base + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
    }

    public static func snippets(port: Int, host: String? = nil, token: String? = nil) -> MCPConfigSnippets {
        let url = url(port: port, host: host, token: token)
        let endpoint = Self.url(port: port, host: host)
        let shellURL = url.contains("?") ? "'" + url.replacingOccurrences(of: "'", with: "'\\''") + "'" : url
        return MCPConfigSnippets(
            claudeCommand: "claude mcp add -s user --transport http \(serverName) \(shellURL)",
            codexCommand: "codex mcp add \(serverName) --url \(shellURL)",
            opencodeJSON: "\"mcp\": { \"\(serverName)\": { \"type\": \"remote\", \"url\": \"\(url)\", \"enabled\": true } }",
            mcpJSON: genericJSON(endpoint: endpoint, token: token),
            endpoint: endpoint,
            header: token.map { "Authorization: Bearer \($0)" } ?? ""
        )
    }

    private static func genericJSON(endpoint: String, token: String?) -> String {
        let headers = token.map { #", "headers": { "Authorization": "Bearer \#($0)" }"# } ?? ""
        return #"{ "mcpServers": { "\#(serverName)": { "type": "http", "url": "\#(endpoint)"\#(headers) } } }"#
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard listener == nil else { return }
        let token = token
        let authorize: HTTPListener.Authorizer = { request, query in request.path == "/health" || Self.authorized(request, query: query, token: token) }
        let started = try await HTTPListener.start(port: requestedPort, authorize: authorize) { [weak self] request, query in
            guard let self else { return .error(statusCode: 503, MCPError.internalError("server stopped")) }
            return await self.route(request, query: query)
        }
        listener = started
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.sweepIdleSessions()
            }
        }
        if let portFileURL {
            try? FileManager.default.createDirectory(at: portFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 0600 from the start: it holds the token.
            try? FileManager.default.removeItem(at: portFileURL)
            FileManager.default.createFile(atPath: portFileURL.path, contents: Self.portFileContents(port: started.port, token: token), attributes: [.posixPermissions: 0o600])
        }
    }

    private func sweepIdleSessions() async {
        let cutoff = Date().addingTimeInterval(-Self.sessionIdleLimit)
        for (id, session) in sessions where session.lastUsed < cutoff {
            sessions[id] = nil
            await session.server.stop()
            await session.transport.disconnect()
        }
    }

    public func stop() async {
        sweeper?.cancel()
        sweeper = nil
        for session in sessions.values {
            await session.server.stop()
            await session.transport.disconnect()
        }
        sessions = [:]
        await listener?.stop()
        listener = nil
        if let portFileURL { try? FileManager.default.removeItem(at: portFileURL) }
    }

    // MARK: Routing

    private func route(_ request: HTTPRequest, query: [String: String]) async -> HTTPResponse {
        if request.path != "/health", !Self.authorized(request, query: query, token: token) {
            return .error(statusCode: 401, MCPError.invalidRequest("missing or wrong token"))
        }
        switch (request.method.uppercased(), request.path ?? "/") {
        case (_, "/mcp"):
            return await handleMCP(request, host: query["host"].flatMap { $0.isEmpty ? nil : $0 } ?? "local")
        case ("GET", "/health"):
            return .data(Data("ok\n".utf8), headers: ["Content-Type": "text/plain"])
        case ("POST", "/plugin/note"):
            return await handlePluginNote(request.body ?? Data())
        case ("POST", "/plugin/open"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] else {
                return .error(statusCode: 400, MCPError.invalidParams("path is required"))
            }
            var host = object["host"] as? String ?? "local"
            var path = object["path"] as? String ?? ""
            if let raw = object["url"] as? String, let url = URL(string: raw) {
                // A URL the app has no document for is a web page, as open_in_viewer treats it.
                if let resolved = dependencies.resolveURL(url) { (host, path) = resolved } else if DocumentKindDetector.isWebURL(raw) { (host, path) = ("web", raw) }
            }
            guard path.hasPrefix("/") || DocumentKindDetector.isWebURL(path) else {
                return .error(statusCode: 400, MCPError.invalidParams("path is required"))
            }
            do {
                let line = (object["line"] as? Int).flatMap { $0 > 0 ? $0 : nil }
                try await dependencies.openDocument(host, path, line, nil)
                return .ok(headers: ["Content-Length": "0"])
            } catch {
                return .error(statusCode: 500, MCPError.internalError("\(error)"))
            }
        default:
            return .error(statusCode: 404, MCPError.methodNotFound("no route for \(request.path ?? "/")"))
        }
    }

    /// `host` is where the session's agent runs (from the registration URL); it is fixed when the session starts.
    private func handleMCP(_ request: HTTPRequest, host: String) async -> HTTPResponse {
        if let id = request.header("Mcp-Session-Id"), let session = sessions[id] {
            sessions[id]?.lastUsed = Date()
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                sessions[id] = nil
                await session.server.stop()
            }
            return response
        }
        guard request.method.uppercased() == "POST", let body = request.body, Self.isInitialize(body) else {
            // 404 for a session this process no longer knows (an app restart): clients re-initialize on it.
            if request.header("Mcp-Session-Id") != nil { return .error(statusCode: 404, MCPError.invalidRequest("session not found")) }
            return .error(statusCode: 400, MCPError.invalidRequest("send initialize first"))
        }
        let id = UUID().uuidString
        let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedSessionID(id), logger: nil)
        let client = ClientName()
        let server = await makeServer(agentHost: host, client: client)
        do {
            try await server.start(transport: transport) { info, _ in client.set(info.name) }
        } catch {
            return .error(statusCode: 500, MCPError.internalError("\(error)"))
        }
        sessions[id] = Session(server: server, transport: transport, lastUsed: Date())
        let response = await transport.handleRequest(request)
        if case .error = response {
            sessions[id] = nil
            await server.stop()
        }
        return response
    }

    nonisolated static func isInitialize(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["method"] as? String == "initialize"
    }

    private func handlePluginNote(_ body: Data) async -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = object["text"] as? String, !text.isEmpty else {
            return .error(statusCode: 400, MCPError.invalidParams("text is required"))
        }
        let host = object["host"] as? String ?? "local"
        do {
            let id = try await dependencies.createDraft(host, object["path"] as? String, object["cwd"] as? String, text)
            let data = try JSONSerialization.data(withJSONObject: ["note_id": id.rawValue])
            return .data(data, headers: ["Content-Type": "application/json"])
        } catch {
            return .error(statusCode: 500, MCPError.internalError("\(error)"))
        }
    }

    // MARK: MCP surface

    static let toolSchemas: [Tool] = [
        Tool(
            name: "list_pending_notes",
            description: "Notes the user has sent you that are not resolved yet. Filter by host (\"local\", an ssh alias, or \"github\", \"atlassian\" or \"web\" for notes on pull requests, Jira issues and Confluence pages, and web pages) and/or an absolute path prefix.",
            inputSchema: ["type": "object", "properties": ["host": ["type": "string"], "path": ["type": "string", "description": "absolute file path or directory prefix"]], "additionalProperties": false],
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "get_note",
            description: "Full text of one note in context-packet form, with excerpt and attachment resource URIs.",
            inputSchema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"], "additionalProperties": false],
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: PacketBuilder.toolName,
            description: "Mark a note resolved after acting on it.",
            inputSchema: ["type": "object", "properties": ["id": ["type": "string"], "outcome": ["type": "string", "enum": ["done", "skipped", "needs_input"]], "message": ["type": "string"]], "required": ["id"], "additionalProperties": false],
            annotations: .init(idempotentHint: true)
        ),
        Tool(
            name: "open_in_viewer",
            description: "Show a file in Gloss's viewer, scrolled to a line, so the user can look at what you are pointing at. The path is on the machine you run on unless host names another. Give url instead for a GitHub pull request (https://github.com/o/r/pull/12, optionally /files/<path>), a Jira issue (https://<site>/browse/KEY) or Confluence page (https://<site>/wiki/spaces/KEY/pages/<id>) of the user's saved site, or any web page.",
            inputSchema: ["type": "object", "properties": ["path": ["type": "string", "description": "absolute path"], "url": ["type": "string", "description": "a pull request, Jira issue, Confluence page or web page URL, instead of path"], "line": ["type": "integer", "minimum": 1], "end_line": ["type": "integer", "minimum": 1, "description": "selects line through end_line"], "host": ["type": "string", "description": "\"local\", an ssh alias, \"github\" or \"atlassian\"; defaults to your machine"]], "additionalProperties": false],
            annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "ask_user",
            description: "Ask the user something about a place in a file: content you made or changed that they should review, or a decision only they can make. The question appears in Gloss beside that text, under Attention; the user's answer comes back to you as a note when they send it. Give the lines, or the exact text, it is about; neither means the whole file. Don't use it for progress reports.",
            inputSchema: ["type": "object", "properties": [
                "path": ["type": "string", "description": "absolute path on your machine (or on host)"],
                "question": ["type": "string"],
                "line": ["type": "integer", "minimum": 1],
                "end_line": ["type": "integer", "minimum": 1],
                "text": ["type": "string", "description": "exact text in the file the question is about; found nearest line when given"],
                "host": ["type": "string", "description": "\"local\" or an ssh alias; defaults to your machine"],
            ], "required": ["path", "question"], "additionalProperties": false],
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: "add_favorite",
            description: "Keep a project folder at hand: adds it to the favorites in Gloss's explorer (if it isn't one) and opens it.",
            inputSchema: ["type": "object", "properties": ["path": ["type": "string", "description": "absolute folder path"], "host": ["type": "string", "description": "\"local\" or an ssh alias; defaults to your machine"]], "required": ["path"], "additionalProperties": false],
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "list_favorites",
            description: "The folders the user keeps as favorites in Gloss, as host:path.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "list_documents",
            description: "Documents with notes the user has sent you, with counts per state.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            annotations: .init(readOnlyHint: true)
        ),
    ]

    /// Handlers are registered before the server starts, so the first `tools/list` can never race them.
    private func makeServer(agentHost: String, client: ClientName = ClientName()) async -> Server {
        let server = Server(
            name: Self.serverName, version: dependencies.appVersion,
            instructions: "Notes the user sent you about places in files. Call list_pending_notes for the open ones, act on each, then resolve_note. To show the user something, call open_in_viewer with a path and lines. When you made or changed something the user should review or decide on, call ask_user with the file, the lines, and your question: it appears in Gloss beside that text, and the answer comes back to you when the user sends it. add_favorite keeps a project folder at hand in Gloss's explorer.",
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false))
        )
        let dependencies = dependencies
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: Self.toolSchemas) }
        await server.withMethodHandler(CallTool.self) { params in try await Self.callTool(params, dependencies: dependencies, agentHost: agentHost, agentName: client.agentName) }
        await server.withMethodHandler(ListResources.self) { _ in ListResources.Result(resources: try await Self.resources(dependencies: dependencies)) }
        await server.withMethodHandler(ReadResource.self) { params in try await Self.readResource(uri: params.uri, dependencies: dependencies) }
        return server
    }

    nonisolated static func text(_ string: String) -> Tool.Content {
        .text(text: string, annotations: nil, _meta: nil)
    }

    nonisolated static func callTool(_ params: CallTool.Parameters, dependencies: MCPDependencies, agentHost: String = "local", agentName: String = "agent") async throws -> CallTool.Result {
        let store = dependencies.noteStore
        let arguments = params.arguments ?? [:]
        switch params.name {
        case "list_pending_notes":
            let hostID = try await hostID(named: arguments["host"]?.stringValue, store: store)
            if let name = arguments["host"]?.stringValue, !name.isEmpty, hostID == nil {
                return CallTool.Result(content: [text("unknown host \(name)")], isError: true)
            }
            // Sent notes, and sent notes whose text has since gone (often because the agent removed it, as asked).
            let sentOrphans = try await store.sentOrphanIDs()
            let pending = try await store.pendingNotes(hostID: hostID, pathPrefix: arguments["path"]?.stringValue, states: Self.sharedStates.union([.orphaned]))
                .filter { $0.note.state != .orphaned || sentOrphans.contains($0.note.id) }
            func anchor(_ note: Note) -> String {
                note.state == .orphaned ? "\(note.anchor.summary) (text no longer found)" : note.anchor.summary
            }
            let hosts = Dictionary(uniqueKeysWithValues: try await store.hosts().map { ($0.id, $0.name) })
            let lines = pending.map { entry in
                let preview = entry.note.body.replacingOccurrences(of: "\n", with: " ").prefix(80)
                return "\(entry.note.id.rawValue)\t\(hosts[entry.document.hostID] ?? entry.document.hostID.rawValue):\(entry.document.path)\t\(anchor(entry.note))\t\(entry.note.state.rawValue)\t\(preview)"
            }
            let json: [[String: Any]] = pending.map { entry in
                ["id": entry.note.id.rawValue, "host": hosts[entry.document.hostID] ?? entry.document.hostID.rawValue, "path": entry.document.path, "anchor": anchor(entry.note), "state": entry.note.state.rawValue, "body": entry.note.body]
            }
            let jsonText = String(data: (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? "[]"
            return CallTool.Result(content: [text(lines.isEmpty ? "No pending notes." : lines.joined(separator: "\n")), text(jsonText)])
        case "get_note":
            guard let raw = arguments["id"]?.stringValue, let id = NoteID(validating: raw), let note = try await store.note(id), try await store.sharedNoteIDs().contains(id) else {
                return CallTool.Result(content: [text("unknown note id")], isError: true)
            }
            let packet = try await dependencies.packet([id])
            let attachments = try await store.attachments(for: id)
            var body = packet.text
            if !attachments.isEmpty {
                body += "\nAttachments: " + attachments.indices.map { "note://\(note.id.rawValue)/attachment/\($0)" }.joined(separator: " ")
            }
            return CallTool.Result(content: [text(body)])
        case PacketBuilder.toolName:
            guard let raw = arguments["id"]?.stringValue, let id = NoteID(validating: raw), let note = try await store.note(id), try await store.sharedNoteIDs().contains(id) else {
                return CallTool.Result(content: [text("unknown note id")], isError: true)
            }
            switch note.state {
            case .draft: return CallTool.Result(content: [text("note \(raw) is a draft: the user took it back and hasn't sent it again")], isError: true)
            case .resolved: return CallTool.Result(content: [text("note \(raw) is already resolved")], isError: true)
            case .sent, .orphaned: break
            }
            var outcome = ResolveOutcome.done
            if let rawOutcome = arguments["outcome"]?.stringValue {
                guard let parsed = ResolveOutcome(rawValue: rawOutcome) else {
                    return CallTool.Result(content: [text("outcome must be done, skipped, or needs_input")], isError: true)
                }
                outcome = parsed
            }
            do {
                try await store.resolveSent(id, outcome: outcome, message: arguments["message"]?.stringValue, agent: agentName)
            } catch NoteStoreError.illegalTransition(from: .draft, to: _) {
                return CallTool.Result(content: [text("note \(raw) isn't sent: the user took it back and hasn't sent it again")], isError: true)
            } catch {
                return CallTool.Result(content: [text(error.localizedDescription)], isError: true)
            }
            return CallTool.Result(content: [text("resolved \(raw)")])
        case "open_in_viewer":
            var host = arguments["host"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? agentHost
            let path: String
            if let raw = arguments["url"]?.stringValue, !raw.isEmpty {
                guard let url = URL(string: raw) else { return CallTool.Result(content: [text("url is not a URL")], isError: true) }
                if let resolved = dependencies.resolveURL(url) {
                    (host, path) = resolved
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    (host, path) = ("web", raw)
                } else {
                    return CallTool.Result(content: [text("no viewer for \(raw)")], isError: true)
                }
            } else {
                guard let given = arguments["path"]?.stringValue, given.hasPrefix("/") else {
                    return CallTool.Result(content: [text("path must be absolute (or give url)")], isError: true)
                }
                path = given
            }
            if host != "local", try await hostID(named: host, store: store) == nil {
                return CallTool.Result(content: [text("unknown host \(host)")], isError: true)
            }
            let line: Int?, endLine: Int?
            do {
                (line, endLine) = try lines(arguments)
            } catch {
                return CallTool.Result(content: [text("\(error)")], isError: true)
            }
            try await dependencies.openDocument(host, path, line, endLine)
            let at = line.map { start in endLine.map { $0 > start ? " at lines \(start)-\($0)" : " at line \(start)" } ?? " at line \(start)" } ?? ""
            return CallTool.Result(content: [text("showing \(host):\(path)\(at)")])
        case "add_favorite":
            let host = arguments["host"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? agentHost
            guard let path = arguments["path"]?.stringValue, path.hasPrefix("/") else {
                return CallTool.Result(content: [text("path must be an absolute folder path")], isError: true)
            }
            if host != "local", try await hostID(named: host, store: store) == nil {
                return CallTool.Result(content: [text("unknown host \(host)")], isError: true)
            }
            let added = try await dependencies.addFavorite(host, path)
            return CallTool.Result(content: [text(added ? "added \(host):\(path) to the favorites" : "\(host):\(path) is already a favorite")])
        case "list_favorites":
            var lines: [String] = []
            for host in try await store.hosts() {
                for root in try await store.roots(for: host.id) where root.pinned { lines.append("\(host.name):\(root.path)") }
            }
            return CallTool.Result(content: [text(lines.isEmpty ? "No favorites." : lines.joined(separator: "\n"))])
        case "ask_user":
            let host = arguments["host"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? agentHost
            guard let path = arguments["path"]?.stringValue, path.hasPrefix("/") else {
                return CallTool.Result(content: [text("path must be absolute")], isError: true)
            }
            guard let question = arguments["question"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
                return CallTool.Result(content: [text("question is required")], isError: true)
            }
            if host != "local", try await hostID(named: host, store: store) == nil {
                return CallTool.Result(content: [text("unknown host \(host)")], isError: true)
            }
            let line: Int?, endLine: Int?
            do {
                (line, endLine) = try lines(arguments)
            } catch {
                return CallTool.Result(content: [text("\(error)")], isError: true)
            }
            let quoted = arguments["text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            do {
                let id = try await dependencies.askUser(AgentQuestion(host: host, path: path, question: question, line: line, endLine: endLine, text: quoted, agent: agentName))
                return CallTool.Result(content: [text("asked the user (note \(id.rawValue)); the answer comes back when they send it")])
            } catch NoteStoreError.tooManyQuestions(let limit) {
                return CallTool.Result(content: [text("that file already has \(limit) open questions; wait for answers")], isError: true)
            }
        case "list_documents":
            // Notes never sent are the user's own: only notes an agent was given count, and a document with none of
            // them is not listed.
            let shared = try await store.sharedNoteIDs()
            let sentOrphans = try await store.sentOrphanIDs()
            // An orphan counts only if it was sent when its text went, as list_pending_notes and resolve_note see it.
            let documents = try await store.documentsWithNotes()
                .map { (document: $0.document, notes: $0.notes.filter { shared.contains($0.id) && ($0.state != .orphaned || sentOrphans.contains($0.id)) }) }
                .filter { !$0.notes.isEmpty }
            let hosts = Dictionary(uniqueKeysWithValues: try await store.hosts().map { ($0.id, $0.name) })
            let lines = documents.map { entry in
                let counts = NoteState.allCases.filter { $0 != .draft }.map { state in "\(state.rawValue)=\(entry.notes.filter { $0.state == state }.count)" }.joined(separator: " ")
                return "\(hosts[entry.document.hostID] ?? entry.document.hostID.rawValue):\(entry.document.path)\t\(counts)"
            }
            return CallTool.Result(content: [text(lines.isEmpty ? "No documents have notes." : lines.joined(separator: "\n"))])
        default:
            throw MCPError.methodNotFound("unknown tool \(params.name)")
        }
    }

    /// The open notes an agent may see: sent ones. Drafts stay in the app until the user sends them.
    nonisolated static let sharedStates: Set<NoteState> = [.sent]

    /// `line` and `end_line` as 1-based integers (end at or after line); both optional.
    nonisolated static func lines(_ arguments: [String: Value]) throws -> (Int?, Int?) {
        struct Refusal: Error, CustomStringConvertible { var description: String }
        func positive(_ key: String) throws -> Int? {
            guard let raw = arguments[key] else { return nil }
            guard let value = raw.intValue ?? raw.doubleValue.flatMap({ $0.isFinite ? Int(exactly: $0.rounded(.down)) : nil }) ?? raw.stringValue.flatMap({ Int($0) }), value > 0 else {
                throw Refusal(description: "\(key) must be a positive integer")
            }
            return value
        }
        let line = try positive("line"), end = try positive("end_line")
        if end != nil, line == nil { throw Refusal(description: "end_line needs line") }
        if let line, let end, end < line { throw Refusal(description: "end_line must not be before line") }
        return (line, end)
    }

    /// The asking agent's name from its MCP client name: "claude-code" is claude, and so on.
    nonisolated static func agentName(client: String?) -> String {
        let name = client?.lowercased() ?? ""
        if name.contains("claude") { return "claude" }
        if name.contains("codex") { return "codex" }
        if name.contains("opencode") { return "opencode" }
        return name.isEmpty ? "agent" : name
    }

    nonisolated static func hostID(named name: String?, store: NoteStore) async throws -> HostID? {
        guard let name, !name.isEmpty else { return nil }
        if name == "local" { return .local }
        return try await store.hosts().first { $0.name == name }?.id
    }

    nonisolated static func resources(dependencies: MCPDependencies) async throws -> [Resource] {
        var resources: [Resource] = []
        for entry in try await dependencies.noteStore.pendingNotes(states: sharedStates) {
            let attachments = try await dependencies.noteStore.attachments(for: entry.note.id)
            for (index, attachment) in attachments.enumerated() {
                resources.append(Resource(
                    name: "\(PathUtilities.name(of: entry.document.path)) region \(index)",
                    uri: "note://\(entry.note.id.rawValue)/attachment/\(index)",
                    description: entry.note.body.prefix(80).description,
                    mimeType: "image/png",
                    size: (try? FileManager.default.attributesOfItem(atPath: attachment.localPath)[.size] as? Int)
                ))
            }
        }
        return resources
    }

    nonisolated static func readResource(uri: String, dependencies: MCPDependencies) async throws -> ReadResource.Result {
        // note://<id>/attachment/<n>
        guard let url = URL(string: uri), url.scheme == "note", let raw = url.host, let id = NoteID(validating: raw) else {
            throw MCPError.invalidParams("unknown resource \(uri)")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "attachment", let index = Int(parts[1]) else { throw MCPError.invalidParams("unknown resource \(uri)") }
        let attachments = try await dependencies.noteStore.attachments(for: id)
        guard attachments.indices.contains(index), let data = FileManager.default.contents(atPath: attachments[index].localPath) else {
            throw MCPError.invalidParams("attachment \(index) of \(raw) is not available")
        }
        return ReadResource.Result(contents: [.binary(data, uri: uri, mimeType: "image/png")])
    }
}

private struct FixedSessionID: SessionIDGenerator {
    let id: String
    init(_ id: String) { self.id = id }
    func generateSessionID() -> String { id }
}

/// The MCP client's name for one session, captured when it initializes.
final class ClientName: Sendable {
    private let name = Mutex<String?>(nil)

    func set(_ value: String) { name.withLock { $0 = value } }
    var agentName: String { MCPServer.agentName(client: name.withLock { $0 }) }
}
