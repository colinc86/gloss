import AppKit
import Core
import Testing
import WebKit
@testable import Viewers

/// The bridge script against a real WKWebView, loaded offscreen in a window so layout runs. Every wait suspends
/// (`await`) rather than spinning a nested run loop: WebKit delivers its callbacks as main-queue blocks, which a
/// run loop nested inside the test's own main-actor block can never drain.
@MainActor
@Suite(.serialized)
struct WebBridgeTests {
    static let fixture = """
    <!doctype html><html><head><title>Fixture</title></head><body>
    <nav><a href="/one">One</a><a href="/two">Two</a></nav>
    <main>
      <section><p>First section paragraph.</p></section>
      <section><p>Second section, first paragraph.</p><p>Second section, second paragraph.</p><p>Target paragraph.</p></section>
      <div id="toolbar"><button>Cancel</button><button class="primary" data-testid="save">Save</button></div>
      <p id="long">LONG</p>
    </main>
    </body></html>
    """

    @MainActor
    final class Harness {
        let window: NSWindow
        let browser = WebBrowserController()
        let page: HTMLViewerController
        var documentChanges: [URL] = []
        var urlObservations = 0
        private var observation: NSKeyValueObservation?

        init(html: String, url: URL = URL(string: "http://fixture.test/")!) {
            page = HTMLViewerController(livePage: url)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            browser.webView.frame = window.contentView!.bounds
            window.contentView!.addSubview(browser.webView)
            browser.onDocumentChange = { [unowned self] in documentChanges.append($0) }
            observation = browser.webView.observe(\.url, options: [.new]) { [unowned self] _, _ in urlObservations += 1 }
            browser.attach(page, load: false)
            browser.webView.loadHTMLString(html, baseURL: url)
        }

        /// Suspends until `condition` holds, so WebKit's main-queue callbacks can run in between.
        func wait(_ what: String, timeout: TimeInterval = 30, until condition: () -> Bool) async throws {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while !condition() {
                let w = browser.webView
                try #require(Date() < deadline, "timed out waiting for \(what): isLoading=\(w.isLoading) url=\(String(describing: w.url)) progress=\(w.estimatedProgress) refusal=\(String(describing: browser.refusal))")
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func ready() async throws {
            try await wait("the page to load and align") { page.alignment != nil }
        }

        /// Runs a function body in the bridge's world and returns its value.
        func js(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
            let value = try await browser.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient)
            return value is NSNull ? nil : value
        }

        func string(_ body: String, _ arguments: [String: Any] = [:]) async throws -> String {
            try #require(try await js(body, arguments) as? String)
        }
    }

    @Test func selectorsPreferIdsThenTestIdsThenPositions() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        let selector = { (query: String) in try await harness.string("return window.__cc.selectorFor(document.querySelector(q))", ["q": query]) }
        #expect(try await selector("#toolbar") == "#toolbar")
        #expect(try await selector("button.primary") == "[data-testid=\"save\"]")
        #expect(try await selector("#toolbar > button") == "#toolbar > button:nth-of-type(1)", "a sibling of the same tag forces a position")
        #expect(try await selector("main > section:nth-of-type(2) > p:nth-of-type(3)") == "html > body > main > section:nth-of-type(2) > p:nth-of-type(3)")
        #expect(try await selector("section > p") == "html > body > main > section:nth-of-type(1) > p", "an only child of its tag needs no position")
        for query in ["#toolbar", "button.primary", "#toolbar > button", "main > section:nth-of-type(2) > p:nth-of-type(3)", "nav > a:nth-of-type(2)"] {
            let found = try await selector(query)
            #expect(try await harness.js("return document.querySelectorAll(s).length", ["s": found]) as? Int == 1, "\(found) names one element")
            #expect(try await harness.js("return document.querySelector(s) === document.querySelector(q)", ["s": found, "q": query]) as? Bool == true)
        }
    }

    @Test func describeCapsTextAndHTMLAndMapsToSource() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        _ = try await harness.js("document.getElementById('long').textContent = 'x '.repeat(600); return true")
        let described = try #require(try await harness.js("return window.__cc.describeAt('#long')") as? [String: Any])
        #expect((described["text"] as? String)?.count == 500)
        #expect((described["html"] as? String)?.count ?? 0 <= 2048)
        #expect(described["tag"] as? String == "p")
        #expect((described["page"] as? [String: Any])?["w"] as? Double ?? 0 > 0, "layout ran, so the element has a size")

        // The first text node's DOM offset maps through the live page's serialised source to that text.
        try await harness.wait("the serialised source to settle") { harness.page.source.text.contains("x x x") }
        let target = try #require(try await harness.js("return window.__cc.describeAt('main > section:nth-of-type(2) > p:nth-of-type(3)')") as? [String: Any])
        let offset = try #require(target["textOffset"] as? Int)
        let alignment = try #require(harness.page.alignment)
        let projected = try #require(alignment.projected(NSRange(location: offset, length: 16)))
        let sourceRange = try #require(harness.page.projection.sourceRange(forProjected: projected))
        #expect((harness.page.source.text as NSString).substring(with: sourceRange) == "Target paragraph")
    }

    @Test func resolvesElementsAfterThePageChanges() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        let id = NoteID.new()
        let anchor = ElementAnchor(selector: "[data-testid=\"save\"]", tag: "button", text: "Save", html: "", rect: .init(x: 0, y: 0, w: 1, h: 1))
        var resolved = await harness.browser.resolve([(id, anchor)])
        #expect(resolved[id]?.bySelector?.tag == "button" && resolved[id]?.bySelector?.text == "Save")
        #expect(resolved[id]?.byText.isEmpty == true, "the selector hit is not repeated among the text hits")

        // Rename the test id: the selector misses, the same text is found under its new selector.
        _ = try await harness.js("const b = document.querySelector('[data-testid=save]'); b.removeAttribute('data-testid'); b.id = 'store'; return true")
        resolved = await harness.browser.resolve([(id, anchor)])
        #expect(resolved[id]?.bySelector == nil)
        #expect(resolved[id]?.byText.map(\.selector) == ["#store"])
        #expect(ReAnchorer.element(anchor, resolution: resolved[id]!, newHash: "new") == .movedNeedsReview(.element(ElementAnchor(
            selector: "#store", tag: "button", text: "Save", html: resolved[id]!.byText[0].html, rect: resolved[id]!.byText[0].rect, hash: "new"
        ))))
    }

    @Test func highlightsAddNoTextAndSerialisationLeavesTheOverlayOut() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        let before = try await harness.string("return document.documentElement.textContent")
        let id = NoteID.new()
        harness.page.elementHighlights = [ElementHighlight(id: id, selector: "#toolbar > button:nth-of-type(1)", tag: "button", text: "Cancel", color: .systemYellow, state: .draft, needsReview: true)]
        harness.browser.sync()
        try await harness.wait("the element rect") { harness.page.elementRects[id] != nil }
        #expect(try await harness.string("return document.documentElement.textContent") == before, "the overlay holds no text")
        #expect(try await harness.js("return document.querySelectorAll('gloss-overlay div').length") as? Int == 1)
        let serialised = try #require(try await harness.js("return window.__cc.serialize()") as? [String: Any])
        #expect((serialised["html"] as? String)?.contains("gloss-overlay") == false)
        #expect(try await harness.js("return document.querySelector('gloss-overlay') !== null") as? Bool == true, "the overlay is put back after serialising")
        #expect(harness.page.elementRects[id]?.width ?? 0 > 0)
    }

    @Test func pushStateBecomesANewDocument() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        _ = try await harness.js("history.pushState({}, '', '/next?tab=2'); return true")
        try await harness.wait("the route change") { !harness.documentChanges.isEmpty }
        #expect(harness.documentChanges == [URL(string: "http://fixture.test/next?tab=2")!])
        #expect(harness.browser.displayedURL == URL(string: "http://fixture.test/next?tab=2"))
        // WebKit's url KVO fires for pushState too (seen: 2 observations); the bridge's own report is the belt to its braces.
        #expect(harness.urlObservations >= 1)
    }

    @Test func pickModeReportsTheClickedElement() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        harness.page.isNoteMode = true
        harness.browser.sync()
        var picks = 0
        harness.page.onPick = { _ in picks += 1 }
        _ = try await harness.js("""
            const el = document.querySelector('[data-testid=save]'); const r = el.getBoundingClientRect();
            const at = { bubbles: true, cancelable: true, clientX: r.left + 2, clientY: r.top + 2 };
            el.dispatchEvent(new MouseEvent('mousedown', { ...at, button: 2 }));
            el.dispatchEvent(new MouseEvent('mousedown', { ...at, button: 0 }));
            el.dispatchEvent(new MouseEvent('click', at)); return true
            """)
        try await harness.wait("the pick") { harness.page.pendingPick != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(picks == 1, "one pick per left press: the right press and the click that follows post nothing")
        #expect(harness.page.pendingPick?.selector == "[data-testid=\"save\"]")
        #expect(harness.page.pendingPick?.text == "Save")
        #expect(harness.page.pendingPick?.pageRect.w ?? 0 > 0)
    }

    @Test func schemeHandlerServesOnlyServedPages() throws {
        final class Task: NSObject, WKURLSchemeTask {
            let request: URLRequest
            var error: (any Error)?
            var data = Data()
            init(_ url: String, mainDocument: String?) {
                var request = URLRequest(url: URL(string: url)!)
                request.mainDocumentURL = mainDocument.map { URL(string: $0)! }
                self.request = request
            }
            func didReceive(_ response: URLResponse) {}
            func didReceive(_ data: Data) { self.data.append(data) }
            func didFinish() {}
            func didFailWithError(_ error: any Error) { self.error = error }
        }
        let browser = WebBrowserController()
        let handler = HTMLSchemeHandler()
        handler.browser = browser

        let live = HTMLViewerController(livePage: URL(string: "https://example.com/")!)
        browser.attach(live, load: false)
        let fromLive = Task("gloss-html://doc/etc/hosts", mainDocument: "https://example.com/")
        handler.webView(browser.webView, start: fromLive)
        #expect((fromLive.error as? URLError)?.code == .noPermissionsToReadFile, "a live page cannot read files")

        let served = HTMLViewerController(source: TextEditorController(text: "<p>served</p>", languageName: "html"), documentPath: "/site/index.html") { _ in Data() }
        browser.attach(served, load: false)
        let own = Task("gloss-html://doc/site/index.html", mainDocument: "gloss-html://doc/site/index.html")
        handler.webView(browser.webView, start: own)
        #expect(own.error == nil && String(decoding: own.data, as: UTF8.self) == "<p>served</p>")
        let crossScheme = Task("gloss-html://doc/site/index.html", mainDocument: "https://example.com/")
        handler.webView(browser.webView, start: crossScheme)
        #expect((crossScheme.error as? URLError)?.code == .noPermissionsToReadFile, "a page from another scheme cannot read through ours")
    }
}
