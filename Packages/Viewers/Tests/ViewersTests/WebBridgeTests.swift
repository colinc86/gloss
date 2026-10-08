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
            browser.onDocumentChange = { [unowned self] url, _, _ in documentChanges.append(url) }
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

    @Test func aPageTheViewLeftNeverTakesTheNextPagesState() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        try await harness.wait("the serialised source") { harness.page.source.text.contains("Target paragraph") }
        let before = harness.page.source.text
        // The view moves on by itself (a redirect, a route): the old page lets go before the new one loads.
        harness.browser.webView.loadHTMLString("<html><body><p>OTHER PAGE</p></body></html>", baseURL: URL(string: "http://other.test/")!)
        try await harness.wait("the new page to commit") { harness.documentChanges.contains(URL(string: "http://other.test/")!) }
        #expect(harness.browser.current == nil)
        try await harness.wait("the new page to finish") { !harness.browser.webView.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.page.source.text == before, "the old page's source is not replaced by the new page's DOM")

        // Attaching the old page again reloads it, since the view no longer shows it.
        harness.browser.attach(harness.page, load: false)
        #expect(harness.browser.current === harness.page)
        #expect(harness.browser.refusal == nil)
    }

    @Test func unloadStopsThePage() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        harness.browser.unload()
        #expect(harness.browser.current == nil)
        #expect(harness.browser.displayedURL == nil)
        try await harness.wait("about:blank") { harness.browser.webView.url?.absoluteString == "about:blank" }
        #expect(harness.documentChanges.allSatisfy { $0.scheme != "about" }, "a blank page is never a document")
    }

    @Test func elementsWithoutTextStillHaveAPlaceInTheText() async throws {
        let harness = Harness(html: "<html><body><p>Before</p><img id=\"logo\" src=\"data:,\"><p>After the logo</p></body></html>")
        try await harness.ready()
        let image = try #require(try await harness.js("return window.__cc.describeAt('#logo')") as? [String: Any])
        let offset = try #require(image["textOffset"] as? Int, "an image maps to the text that follows it")
        let text = try await harness.string("return document.documentElement.textContent")
        #expect((text as NSString).substring(with: NSRange(location: offset, length: 5)) == "After")
        let resolved = try #require(try await harness.js("return window.__cc.resolveElements([{ id: 'x', selector: '#logo', tag: 'img', text: '' }], true)") as? [[String: Any]])
        #expect((resolved.first?["bySelector"] as? [String: Any])?["textOffset"] as? Int == offset)
    }

    @Test func theBridgeLeavesThePagesOwnHighlightsAndDOMAlone() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        #expect(try await harness.js("return document.querySelector('gloss-overlay') === null") as? Bool == true, "no overlay without element notes")
        _ = try await harness.js("""
            const r = new Range(); r.selectNodeContents(document.querySelector('#long'));
            CSS.highlights.set('page-own', new Highlight(r)); return true
            """)
        _ = try await harness.js("window.__cc.highlight([{ name: 'gloss-note-0', start: 0, end: 3 }], ''); return true")
        _ = try await harness.js("window.__cc.highlight([], ''); return true")
        #expect(try await harness.js("return CSS.highlights.has('page-own')") as? Bool == true, "the page's own highlight survives ours being cleared")
        #expect(try await harness.js("return CSS.highlights.has('gloss-note-0')") as? Bool == false)
        // A page that replaces its adopted stylesheets gets ours back on the next paint.
        _ = try await harness.js("document.adoptedStyleSheets = []; window.__cc.highlight([], ''); return true")
        #expect(try await harness.js("return document.adoptedStyleSheets.length") as? Int == 1)

        // An orphaned note is drawn where its element last was; with nothing left to draw the overlay goes.
        let orphan: [String: Any] = ["id": "n1", "selector": "#gone", "tag": "button", "text": "", "color": "red", "fill": "rgba(0,0,0,0)",
                                     "state": "orphaned", "needsReview": false, "rect": ["x": 10, "y": 20, "w": 30, "h": 40]]
        let rects = try #require(try await harness.js("return window.__cc.highlightElements(list)", ["list": [orphan]]) as? [String: Any])
        #expect((rects["n1"] as? [String: Any])?["w"] as? Double == 30)
        #expect(try await harness.js("return document.querySelector('gloss-overlay div').style.borderStyle") as? String == "dashed")
        _ = try await harness.js("return window.__cc.highlightElements([])")
        #expect(try await harness.js("return document.querySelector('gloss-overlay') === null") as? Bool == true)
    }

    /// A note whose text was removed is a caret in the overlay, at the collapsed range, adding no text; drawn again
    /// without it, the caret and the overlay go. Driven through the page's own highlights, as the app does: the
    /// viewer re-applies them whenever the page settles, so a caret painted around it would be wiped.
    @Test func aRemovalPointIsACaretInTheOverlay() async throws {
        let harness = Harness(html: Self.fixture)
        try await harness.ready()
        let before = try await harness.string("return document.documentElement.textContent")
        let id = NoteID.new()
        // The live page's source is the DOM serialised once it settles, which can land after the page aligned; as the
        // app's session does, the point is placed again in the source as it is now.
        try await harness.wait("the caret's rect") {
            let offset = (harness.page.source.text as NSString).range(of: "Target paragraph").location
            if harness.page.source.highlights.first?.range.location != offset {
                harness.page.source.highlights = [TextHighlight(id: id, range: NSRange(location: offset, length: 0), color: .yellow, state: .draft)]
            }
            return harness.page.elementRects[id] != nil
        }
        let caret = try #require(try await harness.js("""
            const b = document.querySelector('gloss-overlay > div').getBoundingClientRect(); return { x: b.left, y: b.top, w: b.width, h: b.height }
            """) as? [String: Any])
        #expect(caret["w"] as? Double == 2)
        #expect((caret["h"] as? Double ?? 0) > 8)
        let word = try #require(try await harness.js("""
            const p = [...document.querySelectorAll('p')].find((e) => e.textContent.startsWith('Target paragraph'));
            const b = p.getBoundingClientRect(); return { x: b.left, y: b.top }
            """) as? [String: Any])
        #expect(abs((caret["x"] as? Double ?? 0) + 1 - (word["x"] as? Double ?? 0)) < 1.5, "at the start of the paragraph, not the end of the one before")
        #expect(abs((caret["y"] as? Double ?? 0) - (word["y"] as? Double ?? 0)) < 4)
        #expect(try await harness.js("return document.querySelectorAll('gloss-overlay > div').length") as? Int == 1)
        #expect(try await harness.js("return [...CSS.highlights.keys()].some((k) => k.startsWith('gloss-note-'))") as? Bool == false, "not a one-letter highlight")
        #expect(try await harness.string("return document.documentElement.textContent") == before, "the caret holds no text")
        harness.page.source.highlights = []
        try await harness.wait("the caret to go") { harness.page.elementRects[id] == nil }
        #expect(try await harness.js("return document.querySelector('gloss-overlay') === null") as? Bool == true)
    }

    /// A point in text WebKit gives no box (the whitespace between two paragraphs, the newline at the very end) still
    /// gets a caret: at the start of the next text that shows, else the end of the last one before it.
    @Test func aPointInUnboxedWhitespaceStillHasACaret() async throws {
        let harness = Harness(html: "<!doctype html><html><head><title>W</title></head><body><p>Alpha</p>\n<p>Beta</p>\n</body></html>\n")
        try await harness.ready()
        let between = NoteID.new(), end = NoteID.new()
        try await harness.wait("both carets") {
            let text = harness.page.source.text as NSString
            let found = text.range(of: "</p>\n<p>")
            guard found.location != NSNotFound else { return false }
            let gap = found.location + 4, last = text.length
            let wanted = [TextHighlight(id: between, range: NSRange(location: gap, length: 0), color: .yellow, state: .draft),
                          TextHighlight(id: end, range: NSRange(location: last, length: 0), color: .blue, state: .draft)]
            if harness.page.source.highlights != wanted { harness.page.source.highlights = wanted }
            return harness.page.elementRects[between] != nil && harness.page.elementRects[end] != nil
        }
        let carets = try #require(try await harness.js("""
            return [...document.querySelectorAll('gloss-overlay > div')].map((d) => { const b = d.getBoundingClientRect(); return { x: b.left, y: b.top, w: b.width } })
            """) as? [[String: Any]])
        try #require(carets.count == 2, "\(carets)")
        #expect(carets.allSatisfy { $0["w"] as? Double == 2 && $0["x"] as? Double ?? -1 >= 0 }, "\(carets)")
        let words = try #require(try await harness.js("""
            const r = document.createRange(), [a, b] = document.querySelectorAll('p');
            r.selectNodeContents(b); const beta = r.getClientRects()[0];
            r.selectNodeContents(a); const alpha = r.getClientRects()[0];
            return { betaX: beta.left, betaY: beta.top, betaRight: beta.right }
            """) as? [String: Any])
        let ys = carets.compactMap { $0["y"] as? Double }
        #expect(ys.allSatisfy { abs($0 - (words["betaY"] as? Double ?? 0)) < 4 }, "both sit on Beta's line: the start of the next text, the end of the last")
        let xs = carets.compactMap { $0["x"] as? Double }.sorted()
        #expect(abs(xs[0] + 1 - (words["betaX"] as? Double ?? 0)) < 1.5)
        #expect(abs(xs[1] + 1 - (words["betaRight"] as? Double ?? 0)) < 1.5)
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
        // Events a page script makes are untrusted: none of them picks, or cancels the mode.
        _ = try await harness.js("""
            const el = document.querySelector('[data-testid=save]'); const r = el.getBoundingClientRect();
            const at = { bubbles: true, cancelable: true, clientX: r.left + 2, clientY: r.top + 2 };
            el.dispatchEvent(new MouseEvent('mousedown', { ...at, button: 0 }));
            el.dispatchEvent(new MouseEvent('click', at));
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return true
            """)
        try await Task.sleep(for: .milliseconds(200))
        #expect(picks == 0 && harness.page.pendingPick == nil, "a synthetic press picks nothing")
        #expect(harness.page.isNoteMode, "a synthetic Escape doesn't leave note mode")
        _ = try await harness.js("""
            const r = document.querySelector('[data-testid=save]').getBoundingClientRect();
            return window.__cc.pickAt(r.left + 2, r.top + 2)
            """)
        try await harness.wait("the pick") { harness.page.pendingPick != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(picks == 1)
        #expect(harness.page.pendingPick?.selector == "[data-testid=\"save\"]")
        #expect(harness.page.pendingPick?.text == "Save")
        #expect(harness.page.pendingPick?.pageRect.w ?? 0 > 0)
    }

    /// A transparent PNG of the given size, as a data URI.
    static func png(_ width: Int, _ height: Int) -> String {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return "data:image/png;base64," + bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    static let pictures = """
    <!doctype html><html><body style="margin:0">
    <a href="/big" style="display:block;width:200px"><img id="thumb" src="\(png(200, 100))" style="display:block;width:200px;height:100px"></a>
    <img id="cover" src="\(png(200, 100))" style="display:block;width:100px;height:100px;object-fit:cover">
    <div class="card" style="width:220px;padding:10px"><img src="\(png(40, 40))" style="display:block;width:40px;height:40px"><p>Caption text</p></div>
    <button id="control" style="display:block"><img src="\(png(100, 60))" style="display:block;width:100px;height:60px"></button>
    <a id="avatar" href="/someone" style="display:block;width:32px"><img src="\(png(64, 64))" style="display:block;width:32px;height:32px"></a>
    </body></html>
    """

    func picturesReady(_ harness: Harness) async throws {
        try await harness.ready()
        for _ in 0..<150 {
            if try await harness.js("return [...document.images].every((i) => i.complete && i.naturalWidth > 0)") as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the pictures never loaded")
    }

    func center(_ harness: Harness, _ query: String) async throws -> (x: Double, y: Double) {
        let point = try #require(try await harness.js("const r = document.querySelector(q).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]", ["q": query]) as? [Double])
        return (point[0], point[1])
    }

    @Test func aClickOnALinkedPictureChoosesThePictureNotTheLink() async throws {
        let harness = Harness(html: Self.pictures)
        try await picturesReady(harness)
        let point = try await center(harness, "#thumb")
        #expect(try await harness.js("return window.__cc.dragAt(x, y, x, y)", ["x": point.x, "y": point.y]) as? Bool == true)
        try await harness.wait("the chosen picture") { harness.page.selectedPicture != nil }
        let chosen = try #require(harness.page.selectedPicture)
        #expect(chosen.selector == "#thumb" && chosen.tag == "img", "the picture, not the link around it")
        #expect(chosen.picture?.region == ImageAnchor(x: 0, y: 0, w: 200, h: 100, imageW: 200, imageH: 100), "a click takes all of it")
        #expect(chosen.picture?.source == "data:image/png (inline)", "an inline picture is named, not copied")
        #expect(chosen.picture?.pageRect.w == 200)
        #expect(harness.page.pendingPick == nil, "a chosen picture waits for Add Note")
        #expect(try await harness.js("return document.querySelector('gloss-overlay div[data-size]').getAttribute('data-size')") as? String == "200 × 100")

        // A picture in a control, or one the size of an icon, is the page's: its click goes to the button or link.
        for query in ["#control img", "#avatar img"] {
            let at = try await center(harness, query)
            #expect(try await harness.js("return window.__cc.dragAt(x, y, x, y)", ["x": at.x, "y": at.y]) as? Bool == false, "\(query) is left to the page")
        }
        try await harness.wait("the picture to be put away") { harness.page.selectedPicture == nil }
        _ = try await harness.js("window.__cc.dragAt(x, y, x, y); return true", ["x": point.x, "y": point.y])
        try await harness.wait("the chosen picture") { harness.page.selectedPicture != nil }

        // A press on text is the page's: no picture, and the chosen one is put away.
        let text = try await center(harness, ".card p")
        #expect(try await harness.js("return window.__cc.dragAt(x, y, x, y)", ["x": text.x, "y": text.y]) as? Bool == false)
        try await harness.wait("the picture to be put away") { harness.page.selectedPicture == nil }
        #expect(try await harness.js("return document.querySelector('gloss-overlay') === null") as? Bool == true)

        // The app clearing its selection takes the page's drawing away too.
        _ = try await harness.js("window.__cc.dragAt(x, y, x, y); return true", ["x": point.x, "y": point.y])
        try await harness.wait("the chosen picture") { harness.page.selectedPicture != nil }
        harness.page.selectedPicture = nil
        harness.browser.sync()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await harness.js("return document.querySelector('gloss-overlay') === null") as? Bool == true)
    }

    @Test func aDragChoosesARegionInThePicturesOwnPixels() async throws {
        let harness = Harness(html: Self.pictures)
        try await picturesReady(harness)
        let box = try #require(try await harness.js("const r = document.querySelector('#cover').getBoundingClientRect(); return [r.left, r.top]") as? [Double])
        // object-fit: cover draws the 200x100 picture at 100x100 points, its middle 100 pixels showing.
        _ = try await harness.js("return window.__cc.dragAt(x0, y0, x1, y1)", ["x0": box[0] + 10, "y0": box[1] + 10, "x1": box[0] + 60, "y1": box[1] + 60])
        try await harness.wait("the region") { harness.page.selectedPicture != nil }
        let picture = try #require(harness.page.selectedPicture?.picture)
        #expect(picture.region == ImageAnchor(x: 60, y: 10, w: 50, h: 50, imageW: 200, imageH: 100))
        #expect(picture.pageRect.w == 50 && picture.pageRect.h == 50)

        // A note on that region is drawn over that part of the picture.
        let item: [String: Any] = ["id": "n1", "selector": "#cover", "tag": "img", "text": "", "color": "red", "fill": "rgba(0,0,0,0)", "state": "draft",
                                   "needsReview": false, "region": ["x": 60, "y": 10, "w": 50, "h": 50, "imageW": 200, "imageH": 100]]
        let rects = try #require(try await harness.js("return window.__cc.highlightElements(list)", ["list": [item]]) as? [String: Any])
        let drawn = try #require(rects["n1"] as? [String: Any])
        #expect(drawn["x"] as? Double == box[0] + 10 && drawn["w"] as? Double == 50)

        // Found again, the picture says how big it is, so a resized picture's region can follow it; one that hasn't
        // loaded says nothing rather than 1x1.
        let anchor = ElementAnchor(selector: "#cover", tag: "img", text: "", html: "", rect: .init(x: 0, y: 0, w: 1, h: 1), region: picture.region)
        let id = NoteID.new()
        let resolved = await harness.browser.resolve([(id, anchor)])
        #expect(resolved[id]?.bySelector?.imageW == 200 && resolved[id]?.bySelector?.imageH == 100)
        _ = try await harness.js("document.querySelector('#cover').removeAttribute('src'); return true")
        let unloaded = await harness.browser.resolve([(id, anchor)])
        #expect(unloaded[id]?.bySelector?.tag == "img" && unloaded[id]?.bySelector?.imageW == nil)
    }

    @Test func aPictureThePageMovesUnderTheDragIsNotChosen() async throws {
        let harness = Harness(html: Self.pictures)
        try await picturesReady(harness)
        let box = try #require(try await harness.js("const r = document.querySelector('#thumb').getBoundingClientRect(); return [r.left, r.top]") as? [Double])
        // A carousel slides the picture along while the button is down: the drag was the page's.
        #expect(try await harness.js("""
            return window.__cc.dragAt(x0, y0, x1, y1, () => { document.querySelector('#thumb').style.marginLeft = '-60px'; })
            """, ["x0": box[0] + 100, "y0": box[1] + 20, "x1": box[0] + 40, "y1": box[1] + 60]) as? Bool == true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.page.selectedPicture == nil)
        #expect(try await harness.js("return document.querySelector('gloss-overlay') === null") as? Bool == true)
    }

    @Test func pickModeStepsToTheParentAndBack() async throws {
        let harness = Harness(html: Self.pictures)
        try await picturesReady(harness)
        harness.page.isNoteMode = true
        harness.browser.sync()
        let point = try await center(harness, ".card img")
        #expect(try await harness.js("return window.__cc.pickAt(x, y, [])", ["x": point.x, "y": point.y]) as? String == "div.card › img")
        try await harness.wait("the picture's pick") { harness.page.pendingPick != nil }
        #expect(harness.page.pendingPick?.tag == "img")
        #expect(harness.page.pendingPick?.picture?.region == ImageAnchor(x: 0, y: 0, w: 40, h: 40, imageW: 40, imageH: 40), "a picked picture is all of it")
        #expect(harness.page.selectedPicture == nil, "in note mode a pick goes straight to the editor")

        harness.page.pendingPick = nil
        #expect(try await harness.js("return window.__cc.pickAt(x, y, ['up'])", ["x": point.x, "y": point.y]) as? String == "div.card")
        try await harness.wait("the card's pick") { harness.page.pendingPick != nil }
        #expect(harness.page.pendingPick?.tag == "div" && harness.page.pendingPick?.picture == nil)

        harness.page.pendingPick = nil
        #expect(try await harness.js("return window.__cc.pickAt(x, y, ['up', 'down'])", ["x": point.x, "y": point.y]) as? String == "div.card › img", "down goes back the way it came")

        // The picture inside a link is preferred to the link.
        harness.page.pendingPick = nil
        let thumb = try await center(harness, "#thumb")
        _ = try await harness.js("return window.__cc.pickAt(x, y, [])", ["x": thumb.x, "y": thumb.y])
        try await harness.wait("the thumbnail's pick") { harness.page.pendingPick != nil }
        #expect(harness.page.pendingPick?.selector == "#thumb")
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
        let fromLive = Task("gloss-html://h_local/etc/hosts", mainDocument: "https://example.com/")
        handler.webView(browser.webView, start: fromLive)
        #expect((fromLive.error as? URLError)?.code == .noPermissionsToReadFile, "a live page cannot read files")

        let served = HTMLViewerController(source: TextEditorController(text: "<p>served</p>", languageName: "html"), documentPath: "/site/index.html") { _ in Data() }
        browser.attach(served, load: false)
        let own = Task("gloss-html://h_local/site/index.html", mainDocument: "gloss-html://h_local/site/index.html")
        handler.webView(browser.webView, start: own)
        #expect(own.error == nil && String(decoding: own.data, as: UTF8.self) == "<p>served</p>")
        let crossScheme = Task("gloss-html://h_local/site/index.html", mainDocument: "https://example.com/")
        handler.webView(browser.webView, start: crossScheme)
        #expect((crossScheme.error as? URLError)?.code == .noPermissionsToReadFile, "a page from another scheme cannot read through ours")
        let otherHost = Task("gloss-html://h_asus/site/index.html", mainDocument: "gloss-html://h_local/site/index.html")
        handler.webView(browser.webView, start: otherHost)
        #expect((otherHost.error as? URLError)?.code == .noPermissionsToReadFile, "a served page cannot reach another host's files")
    }

    /// On a remote host a link inside the site pointing out of it (to /etc, to ~/.ssh) is refused: the file's real
    /// place, links followed, must be inside the root's.
    @Test func aRemoteLinkOutOfTheSiteIsRefused() async throws {
        final class Task: NSObject, WKURLSchemeTask {
            let request: URLRequest
            var error: (any Error)?
            var data = Data()
            var finished = false
            init(_ url: String, mainDocument: String) {
                var request = URLRequest(url: URL(string: url)!)
                request.mainDocumentURL = URL(string: mainDocument)
                self.request = request
            }
            func didReceive(_ response: URLResponse) {}
            func didReceive(_ data: Data) { self.data.append(data) }
            func didFinish() { finished = true }
            func didFailWithError(_ error: any Error) { self.error = error; finished = true }
        }
        let browser = WebBrowserController()
        let handler = HTMLSchemeHandler()
        handler.browser = browser
        let page = HTMLViewerController(source: TextEditorController(text: "<p>x</p>", languageName: "html"), documentPath: "/site/index.html", resourceRoot: { "/site" }) { _ in Data("bytes".utf8) }
        page.hostID = HostID(rawValue: "h_asus")
        page.isLocal = false
        page.resolveRemotePath = { path in path == "/site/link.txt" ? "/etc/passwd" : path }
        browser.attach(page, load: false)

        let link = Task("gloss-html://h_asus/site/link.txt", mainDocument: "gloss-html://h_asus/site/index.html")
        handler.webView(browser.webView, start: link)
        let plain = Task("gloss-html://h_asus/site/style.css", mainDocument: "gloss-html://h_asus/site/index.html")
        handler.webView(browser.webView, start: plain)
        for _ in 0..<100 where !(link.finished && plain.finished) { try await _Concurrency.Task.sleep(for: .milliseconds(20)) }
        #expect((link.error as? URLError)?.code == .noPermissionsToReadFile, "the link leads out of the site")
        #expect(link.data.isEmpty)
        #expect(plain.error == nil && String(decoding: plain.data, as: UTF8.self) == "bytes")
    }

    @Test func schemePermissions() {
        let url = { URL(string: $0)! }
        let permits = { (u: String, main: String?, ref: String?) in
            HTMLSchemeHandler.permits(url: url(u), mainDocument: main.map(url), referrer: ref.map(url), servingHost: "h_local")
        }
        #expect(permits("gloss-html://h_local/a.css", "gloss-html://h_local/index.html", nil))
        #expect(permits("gloss-html://h_local/a.css", nil, "gloss-html://h_local/index.html"))
        #expect(!permits("gloss-html://h_local/a.css", nil, nil), "a request that says nothing about where it came from")
        #expect(!permits("gloss-html://h_local/a.css", "https://evil.example/", nil))
        #expect(!permits("gloss-html://h_local/a.css", "gloss-html://h_local/index.html", "https://evil.example/"), "an https frame inside a served page")
        #expect(!permits("gloss-html://h_asus/a.css", "gloss-html://h_asus/index.html", nil), "another host than the one shown")
    }
}
