import Foundation

/// Fetches the web pictures rendered Markdown links to (badges, screenshots), as GitHub shows them. A plain GET with
/// no cookies or stored credentials, redirected only to http(s), within the size local pictures are held to. What
/// arrives is kept in memory for every document; what fails is not asked for again for a while.
public nonisolated final class WebImageLoader: Sendable {
    public static let shared = WebImageLoader()

    static let timeout: TimeInterval = 15
    /// The same bound local pictures have.
    static let maximumSize = 25 * 1024 * 1024
    /// Fetched pictures kept in memory; past this the cache starts over.
    private let cacheLimit: Int
    /// How long a failed picture is left alone before it is asked for again.
    static let failureLifetime: Duration = .seconds(300)

    private let session: URLSession
    private let state = Mutex()

    /// `protocolClasses` stand in for the network in tests.
    public init(protocolClasses: [AnyClass]? = nil, cacheLimit: Int = 128 * 1024 * 1024) {
        self.cacheLimit = cacheLimit
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept": "image/*"]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "Gloss/\(version) (Macintosh; Markdown pictures)"
    }()

    /// Whether `source` names a web picture this loader fetches.
    public static func handles(_ source: String) -> Bool {
        guard let scheme = URL(string: source)?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// The picture's bytes, or nil when it can't be had (gone, too large, not answering, failed recently).
    public func data(for source: String) async -> Data? {
        guard Self.handles(source), let url = URL(string: source) else { return nil }
        let task: Task<Data?, Never> = state.withLock { state in
            if let data = state.cache[url] { return Task { data } }
            if let failed = state.failures[url], ContinuousClock.now - failed < Self.failureLifetime { return Task { nil } }
            if let running = state.running[url] { return running }
            let session = session
            // Only the task that fetched records the result; whoever else waited on it just reads it.
            let task = Task { [self] in
                let data = await Self.fetch(url, session: session)
                record(data, for: url)
                return data
            }
            state.running[url] = task
            return task
        }
        return await task.value
    }

    private func record(_ data: Data?, for url: URL) {
        state.withLock { state in
            state.running[url] = nil
            guard let data else {
                state.failures[url] = .now
                return
            }
            state.failures[url] = nil
            guard state.cache[url] == nil else { return }
            if state.cachedBytes + data.count > cacheLimit {
                state.cache.removeAll()
                state.cachedBytes = 0
            }
            state.cache[url] = data
            state.cachedBytes += data.count
        }
    }

    private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        let limit = maximumSize
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  response.expectedContentLength <= Int64(limit) else { return nil }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    // MARK: State

    private nonisolated struct State {
        var cache: [URL: Data] = [:]
        var failures: [URL: ContinuousClock.Instant] = [:]
        var running: [URL: Task<Data?, Never>] = [:]
        var cachedBytes = 0
    }

    /// The loader's state behind a lock: it is reached from whichever task asks.
    private nonisolated final class Mutex: @unchecked Sendable {
        private let lock = NSLock()
        private var state = State()

        func withLock<T>(_ body: (inout State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&state)
        }
    }

    /// Follows a redirect only to another web address, never to a file or a custom scheme.
    private nonisolated final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, WebImageLoader.handles(url.absoluteString) else { return nil }
            return request
        }
    }
}
