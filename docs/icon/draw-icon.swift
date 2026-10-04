import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824 pt squircle centred in 1024, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(srgbRed: 0.20, green: 0.22, blue: 0.62, alpha: 1).setFill()
tilePath.fill()
ctx.restoreGState()
tilePath.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.30, blue: 0.86, alpha: 1),
                    NSColor(srgbRed: 0.13, green: 0.47, blue: 0.95, alpha: 1)])!.draw(in: tile, angle: -60)
// A gentle sheen from the top.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!.draw(in: tile, angle: -90)

// The page, tilted a little, with its own shadow.
ctx.saveGState()
ctx.translateBy(x: 500, y: 505)
ctx.rotate(by: -0.10)
let page = CGRect(x: -235, y: -300, width: 470, height: 600)
let pageShadow = NSShadow()
pageShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
pageShadow.shadowBlurRadius = 30
pageShadow.shadowOffset = NSSize(width: 0, height: -14)
ctx.saveGState()
pageShadow.set()
NSColor.white.setFill()
NSBezierPath(roundedRect: page, xRadius: 36, yRadius: 36).fill()
ctx.restoreGState()
// Text lines, one of them highlighted like a draft note.
let lineX = page.minX + 60
let widths: [CGFloat] = [300, 340, 250, 330, 280, 200]
for (index, width) in widths.enumerated() {
    let y = page.maxY - 110 - CGFloat(index) * 78
    if index == 2 {
        NSColor(srgbRed: 1.0, green: 0.80, blue: 0.10, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: CGRect(x: lineX - 18, y: y - 22, width: 350, height: 62), xRadius: 14, yRadius: 14).fill()
        NSColor(srgbRed: 1.0, green: 0.68, blue: 0.0, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: lineX - 46, y: y - 22, width: 12, height: 62), xRadius: 6, yRadius: 6).fill()
    }
    NSColor(white: index == 2 ? 0.20 : 0.78, alpha: 1).setFill()
    NSBezierPath(roundedRect: CGRect(x: lineX, y: y, width: width, height: 18), xRadius: 9, yRadius: 9).fill()
}
ctx.restoreGState()

// The send badge: a white disc with the accent paper plane, bottom right.
let badge = CGRect(x: 610, y: 168, width: 250, height: 250)
ctx.saveGState()
let badgeShadow = NSShadow()
badgeShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
badgeShadow.shadowBlurRadius = 24
badgeShadow.shadowOffset = NSSize(width: 0, height: -10)
badgeShadow.set()
NSColor.white.setFill()
NSBezierPath(ovalIn: badge).fill()
ctx.restoreGState()
if let plane = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 128, weight: .semibold).applying(.init(paletteColors: [NSColor(srgbRed: 0.18, green: 0.42, blue: 0.95, alpha: 1)]))) {
    let s = plane.size
    // Turned to fly up and to the right: sending, not landing.
    ctx.saveGState()
    ctx.translateBy(x: badge.midX, y: badge.midY)
    ctx.rotate(by: .pi)
    plane.draw(in: CGRect(x: -s.width / 2 - 4, y: -s.height / 2, width: s.width, height: s.height))
    ctx.restoreGState()
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
