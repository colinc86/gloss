import AppKit
import Foundation
import ImageIO
import Testing
@testable import Viewers

/// Stands in for the network: answers each URL from a table and counts what was asked for.
nonisolated final class StubImageProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func set(_ url: String, _ reply: Reply) {
        lock.withLock { replies[url] = reply }
    }

    static func requests(_ url: String) -> Int {
        lock.withLock { counts[url, default: 0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.lock.withLock {
            Self.counts[url.absoluteString, default: 0] += 1
            return Self.replies[url.absoluteString]
        } ?? Reply(status: 404)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if (300..<400).contains(reply.status), let location = reply.headers["Location"], let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct WebImageLoaderTests {
    static let badge = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="88" height="20"><rect width="51" height="20" fill="#555"/><rect x="51" width="37" height="20" fill="#f5b942"/></svg>"##.utf8)

    @Test func svgBadgesDecodeWithoutAnExtension() throws {
        let image = try #require(NSImage(data: Self.badge))
        #expect(image.size == CGSize(width: 88, height: 20))
        #expect(ImageDecoder.isSVG(Self.badge) && !ImageDecoder.isSVG(Data([0x89, 0x50, 0x4E, 0x47])))
        let decoded = try ImageDecoder.decode(Self.badge, fileName: "release")
        #expect(decoded.cgImage.width == 88 && decoded.cgImage.height == 20, "at its own size, as region notes measure it")
    }

    @Test func fetchesOnceCachesAndRemembersFailures() async {
        let loader = WebImageLoader(protocolClasses: [StubImageProtocol.self])
        let good = "https://img.example.com/once-\(UUID().uuidString)"
        let missing = "https://img.example.com/missing-\(UUID().uuidString)"
        StubImageProtocol.set(good, .init(headers: ["Content-Type": "image/svg+xml"], body: Self.badge))
        async let first = loader.data(for: good)
        async let second = loader.data(for: good)
        let (a, b) = await (first, second)
        #expect(a == Self.badge && b == Self.badge)
        #expect(await loader.data(for: good) == Self.badge)
        #expect(StubImageProtocol.requests(good) == 1, "asked for once, then served from memory")
        #expect(await loader.data(for: missing) == nil)
        #expect(await loader.data(for: missing) == nil)
        #expect(StubImageProtocol.requests(missing) == 1, "a failure is not asked for again at once")
    }

    @Test func refusesOtherSchemesRedirectsAndOversizedPictures() async {
        let loader = WebImageLoader(protocolClasses: [StubImageProtocol.self])
        #expect(await loader.data(for: "file:///etc/hosts") == nil)
        #expect(!WebImageLoader.handles("ftp://x/y.png") && !WebImageLoader.handles("pic.png") && WebImageLoader.handles("HTTP://x/y.png"))
        let redirect = "https://img.example.com/redirect-\(UUID().uuidString)"
        StubImageProtocol.set(redirect, .init(status: 302, headers: ["Location": "file:///etc/hosts"]))
        #expect(await loader.data(for: redirect) == nil)
        #expect(StubImageProtocol.requests("file:///etc/hosts") == 0)
        let huge = "https://img.example.com/huge-\(UUID().uuidString)"
        StubImageProtocol.set(huge, .init(headers: ["Content-Length": "\(WebImageLoader.maximumSize + 1)"], body: Data(count: 16)))
        #expect(await loader.data(for: huge) == nil)
        let sent = "https://img.example.com/agent-\(UUID().uuidString)"
        StubImageProtocol.set(sent, .init(body: Self.badge))
        #expect(await loader.data(for: sent) != nil)
    }

    /// A web picture in a document is fetched, drawn, and its bytes kept for a note's crop.
    @Test func theViewerDrawsWebPicturesAndKeepsTheirBytes() async throws {
        let loader = WebImageLoader(protocolClasses: [StubImageProtocol.self])
        let url = "https://img.example.com/badge-\(UUID().uuidString)"
        StubImageProtocol.set(url, .init(headers: ["Content-Type": "image/svg+xml"], body: Self.badge))
        let text = "Status: ![release](\(url)) and <img alt=\"again\" src=\"\(url)\" height=\"40\">\n"
        let markdown = MarkdownViewerController(source: TextEditorController(text: text), webImageLoader: loader)
        for _ in 0..<300 where Self.pictures(markdown.rendered).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(markdown.imageData(for: url) == Self.badge)
        let sizes = Self.pictures(markdown.rendered).map(\.naturalSize)
        #expect(sizes == [CGSize(width: 88, height: 20), CGSize(width: 176, height: 40)], "\(sizes)")
        #expect(StubImageProtocol.requests(url) == 1)
    }

    static func pictures(_ text: NSAttributedString) -> [FittedImageAttachment] {
        var found: [FittedImageAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? FittedImageAttachment { found.append(attachment) }
        }
        return found
    }

    @Test func picturesTooBigToDrawAreRefusedBeforeDecoding() async throws {
        // ImageIO itself refuses absurd bitmap headers; the size check is shown here with a lower limit.
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(ImageDecoder.checkedImage(png, maximumPixels: 32) == nil && ImageDecoder.checkedImage(png) != nil)
        let svgBomb = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="200000" height="200000"><rect width="1" height="1"/></svg>"#.utf8)
        #expect(ImageDecoder.checkedImage(svgBomb) == nil)
        #expect(ImageDecoder.checkedImage(Self.badge) != nil)
        let loader = WebImageLoader(protocolClasses: [StubImageProtocol.self])
        let url = "https://img.example.com/bomb-\(UUID().uuidString)"
        StubImageProtocol.set(url, .init(body: svgBomb))
        #expect(await MarkdownViewerController.load(url, web: loader, host: nil) == nil, "from the web")
        #expect(await MarkdownViewerController.load("bomb.svg", web: loader, host: { _ in svgBomb }) == nil, "from the document's host")
        let badge = Self.badge
        #expect(await MarkdownViewerController.load("badge.svg", web: loader, host: { _ in badge }) != nil)
    }

    @Test func aByteOrderMarkStillReadsAsSVG() {
        #expect(ImageDecoder.isSVG(Data([0xEF, 0xBB, 0xBF]) + Self.badge))
    }

    @Test func aCacheHitKeepsTheCache() async {
        let loader = WebImageLoader(protocolClasses: [StubImageProtocol.self], cacheLimit: Self.badge.count * 2)
        let first = "https://img.example.com/first-\(UUID().uuidString)", second = "https://img.example.com/second-\(UUID().uuidString)"
        StubImageProtocol.set(first, .init(body: Self.badge))
        StubImageProtocol.set(second, .init(body: Self.badge))
        _ = await loader.data(for: first)
        _ = await loader.data(for: second)
        _ = await loader.data(for: first)
        _ = await loader.data(for: second)
        #expect(StubImageProtocol.requests(first) == 1 && StubImageProtocol.requests(second) == 1, "a hit never empties a full cache")
    }

    /// Pictures arrive a few at a time and show as they come; one that never answers holds up nothing, and closing
    /// the document stops asking its host.
    @Test func fetchesRunTogetherAndStopWhenTheDocumentCloses() async throws {
        nonisolated final class Record: @unchecked Sendable {
            private let lock = NSLock()
            private var cancelled = false
            func cancel() { lock.withLock { cancelled = true } }
            var wasCancelled: Bool { lock.withLock { cancelled } }
        }
        let record = Record()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let text = ["dead", "a", "b", "c", "d", "e"].map { "![\($0)](\($0).png)" }.joined(separator: " ") + "\n"
        var markdown: MarkdownViewerController? = MarkdownViewerController(source: TextEditorController(text: text),
                                                                           webImageLoader: WebImageLoader(protocolClasses: [StubImageProtocol.self]))
        markdown?.loadImage = { source in
            guard source == "dead.png" else { return png }
            do { try await Task.sleep(for: .seconds(30)) } catch { record.cancel() }
            return nil
        }
        for _ in 0..<300 where Self.pictures(markdown?.rendered ?? NSAttributedString()).count < 5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Self.pictures(markdown?.rendered ?? NSAttributedString()).count == 5, "every live picture shows while one host is silent")
        markdown = nil
        for _ in 0..<300 where !record.wasCancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(record.wasCancelled)
    }

    @Test func webPicturesAreListedForFetchingWhereverTheDocumentIs() {
        let source = "![a](https://img.example.com/a.svg) ![b](local.png) <img src=\"http://img.example.com/b.png\">\n"
        let local = MarkdownRenderer.render(source, baseURL: FileManager.default.temporaryDirectory)
        #expect(local.unresolvedImages == ["https://img.example.com/a.svg", "http://img.example.com/b.png"])
        let remote = MarkdownRenderer.render(source)
        #expect(remote.unresolvedImages == ["https://img.example.com/a.svg", "local.png", "http://img.example.com/b.png"])
    }
}
