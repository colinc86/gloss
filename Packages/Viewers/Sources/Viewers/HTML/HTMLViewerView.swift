import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Segmented Rendered / Source toggle above the matching view, as for markdown.
public struct HTMLViewerView: View {
    public let controller: HTMLViewerController
    public let browser: WebBrowserController
    /// The ssh host whose loopback this page is reached through, when it is.
    public let via: String?

    public init(controller: HTMLViewerController, browser: WebBrowserController, via: String? = nil) {
        self.controller = controller
        self.browser = browser
        self.via = via
    }

    public var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            ViewerToolbar {
                if controller.mode == .rendered {
                    ToolGroup {
                        Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!browser.canGoBack)
                            .help("Back")
                            .accessibilityLabel("Back")
                        Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                            .disabled(!browser.canGoForward)
                            .help("Forward")
                            .accessibilityLabel("Forward")
                    }
                    .transition(.opacity)
                }
                WebAddressField(controller: controller, browser: browser)
                if let via {
                    Label("via \(via)", systemImage: "network")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.12), in: Capsule())
                        .help("localhost here means \(via)'s loopback, reached through the app's ssh connection")
                }
                if let refusal = browser.refusal, controller.mode == .rendered {
                    Label(refusal, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .transition(.opacity.calmed)
                }
            } trailing: {
                if controller.mode == .rendered {
                    if controller.isNoteMode {
                        ToolHints([ToolHint(symbol: "escape", keys: ["esc"], "Leave", explained: "Leave element notes without picking anything")], inline: 1)
                            .transition(.opacity.calmed)
                    }
                    ToolGroup {
                        Button { controller.isNoteMode.toggle() } label: {
                            Image(systemName: "rectangle.dashed")
                                .foregroundStyle(controller.isNoteMode ? Color.white : Color.primary)
                                .padding(.horizontal, 3)
                                .background(controller.isNoteMode ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .help(controller.isNoteMode ? "Click any element on the page to attach a note to it" : "Element Notes: attach a note to a button, an image, any element")
                        .accessibilityLabel("Element Notes")
                        .accessibilityAddTraits(controller.isNoteMode ? .isSelected : [])
                        Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .help(controller.page.isLive ? "Reload the page" : "Reload the page and run its scripts again")
                            .accessibilityLabel("Reload")
                    }
                    .transition(.opacity)
                }
                ModeSwitch([
                    .init(HTMLViewerController.Mode.rendered, "Rendered", symbol: "eye"),
                    .init(HTMLViewerController.Mode.source, "Source", symbol: "chevron.left.forwardslash.chevron.right"),
                ], selection: $controller.mode)
                .help(controller.page.isLive ? "Toggle the page and its current DOM" : "Toggle rendered and source")
            }
            .overlay(alignment: .bottom) { LoadProgressLine(progress: controller.mode == .rendered ? controller.loadProgress : nil) }
            .animation(Motion.smooth, value: controller.mode)
            .animation(Motion.smooth, value: browser.refusal)
            .animation(Motion.snappy, value: controller.isNoteMode)
            switch controller.mode {
            case .rendered:
                RenderedHTMLView(controller: controller, browser: browser)
            case .source:
                TextEditorView(controller: controller.source)
            }
        }
        // Escape leaves element notes wherever focus is (the page catches it too, but only while it has focus).
        .onExitCommand(perform: controller.isNoteMode ? { controller.isNoteMode = false } : nil)
    }
}

/// The page's name at rest: the file's title with a globe, or a live page's address. A click turns it into a
/// field; Return opens what was typed, Escape puts the address back.
struct WebAddressField: View {
    let controller: HTMLViewerController
    let browser: WebBrowserController
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var address: String? {
        if case .live = controller.page { return (browser.displayedURL ?? liveURL)?.absoluteString }
        return nil
    }

    private var liveURL: URL? { if case .live(let url) = controller.page { url } else { nil } }

    var body: some View {
        if editing {
            TextField("Address", text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($focused)
                .onSubmit(open)
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, isFocused in if !isFocused { editing = false } }
                .frame(minWidth: 180, maxWidth: 520)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .onAppear { focused = true }
        } else {
            Button {
                draft = address ?? ""
                editing = true
            } label: {
                Label(address ?? controller.pageTitle ?? "Web page", systemImage: "globe")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.plain)
            .help(address == nil ? "Click to type an address" : "Open another address")
            .accessibilityLabel(address.map { "Address: " + $0 } ?? "Address")
            .animation(Motion.smooth, value: controller.pageTitle)
        }
    }

    private func open() {
        editing = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var url = URL(string: text)
        if url?.scheme == nil, !text.contains("://") {
            let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
            let bare = host.split(separator: ":").first.map(String.init) ?? host
            url = URL(string: (WebProxyMap.loopbackHosts.contains(bare.lowercased()) ? "http://" : "https://") + text)
        }
        guard let url, url.host() != nil else { return }
        browser.open(url)
    }
}

/// Parks the app's one web view in this pane and makes the page current. Switching documents or modes moves the
/// view between containers without destroying it, so the page, its history and its scroll position survive.
struct RenderedHTMLView: NSViewRepresentable {
    let controller: HTMLViewerController
    let browser: WebBrowserController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        park(in: container, fresh: true)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        park(in: nsView, fresh: false)
        browser.sync()
    }

    private func park(in container: NSView, fresh: Bool) {
        // The page the view just left (a link, Back, a redirect) belongs to a pane on its way out; only a pane
        // made for it again takes the view back.
        if !fresh, browser.released === controller { return }
        let webView = browser.webView
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
        if browser.current !== controller {
            // A page the view already shows (a link it followed, a route change) is adopted, not reloaded; the same
            // address reached through another machine's loopback is a different page.
            let adopt: Bool = {
                switch controller.page {
                case .live(let url):
                    guard let shown = browser.displayedURL, browser.shownProxyHost == controller.proxy?.hostID else { return false }
                    return WebDocumentKey.normalize(shown) == WebDocumentKey.normalize(url)
                case .file(let path):
                    // The same path on another host is another file.
                    return browser.shownFilePath == path && browser.shownFileHost == WebBrowserController.hostKey(controller.hostID) && browser.displayedURL == nil
                }
            }()
            browser.attach(controller, load: !adopt)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // The web view belongs to the browser; the next pane adopts it.
    }
}

/// Serves `gloss-html://<host key>/<absolute path>`: the document itself from the editor's current text, and other paths
/// (stylesheets, images, scripts) inside the controller's resource root through its loader. Anything else fails.
final class HTMLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "gloss-html"
    weak var browser: WebBrowserController?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        let key = ObjectIdentifier(urlSchemeTask)
        let request = urlSchemeTask.request
        // The page the request belongs to is its main document: the current page, or, while Back or Forward goes
        // to a file, that file's open document.
        let main = request.mainDocumentURL ?? url
        guard let controller = browser?.servingController(host: main.host()?.lowercased(), documentPath: main.path), case .file = controller.page,
              Self.permits(url: url, mainDocument: request.mainDocumentURL,
                           referrer: (request.value(forHTTPHeaderField: "Referer") ?? request.value(forHTTPHeaderField: "Origin")).flatMap(URL.init(string:)),
                           servingHost: WebBrowserController.hostKey(controller.hostID)) else {
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

    /// The view is shared with live pages, which must never read files through this scheme. A request is served
    /// only for the host of the file the view shows (a page cannot reach another host's files by writing
    /// `gloss-html://other/…`), only when its main document is a served file on that host, and only when whatever it
    /// says it came from is one too. A request that names neither a main document nor a referrer is refused.
    nonisolated static func permits(url: URL, mainDocument: URL?, referrer: URL?, servingHost: String) -> Bool {
        func ours(_ candidate: URL) -> Bool { candidate.scheme?.lowercased() == scheme && candidate.host()?.lowercased() == servingHost }
        guard ours(url) else { return false }
        if let mainDocument, !ours(mainDocument) { return false }
        if let referrer, !ours(referrer) { return false }
        return mainDocument != nil || referrer != nil
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
