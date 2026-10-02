import AppKit
import Core
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Viewers

struct ImageDecoderTests {
    /// 4×2 image: top row red, bottom row blue; left half opaque, right half green-tinted.
    func makeImage() -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext origin is bottom-left: y=0 is the bottom row.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 1, width: 4, height: 1))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 3, y: 1, width: 1, height: 1))
        return context.makeImage()!
    }

    enum Hue { case red, green, blue }

    /// Dominant channel, tolerant of color-space conversion.
    func hue(_ image: CGImage, x: Int, y: Int) -> Hue {
        let rep = NSBitmapImageRep(cgImage: image)
        let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
        if r > g && r > b { return .red }
        if g > r && g > b { return .green }
        return .blue
    }

    func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func decodesPNGAndCropsWithTopLeftOrigin() throws {
        let data = encode(makeImage(), type: .png)
        let decoded = try ImageDecoder.decode(data, fileName: "x.png")
        #expect(decoded.width == 4 && decoded.height == 2)
        #expect(decoded.hash == data.sha256Hex)
        // Top-left pixel is red (y=0 is the top in anchor space).
        #expect(hue(decoded.cgImage, x: 0, y: 0) == .red)
        let crop = try #require(ImageDecoder.crop(decoded, to: CGRect(x: 3, y: 0, width: 1, height: 1)))
        #expect(crop.width == 1 && crop.height == 1)
        #expect(hue(crop, x: 0, y: 0) == .green, "the top-right pixel is green")
        let bottom = try #require(ImageDecoder.crop(decoded, to: CGRect(x: 0, y: 1, width: 2, height: 1)))
        #expect(hue(bottom, x: 0, y: 0) == .blue, "the bottom row is blue")
        #expect(ImageDecoder.crop(decoded, to: CGRect(x: 10, y: 10, width: 5, height: 5)) == nil)
        let png = try #require(ImageDecoder.pngData(crop))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func appliesExifOrientation() throws {
        // Orientation 6 (.right): the stored image must be rotated 90° clockwise to display upright.
        let data = encode(makeImage(), type: .tiff, properties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue])
        let decoded = try ImageDecoder.decode(data, fileName: "x.tiff")
        #expect(decoded.width == 2 && decoded.height == 4, "dimensions swap for a rotated image")
        // After a clockwise turn the original top row (red, green at its right end) is the right column, green at the bottom.
        #expect(hue(decoded.cgImage, x: 1, y: 0) == .red)
        #expect(hue(decoded.cgImage, x: 1, y: 3) == .green)
        #expect(hue(decoded.cgImage, x: 0, y: 0) == .blue)
    }

    @Test func selectionAnchorUsesIntegralPixels() throws {
        let decoded = try ImageDecoder.decode(encode(makeImage(), type: .png), fileName: "x.png")
        let controller = ImageViewerController(image: decoded)
        controller.selection = CGRect(x: 0.6, y: 0.2, width: 2.4, height: 1.2)
        let anchor = try #require(controller.selectionAnchor)
        #expect(anchor.imageW == 4 && anchor.imageH == 2)
        #expect(anchor.x == 0 && anchor.y == 0 && anchor.w == 3 && anchor.h == 2)
        #expect(anchor.hash == decoded.hash)
        controller.selection = CGRect(x: 1, y: 1, width: 0.5, height: 0.5)
        #expect(controller.selectionAnchor == nil)
    }
}
