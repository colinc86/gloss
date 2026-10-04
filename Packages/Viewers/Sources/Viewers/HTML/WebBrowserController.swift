import AppKit
import Core
import Observation
import WebKit

/// The one web view the app shows pages in, kept alive across documents so Back and Forward cross from a file to
/// a site and back, and a single-page app can change its route without reloading. Each page's own state lives
/// in an `HTMLViewerController`; `attach` makes one current. The app supplies what happens when a page wants to
/// open a file, becomes another document, or needs a tunnel to a remote host's loopback.
@Observable
public final class WebBrowserController {
    public let webView: WKWebView
    public private(set) var current: HTMLViewerController?
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    /// The logical address of what the view shows: nil for a file page.
    public private(set) var displayedURL: URL?
    /// Why the last navigation was refused, for the toolbar; cleared by the next successful load.
    public private(set) var refusal: String?

    /// A main-frame load committed to a live page with this logical URL (a link, Back, or a route change).
    @ObservationIgnored public var onDocumentChange: @MainActor (URL) -> Void = { _ in }
    /// A link to a file on the current page's host.
    @ObservationIgnored public var onOpenFile: @MainActor (String) -> Void = { _ in }
    /// The page wants `port` on `host`'s loopback; return the local port that reaches it.
    @ObservationIgnored public var onNeedsTunnel: @MainActor (HostID, UInt16) async throws -> UInt16 = { _, _ in throw CancellationError() }
    @ObservationIgnored public var onExternal: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    @ObservationIgnored private let delegate: Delegate
    @ObservationIgnored private let schemeHandler: HTMLSchemeHandler
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var highlightToken: UUID?
    @ObservationIgnored private var loadedVersion = -1
    @ObservationIgnored private var appliedScrollVersion = 0
    @ObservationIgnored private var appliedCollapseVersion = 0
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var savedScrollY: Double?

    public init() {
        let configuration = WKWebViewConfiguration()
        let delegate = Delegate()
        let schemeHandler = HTMLSchemeHandler()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: HTMLSchemeHandler.scheme)
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: WebBridge.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        content.add(delegate, contentWorld: .defaultClient, name: WebBridge.handlerName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        self.delegate = delegate
        self.schemeHandler = schemeHandler
        delegate.browser = self
        schemeHandler.browser = self
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.current?.pageTitle = title?.isEmpty == false ? title : nil
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progressChanged(webView.estimatedProgress, loading: webView.isLoading) }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
        ]
    }

    // MARK: Pages

    /// Makes `controller` the page the view shows. `load` false adopts what the view already shows (the document
    /// changed under a navigation the view made itself); true loads the page.
    public func attach(_ controller: HTMLViewerController, load: Bool) {
        if current === controller {
            if load { self.load(controller) }
            return
        }
        detachCurrent()
        current = controller
        highlightToken = controller.source.addHighlightObserver { [weak self] in self?.applyHighlights() }
        if load {
            self.load(controller)
        } else {
            loadedVersion = controller.renderedVersion
            isLoaded = true
            controller.pageRect = topRect()
            applyHighlights()
        }
    }

    private func detachCurrent() {
        guard let current else { return }
        if let highlightToken { current.source.removeHighlightObserver(highlightToken) }
        highlightToken = nil
        schemeHandler.cancelAll()
        current.loadProgress = nil
        // The next page starts without a selection; a stale one would show an Add Note button for nothing.
        current.selection = nil
        current.alignment = nil
    }

    private func load(_ controller: HTMLViewerController) {
        loadedVersion = controller.renderedVersion
        isLoaded = false
        refusal = nil
        switch controller.page {
        case .file(let path):
            var components = URLComponents()
            components.scheme = HTMLSchemeHandler.scheme
            components.host = HTMLSchemeHandler.host
            components.path = path
            guard let url = components.url else { return }
            displayedURL = nil
            webView.load(URLRequest(url: url))
        case .live(let url):
            displayedURL = url
            webView.load(URLRequest(url: controller.proxy?.proxied(url) ?? url))
        }
    }

    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }

    public func reload() {
        guard let current else { return }
        switch current.page {
        case .file: current.rebuildNow()
        case .live: webView.reload()
        }
    }

    /// Loads a URL typed in the address field, through the current page's tunnels when it needs one.
    public func open(_ url: URL) {
        refusal = nil
        if let proxy = current?.proxy, let port = WebProxyMap.loopbackPort(of: url), !proxy.isProxied(url) {
            tunnel(port: port, then: url, proxy: proxy)
            return
        }
        webView.load(URLRequest(url: url))
    }

    /// Called by the representable on every SwiftUI update: reloads a file page whose text changed, and applies
    /// scroll and collapse requests once the page has loaded.
    func sync() {
        guard let current else { return }
        _ = current.source.highlightsVersion
        if loadedVersion != current.renderedVersion {
            // Keep the reader's place across the reload that shows an edit.
            loadedVersion = current.renderedVersion
            webView.callAsyncJavaScript("return window.scrollY", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, let current = self.current else { return }
                    if case .success(let value) = result { self.savedScrollY = value as? Double }
                    self.load(current)
                }
            }
            return
        }
        guard isLoaded else { return }
        applyPendingScroll()
        if appliedCollapseVersion != current.collapseVersion {
            appliedCollapseVersion = current.collapseVersion
            run("window.__cc && window.__cc.collapse()")
        }
    }

    // MARK: Navigation

    fileprivate func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url, let current else { return .cancel }
        let decision = WebNavigationPolicy.decide(
            url: url, type: action.navigationType, isMainFrame: action.targetFrame?.isMainFrame ?? true,
            page: current.page, proxy: current.proxy, isLocalHost: current.isLocal
        )
        switch decision {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .openFile(let path):
            onOpenFile(path)
            return .cancel
        case .tunnel(let port, let then):
            if let proxy = current.proxy { tunnel(port: port, then: then, proxy: proxy) }
            return .cancel
        case .external(let url):
            onExternal(url)
            return .cancel
        }
    }

    private func tunnel(port: UInt16, then url: URL, proxy: WebProxyMap) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let local = try await onNeedsTunnel(proxy.hostID, port)
                guard let current, current.proxy?.hostID == proxy.hostID else { return }
                var updated = current.proxy ?? proxy
                updated.tunnels[port] = local
                current.proxy = updated
                if let proxied = updated.proxied(url) { webView.load(URLRequest(url: proxied)) }
            } catch {
                refusal = "Couldn't reach port \(port) on the host: \(error.localizedDescription)"
            }
        }
    }

    fileprivate func committed(_ url: URL?) {
        guard let url, let current else { return }
        if url.scheme?.lowercased() == HTMLSchemeHandler.scheme {
            displayedURL = nil
            return
        }
        let logical = current.proxy?.logical(url) ?? url
        displayedURL = logical
        refusal = nil
        if case .live(let shown) = current.page, WebDocumentKey.normalize(shown) == WebDocumentKey.normalize(logical) { return }
        onDocumentChange(logical)
    }

    fileprivate func finished() {
        isLoaded = true
        realign { [weak self] in
            guard let self else { return }
            if let y = savedScrollY {
                savedScrollY = nil
                run("window.scrollTo(0, \(y))")
            }
            current?.pageRect = topRect()
            applyPendingScroll()
        }
    }

    fileprivate func refuse(_ reason: String) {
        refusal = reason
    }

    // MARK: Bridge

    /// Maps the page's current text onto the source again (after a load, or after scripts changed the page),
    /// then repaints the highlights.
    private func realign(then next: @escaping @MainActor () -> Void = {}) {
        webView.callAsyncJavaScript("return document.documentElement ? document.documentElement.textContent : ''", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, let current = self.current else { return }
                if case .success(let value) = result, let text = value as? String {
                    current.alignment = current.projection.alignment(withDOM: text)
                }
                self.applyHighlights()
                next()
            }
        }
    }

    fileprivate func received(_ body: Any) {
        guard let current, let message = body as? [String: Any] else { return }
        if message["changed"] != nil {
            realign()
            return
        }
        guard let start = message["start"] as? Int, let length = message["length"] as? Int, length > 0 else {
            if current.selection != nil { current.selection = nil }
            return
        }
        var rect: CGRect?
        if let x = message["x"] as? Double, let y = message["y"] as? Double, let w = message["w"] as? Double, let h = message["h"] as? Double {
            rect = webView.topLeftWindowRect(CGRect(x: x, y: y, width: max(w, 2), height: max(h, 2)))
        }
        current.selection = HTMLSelection(dom: NSRange(location: start, length: length), text: message["text"] as? String ?? "", rect: rect)
    }

    private func topRect() -> CGRect? {
        webView.topLeftWindowRect(CGRect(x: webView.bounds.midX, y: 24, width: 2, height: 2))
    }

    private func applyHighlights() {
        guard isLoaded, let current, current.alignment != nil else { return }
        var list: [[String: Any]] = []
        var css = ""
        for (index, highlight) in current.source.highlights.enumerated() where !highlight.isInvalidated {
            guard let dom = current.domRange(forSource: highlight.range) else { continue }
            // A page brings its own (usually light) background, so its tints are the light ones whatever the app's
            // appearance; resolved explicitly, since this runs outside any drawing context.
            var color = NSColor.clear
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                color = Theme.highlightBackground(for: highlight.highlight).usingColorSpace(.sRGB) ?? .clear
            }
            let name = "gloss-note-\(index)"
            list.append(["name": name, "start": dom.location, "end": dom.location + dom.length])
            css += "::highlight(\(name)) { background-color: rgba(\(Int(color.redComponent * 255)), \(Int(color.greenComponent * 255)), \(Int(color.blueComponent * 255)), \(color.alphaComponent)); }\n"
        }
        webView.callAsyncJavaScript("window.__cc && window.__cc.highlight(list, css)", arguments: ["list": list, "css": css], in: nil, in: .defaultClient)
    }

    private func applyPendingScroll() {
        guard isLoaded, let current, appliedScrollVersion != current.pendingScrollVersion, let pending = current.pendingScroll,
              let dom = current.domRange(forSource: pending.range) else { return }
        appliedScrollVersion = current.pendingScrollVersion
        // Consumed, so toggling Source and back does not replay an old jump.
        current.pendingScroll = nil
        webView.callAsyncJavaScript("window.__cc && window.__cc.scrollTo(start, end, select)",
                                    arguments: ["start": dom.location, "end": dom.location + dom.length, "select": pending.select], in: nil, in: .defaultClient)
    }

    private func run(_ script: String) {
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient)
    }

    /// Shows the line while the page loads; at the end it fills, then fades, rather than vanishing mid-way.
    private func progressChanged(_ value: Double, loading: Bool) {
        guard let current else { return }
        if loading, value < 1 {
            current.loadProgress = max(value, 0.08)
        } else if current.loadProgress != nil {
            current.loadProgress = 1
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                if self?.current?.loadProgress == 1 { self?.current?.loadProgress = nil }
            }
        }
    }

    // MARK: Delegate

    /// WebKit's delegate and the bridge's message handler, kept off the observable class and holding it weakly
    /// so the user content controller never retains the browser.
    private final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var browser: WebBrowserController?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            browser?.decide(navigationAction) ?? .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard navigationResponse.isForMainFrame else { return .allow }
            let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
                browser?.refuse("Downloads aren't available here")
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            browser?.committed(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser?.finished()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if (error as NSError).code != NSURLErrorCancelled { browser?.refuse(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if (error as NSError).code != NSURLErrorCancelled { browser?.refuse(error.localizedDescription) }
        }

        /// A link that wants a new window loads here instead; the policy above then judges it like any other.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            browser?.received(message.body)
        }
    }
}
