import AppKit
import Core
import Testing
@testable import Viewers

/// Drawing a transparent picture never traps, even when AppKit asks for a rect outside it.
@MainActor
struct ImageCanvasDrawTests {
    @Test func aDirtyRectOutsideThePictureDrawsNothing() throws {
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try #require(context.makeImage())
        #expect(ImageCanvasView.hasAlpha(image))
        // The canvas holds its controller weakly: keep it alive or drawing returns before it starts.
        let controller = ImageViewerController(image: DecodedImage(cgImage: image, hash: "h"))
        let canvas = ImageCanvasView(controller: controller)
        let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // The intersection with the bounds is the null rect, whose edges are infinite.
        canvas.draw(NSRect(x: 500, y: 500, width: 10, height: 10))
        canvas.draw(canvas.bounds)
        withExtendedLifetime(controller) {}
    }
}
