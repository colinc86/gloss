import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Segmented Rendered / Source toggle above the matching view, as for markdown.
public struct HTMLViewerView: View {
    public let controller: HTMLViewerController
    public let browser: WebBrowserController

    public init(controller: HTMLViewerController, browser: WebBrowserController) {
        self.controller = controller
        self.browser = browser
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
                        Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
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
                RenderedHTMLView(controller: controller, browser: browser)
            case .source:
                TextEditorView(controller: controller.source)
            }
        }
    }
}

/// Parks the app's one web view in this pane and makes the page current. Switching documents or modes moves the
/// view between containers without destroying it, so the page, its history and its scroll position survive.
struct RenderedHTMLView: NSViewRepresentable {
    let controller: HTMLViewerController
    let browser: WebBrowserController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        park(in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        park(in: nsView)
        browser.sync()
    }

    private func park(in container: NSView) {
        let webView = browser.webView
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
        if browser.current !== controller {
            // A page the view already shows (a link it followed, a route change) is adopted, not reloaded.
            let adopt: Bool = {
                guard case .live(let url) = controller.page, let shown = browser.displayedURL else { return false }
                return WebDocumentKey.normalize(shown) == WebDocumentKey.normalize(url)
            }()
            browser.attach(controller, load: !adopt)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // The web view belongs to the browser; the next pane adopts it.
    }
}

/// Serves `gloss-html://doc/<absolute path>`: the document itself from the editor's current text, and other paths
/// (stylesheets, images, scripts) inside the controller's resource root through its loader. Anything else fails.
final class HTMLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "gloss-html"
    nonisolated static let host = "doc"
    weak var browser: WebBrowserController?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        let key = ObjectIdentifier(urlSchemeTask)
        // `//host/x` references resolve to `gloss-html://host/x`; only `doc` is ours.
        guard url.host == Self.host else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        // The view is shared with live pages, which must not be able to read files through this scheme: the
        // request has to come from a served page (its main document URL is ours), and the current page must be one.
        guard let controller = browser?.current, case .file = controller.page,
              urlSchemeTask.request.mainDocumentURL.map({ $0.scheme?.lowercased() == Self.scheme }) ?? true else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
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
