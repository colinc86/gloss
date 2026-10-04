import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Segmented Rendered / Source toggle above the matching view, as for markdown.
public struct HTMLViewerView: View {
    public let controller: HTMLViewerController

    public init(controller: HTMLViewerController) {
        self.controller = controller
    }

    public var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            ViewerToolbar {
                Label(controller.pageTitle ?? "Web page", systemImage: "globe")
                    .contentTransition(.opacity)
                    .animation(Motion.smooth, value: controller.pageTitle)
            } trailing: {
                if controller.mode == .rendered {
                    ToolGroup {
                        Button { controller.rebuildNow() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Reload the page and run its scripts again")
                            .accessibilityLabel("Reload")
                    }
                    .transition(.opacity)
                }
                ModeSwitch([
                    .init(HTMLViewerController.Mode.rendered, "Rendered", symbol: "eye"),
                    .init(HTMLViewerController.Mode.source, "Source", symbol: "chevron.left.forwardslash.chevron.right"),
                ], selection: $controller.mode)
                .help("Toggle rendered and source")
            }
            .overlay(alignment: .bottom) { LoadProgressLine(progress: controller.mode == .rendered ? controller.loadProgress : nil) }
            .animation(Motion.smooth, value: controller.mode)
            switch controller.mode {
            case .rendered:
                RenderedHTMLView(controller: controller)
            case .source:
                TextEditorView(controller: controller.source)
            }
        }
    }
}

/// The page in a WKWebView, scripts and all. The app's own bridge runs in an isolated world the page cannot see:
/// it reports the selection, paints note highlights (CSS custom highlights), scrolls to notes, and says when
/// the page's text changes so offsets can be re-aligned.
struct RenderedHTMLView: NSViewRepresentable {
    let controller: HTMLViewerController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: HTMLSchemeHandler.scheme)
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: Coordinator.bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        content.add(WeakMessageHandler(context.coordinator), contentWorld: .defaultClient, name: "gloss")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        context.coordinator.attach(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.sync()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "gloss", contentWorld: .defaultClient)
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let controller: HTMLViewerController
        let schemeHandler: HTMLSchemeHandler
        private weak var webView: WKWebView?
        private var loadedVersion = -1
        private var appliedScrollVersion = 0
        private var appliedCollapseVersion = 0
        private var isLoaded = false
        private var savedScrollY: Double?
        private var highlightToken: UUID?
        private var observations: [NSKeyValueObservation] = []

        init(controller: HTMLViewerController) {
            self.controller = controller
            schemeHandler = HTMLSchemeHandler(controller: controller)
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            highlightToken = controller.source.addHighlightObserver { [weak self] in self?.applyHighlights() }
            observations = [
                webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                    MainActor.assumeIsolated {
                        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.controller.pageTitle = title?.isEmpty == false ? title : nil
                    }
                },
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    MainActor.assumeIsolated { self?.progressChanged(webView.estimatedProgress, loading: webView.isLoading) }
                },
            ]
            load()
        }

        /// Shows the line while the page loads; at the end it fills, then fades, rather than vanishing mid-way.
        private func progressChanged(_ value: Double, loading: Bool) {
            if loading, value < 1 {
                controller.loadProgress = max(value, 0.08)
            } else if controller.loadProgress != nil {
                controller.loadProgress = 1
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    if self?.controller.loadProgress == 1 { self?.controller.loadProgress = nil }
                }
            }
        }

        func detach() {
            observations.forEach { $0.invalidate() }
            observations = []
            controller.loadProgress = nil
            if let highlightToken { controller.source.removeHighlightObserver(highlightToken) }
            schemeHandler.cancelAll()
            // The next page starts without a selection; a stale one would show an Add Note button for nothing.
            controller.selection = nil
            controller.alignment = nil
        }

        private var documentURL: URL? {
            var components = URLComponents()
            components.scheme = HTMLSchemeHandler.scheme
            components.host = "doc"
            components.path = controller.documentPath
            return components.url
        }

        private func load() {
            guard let webView, let url = documentURL else { return }
            loadedVersion = controller.renderedVersion
            isLoaded = false
            webView.load(URLRequest(url: url))
        }

        func sync() {
            _ = controller.source.highlightsVersion
            guard let webView else { return }
            if loadedVersion != controller.renderedVersion {
                // Keep the reader's place across the reload that shows an edit.
                webView.callAsyncJavaScript("return window.scrollY", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                    MainActor.assumeIsolated {
                        if case .success(let value) = result { self?.savedScrollY = value as? Double }
                        self?.load()
                    }
                }
                loadedVersion = controller.renderedVersion
                return
            }
            guard isLoaded else { return }
            applyPendingScroll()
            if appliedCollapseVersion != controller.collapseVersion {
                appliedCollapseVersion = controller.collapseVersion
                run("window.__cc && window.__cc.collapse()")
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            realign { [weak self] in
                guard let self else { return }
                if let y = self.savedScrollY {
                    self.savedScrollY = nil
                    self.run("window.scrollTo(0, \(y))")
                }
                self.controller.pageRect = self.topRect()
                self.applyPendingScroll()
            }
        }

        /// Maps the page's current text onto the source again (after a load, or after scripts changed the page),
        /// then repaints the highlights.
        private func realign(then next: @escaping @MainActor () -> Void = {}) {
            webView?.callAsyncJavaScript("return document.documentElement ? document.documentElement.textContent : ''", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .success(let value) = result, let text = value as? String {
                        self.controller.alignment = self.controller.projection.alignment(withDOM: text)
                    }
                    self.applyHighlights()
                    next()
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            let isDocument = url.scheme == HTMLSchemeHandler.scheme && url.path == controller.documentPath
            if navigationAction.navigationType == .linkActivated {
                // Same-page anchors scroll in place; web links open in the browser.
                if isDocument, url.fragment != nil { return .allow }
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }
            // Frames may load what they like; the preview itself only ever shows this document.
            if navigationAction.targetFrame?.isMainFrame == false { return .allow }
            return isDocument ? .allow : .cancel
        }

        // MARK: Bridge

        func received(_ body: Any) {
            guard let message = body as? [String: Any] else { return }
            if message["changed"] != nil {
                realign()
                return
            }
            guard let start = message["start"] as? Int, let length = message["length"] as? Int, length > 0 else {
                if controller.selection != nil { controller.selection = nil }
                return
            }
            var rect: CGRect?
            if let x = message["x"] as? Double, let y = message["y"] as? Double, let w = message["w"] as? Double, let h = message["h"] as? Double, let webView {
                rect = webView.topLeftWindowRect(CGRect(x: x, y: y, width: max(w, 2), height: max(h, 2)))
            }
            controller.selection = HTMLSelection(dom: NSRange(location: start, length: length), text: message["text"] as? String ?? "", rect: rect)
        }

        private func topRect() -> CGRect? {
            guard let webView else { return nil }
            return webView.topLeftWindowRect(CGRect(x: webView.bounds.midX, y: 24, width: 2, height: 2))
        }

        private func applyHighlights() {
            guard isLoaded, controller.alignment != nil else { return }
            var list: [[String: Any]] = []
            var css = ""
            for (index, highlight) in controller.source.highlights.enumerated() where !highlight.isInvalidated {
                guard let dom = controller.domRange(forSource: highlight.range) else { continue }
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
            webView?.callAsyncJavaScript("window.__cc && window.__cc.highlight(list, css)", arguments: ["list": list, "css": css], in: nil, in: .defaultClient)
        }

        private func applyPendingScroll() {
            guard isLoaded, appliedScrollVersion != controller.pendingScrollVersion, let pending = controller.pendingScroll,
                  let dom = controller.domRange(forSource: pending.range) else { return }
            appliedScrollVersion = controller.pendingScrollVersion
            // Consumed, so toggling Source and back does not replay an old jump.
            controller.pendingScroll = nil
            webView?.callAsyncJavaScript("window.__cc && window.__cc.scrollTo(start, end, select)",
                                        arguments: ["start": dom.location, "end": dom.location + dom.length, "select": pending.select], in: nil, in: .defaultClient)
        }

        private func run(_ script: String) {
            webView?.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient)
        }

        /// Runs in the `.defaultClient` world: page scripts are off and cannot see it.
        static let bridge = """
        (() => {
          const post = (message) => window.webkit.messageHandlers.gloss.postMessage(message);
          const root = () => document.documentElement;
          function textNodes() {
            const walker = document.createTreeWalker(root(), NodeFilter.SHOW_TEXT);
            const nodes = [];
            let node;
            while ((node = walker.nextNode())) nodes.push(node);
            return nodes;
          }
          function offsetOf(container, offset) {
            const before = document.createRange();
            before.selectNodeContents(root());
            before.setEnd(container, offset);
            return before.toString().length;
          }
          function rangeAt(start, end) {
            const range = document.createRange();
            let position = 0, started = false;
            for (const node of textNodes()) {
              const length = node.data.length;
              if (!started && start <= position + length) { range.setStart(node, start - position); started = true; }
              if (started && end <= position + length) { range.setEnd(node, end - position); return range; }
              position += length;
            }
            return null;
          }
          let timer = null;
          function report() {
            const selection = getSelection();
            if (!selection || selection.rangeCount === 0 || selection.isCollapsed) { post({}); return; }
            const range = selection.getRangeAt(0);
            const text = range.toString();
            const box = range.getBoundingClientRect();
            post({ start: offsetOf(range.startContainer, range.startOffset), length: text.length, text,
                   x: box.left, y: box.top, w: box.width, h: box.height });
          }
          document.addEventListener('selectionchange', () => { clearTimeout(timer); timer = setTimeout(report, 60); });
          // Page scripts may rewrite the text; the app re-aligns its map once they settle.
          let changeTimer = null;
          new MutationObserver(() => { clearTimeout(changeTimer); changeTimer = setTimeout(() => post({ changed: true }), 200); })
            .observe(root(), { childList: true, characterData: true, subtree: true });
          window.addEventListener('scroll', () => { if (!getSelection().isCollapsed) { clearTimeout(timer); timer = setTimeout(report, 60); } }, { passive: true });
          // A constructed stylesheet adds no text node, so page-text offsets stay those of the source.
          let sheet = null;
          window.__cc = {
            highlight(list, css) {
              if (!sheet) { sheet = new CSSStyleSheet(); document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet]; }
              sheet.replaceSync(css);
              if (!window.CSS || !CSS.highlights) return;
              CSS.highlights.clear();
              for (const item of list) {
                const range = rangeAt(item.start, item.end);
                if (range) CSS.highlights.set(item.name, new Highlight(range));
              }
            },
            scrollTo(start, end, select) {
              const range = rangeAt(start, end);
              if (!range) return;
              const element = range.startContainer.parentElement;
              if (element) element.scrollIntoView({ block: 'center' });
              if (select) { const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); }
            },
            collapse() { const selection = getSelection(); if (selection.rangeCount) selection.collapseToEnd(); },
          };
        })();
        """
    }
}

/// Forwards bridge messages without the user content controller retaining the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: RenderedHTMLView.Coordinator?

    init(_ coordinator: RenderedHTMLView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        coordinator?.received(message.body)
    }
}

/// Serves `gloss-html://doc/<absolute path>`: the document itself from the editor's current text, and other paths
/// (stylesheets, images, scripts) inside the controller's resource root through its loader. Anything else fails.
final class HTMLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "gloss-html"
    private let controller: HTMLViewerController
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(controller: HTMLViewerController) {
        self.controller = controller
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        let key = ObjectIdentifier(urlSchemeTask)
        // `//host/x` references resolve to `gloss-html://host/x`; only `doc` is ours.
        guard url.host == "doc" else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        if path == controller.documentPath {
            respond(urlSchemeTask, url: url, data: Data(controller.source.text.utf8), mimeType: "text/html")
            return
        }
        guard HTMLViewerController.allowsResource(path, root: controller.resourceRoot, local: controller.isLocal) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let load = controller.loadResource
        tasks[key] = Task { [weak self] in
            let result: Result<Data, any Error>
            do { result = .success(try await load(path)) } catch { result = .failure(error) }
            guard let self, self.tasks.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
            switch result {
            case .success(let data) where data.count <= HTMLViewerController.maximumResourceSize:
                let type = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                self.respond(urlSchemeTask, url: url, data: data, mimeType: type)
            case .success:
                urlSchemeTask.didFailWithError(URLError(.dataLengthExceedsMaximum))
            case .failure:
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        let encoding = mimeType.hasPrefix("text/") || mimeType == "application/javascript" ? "utf-8" : nil
        task.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: encoding))
        task.didReceive(data)
        task.didFinish()
    }
}

/// A thin accent line along a toolbar's bottom edge while something loads, the way Safari shows a page coming in.
struct LoadProgressLine: View {
    let progress: Double?

    var body: some View {
        GeometryReader { proxy in
            if let progress {
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: max(6, proxy.size.width * progress), height: 2)
                    .transition(.opacity)
            }
        }
        .frame(height: 2)
        .animation(Motion.smooth, value: progress)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
