import Foundation
import WebKit

/// Where a main-frame navigation goes. A pure function of the request so every row has a test; the browser
/// applies the decision.
public enum WebNavigationPolicy {
    public enum Decision: Equatable, Sendable {
        case allow
        case cancel
        /// Open this absolute path on the page's host as a document.
        case openFile(String)
        /// The page wants a loopback port on its remote host: tunnel it, then load `then` through the tunnel.
        case tunnel(port: UInt16, then: URL)
        /// Hand the URL to the system (mail, phone).
        case external(URL)
    }

    nonisolated public static let externalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio"]

    /// - page: what the view is showing now.
    /// - proxy: the tunnels of the page's host, when it is remote.
    /// - isLocalHost: the page's host is this Mac, so `file://` links can be opened.
    nonisolated public static func decide(url: URL, type: WKNavigationType, isMainFrame: Bool, page: BrowserPage, proxy: WebProxyMap?, isLocalHost: Bool) -> Decision {
        guard isMainFrame else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case HTMLSchemeHandler.scheme:
            guard url.host()?.lowercased() == HTMLSchemeHandler.host else { return .cancel }
            if case .file(let path) = page {
                return url.path == path ? .allow : .openFile(url.path)
            }
            // A live page cannot address files; the scheme handler refuses such loads too.
            return .cancel
        case "file":
            if case .file = page, isLocalHost { return .openFile(url.path) }
            return .cancel
        case "http", "https":
            guard let proxy else { return .allow }
            if proxy.isProxied(url) { return .allow }
            if let port = WebProxyMap.loopbackPort(of: url) { return .tunnel(port: port, then: url) }
            return .allow
        case "about":
            return .allow
        case _ where externalSchemes.contains(scheme):
            return .external(url)
        default:
            return .cancel
        }
    }
}
