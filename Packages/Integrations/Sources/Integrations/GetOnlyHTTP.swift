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
    /// One representation per URL and Accept header: a pull request's JSON and its diff share a URL.
    private struct CacheKey: Hashable { var url: URL; var accept: String }
    private var cached: [CacheKey: (etag: String, reply: HTTPReply)] = [:]
    /// Least recently used first; the cache keeps at most `cacheLimit` replies.
    private var cacheOrder: [CacheKey] = []
    static let cacheLimit = 200

    private func remember(_ key: CacheKey, _ entry: (etag: String, reply: HTTPReply)) {
        cached[key] = entry
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > Self.cacheLimit { cached[cacheOrder.removeFirst()] = nil }
    }

    /// A query string with every reserved character escaped: `URLQueryItem` leaves `+` alone, which servers read
    /// as a space (JQL `a+b`, GitHub's `q=`).
    nonisolated public static func url(_ base: URL, path: String, query: [String: String]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "+&=#")
            components.percentEncodedQuery = query.sorted { $0.key < $1.key }
                .map { ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.key) + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value) }
                .joined(separator: "&")
        }
        return components.url!
    }

    /// When a spent limit resets: `Retry-After` (seconds or an HTTP date), else `X-RateLimit-Reset` (epoch seconds,
    /// as GitHub sends it, or an ISO 8601 time, as Atlassian does).
    nonisolated static func resetDate(_ headers: [String: String], now: Date = Date()) -> Date? {
        if let retry = headers["retry-after"] {
            if let seconds = Double(retry.trimmingCharacters(in: .whitespaces)) { return now.addingTimeInterval(seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: retry) { return date }
        }
        if let reset = headers["x-ratelimit-reset"] {
            if let epoch = Double(reset) { return Date(timeIntervalSince1970: epoch) }
            if let date = try? Date(reset, strategy: .iso8601) { return date }
        }
        return nil
    }

    public init(session: URLSession = .shared, log: @escaping Logger = { _ in }) {
        self.session = session
        self.log = log
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPReply {
        try await get(url, headers: headers, revalidate: true)
    }

    private func get(_ url: URL, headers: [String: String], revalidate: Bool) async throws -> HTTPReply {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        // The app's own ETag handling is the only cache; URLCache would serve a poll from GitHub's max-age.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let key = CacheKey(url: url, accept: headers["Accept"] ?? "")
        if revalidate, let cached = cached[key] { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
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
        if http.statusCode == 304 {
            if let cached = cached[key] {
                cacheOrder.removeAll { $0 == key }
                cacheOrder.append(key)
                return cached.reply
            }
            // The entry went while the request was out: ask again without a tag.
            if revalidate { return try await get(url, headers: headers, revalidate: false) }
        }
        let reply = HTTPReply(status: http.statusCode, headers: lowered, data: data)
        switch http.statusCode {
        case 200..<300:
            // Raw file bodies are cached by their commit by the caller, and a diff can be megabytes; holding them
            // here too would keep every one of them.
            if let etag = lowered["etag"], !key.accept.contains("raw"), !key.accept.contains("diff") { remember(key, (etag, reply)) }
            return reply
        case 401:
            throw IntegrationError.unauthorized(Self.message(in: data) ?? "")
        case 403, 429:
            // A spent limit, GitHub's secondary limit (a 403 with Retry-After, or a body saying so), or a 429.
            let message = Self.message(in: data) ?? ""
            if lowered["x-ratelimit-remaining"] == "0" || http.statusCode == 429 || lowered["retry-after"] != nil
                || message.localizedCaseInsensitiveContains("rate limit") {
                throw IntegrationError.rateLimited(resetAt: Self.resetDate(lowered))
            }
            throw IntegrationError.unauthorized(message.isEmpty ? "Access denied." : message)
        case 503 where lowered["retry-after"] != nil:
            throw IntegrationError.rateLimited(resetAt: Self.resetDate(lowered))
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
