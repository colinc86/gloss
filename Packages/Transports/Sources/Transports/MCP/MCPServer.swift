import Core
import Foundation
import MCP
import Synchronization

/// What the app provides: note storage plus packet and hook text built with the app's excerpt logic.
public struct MCPDependencies: Sendable {
    public var noteStore: NoteStore
    public var packet: @Sendable ([NoteID]) async throws -> Packet
    /// `UserPromptSubmit` context for notes under `cwd` on `host`, already fitted to the hook limit. `flavour` is
    /// `claude` or `codex`, so the app can record which hook drained the notes.
    public var hookText: @Sendable (_ flavour: String, _ host: String, _ cwd: String?) async throws -> String
    /// A whole-file draft note from the Herdr plugin on a host where `open` cannot reach the app.
    public var createDraft: @Sendable (_ host: String, _ path: String?, _ cwd: String?, _ text: String) async throws -> NoteID
    /// Opens a file in the viewer, for the plugin's link handler on a host.
    /// Opens a file on a host, scrolled to a 1-based line when one is given.
    public var openDocument: @Sendable (_ host: String, _ path: String, _ line: Int?) async throws -> Void = { _, _, _ in }
    /// A resource URL (a GitHub pull request) as the host and path it opens under; nil when the app has no host for it.
    public var resolveURL: (@Sendable (URL) -> (host: String, path: String)?) = { _ in nil }
    public var appVersion: String

    public init(noteStore: NoteStore, packet: @escaping @Sendable ([NoteID]) async throws -> Packet, hookText: @escaping @Sendable (String, String, String?) async throws -> String, createDraft: @escaping @Sendable (String, String?, String?, String) async throws -> NoteID, appVersion: String) {
        self.noteStore = noteStore
        self.packet = packet
        self.hookText = hookText
        self.createDraft = createDraft
        self.appVersion = appVersion
    }
}

/// Config lines shown in Settings so each agent can be pointed at the server.
public struct MCPConfigSnippets: Sendable, Equatable {
    public var claudeCommand: String
    public var codexCommand: String
    public var opencodeJSON: String
    public var mcpJSON: String
}

/// The app's MCP server over streamable HTTP on the loopback interface, plus the plain endpoints the hook scripts
/// and the Herdr plugin call. One MCP `Server` per session, as the SDK's stateful transport requires.
public actor MCPServer {
    public static let defaultPort = 47831
    public static let serverName = "gloss"

    private let dependencies: MCPDependencies
    private let requestedPort: Int
    private let portFileURL: URL?
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

    public init(dependencies: MCPDependencies, port: Int = MCPServer.defaultPort, portFileURL: URL? = MCPServer.defaultPortFileURL) {
        self.dependencies = dependencies
        self.requestedPort = port
        self.portFileURL = portFileURL
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
    public static func url(port: Int, host: String? = nil) -> String {
        let base = "http://127.0.0.1:\(port)/mcp"
        guard let host, !host.isEmpty, host != "local" else { return base }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "host", value: host)]
        return base + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
    }

    public static func snippets(port: Int, host: String? = nil) -> MCPConfigSnippets {
        let url = url(port: port, host: host)
        let shellURL = url.contains("?") ? "'" + url.replacingOccurrences(of: "'", with: "'\\''") + "'" : url
        return MCPConfigSnippets(
            claudeCommand: "claude mcp add -s user --transport http \(serverName) \(shellURL)",
            codexCommand: "codex mcp add \(serverName) --url \(shellURL)",
            opencodeJSON: "\"mcp\": { \"\(serverName)\": { \"type\": \"remote\", \"url\": \"\(url)\", \"enabled\": true } }",
            mcpJSON: "{ \"mcpServers\": { \"\(serverName)\": { \"type\": \"http\", \"url\": \"\(url)\" } } }"
        )
    }

    // MARK: Lifecycle

    public func start() async throws {
        guard listener == nil else { return }
        let started = try await HTTPListener.start(port: requestedPort) { [weak self] request, query in
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
            try? "\(started.port)\n".write(to: portFileURL, atomically: true, encoding: .utf8)
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
        switch (request.method.uppercased(), request.path ?? "/") {
        case (_, "/mcp"):
            return await handleMCP(request, host: query["host"].flatMap { $0.isEmpty ? nil : $0 } ?? "local")
        case ("GET", "/health"):
            return .data(Data("ok\n".utf8), headers: ["Content-Type": "text/plain"])
        case ("GET", "/hook/claude"):
            return await handleHook(flavour: "claude", query: query)
        case ("GET", "/hook/codex"):
            return await handleHook(flavour: "codex", query: query)
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
                try await dependencies.openDocument(host, path, line)
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
        let server = await makeServer(agentHost: host)
        do {
            try await server.start(transport: transport)
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

    private func handleHook(flavour: String, query: [String: String]) async -> HTTPResponse {
        let host = query["host"].flatMap { $0.isEmpty ? nil : $0 } ?? "local"
        let text = (try? await dependencies.hookText(flavour, host, query["cwd"])) ?? ""
        guard !text.isEmpty else { return .ok(headers: ["Content-Length": "0"]) }
        let payload: [String: Any] = ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": text]]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])) ?? Data()
        return .data(data, headers: ["Content-Type": "application/json"])
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
            description: "Notes the user wants addressed, newest first. Filter by host (\"local\", an ssh alias, or \"github\", \"atlassian\" or \"web\" for notes on pull requests, Jira issues and Confluence pages, and web pages) and/or an absolute path prefix.",
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
            inputSchema: ["type": "object", "properties": ["path": ["type": "string", "description": "absolute path"], "url": ["type": "string", "description": "a pull request, Jira issue, Confluence page or web page URL, instead of path"], "line": ["type": "integer", "minimum": 1], "host": ["type": "string", "description": "\"local\", an ssh alias, \"github\" or \"atlassian\"; defaults to your machine"]], "additionalProperties": false],
            annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "list_documents",
            description: "Documents that currently have notes, with counts per state.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            annotations: .init(readOnlyHint: true)
        ),
    ]

    /// Handlers are registered before the server starts, so the first `tools/list` can never race them.
    private func makeServer(agentHost: String) async -> Server {
        let server = Server(
            name: Self.serverName, version: dependencies.appVersion,
            instructions: "Notes the user attached to files. Call list_pending_notes, act on each, then resolve_note. To point the user at code, call open_in_viewer with a path and line.",
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false))
        )
        let dependencies = dependencies
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: Self.toolSchemas) }
        await server.withMethodHandler(CallTool.self) { params in try await Self.callTool(params, dependencies: dependencies, agentHost: agentHost) }
        await server.withMethodHandler(ListResources.self) { _ in ListResources.Result(resources: try await Self.resources(dependencies: dependencies)) }
        await server.withMethodHandler(ReadResource.self) { params in try await Self.readResource(uri: params.uri, dependencies: dependencies) }
        return server
    }

    nonisolated static func text(_ string: String) -> Tool.Content {
        .text(text: string, annotations: nil, _meta: nil)
    }

    nonisolated static func callTool(_ params: CallTool.Parameters, dependencies: MCPDependencies, agentHost: String = "local") async throws -> CallTool.Result {
        let store = dependencies.noteStore
        let arguments = params.arguments ?? [:]
        switch params.name {
        case "list_pending_notes":
            let hostID = try await hostID(named: arguments["host"]?.stringValue, store: store)
            if let name = arguments["host"]?.stringValue, !name.isEmpty, hostID == nil {
                return CallTool.Result(content: [text("unknown host \(name)")], isError: true)
            }
            let pending = try await store.pendingNotes(hostID: hostID, pathPrefix: arguments["path"]?.stringValue)
            let hosts = Dictionary(uniqueKeysWithValues: try await store.hosts().map { ($0.id, $0.name) })
            let lines = pending.map { entry in
                let preview = entry.note.body.replacingOccurrences(of: "\n", with: " ").prefix(80)
                return "\(entry.note.id.rawValue)\t\(hosts[entry.document.hostID] ?? entry.document.hostID.rawValue):\(entry.document.path)\t\(entry.note.anchor.summary)\t\(entry.note.state.rawValue)\t\(preview)"
            }
            let json: [[String: Any]] = pending.map { entry in
                ["id": entry.note.id.rawValue, "host": hosts[entry.document.hostID] ?? entry.document.hostID.rawValue, "path": entry.document.path, "anchor": entry.note.anchor.summary, "state": entry.note.state.rawValue, "body": entry.note.body]
            }
            let jsonText = String(data: (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? "[]"
            return CallTool.Result(content: [text(lines.isEmpty ? "No pending notes." : lines.joined(separator: "\n")), text(jsonText)])
        case "get_note":
            guard let raw = arguments["id"]?.stringValue, let id = NoteID(validating: raw), let note = try await store.note(id) else {
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
            guard let raw = arguments["id"]?.stringValue, let id = NoteID(validating: raw), let note = try await store.note(id) else {
                return CallTool.Result(content: [text("unknown note id")], isError: true)
            }
            if note.state == .resolved { return CallTool.Result(content: [text("note \(raw) is already resolved")], isError: true) }
            var outcome = ResolveOutcome.done
            if let rawOutcome = arguments["outcome"]?.stringValue {
                guard let parsed = ResolveOutcome(rawValue: rawOutcome) else {
                    return CallTool.Result(content: [text("outcome must be done, skipped, or needs_input")], isError: true)
                }
                outcome = parsed
            }
            try await store.resolve(id, outcome: outcome, message: arguments["message"]?.stringValue)
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
            var line: Int?
            if let raw = arguments["line"] {
                guard let value = raw.intValue ?? raw.doubleValue.flatMap({ $0.isFinite ? Int(exactly: $0.rounded(.down)) : nil }) ?? raw.stringValue.flatMap({ Int($0) }), value > 0 else {
                    return CallTool.Result(content: [text("line must be a positive integer")], isError: true)
                }
                line = value
            }
            try await dependencies.openDocument(host, path, line)
            return CallTool.Result(content: [text("showing \(host):\(path)\(line.map { " at line \($0)" } ?? "")")])
        case "list_documents":
            let documents = try await store.documentsWithNotes()
            let hosts = Dictionary(uniqueKeysWithValues: try await store.hosts().map { ($0.id, $0.name) })
            let lines = documents.map { entry in
                let counts = NoteState.allCases.map { state in "\(state.rawValue)=\(entry.notes.filter { $0.state == state }.count)" }.joined(separator: " ")
                return "\(hosts[entry.document.hostID] ?? entry.document.hostID.rawValue):\(entry.document.path)\t\(counts)"
            }
            return CallTool.Result(content: [text(lines.isEmpty ? "No documents have notes." : lines.joined(separator: "\n"))])
        default:
            throw MCPError.methodNotFound("unknown tool \(params.name)")
        }
    }

    nonisolated static func hostID(named name: String?, store: NoteStore) async throws -> HostID? {
        guard let name, !name.isEmpty else { return nil }
        if name == "local" { return .local }
        return try await store.hosts().first { $0.name == name }?.id
    }

    nonisolated static func resources(dependencies: MCPDependencies) async throws -> [Resource] {
        var resources: [Resource] = []
        for entry in try await dependencies.noteStore.pendingNotes() {
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
