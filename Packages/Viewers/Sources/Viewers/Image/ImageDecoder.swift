import AppKit
import Core
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image normalized to its upright pixel orientation. Anchors are stored in this pixel space.
public nonisolated struct DecodedImage: @unchecked Sendable {
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

public nonisolated enum ImageDecodeError: Error, Equatable {
    case unreadable
    /// More pixels than `ImageDecoder.maximumPixels`: a small file can declare a 50000×50000 image (10 GB decoded).
    case tooManyPixels(width: Int, height: Int)
}

public nonisolated enum ImageDecoder {
    /// 100 megapixels, 400 MB decoded: above any photo or screenshot, below what takes the app down.
    public static let maximumPixels = 100_000_000

    static func checkPixels(width: Int, height: Int, limit: Int = maximumPixels) throws {
        guard width > 0, height > 0 else { return }
        if width.multipliedReportingOverflow(by: height).overflow || width * height > limit {
            throw ImageDecodeError.tooManyPixels(width: width, height: height)
        }
    }

    /// Decodes PNG, JPEG, HEIC, GIF (first frame), WebP, TIFF, BMP, AVIF, JPEG XL, JPEG 2000 and icons (their largest
    /// size) through ImageIO, and SVG through AppKit at 1x.
    /// The size is checked from the header before any pixels are decoded, and the image is decoded once here (not
    /// on every redraw), so call it off the main actor.
    public static func decode(_ data: Data, fileName: String, maximumPixels limit: Int = maximumPixels) throws -> DecodedImage {
        let hash = data.sha256Hex
        if fileName.lowercased().hasSuffix(".svg") || isSVG(data) {
            guard let image = NSImage(data: data) else { throw ImageDecodeError.unreadable }
            try checkPixels(width: Int(image.size.width.rounded(.up)), height: Int(image.size.height.rounded(.up)), limit: limit)
            // At its own size, not the screen's scale, so the pixels match a region measured in its points.
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform.identity]) else { throw ImageDecodeError.unreadable }
            return DecodedImage(cgImage: cgImage, hash: hash)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ImageDecodeError.unreadable }
        let index = shownIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        if let width = properties?[kCGImagePropertyPixelWidth] as? Int, let height = properties?[kCGImagePropertyPixelHeight] as? Int {
            try checkPixels(width: width, height: height, limit: limit)
        }
        guard let raw = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ImageDecodeError.unreadable
        }
        try checkPixels(width: raw.width, height: raw.height, limit: limit)
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return DecodedImage(cgImage: upright(raw, orientation: orientation), hash: hash)
    }

    /// Icon formats: one file holds the same picture at several sizes.
    static let iconTypes: Set<String> = ["com.microsoft.ico", "com.apple.icns"]

    /// Which image of a file the viewer shows: an icon's largest size (its first is often 16x16), else the file's
    /// primary image. Sizes come from the headers; nothing is decoded.
    static func shownIndex(_ source: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return 0 }
        guard let type = CGImageSourceGetType(source) as String?, iconTypes.contains(type) else { return CGImageSourceGetPrimaryImageIndex(source) }
        func area(_ index: Int) -> Int {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return ((properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0) * ((properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0)
        }
        return (0..<count).max { area($0) < area($1) } ?? 0
    }

    /// Most frames an animated picture may have, and its frames' pixels all told as a multiple of `maximumPixels`.
    static let maximumFrames = 1000
    static let animationPixelBudget = 4
    /// Formats whose further images are an animation's frames rather than other pages or sizes.
    static let animatedTypes: Set<String> = ["com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics"]

    /// A picture fetched for rendered Markdown, decoded only when its size is safe: every image in a bitmap is
    /// measured from its header before any pixels, an SVG once parsed. A file of several pages or sizes (a TIFF, an
    /// icon) gives its first image, the one a crop is cut from; only an animation keeps every frame. Call it off the
    /// main actor; nil when it is unreadable or too big.
    public static func checkedImage(_ data: Data, maximumPixels limit: Int = maximumPixels) -> NSImage? {
        if isSVG(data) {
            guard let image = NSImage(data: data), (try? checkPixels(width: Int(image.size.width.rounded(.up)), height: Int(image.size.height.rounded(.up)), limit: limit)) != nil
            else { return nil }
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= maximumFrames else { return nil }
        var total = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (try? checkPixels(width: width, height: height, limit: limit)) != nil else { return nil }
            total += width * height
        }
        guard total <= limit * animationPixelBudget else { return nil }
        if count > 1, !animatedTypes.contains((CGImageSourceGetType(source) as String?) ?? "") {
            guard let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            // A bitmap of its own pixels, so the picture's pixel size is the page's, not the screen's.
            let rep = NSBitmapImageRep(cgImage: first)
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            return image
        }
        return NSImage(data: data)
    }

    /// An SVG named without its extension (a badge served from a web address): markup with an `<svg` element near
    /// its start. Bitmap formats are binary and never read as this.
    static func isSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(1024), as: UTF8.self)
        // A byte-order mark may come first.
        return head.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).hasPrefix("<") && head.contains("<svg")
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
