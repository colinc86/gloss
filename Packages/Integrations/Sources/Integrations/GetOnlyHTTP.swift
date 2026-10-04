import Foundation

/// What an integration request can fail with, in words a settings pane can show.
public enum IntegrationError: Error, Equatable, Sendable {
    /// The key was refused (401) or lacks access (403).
    case unauthorized(String)
    case notFound(String)
    /// The API's rate limit is spent until `resetAt`.
    case rateLimited(resetAt: Date?)
    case http(status: Int, message: String)
    case transport(String)
    case malformed(String)

    public var message: String {
        switch self {
        case .unauthorized(let detail): detail.isEmpty ? "The key was refused." : detail
        case .notFound(let what): "Not found: \(what)"
        case .rateLimited(let resetAt):
            resetAt.map { "Rate limited until \($0.formatted(date: .omitted, time: .shortened))." } ?? "Rate limited."
        case .http(let status, let message): message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        case .transport(let detail): detail
        case .malformed(let detail): "Unexpected response: \(detail)"
        }
    }
}

/// A response the client got, headers lowercased.
public struct HTTPReply: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// The one way the integrations talk to the network: GET, and nothing else. The app reads with the user's keys;
/// every change is the agent's to make, so there is no method parameter to get wrong. Responses with an ETag are
/// kept so a repeat read costs a 304, which GitHub does not count against the rate limit.
public actor GetOnlyHTTP {
    public typealias Logger = @Sendable (String) -> Void

    private let session: URLSession
    private let log: Logger
    private var cached: [URL: (etag: String, reply: HTTPReply)] = [:]

    public init(session: URLSession = .shared, log: @escaping Logger = { _ in }) {
        self.session = session
        self.log = log
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPReply {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let cached = cached[url] { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log("GET \(url.absoluteString) failed: \(error.localizedDescription)")
            throw IntegrationError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw IntegrationError.transport("not an HTTP response") }
        let lowered = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let name = key as? String else { return nil }
            return (name.lowercased(), "\(value)")
        })
        log("GET \(url.absoluteString) → \(http.statusCode)")
        if http.statusCode == 304, let cached = cached[url] { return cached.reply }
        let reply = HTTPReply(status: http.statusCode, headers: lowered, data: data)
        switch http.statusCode {
        case 200..<300:
            if let etag = lowered["etag"] { cached[url] = (etag, reply) }
            return reply
        case 401:
            throw IntegrationError.unauthorized(Self.message(in: data) ?? "")
        case 403, 429:
            if lowered["x-ratelimit-remaining"] == "0" || http.statusCode == 429 {
                let reset = lowered["x-ratelimit-reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
                throw IntegrationError.rateLimited(resetAt: reset)
            }
            throw IntegrationError.unauthorized(Self.message(in: data) ?? "Access denied.")
        case 404:
            throw IntegrationError.notFound(url.path)
        default:
            throw IntegrationError.http(status: http.statusCode, message: Self.message(in: data) ?? "")
        }
    }

    /// The `message` GitHub and Atlassian put in error bodies, when there is one.
    nonisolated static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String { return message }
        if let messages = object["errorMessages"] as? [String], let first = messages.first { return first }
        return nil
    }
}

extension JSONDecoder {
    /// GitHub and Atlassian dates are ISO 8601, Atlassian's with fractional seconds and a numeric offset.
    nonisolated static var integrations: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            // Atlassian: 2026-10-03T12:34:56.789+0100
            let atlassian = DateFormatter()
            atlassian.locale = Locale(identifier: "en_US_POSIX")
            atlassian.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            if let date = atlassian.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "unreadable date \(string)")
        }
        return decoder
    }
}
