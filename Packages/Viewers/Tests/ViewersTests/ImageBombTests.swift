import AppKit
import Foundation
import Testing
@testable import Viewers

struct ImageBombTests {
    static func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The size comes from the header and is checked before the pixels are decoded.
    @Test func moreThanTheLimitIsRefused() throws {
        let data = try Self.png(width: 200, height: 150)
        #expect(throws: ImageDecodeError.tooManyPixels(width: 200, height: 150)) {
            try ImageDecoder.decode(data, fileName: "big.png", maximumPixels: 10_000)
        }
        #expect(try ImageDecoder.decode(data, fileName: "big.png").width == 200)
        #expect(throws: ImageDecodeError.tooManyPixels(width: 1 << 32, height: 1 << 32)) {
            try ImageDecoder.checkPixels(width: 1 << 32, height: 1 << 32)
        }
    }

    @Test func anSVGDeclaringAHugeCanvasIsRefused() {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="50000" height="50000"><rect width="10" height="10"/></svg>"#.utf8)
        #expect(throws: ImageDecodeError.tooManyPixels(width: 50000, height: 50000)) {
            try ImageDecoder.decode(svg, fileName: "huge.svg")
        }
    }
}
