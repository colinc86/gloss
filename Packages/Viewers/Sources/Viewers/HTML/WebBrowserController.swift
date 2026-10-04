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
    /// The served file the view shows, when it shows one, and its host's scheme key.
    public private(set) var shownFilePath: String?
    public private(set) var shownFileHost: String?
    /// The ssh host whose tunnels the shown live page came through; nil on this Mac and on the web.
    public var shownProxyHost: HostID? { shownProxy?.hostID }
    /// Those tunnels, kept while no page is attached so the next commit still maps back to a logical address.
    @ObservationIgnored private var shownProxy: WebProxyMap?
    /// Why the last navigation was refused, for the toolbar; cleared by the next successful load.
    public private(set) var refusal: String?

    /// A main-frame load committed to a live page with this logical URL (a link, Back, or a route change): the
    /// ssh host it came through when it is on that host's loopback, and the page that was current before, so the
    /// app can tell whether the browser was what the viewer showed.
    @ObservationIgnored public var onDocumentChange: @MainActor (_ url: URL, _ via: HostID?, _ previous: HTMLViewerController?) -> Void = { _, _, _ in }
    /// A link to a file, or Back to one: the host it lives on, its absolute path, and the page that was current.
    @ObservationIgnored public var onOpenFile: @MainActor (_ host: HostID?, _ path: String, _ previous: HTMLViewerController?) -> Void = { _, _, _ in }
    /// Scheme host keys of the hosts whose files this view has served, back to their ids (WebKit lowercases hosts).
    @ObservationIgnored private var hostKeys: [String: HostID] = [:]
    /// Back or Forward to a served file that is not current: once its document attaches, the view returns to
    /// this history item instead of loading the file as a new one.
    @ObservationIgnored private var pendingHistory: WKBackForwardListItem?
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
    @ObservationIgnored private var appliedPickMode = false
    @ObservationIgnored private var appliedElementVersion = -1

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
            // Same-document navigations (pushState, hash changes) commit nothing; the URL still moves. While a
            // real navigation loads, the URL is only provisional: didCommit reports it when it is the page.
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { if !webView.isLoading { self?.committed(webView.url) } }
            },
        ]
    }

    // MARK: Pages

    /// Makes `controller` the page the view shows. `load` false adopts what the view already shows (the document
    /// changed under a navigation the view made itself); true loads the page.
    public func attach(_ controller: HTMLViewerController, load: Bool) {
        refusal = nil
        if current === controller {
            if load { self.load(controller) }
            return
        }
        detachCurrent()
        current = controller
        if case .file = controller.page { hostKeys[Self.hostKey(controller.hostID)] = controller.hostID }
        controller.snapshotProvider = { [weak self] rect in try await self?.snapshot(pageRect: rect) }
        controller.resolveElements = { [weak self] items in await self?.resolve(items) ?? [:] }
        controller.scrollToElement = { [weak self] selector in self?.scrollToElement(selector: selector) }
        highlightToken = controller.source.addHighlightObserver { [weak self] in self?.applyHighlights() }
        observePageState(of: controller)
        if load {
            self.load(controller)
        } else {
            loadedVersion = controller.renderedVersion
            isLoaded = true
            controller.pageRect = topRect()
            refresh()
        }
    }

    /// Note mode and element highlights change outside SwiftUI's updates (the session sets them), so the browser
    /// watches them itself and pushes them to the page, re-arming after every change while the page is current.
    private func observePageState(of controller: HTMLViewerController) {
        withObservationTracking {
            _ = controller.isNoteMode
            _ = controller.elementHighlightsVersion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.current === controller else { return }
                self.sync()
                self.observePageState(of: controller)
            }
        }
    }

    /// The scheme host a served file's URL carries: its host's id, lowercased as WebKit will have it.
    nonisolated public static func hostKey(_ host: HostID?) -> String { (host?.rawValue ?? "h_local").lowercased() }

    /// The served-file URL of `path` on `host`.
    nonisolated public static func fileURL(path: String, host: HostID?) -> URL? {
        var components = URLComponents()
        components.scheme = HTMLSchemeHandler.scheme
        components.host = hostKey(host)
        components.path = path
        return components.url
    }

    /// Stops showing any page: a closed document's page must not keep running (audio, polling, sockets) or keep
    /// feeding its state anywhere.
    public func unload() {
        detachCurrent()
        current = nil
        pendingHistory = nil
        displayedURL = nil
        shownFilePath = nil
        shownFileHost = nil
        shownProxy = nil
        isLoaded = false
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// The view moved to something else: the page that was current stops receiving its state until a document
    /// attaches again (a later attach of the same page reloads it, since the view no longer shows it).
    private func release() {
        detachCurrent()
        current = nil
    }

    private func detachCurrent() {
        guard let current else { return }
        if let highlightToken { current.source.removeHighlightObserver(highlightToken) }
        highlightToken = nil
        schemeHandler.cancelAll()
        current.loadProgress = nil
        if appliedPickMode { run("window.__cc && window.__cc.setPickMode(false)") }
        appliedPickMode = false
        appliedElementVersion = -1
        current.isNoteMode = false
        current.snapshotProvider = nil
        current.resolveElements = nil
        current.scrollToElement = nil
        // The next page starts without a selection; a stale one would show an Add Note button for nothing.
        current.selection = nil
        current.alignment = nil
    }

    private func load(_ controller: HTMLViewerController) {
        loadedVersion = controller.renderedVersion
        isLoaded = false
        appliedPickMode = false
        refusal = nil
        switch controller.page {
        case .file(let path):
            guard let url = Self.fileURL(path: path, host: controller.hostID) else { return }
            displayedURL = nil
            shownFilePath = path
            shownFileHost = Self.hostKey(controller.hostID)
            shownProxy = nil
            // Back or Forward brought this file back: return to its history item rather than adding a new one.
            if let item = pendingHistory, item.url.path == path, item.url.host()?.lowercased() == shownFileHost {
                pendingHistory = nil
                webView.go(to: item)
                return
            }
            pendingHistory = nil
            webView.load(URLRequest(url: url))
        case .live(let url):
            displayedURL = url
            shownFilePath = nil
            shownFileHost = nil
            shownProxy = controller.proxy
            pendingHistory = nil
            if let proxy = controller.proxy, let port = WebProxyMap.loopbackPort(of: url), !proxy.isProxied(url), proxy.tunnels[port] == nil {
                // The page lives on the host's loopback: get there first, then load.
                tunnel(port: port, then: url, proxy: proxy)
                return
            }
            webView.load(URLRequest(url: controller.proxy?.proxied(url) ?? url))
        }
    }

    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }

    public func reload() {
        guard let current else { return }
        switch current.page {
        case .file: current.rebuildNow()
        // Through load, so a tunnel that went with a dropped connection is made again first.
        case .live:
            if current.proxy == nil { webView.reload() } else { load(current) }
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
        if appliedPickMode != current.isNoteMode {
            appliedPickMode = current.isNoteMode
            webView.callAsyncJavaScript("window.__cc && window.__cc.setPickMode(on)", arguments: ["on": current.isNoteMode], in: nil, in: .defaultClient)
        }
        if appliedElementVersion != current.elementHighlightsVersion {
            applyElementHighlights()
        }
    }

    // MARK: Navigation

    fileprivate func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // Nothing attached (a page was closed, or the view is between documents): only the view's own loads.
        guard let current else { return url.scheme?.lowercased() == "about" ? .allow : .cancel }
        let fileHost: String? = { if case .file = current.page { Self.hostKey(current.hostID) } else { nil } }()
        let decision = WebNavigationPolicy.decide(
            url: url, type: action.navigationType, isMainFrame: action.targetFrame?.isMainFrame ?? true,
            page: current.page, fileHost: fileHost, proxy: current.proxy, isLocalHost: current.isLocal
        )
        switch decision {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .refuse(let reason):
            refusal = reason
            return .cancel
        case .openFile(let path):
            let host: HostID?
            if url.scheme?.lowercased() == HTMLSchemeHandler.scheme {
                guard let key = url.host()?.lowercased(), let known = hostKeys[key] else { return .cancel }
                host = known
                if action.navigationType == .backForward { pendingHistory = historyItem(for: url) }
            } else {
                host = current.hostID
            }
            onOpenFile(host, path, current)
            return .cancel
        case .tunnel(let port, let then):
            if let proxy = current.proxy { tunnel(port: port, then: then, proxy: proxy) }
            return .cancel
        case .external(let url):
            onExternal(url)
            return .cancel
        }
    }

    /// The nearest history item showing `url`, behind or ahead of the current one.
    private func historyItem(for url: URL) -> WKBackForwardListItem? {
        let list = webView.backForwardList
        let candidates = list.backList.reversed() + list.forwardList
        return candidates.first { $0.url.path == url.path && $0.url.host()?.lowercased() == url.host()?.lowercased() }
    }

    private func tunnel(port: UInt16, then url: URL, proxy: WebProxyMap) {
        let started = current
        Task { [weak self] in
            guard let self else { return }
            do {
                let local = try await onNeedsTunnel(proxy.hostID, port)
                // The reader may have moved on while the tunnel came up; only the page that asked loads through it.
                guard let current, current === started, current.proxy?.hostID == proxy.hostID else { return }
                var updated = current.proxy ?? proxy
                updated.tunnels[port] = local
                current.proxy = updated
                shownProxy = updated
                if let proxied = updated.proxied(url) { webView.load(URLRequest(url: proxied)) }
            } catch {
                refusal = "Couldn't reach port \(port) on the host: \(error.localizedDescription)"
            }
        }
    }

    /// The view now shows `url`. When that is not the current page's address, the current page lets go before
    /// anything else happens: what loads next (a link, a redirect, a route) must never be read into it.
    fileprivate func committed(_ url: URL?) {
        guard let url else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        // about:blank and friends are the view's own pages, never documents.
        if scheme == "about" { return }
        if scheme == HTMLSchemeHandler.scheme {
            let key = url.host()?.lowercased()
            displayedURL = nil
            shownFilePath = url.path
            shownFileHost = key
            shownProxy = nil
            guard let current else { return }
            if case .file(let path) = current.page, path == url.path, Self.hostKey(current.hostID) == key { return }
            release()
            if let key, let host = hostKeys[key] { onOpenFile(host, url.path, current) }
            return
        }
        let proxy = current?.proxy ?? shownProxy
        let logical = proxy?.logical(url) ?? url
        displayedURL = logical
        shownFilePath = nil
        shownFileHost = nil
        refusal = nil
        guard let current else { return }
        if case .live(let shown) = current.page, WebDocumentKey.normalize(shown) == WebDocumentKey.normalize(logical) { return }
        // A page on the host's loopback stays on that host; anything else is the open web.
        let via = proxy.flatMap { WebProxyMap.loopbackPort(of: logical) != nil ? $0.hostID : nil }
        if via == nil { shownProxy = nil }
        release()
        onDocumentChange(logical, via, current)
    }

    fileprivate func finished() {
        isLoaded = true
        // A new page's bridge starts with everything off; note mode is applied again below if it is still on.
        appliedPickMode = false
        refresh { [weak self] in
            guard let self else { return }
            if let y = savedScrollY {
                savedScrollY = nil
                run("window.scrollTo(0, \(y))")
            }
            current?.pageRect = topRect()
            applyPendingScroll()
            sync()
        }
    }

    fileprivate func refuse(_ reason: String) {
        refusal = reason
    }

    fileprivate func contentProcessEnded() {
        guard let current else { return }
        load(current)
    }

    // MARK: Bridge

    /// Reads the page's text (and, for a live page, its DOM) after a load or a change, maps it onto the source,
    /// repaints the highlights, and tells the session when the text actually changed.
    private func refresh(then next: @escaping @MainActor () -> Void = {}) {
        guard let current else { return }
        let live = current.page.isLive
        let script = live
            ? "return window.__cc ? window.__cc.serialize() : { html: document.documentElement.outerHTML, text: document.documentElement.textContent, textHash: '' }"
            : "return { text: document.documentElement ? document.documentElement.textContent : '', textHash: window.__cc ? window.__cc.textHash() : '' }"
        let started = current
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, let current = self.current, current === started else { return }
                var changed = false
                if case .success(let value) = result, let page = value as? [String: Any], let text = page["text"] as? String {
                    let hash = page["textHash"] as? String ?? ""
                    changed = hash != current.textHash
                    if live, changed, let html = page["html"] as? String {
                        current.adoptLivePage(html: html, textHash: hash)
                    } else if changed {
                        current.textHash = hash
                    }
                    current.alignment = current.projection.alignment(withDOM: text)
                }
                self.applyHighlights()
                self.applyElementHighlights()
                if changed { current.onPageChanged() }
                next()
            }
        }
    }

    fileprivate func received(_ body: Any) {
        guard let current, let message = body as? [String: Any] else { return }
        if message["changed"] != nil {
            refresh()
            return
        }
        if let url = message["url"] as? String {
            committed(URL(string: url))
            return
        }
        if let pick = message["pick"] as? [String: Any] {
            guard let picked = elementPick(from: pick) else { return }
            current.pendingPick = picked
            current.onPick(picked)
            return
        }
        if message["pickCancel"] != nil {
            current.isNoteMode = false
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

    private func elementPick(from pick: [String: Any]) -> ElementPick? {
        guard let selector = pick["selector"] as? String, let tag = pick["tag"] as? String,
              let page = rect(pick["page"]) else { return nil }
        let viewport = rect(pick["rect"]).map { CGRect(x: $0.x, y: $0.y, width: max($0.w, 2), height: max($0.h, 2)) }
        return ElementPick(
            selector: selector, tag: tag, text: pick["text"] as? String ?? "", html: pick["html"] as? String ?? "",
            windowRect: viewport.flatMap { webView.topLeftWindowRect($0) }, pageRect: page, textOffset: pick["textOffset"] as? Int
        )
    }

    private func rect(_ value: Any?) -> ElementRect? {
        guard let dictionary = value as? [String: Any], let x = dictionary["x"] as? Double, let y = dictionary["y"] as? Double,
              let w = dictionary["w"] as? Double, let h = dictionary["h"] as? Double else { return nil }
        return ElementRect(x: x, y: y, w: w, h: h)
    }

    private func candidate(_ value: Any?) -> ElementCandidate? {
        guard let dictionary = value as? [String: Any], let selector = dictionary["selector"] as? String,
              let tag = dictionary["tag"] as? String, let rect = rect(dictionary["rect"]) else { return nil }
        return ElementCandidate(selector: selector, tag: tag, text: dictionary["text"] as? String ?? "", html: dictionary["html"] as? String ?? "", rect: rect,
                                textOffset: dictionary["textOffset"] as? Int)
    }

    // MARK: Elements

    /// Asks the page where each element note's element is now: at its selector, and wherever the same text sits.
    public func resolve(_ items: [(id: NoteID, anchor: ElementAnchor)]) async -> [NoteID: ElementResolution] {
        guard isLoaded, !items.isEmpty else { return [:] }
        let list: [[String: Any]] = items.map { ["id": $0.id.rawValue, "selector": $0.anchor.selector, "tag": $0.anchor.tag, "text": $0.anchor.text] }
        let value = try? await webView.callAsyncJavaScript("return window.__cc ? window.__cc.resolveElements(list) : []", arguments: ["list": list], in: nil, contentWorld: .defaultClient)
        var result: [NoteID: ElementResolution] = [:]
        for entry in value as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String else { continue }
            let byText = (entry["byText"] as? [Any] ?? []).compactMap(candidate)
            result[NoteID(rawValue: id)] = ElementResolution(bySelector: candidate(entry["bySelector"]), byText: byText)
        }
        return result
    }

    /// A 2x PNG of a page rect (CSS pixels from the page's top-left). WebKit snapshots only what is on screen,
    /// so the element is scrolled into view first; a part taller than the view is cut at the view's edge.
    public func snapshot(pageRect: ElementRect) async throws -> (png: Data, width: Int, height: Int)? {
        guard isLoaded else { return nil }
        let bounds = webView.bounds
        // CSS pixels are view points only at 100%; a pinch-zoomed page scales them.
        let zoom = webView.magnification
        func scroll() async throws -> [Double] {
            try await webView.callAsyncJavaScript("return [window.scrollX, window.scrollY]", arguments: [:], in: nil, contentWorld: .defaultClient) as? [Double] ?? [0, 0]
        }
        func viewport() async throws -> CGRect {
            let offsets = try await scroll()
            return CGRect(x: (pageRect.x - offsets[0]) * zoom, y: (pageRect.y - offsets[1]) * zoom, width: pageRect.w * zoom, height: pageRect.h * zoom)
        }
        var rect = try await viewport()
        if rect.minX < 0 || rect.minY < 0 || rect.maxX > bounds.width || rect.maxY > bounds.height {
            let original = try await scroll()
            _ = try? await webView.callAsyncJavaScript("window.scrollTo(Math.max(0, x - 16), Math.max(0, y - 16))", arguments: ["x": pageRect.x, "y": pageRect.y], in: nil, contentWorld: .defaultClient)
            try? await Task.sleep(for: .milliseconds(150))
            rect = try await viewport()
            // The reader is put back where they were once the crop is taken.
            defer {
                webView.callAsyncJavaScript("window.scrollTo(x, y)", arguments: ["x": original[0], "y": original[1]], in: nil, in: .defaultClient)
            }
            return try await capture(rect, bounds: bounds)
        }
        return try await capture(rect, bounds: bounds)
    }

    private func capture(_ rect: CGRect, bounds: CGRect) async throws -> (png: Data, width: Int, height: Int)? {
        let capture = rect.insetBy(dx: -4, dy: -4).intersection(bounds)
        guard !capture.isNull, capture.width >= 2, capture.height >= 2 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = capture
        configuration.snapshotWidth = NSNumber(value: Double(capture.width) * 2)
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (png, bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    /// Scrolls the page to an element note's element and pulses its outline.
    public func scrollToElement(selector: String) {
        webView.callAsyncJavaScript("window.__cc && window.__cc.scrollToElement(selector)", arguments: ["selector": selector], in: nil, in: .defaultClient)
    }

    private func applyElementHighlights() {
        guard isLoaded, let current else { return }
        appliedElementVersion = current.elementHighlightsVersion
        let list: [[String: Any]] = current.elementHighlights.map { highlight in
            let color = highlight.color.usingColorSpace(.sRGB) ?? .systemBlue
            let rgb = "\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))"
            var item: [String: Any] = ["id": highlight.id.rawValue, "selector": highlight.selector, "tag": highlight.tag, "text": highlight.text,
                                       "color": "rgb(\(rgb))", "fill": "rgba(\(rgb),0.12)", "state": highlight.state.rawValue, "needsReview": highlight.needsReview]
            if let last = highlight.lastRect { item["rect"] = ["x": last.x, "y": last.y, "w": last.w, "h": last.h] }
            return item
        }
        let started = current
        webView.callAsyncJavaScript("return window.__cc ? window.__cc.highlightElements(list) : {}", arguments: ["list": list], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, let current = self.current, current === started else { return }
                var rects: [NoteID: CGRect] = [:]
                if case .success(let value) = result, let map = value as? [String: Any] {
                    for (id, entry) in map {
                        if let r = self.rect(entry), let window = self.webView.topLeftWindowRect(CGRect(x: r.x, y: r.y, width: max(r.w, 2), height: max(r.h, 2))) {
                            rects[NoteID(rawValue: id)] = window
                        }
                    }
                }
                current.elementRects = rects
            }
        }
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

        // The completion-handler forms decide synchronously; the async ones would hop through the main actor's
        // queue for every request, which also stalls under a manually run loop (the offscreen tests).
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(browser?.decide(navigationAction) ?? .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            guard navigationResponse.isForMainFrame else { return decisionHandler(.allow) }
            let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
                browser?.refuse("Downloads aren't available here")
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
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

        /// A link the user clicked that wants a new window loads here instead, and the policy above judges it like
        /// any other; a window a script opens by itself (ads, pop-unders, `window.open('')`) is not followed.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated, scheme == "http" || scheme == "https" {
                webView.load(navigationAction.request)
            } else {
                browser?.refuse("This page tried to open a window")
            }
            return nil
        }

        /// The page's web content process went away (a crash, memory pressure): show the page again.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            browser?.contentProcessEnded()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            browser?.received(message.body)
        }
    }
}
