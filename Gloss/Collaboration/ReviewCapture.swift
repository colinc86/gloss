import Core
import Foundation
import AppKit
import CoreGraphics
import Viewers
import WebKit
import Remote

/// A single displayed document and the picture bytes it needs. References keep their original spelling and text
/// coordinates; they resolve inside the capture instead of contacting the original provider.
@MainActor enum ReviewCapture {
    static func saved(_ session: DocumentSession, provider: any FileSystemProvider, browser: WebBrowserController) async throws -> (GlossContent,JSONValue?) {
        if let html = session.html { return try await viewport(browser, expected: html) }
        let bytes = try await provider.read(session.path)
        let ext = (session.path as NSString).pathExtension
        guard session.kind == .markdown else { return (.file(bytes,ext: ext.isEmpty ? nil : ext),nil) }
        let sources = Set(EmbedScanner.embeds(in: TextEncoding.decode(bytes).text).map(\.source)).subtracting([EmbedScanner.mermaidSource])
        guard !sources.isEmpty else { return (.file(bytes,ext: "md"),nil) }
        var files = ["document.md": bytes]
        var images: [String: JSONValue] = [:]
        for source in sources.sorted() {
            let data: Data?
            if WebImageLoader.handles(source) { data = session.markdown?.imageData(for: source) }
            else {
                let decoded = source.removingPercentEncoding ?? source
                let path = decoded.hasPrefix("/") ? decoded : (PathUtilities.join(PathUtilities.parent(of: session.path),decoded) as NSString).standardizingPath
                let root = session.resourceRoot() ?? PathUtilities.parent(of: session.path)
                let local = session.hostID == .local
                let allowed = await Task.detached { HTMLViewerController.allowsResource(path,root: root,local: local) }.value
                guard allowed else { throw GlossPackageError.notAllowed("A picture is outside this document's resource folder.") }
                if let remote = provider as? SFTPFileSystem {
                    let resolved = try await remote.resolvedPath(path), base = try await remote.resolvedPath(root)
                    guard HTMLViewerController.allowsResource(resolved,root: base,local: false) else { throw GlossPackageError.notAllowed("A picture is outside this document's resource folder.") }
                }
                if let attributes = try? await provider.stat(path), attributes.kind == .file, attributes.size <= DocumentSession.mediaThreshold { data = try? await provider.read(path) }
                else { data = nil }
            }
            guard let data, !data.isEmpty, data.count <= DocumentSession.mediaThreshold else { throw GlossPackageError.notAllowed("Some content couldn't be included. Reload the document's pictures, then try sharing again.") }
            guard await Task.detached(operation: { ImageDecoder.checkedImage(data) != nil }).value else { throw GlossPackageError.notAllowed("A referenced picture is not a supported image.") }
            let path = "images/" + data.sha256Hex + ".png"
            files[path] = data; images[source] = .string(path)
        }
        let facts: JSONValue = .object(["document": .string("document.md"),"images": .object(images)])
        files["capture.json"] = try encode(facts)
        return (.folder(files),facts)
    }
    static func viewport(_ browser: WebBrowserController, expected: HTMLViewerController) async throws -> (GlossContent,JSONValue?) {
        let url = browser.displayedURL, path = browser.shownFilePath, host = browser.shownFileHost
        let version = expected.renderedVersion
        func checkSource() throws {
            guard browser.current === expected, browser.displayedURL == url, browser.shownFilePath == path,
                  browser.shownFileHost == host, expected.renderedVersion == version else {
                throw GlossPackageError.notAllowed("Open the original rendered document before capturing this review.")
            }
        }
        try checkSource()
        let zoom = max(browser.webView.magnification,0.01)
        let bounds = CGSize(width: browser.webView.bounds.width / zoom,height: browser.webView.bounds.height / zoom)
        let scroll = try await browser.webView.callAsyncJavaScript("return [window.scrollX, window.scrollY]",arguments: [:],in: nil,contentWorld: .defaultClient) as? [Double] ?? [0,0]
        try checkSource()
        guard let image = try await browser.snapshot(pageRect: ElementRect(x: scroll[0],y: scroll[1],w: bounds.width,h: bounds.height)) else { throw GlossPackageError.notAPackage("View the rendered page before sharing a viewport capture") }
        try checkSource()
        let facts: JSONValue = .object(["capture": .string("viewport"),"screenshot": .string("shot.png"),"viewport": .object(["x": .double(scroll[0]),"y": .double(scroll[1]),"w": .double(bounds.width),"h": .double(bounds.height)])])
        return (.folder(["shot.png": image.png,"capture.json": try encode(facts)]),facts)
    }
    private static func encode(_ facts: JSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(facts)
    }
    nonisolated static func read(_ session: GlossReviewSession, hash: String, kind: DocumentKind?, facts: JSONValue?) throws -> (Data,JSONValue?,[String: Data]) {
        guard let content = GlossPackage(url: session.url).contentURL(hash: hash) else { throw GlossPackageError.notAPackage("Missing content") }
        if try content.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { return (try session.readFile("content/" + content.lastPathComponent),facts,[:]) }
        let prefix = "content/" + hash + "/"
        let metadata = (try? session.readFile(prefix + "capture.json")).flatMap { try? JSONDecoder().decode(JSONValue.self,from: $0) } ?? facts
        let entry = metadata?["document"]?.stringValue ?? (kind == .web ? "shot.png" : "document.md")
        let bytes = try session.readFile(prefix + entry)
        var images: [String: Data] = [:]
        for (source,value) in metadata?["images"]?.objectValue ?? [:] {
            guard let path = value.stringValue else { continue }
            images[source] = try session.readFile(prefix + path)
        }
        return (bytes,metadata,images)
    }
}
