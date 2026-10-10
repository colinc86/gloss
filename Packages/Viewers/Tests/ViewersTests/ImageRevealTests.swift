import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

/// Revealing a note on a picture zoomed past the window scrolls its region into sight.
@MainActor
struct ImageRevealTests {
    @Test func aRevealedRegionIsScrolledIntoSight() async throws {
        let context = CGContext(data: nil, width: 2000, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1600))
        let controller = ImageViewerController(image: DecodedImage(cgImage: context.makeImage()!, hash: "h"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: ImageViewerView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        controller.zoom(.actualSize)
        // Until the zoom applies the whole picture fits: wait for actual size rather than for a fixed time.
        for _ in 0..<100 where abs(controller.magnification - 1) > 0.001 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(abs(controller.magnification - 1) < 0.001, "zoomed to actual size")
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let canvas = try #require(find(ImageCanvasView.self, in: hosting))
        let region = CGRect(x: 1850, y: 1450, width: 80, height: 60)
        #expect(!canvas.visibleRect.contains(region), "the corner starts out of sight")
        controller.reveal(region)
        for _ in 0..<100 where !canvas.visibleRect.contains(region) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(canvas.visibleRect.contains(region), "revealing it scrolls it into sight: \(canvas.visibleRect)")
    }
}
