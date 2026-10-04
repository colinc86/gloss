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
        // Tracking parameters name the same page; leaving them in would split its notes across documents.
        if let items = components.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !(name.hasPrefix("utm_") || ["fbclid", "gclid", "msclkid", "_rsc"].contains(name))
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.string ?? url.absoluteString
    }
}

/// What a typed address means: a URL as written, or a bare `host[:port][/path]` with a scheme filled in. Plain
/// http for this machine's loopback, an IP address or an explicit port (a dev server or a box on the LAN rarely
/// has a certificate); https for everything else.
public enum WebAddress {
    nonisolated public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil {
            return url
        }
        guard !trimmed.contains("://") else { return nil }
        let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let bracketed = hostPart.hasPrefix("[")
        let host = bracketed ? String(hostPart.prefix { $0 != "]" }.dropFirst()) : (hostPart.split(separator: ":").first.map(String.init) ?? hostPart)
        let hasPort = bracketed ? hostPart.contains("]:") : hostPart.contains(":")
        let isIP = bracketed || (host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { UInt8($0) != nil })
        let plain = WebProxyMap.isLoopback(host: host) || isIP || hasPort
        guard let url = URL(string: (plain ? "http://" : "https://") + trimmed), url.host() != nil else { return nil }
        return url
    }
}
