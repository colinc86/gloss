import Core
import Foundation
import CoreGraphics

/// Projects an existing page-element note onto the shared viewport without changing its portable DOM anchor.
nonisolated enum CapturedViewport {
    static func rect(for element: ElementAnchor, facts: JSONValue?, pixels: CGSize) -> CGRect? {
        guard let viewport = facts?["viewport"], let w = number(viewport["w"]), let h = number(viewport["h"]), w > 0, h > 0 else { return nil }
        let x = number(viewport["x"]) ?? 0, y = number(viewport["y"]) ?? 0
        var region = CGRect(x: element.rect.x,y: element.rect.y,width: element.rect.w,height: element.rect.h)
        if let crop = element.region, crop.imageW > 0, crop.imageH > 0 {
            region = CGRect(x: region.minX + Double(crop.x) / Double(crop.imageW) * region.width,
                            y: region.minY + Double(crop.y) / Double(crop.imageH) * region.height,
                            width: Double(crop.w) / Double(crop.imageW) * region.width,height: Double(crop.h) / Double(crop.imageH) * region.height)
        }
        let clipped = region.intersection(CGRect(x: x,y: y,width: w,height: h))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return CGRect(x: (clipped.minX-x)*pixels.width/w,y: (clipped.minY-y)*pixels.height/h,
                      width: clipped.width*pixels.width/w,height: clipped.height*pixels.height/h)
    }
    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let number): Double(number)
        case .double(let number): number.isFinite ? number : nil
        default: nil
        }
    }
}
