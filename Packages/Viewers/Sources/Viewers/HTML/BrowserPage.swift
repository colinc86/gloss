import Foundation

/// What a web view is showing: an HTML file the app serves from memory, or a live page by its logical URL (the
/// address the user sees, never the forwarded `127.0.0.1:<port>` form).
public enum BrowserPage: Equatable, Hashable, Sendable {
    case file(path: String)
    case live(URL)

    public var isLive: Bool { if case .live = self { true } else { false } }
}

/// The document key for a live page: its URL with the fragment dropped (it never changes the page), the query
/// kept (it usually does), the scheme and host lowercased, a default port dropped, credentials dropped (they
/// never belong in a database or a packet), and an empty path made `/`. The loopback keeps its spelling:
/// `127.0.0.1` and `localhost` are different origins to the page.
public enum WebDocumentKey {
    nonisolated public static func normalize(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        components.fragment = nil
        components.user = nil
        components.password = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if let port = components.port, let scheme = components.scheme, (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? url.absoluteString
    }
}
