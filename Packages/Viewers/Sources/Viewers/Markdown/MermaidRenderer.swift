import AppKit
import WebKit

/// Draws Mermaid diagrams with the bundled `mermaid.min.js` (never fetched from the network) in an offscreen web view,
/// as PNG at twice the diagram's size: HTML labels draw as they do on GitHub, and a region note has real pixels to
/// crop. One web view serves every document, one diagram at a time, and goes away when it has been idle a while.
public final class MermaidRenderer {
    public static let shared = MermaidRenderer()

    /// A drawn diagram, Mermaid's complaint about its source, or a renderer that couldn't run (WebKit failed or took
    /// too long), which is never remembered so the next render tries again.
    public enum Result {
        case diagram(image: NSImage, png: Data)
        case failed(String)
        case unavailable(String)
    }

    /// The bundled Mermaid release, for the record (`Resources/Mermaid`).
    nonisolated public static let version = "11.17.2"

    private struct Key: Hashable {
        let source: String
        let dark: Bool
    }

    private var cache: [Key: (result: Result, cost: Int)] = [:]
    private var cacheOrder: [Key] = []
    private var cacheCost = 0
    /// Bytes of drawn diagrams kept (their decoded pixels and PNGs); the oldest go first.
    static let cacheCostLimit = 96 * 1024 * 1024
    private var running: [Key: Task<Result, Never>] = [:]
    /// The last render queued: each waits for the one before, so the web view draws one diagram at a time.
    private var queue: Task<Void, Never>?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var delegate: Delegate?
    private var idleTask: Task<Void, Never>?
    static let idleDelay = Duration.seconds(30)
    /// How long one step (starting, drawing, snapshotting) may take before the web view is given up as hung.
    static let deadline = Duration.seconds(10)
    /// The page's size while Mermaid lays a diagram out, the same for every diagram so none takes its width from the
    /// one before (a Gantt chart fills the page's width).
    static let layoutSize = CGSize(width: 800, height: 600)
    /// A diagram larger than this many pixels at 2x is drawn at a smaller scale.
    static let maximumPixels: CGFloat = 4096 * 4096

    init() {}

    /// The diagram for `source` in the light or dark theme, drawn once and then remembered.
    public func render(_ source: String, dark: Bool) async -> Result {
        let key = Key(source: source, dark: dark)
        if let cached = cache[key] { return cached.result }
        if let task = running[key] { return await task.value }
        let previous = queue
        let task = Task { () -> Result in
            await previous?.value
            return await self.draw(source, dark: dark)
        }
        running[key] = task
        queue = Task { _ = await task.value }
        let result = await task.value
        running[key] = nil
        remember(result, for: key)
        return result
    }

    private func remember(_ result: Result, for key: Key) {
        let cost: Int
        switch result {
        case .diagram(let image, let png):
            let pixels = FittedImageAttachment.pixelSize(of: image)
            cost = Int(pixels.width * pixels.height) * 4 + png.count
        case .failed(let reason): cost = reason.utf8.count
        case .unavailable: return
        }
        guard cache[key] == nil else { return }
        cache[key] = (result, cost)
        cacheOrder.append(key)
        cacheCost += cost
        while cacheCost > Self.cacheCostLimit, cacheOrder.count > 1 {
            cacheCost -= cache.removeValue(forKey: cacheOrder.removeFirst())?.cost ?? 0
        }
    }

    /// What the page said: the diagram's size, or Mermaid's error.
    private struct Reply: Sendable {
        var size: CGSize?
        var error: String?
    }

    private func draw(_ source: String, dark: Bool) async -> Result {
        idleTask?.cancel()
        defer { scheduleTeardown() }
        do {
            let webView = try await loadedWebView()
            // Laid out at the same size every time; the view grows to the diagram only for its snapshot.
            window?.setContentSize(Self.layoutSize)
            webView.frame = CGRect(origin: .zero, size: Self.layoutSize)
            let arguments: [String: Any] = ["source": source, "theme": dark ? "dark" : "default", "background": Self.backgroundHex(dark: dark)]
            let reply: Reply = try await withDeadline { finish in
                webView.callAsyncJavaScript(Self.renderScript, arguments: arguments, in: nil, in: .page) { result in
                    finish(result.map { value in
                        let reply = value as? [String: Any]
                        if let error = reply?["error"] as? String { return Reply(error: error) }
                        guard let width = (reply?["width"] as? NSNumber)?.doubleValue, let height = (reply?["height"] as? NSNumber)?.doubleValue else { return Reply() }
                        return Reply(size: CGSize(width: width, height: height))
                    })
                }
            }
            if let error = reply.error { return .failed(Self.summary(of: error)) }
            guard let drawn = reply.size, drawn.width >= 1, drawn.height >= 1 else { return .failed("Mermaid drew nothing") }
            let size = CGSize(width: drawn.width.rounded(.up), height: drawn.height.rounded(.up))
            window?.setContentSize(size)
            webView.frame = CGRect(origin: .zero, size: size)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: size)
            let scale = min(2, (Self.maximumPixels / (size.width * size.height)).squareRoot())
            // The snapshot's width is in points, drawn at the window's backing scale.
            configuration.snapshotWidth = NSNumber(value: Double(size.width * scale / (window?.backingScaleFactor ?? 1)))
            let png: Data = try await withDeadline { finish in
                webView.takeSnapshot(with: configuration) { snapshot, error in
                    if let tiff = snapshot?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        finish(.success(png))
                    } else {
                        finish(.failure(error ?? Failure.unreadable))
                    }
                }
            }
            guard let bitmap = NSBitmapImageRep(data: png) else { throw Failure.unreadable }
            bitmap.size = size
            let image = NSImage(size: size)
            image.addRepresentation(bitmap)
            return .diagram(image: image, png: png)
        } catch {
            // A web view that failed or hung is started afresh for the next diagram.
            tearDown()
            return .unavailable(error.localizedDescription)
        }
    }

    /// Runs one WebKit call that reports through a completion handler, giving up after `deadline`; whichever comes
    /// first resumes, once.
    private func withDeadline<T: Sendable>(_ start: (@escaping @MainActor (Swift.Result<T, any Error>) -> Void) -> Void) async throws -> T {
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let timer = Task { @MainActor in
                try? await Task.sleep(for: Self.deadline)
                guard !Task.isCancelled, !once.done else { return }
                once.done = true
                continuation.resume(throwing: Failure.timedOut)
            }
            start { result in
                timer.cancel()
                guard !once.done else { return }
                once.done = true
                continuation.resume(with: result)
            }
        }
    }

    private final class Once {
        var done = false
    }

    // MARK: Web view

    private enum Failure: LocalizedError {
        case missingScript
        case loadFailed(String)
        case timedOut
        case unreadable
        var errorDescription: String? {
            switch self {
            case .missingScript: "Gloss's copy of Mermaid is missing"
            case .loadFailed(let reason): "Mermaid couldn't start: \(reason)"
            case .timedOut: "Mermaid took too long"
            case .unreadable: "Mermaid's drawing couldn't be read"
            }
        }
    }

    private func loadedWebView() async throws -> WKWebView {
        if let webView { return webView }
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid"),
              let script = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.missingScript }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: CGRect(origin: .zero, size: Self.layoutSize), configuration: configuration)
        let delegate = Delegate()
        webView.navigationDelegate = delegate
        // In a window, never shown, so WebKit lays the page out and paints it for the snapshot.
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.webView = webView
        self.window = window
        self.delegate = delegate
        let _: Bool = try await withDeadline { finish in
            delegate.onLoad = { error in
                delegate.onLoad = nil
                finish(error.map { .failure(Failure.loadFailed($0.localizedDescription)) } ?? .success(true))
            }
            webView.loadHTMLString(Self.page, baseURL: nil)
        }
        return webView
    }

    private func scheduleTeardown() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled, let self, self.running.isEmpty else { return }
            self.tearDown()
        }
    }

    private func tearDown() {
        delegate?.onLoad?(Failure.loadFailed("stopped"))
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
        delegate = nil
    }

    /// Only the empty page itself loads: Mermaid's links and anything else that tries to navigate are refused.
    private final class Delegate: NSObject, WKNavigationDelegate {
        var onLoad: (((any Error)?) -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoad?(nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            onLoad?(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            onLoad?(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MermaidRenderer.shared.contentProcessEnded(webView)
        }
    }

    private func contentProcessEnded(_ ended: WKWebView) {
        if ended === webView { tearDown() }
    }

    // MARK: Page

    /// Nothing may load from anywhere: the script arrives as a user script, and Mermaid's styles are inline.
    static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src data:">
    </head><body style="margin:0"><div id="host" style="display:inline-block"></div></body></html>
    """

    /// Draws `source` at the top left of the page at its own size, and returns that size or Mermaid's error.
    static let renderScript = """
    const host = document.getElementById('host');
    host.replaceChildren();
    document.body.style.background = background;
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: theme, darkMode: theme === 'dark',
                         fontFamily: '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif' });
    window.glossDiagrams = (window.glossDiagrams || 0) + 1;
    try {
        const { svg } = await mermaid.render('gloss-diagram-' + window.glossDiagrams, source);
        host.innerHTML = svg;
        const element = host.querySelector('svg');
        const box = element.viewBox && element.viewBox.baseVal;
        const drawn = element.getBoundingClientRect();
        element.setAttribute('width', box && box.width ? box.width : drawn.width);
        element.setAttribute('height', box && box.height ? box.height : drawn.height);
        element.style.maxWidth = 'none';
        element.style.display = 'block';
        const rect = element.getBoundingClientRect();
        return { width: rect.width, height: rect.height };
    } catch (error) {
        // A failed render leaves its error drawing behind.
        document.querySelectorAll('body > :not(#host)').forEach(node => node.remove());
        return { error: String((error && error.message) || error) };
    }
    """

    /// The rendered view's page color in the theme, so a diagram sits on the page rather than on a card.
    static func backgroundHex(dark: Bool) -> String {
        var hex = dark ? "#1e1e1e" : "#ffffff"
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) else { return }
            hex = String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
                         Int((color.blueComponent * 255).rounded()))
        }
        return hex
    }

    /// Mermaid's parse errors run over several lines with a caret under the source; the first line says where and
    /// the last says what was expected.
    nonisolated static func summary(of error: String) -> String {
        let lines = error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return "Mermaid couldn't draw this diagram" }
        let summary = lines.count > 1 && lines.last != first ? "\(first) \(lines.last!)" : first
        return summary.count > 240 ? String(summary.prefix(240)) + "…" : summary
    }
}
