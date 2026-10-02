import Core
import Foundation

/// One OpenCode HTTP server from Settings: `http://127.0.0.1:4096` or `http://user:pass@host:port` for basic auth.
public struct OpenCodeServer: Sendable, Hashable {
    public var baseURL: URL
    public var username: String?
    public var password: String?

    public init(baseURL: URL, username: String? = nil, password: String? = nil) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    /// Parses the comma-separated Settings value; credentials in the URL become basic auth.
    public static func parse(_ list: String) -> [OpenCodeServer] {
        list.split(separator: ",").compactMap { item in
            var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if !text.contains("://") { text = "http://" + text }
            guard var components = URLComponents(string: text) else { return nil }
            let user = components.user
            let password = components.password
            components.user = nil
            components.password = nil
            // Keep a path prefix (a reverse proxy mount), minus the trailing slash so appending works.
            while components.path.hasSuffix("/") { components.path.removeLast() }
            guard let url = components.url else { return nil }
            let effectiveUser = user ?? (password != nil ? "opencode" : nil)
            return OpenCodeServer(baseURL: url, username: effectiveUser, password: password)
        }
    }

    var authorizationHeader: String? {
        guard let password else { return nil }
        let token = Data("\(username ?? "opencode"):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

/// What the target carries: the server and the session, or an empty session id for "new session".
public struct OpenCodeIdentity: Codable, Sendable, Hashable {
    public var baseURL: String
    public var sessionID: String

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url", sessionID = "session_id"
    }
}

/// Delivers packets to OpenCode's HTTP server: `POST /session/<id>/prompt_async` with a text part and one file
/// part per attachment, which returns at once.
public actor OpenCodeTransport: Transport {
    public nonisolated let kind = TransportKind.opencode

    private let servers: @Sendable () async -> [OpenCodeServer]
    private let session: URLSession
    public static let discoveryTimeout: TimeInterval = 2

    public init(servers: @escaping @Sendable () async -> [OpenCodeServer], session: URLSession = .shared) {
        self.servers = servers
        self.session = session
    }

    // MARK: Transport

    public func discoverTargets() async throws -> [AgentTarget] {
        var targets: [AgentTarget] = []
        for server in await servers() {
            guard let sessions = try? await listSessions(on: server) else { continue }
            let host = server.baseURL.host ?? "opencode"
            for item in sessions {
                let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "untitled"
                let directory = item["directory"] as? String
                guard let id = item["id"] as? String else { continue }
                targets.append(Self.target(server: server, sessionID: id, label: "\(title) · \(host)", detail: directory))
            }
            targets.append(Self.target(server: server, sessionID: "", label: "New session · \(host)", detail: server.baseURL.absoluteString))
        }
        return targets
    }

    public func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt {
        guard let identity = Self.identity(from: target), let baseURL = URL(string: identity.baseURL) else { throw DeliveryError.targetUnavailable("not an OpenCode session") }
        let server = await servers().first { $0.baseURL == baseURL } ?? OpenCodeServer(baseURL: baseURL)
        var sessionID = identity.sessionID
        if sessionID.isEmpty {
            sessionID = try await createSession(on: server, title: "Gloss notes")
        }
        var request = makeRequest(server, path: "/session/\(sessionID)/prompt_async", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.promptBody(packet: packet, attachments: attachments))
        let (data, response) = try await send(request)
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 404 { throw DeliveryError.targetUnavailable("session \(sessionID) not found") }
            throw DeliveryError.failed("OpenCode answered \(response.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        // 204 means accepted, not stored: a part OpenCode cannot decode makes it drop the whole prompt silently.
        guard await promptWasRecorded(packet.text, sessionID: sessionID, on: server) else {
            throw DeliveryError.failed("OpenCode accepted the prompt but did not record it (an attachment it could not decode?)")
        }
        return DeliveryReceipt(detail: identity.sessionID.isEmpty ? "new session \(sessionID)" : "session \(sessionID)")
    }

    /// `GET /session/<id>/message`: the newest user message must carry our text. Polled briefly, since the write
    /// happens after the 204.
    func promptWasRecorded(_ text: String, sessionID: String, on server: OpenCodeServer) async -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            guard let (data, response) = try? await send(makeRequest(server, path: "/session/\(sessionID)/message", method: "GET")), response.statusCode == 200,
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let recorded = messages.contains { message in
                guard (message["info"] as? [String: Any])?["role"] as? String == "user" else { return false }
                return (message["parts"] as? [[String: Any]])?.contains { $0["type"] as? String == "text" && $0["text"] as? String == text } == true
            }
            if recorded { return true }
        }
        return false
    }

    // MARK: Requests

    nonisolated static func promptBody(packet: Packet, attachments: [StagedAttachment]) -> [String: Any] {
        var parts: [[String: Any]] = [["type": "text", "text": packet.text]]
        for attachment in attachments {
            parts.append([
                "type": "file", "mime": "image/png",
                "url": URL(fileURLWithPath: attachment.agentPath).absoluteString,
                "filename": PathUtilities.name(of: attachment.agentPath),
            ])
        }
        return ["parts": parts]
    }

    func listSessions(on server: OpenCodeServer) async throws -> [[String: Any]] {
        let (data, response) = try await send(makeRequest(server, path: "/session", method: "GET", timeout: Self.discoveryTimeout))
        guard response.statusCode == 200 else { throw DeliveryError.targetUnavailable("GET /session: \(response.statusCode)") }
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }

    func createSession(on server: OpenCodeServer, title: String) async throws -> String {
        var request = makeRequest(server, path: "/session", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title])
        let (data, response) = try await send(request)
        guard (200...299).contains(response.statusCode), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? String else {
            throw DeliveryError.failed("could not create an OpenCode session (\(response.statusCode))")
        }
        return id
    }

    private func makeRequest(_ server: OpenCodeServer, path: String, method: String, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: server.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = server.authorizationHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DeliveryError.failed("not an HTTP response") }
            return (data, http)
        } catch let error as DeliveryError {
            throw error
        } catch {
            throw DeliveryError.targetUnavailable("\(request.url?.host ?? "server"): \(error.localizedDescription)")
        }
    }

    nonisolated static func target(server: OpenCodeServer, sessionID: String, label: String, detail: String?) -> AgentTarget {
        let identity = OpenCodeIdentity(baseURL: server.baseURL.absoluteString, sessionID: sessionID)
        let json = (try? JSONEncoder().encode(identity)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return AgentTarget(transport: .opencode, hostID: .local, label: label, detail: detail, identityJSON: json)
    }

    nonisolated static func identity(from target: AgentTarget) -> OpenCodeIdentity? {
        guard let data = target.identityJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OpenCodeIdentity.self, from: data)
    }
}
