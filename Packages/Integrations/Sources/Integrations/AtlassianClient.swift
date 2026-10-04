import Foundation

public struct AtlassianUser: Codable, Sendable, Equatable {
    public var accountId: String
    public var displayName: String
    public var emailAddress: String?
}

/// What the Test connection button learns: who the key is, and which of the two products answered.
public struct AtlassianStatus: Sendable, Equatable {
    public var user: AtlassianUser
    public var confluenceReachable: Bool
}

/// Reads Jira issues and Confluence pages from one Atlassian Cloud site with an API token. GET only, like the
/// GitHub client: the app shows the live ticket or page, the agent edits it with its own tools.
public actor AtlassianClient {
    public let site: URL
    private let http: GetOnlyHTTP
    private let authorization: String

    /// - site: `https://example.atlassian.net`
    public init(site: URL, email: String, token: String, session: URLSession = .shared, log: @escaping GetOnlyHTTP.Logger = { _ in }) {
        self.site = site
        authorization = "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
        http = GetOnlyHTTP(session: session, log: log)
    }

    /// `example.atlassian.net`, `https://example.atlassian.net/` or `example` all name the same site.
    nonisolated public static func siteURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else { return nil }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        if !host.contains(".") { components.host = host + ".atlassian.net" }
        return components.url
    }

    private var headers: [String: String] { ["Authorization": authorization, "Accept": "application/json"] }

    private func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: site.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }

    private func decode<T: Decodable>(_ type: T.Type, from reply: HTTPReply) throws -> T {
        do { return try JSONDecoder.integrations.decode(type, from: reply.data) } catch { throw IntegrationError.malformed("\(error)") }
    }

    public func myself() async throws -> AtlassianUser {
        try decode(AtlassianUser.self, from: try await http.get(url("rest/api/3/myself"), headers: headers))
    }

    /// Whether Confluence answers on this site (it may be absent, or the token may lack access).
    public func confluenceReachable() async -> Bool {
        (try? await http.get(url("wiki/api/v2/spaces", query: ["limit": "1"]), headers: headers)) != nil
    }

    public func status() async throws -> AtlassianStatus {
        AtlassianStatus(user: try await myself(), confluenceReachable: await confluenceReachable())
    }
}
