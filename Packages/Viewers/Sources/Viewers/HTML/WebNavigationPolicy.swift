import Foundation
import WebKit

/// Where a main-frame navigation goes. A pure function of the request so every row has a test; the browser
/// applies the decision.
public enum WebNavigationPolicy {
    public enum Decision: Equatable, Sendable {
        case allow
        case cancel
        /// Open this absolute path, on the host the URL names, as a document.
        case openFile(String)
        /// The page wants a loopback port on its remote host: tunnel it, then load `then` through the tunnel.
        case tunnel(port: UInt16, then: URL)
        /// Hand the URL to the system (mail, phone).
        case external(URL)
        /// Not followed, and the toolbar says why.
        case refuse(String)
    }

    nonisolated public static let externalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio"]

    /// Navigations the user asked for: a click, a form, Back or Forward. Only these may open a document or a
    /// tunnel; a script or a redirect never moves the viewer to another file or opens a port on a host.
    nonisolated static func isUserInitiated(_ type: WKNavigationType) -> Bool {
        type == .linkActivated || type == .formSubmitted || type == .backForward
    }

    /// - page: what the view is showing now.
    /// - fileHost: the scheme host of the served file the view shows (its host's key), nil for a live page.
    /// - proxy: the tunnels of the page's host, when it is remote.
    /// - isLocalHost: the page's host is this Mac, so `file://` links can be opened.
    nonisolated public static func decide(url: URL, type: WKNavigationType, isMainFrame: Bool, page: BrowserPage, fileHost: String?, proxy: WebProxyMap?, isLocalHost: Bool) -> Decision {
        guard isMainFrame else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case HTMLSchemeHandler.scheme:
            guard let host = url.host()?.lowercased(), !host.isEmpty else { return .cancel }
            if case .file(let path) = page, host == fileHost, url.path == path { return .allow }
            // Back or Forward to a served file: that file's document takes over again, on the host its URL names.
            if type == .backForward { return .openFile(url.path) }
            // A link on a served file opens the file it names, on the same host only; a live page cannot address
            // files at all, and neither can a script.
            if case .file = page, host == fileHost, type == .linkActivated || type == .formSubmitted { return .openFile(url.path) }
            return .cancel
        case "file":
            if case .file = page, isLocalHost, type == .linkActivated { return .openFile(url.path) }
            return .cancel
        case "http", "https":
            guard let proxy else { return .allow }
            if proxy.isProxied(url) { return .allow }
            if let port = WebProxyMap.loopbackPort(of: url) {
                // A port already tunnelled is the page's own server (a redirect to its login, a hard-coded base URL).
                if isUserInitiated(type) || proxy.tunnels[port] != nil { return .tunnel(port: port, then: url) }
                return .refuse("This page tried to open port \(port) on its host; follow a link to it instead")
            }
            return .allow
        case "about":
            return .allow
        case _ where externalSchemes.contains(scheme):
            return type == .linkActivated ? .external(url) : .cancel
        case "blob", "data":
            // What a page builds in memory to hand over as a file: a download, which this browser does not do.
            return .refuse("Downloads aren't available here")
        default:
            return .cancel
        }
    }
}
