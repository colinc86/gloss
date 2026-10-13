import AppKit
import Foundation
import Testing
@testable import Viewers

@MainActor struct CapturedMarkdownTests {
    @Test func capturedWebImageUsesPackageBytesWithoutNetworkFallback() async throws {
        let source = "https://example.com/captured-review-image.png"
        StubImageProtocol.set(source,.init(status: 500))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 2,pixelsHigh: 2,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png,properties: [:]))
        let text = TextEditorController(text: "![Captured](\(source))")
        let loader = WebImageLoader(protocolClasses: [StubImageProtocol.self])
        let controller = MarkdownViewerController(source: text,webImageLoader: loader,usesCapturedImages: true,capturedImageLoader: { _ in png })
        for _ in 0..<100 where controller.imageData(for: source) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.imageData(for: source) == png)
        #expect(StubImageProtocol.requests(source) == 0)
    }
    @Test func capturedImagesIgnoreDiskAndCanRefreshWithoutSourceEdits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlossCapturedPictures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 2,pixelsHigh: 2,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0))
        let a = try #require(bitmap.representation(using: .png,properties: [:]))
        bitmap.setColor(.red,atX: 0,y: 0)
        let b = try #require(bitmap.representation(using: .png,properties: [:]))
        try a.write(to: folder.appendingPathComponent("picture.png"))
        let text = TextEditorController(text: "![Captured](picture.png)")
        let controller = MarkdownViewerController(source: text,baseURL: folder,usesCapturedImages: true,capturedImageLoader: { _ in b })
        #expect(controller.imageData(for: "picture.png") == nil)
        for _ in 0..<100 where controller.imageData(for: "picture.png") == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.imageData(for: "picture.png") == b)
        controller.loadImage = { _ in a }
        controller.invalidateCapturedImages()
        for _ in 0..<100 where controller.imageData(for: "picture.png") == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.imageData(for: "picture.png") == a)
    }
}
