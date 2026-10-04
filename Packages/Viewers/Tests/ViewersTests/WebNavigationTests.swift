import Core
import Foundation
import Testing
import WebKit
@testable import Viewers

struct WebDocumentKeyTests {
    @Test func normalisesTheURLsThatNameOnePage() {
        let key = { WebDocumentKey.normalize(URL(string: $0)!) }
        #expect(key("HTTPS://Example.COM:443/docs/?q=1#top") == "https://example.com/docs/?q=1")
        #expect(key("http://localhost:3000") == "http://localhost:3000/")
        #expect(key("http://localhost:80/x") == "http://localhost/x")
        #expect(key("https://example.com:8443/") == "https://example.com:8443/", "a non-default port stays")
        #expect(key("http://localhost:3000/a?x=1") != key("http://localhost:3000/a?x=2"), "the query names a different page")
    }
}

struct WebProxyMapTests {
    let map = WebProxyMap(hostID: .local, tunnels: [3000: 51_000, 80: 51_001])

    @Test func loopbackPorts() {
        let port = { WebProxyMap.loopbackPort(of: URL(string: $0)!) }
        #expect(port("http://localhost:3000/") == 3000)
        #expect(port("http://127.0.0.1:5173/app") == 5173)
        #expect(port("http://[::1]:8080/") == 8080)
        #expect(port("http://0.0.0.0:4000/") == 4000)
        #expect(port("http://localhost/") == 80)
        #expect(port("https://localhost/") == 443)
        #expect(port("https://example.com/") == nil)
        #expect(port("http://localhost.example.com:3000/") == nil)
        #expect(port("file:///tmp/x") == nil)
    }

    @Test func proxiesAndMapsBack() {
        #expect(map.proxied(URL(string: "http://localhost:3000/dashboard?x=1#a")!) == URL(string: "http://127.0.0.1:51000/dashboard?x=1#a"))
        #expect(map.proxied(URL(string: "http://localhost/")!) == URL(string: "http://127.0.0.1:51001/"))
        #expect(map.proxied(URL(string: "http://localhost:9999/")!) == nil, "no tunnel for that port")
        #expect(map.proxied(URL(string: "https://example.com/")!) == nil)

        #expect(map.logical(URL(string: "http://127.0.0.1:51000/dashboard?x=1")!) == URL(string: "http://localhost:3000/dashboard?x=1"))
        #expect(map.logical(URL(string: "http://127.0.0.1:51001/")!) == URL(string: "http://localhost/"), "the default port is dropped again")
        #expect(map.logical(URL(string: "http://127.0.0.1:3000/")!) == nil, "a local port that is not a tunnel is this Mac's own server")
        #expect(map.isProxied(URL(string: "http://127.0.0.1:51000/")!))
        #expect(!map.isProxied(URL(string: "http://localhost:3000/")!))
    }
}

struct WebNavigationPolicyTests {
    let filePage = BrowserPage.file(path: "/home/colin/site/index.html")
    let livePage = BrowserPage.live(URL(string: "https://example.com/")!)
    let proxy = WebProxyMap(hostID: .local, tunnels: [3000: 51_000])

    func decide(_ url: String, type: WKNavigationType = .linkActivated, main: Bool = true, page: BrowserPage? = nil, proxy: WebProxyMap? = nil, local: Bool = true) -> WebNavigationPolicy.Decision {
        WebNavigationPolicy.decide(url: URL(string: url)!, type: type, isMainFrame: main, page: page ?? filePage, proxy: proxy, isLocalHost: local)
    }

    @Test func filePages() {
        #expect(decide("gloss-html://doc/home/colin/site/index.html", type: .other) == .allow, "the page's own load")
        #expect(decide("gloss-html://doc/home/colin/site/index.html#section") == .allow, "a same-page anchor")
        #expect(decide("gloss-html://doc/home/colin/site/index.html", type: .reload) == .allow)
        #expect(decide("gloss-html://doc/home/colin/site/about.html") == .openFile("/home/colin/site/about.html"), "a relative link WebKit resolved")
        #expect(decide("gloss-html://doc/home/colin/docs/PLAN.md") == .openFile("/home/colin/docs/PLAN.md"), "any file, not only pages")
        #expect(decide("gloss-html://other/x") == .cancel)
        #expect(decide("file:///Users/colin/notes.md") == .openFile("/Users/colin/notes.md"))
        #expect(decide("file:///Users/colin/notes.md", local: false) == .cancel, "a remote page cannot address this Mac")
    }

    @Test func livePagesAndTheWeb() {
        #expect(decide("https://example.com/docs/") == .allow)
        #expect(decide("https://example.com/docs/", page: livePage) == .allow)
        #expect(decide("gloss-html://doc/etc/passwd", page: livePage) == .cancel, "a live page cannot address files")
        #expect(decide("file:///etc/passwd", page: livePage) == .cancel)
        #expect(decide("about:blank", type: .other, page: livePage) == .allow)
        #expect(decide("mailto:colin@example.com") == .external(URL(string: "mailto:colin@example.com")!))
        #expect(decide("tel:+441234") == .external(URL(string: "tel:+441234")!))
        #expect(decide("javascript:alert(1)") == .cancel)
        #expect(decide("ftp://example.com/x") == .cancel)
        #expect(decide("javascript:alert(1)", main: false) == .allow, "frames load what they like")
    }

    @Test func loopbackAndTunnels() {
        #expect(decide("http://localhost:3000/") == .allow, "no proxy: this Mac's own server")
        let live = BrowserPage.live(URL(string: "http://localhost:3000/")!)
        #expect(decide("http://localhost:3000/app", page: live, proxy: proxy, local: false) == .tunnel(port: 3000, then: URL(string: "http://localhost:3000/app")!))
        #expect(decide("http://127.0.0.1:51000/app", page: live, proxy: proxy, local: false) == .allow, "a relative link on the proxied page")
        #expect(decide("http://localhost:5173/", page: live, proxy: proxy, local: false) == .tunnel(port: 5173, then: URL(string: "http://localhost:5173/")!), "another port needs its own tunnel")
        #expect(decide("https://example.com/", page: live, proxy: proxy, local: false) == .allow)
    }
}
