import AppKit
import Core
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image normalized to its upright pixel orientation. Anchors are stored in this pixel space.
public struct DecodedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let width: Int
    public let height: Int
    /// SHA-256 of the file bytes.
    public let hash: String

    public init(cgImage: CGImage, hash: String) {
        self.cgImage = cgImage
        width = cgImage.width
        height = cgImage.height
        self.hash = hash
    }
}

public enum ImageDecodeError: Error {
    case unreadable
}

public enum ImageDecoder {
    /// Decodes PNG, JPEG, HEIC, GIF (first frame), WebP, TIFF, BMP through ImageIO and SVG through AppKit at 1x.
    public static func decode(_ data: Data, fileName: String) throws -> DecodedImage {
        let hash = data.sha256Hex
        if fileName.lowercased().hasSuffix(".svg") {
            guard let image = NSImage(data: data), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ImageDecodeError.unreadable }
            return DecodedImage(cgImage: cgImage, hash: hash)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageDecodeError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return DecodedImage(cgImage: upright(raw, orientation: orientation), hash: hash)
    }

    /// Applies an EXIF orientation so the returned image's pixels are upright.
    static func upright(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }
        let width = image.width
        let height = image.height
        let swaps = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let outWidth = swaps ? height : width
        let outHeight = swaps ? width : height
        guard let context = CGContext(
            data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        // CoreGraphics rotates counter-clockwise with y up, so a visually clockwise turn is -π/2.
        let w = CGFloat(width)
        let h = CGFloat(height)
        let rotation: CGAffineTransform = switch orientation {
        case .up, .upMirrored: .identity
        case .down, .downMirrored: CGAffineTransform(translationX: w, y: h).rotated(by: .pi)
        case .left, .leftMirrored: CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2)
        case .right, .rightMirrored: CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2)
        }
        let mirrored = [.upMirrored, .downMirrored, .leftMirrored, .rightMirrored].contains(orientation)
        let flip = mirrored ? CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -CGFloat(outWidth), y: 0) : .identity
        let transform = rotation.concatenating(flip)
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Crops in pixel space with the origin at the top-left, matching `ImageAnchor`.
    public static func crop(_ image: DecodedImage, to rect: CGRect) -> CGImage? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !clamped.isEmpty else { return nil }
        // CGImage.cropping uses a top-left origin for the pixel grid, the same as our anchors.
        return image.cgImage.cropping(to: clamped)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
