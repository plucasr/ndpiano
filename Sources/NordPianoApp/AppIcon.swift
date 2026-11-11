import AppKit
import CoreGraphics

/// Same artwork as ../../icon.swift and icon-work/icon.svg (dark rounded square
/// `#121214`, red accent pillar `#E60000`, 3 white keys with rounded bottoms,
/// 2 black keys, red LED dot; viewBox 512, group offset translate(4,0)), rendered
/// at runtime so the Dock icon matches the bundle .icns everywhere.
func makeAppIcon(size: Int = 512) -> NSImage {
    drawIcon(size)
}

/// Faithful CoreGraphics port of the icon SVG. Coordinates are raw SVG units
/// mapped to image points via per-path transforms (top-down y flipped), NOT via
/// ctx.translate/scale: lockFocus() reuses pooled contexts that retain the CTM.
func drawIcon(_ size: Int) -> NSImage {
    let s = CGFloat(size) / 512
    var flip = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: 512 * s)
    var toDevice = CGAffineTransform(translationX: 4 * s, y: 0).concatenating(flip)

    let img = NSImage(size: NSSize(width: 512 * s, height: 512 * s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let dark = CGColor(srgbRed: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
    let red = CGColor(srgbRed: 0xE6 / 255, green: 0, blue: 0, alpha: 1)
    let keyWhite = CGColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF6 / 255, alpha: 1)

    // Opaque icon: full-square dark fill, then the SVG's rounded-square background.
    ctx.addRect(CGRect(x: 0, y: 0, width: 512 * s, height: 512 * s))
    ctx.setFillColor(dark)
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 32, y: 32, width: 448, height: 448),
                       cornerWidth: 96, cornerHeight: 96, transform: &flip))
    ctx.setFillColor(dark)
    ctx.fillPath()

    // red accent pillar
    ctx.addPath(CGPath(roundedRect: CGRect(x: 96, y: 112, width: 36, height: 288),
                       cornerWidth: 18, cornerHeight: 18, transform: &toDevice))
    ctx.setFillColor(red)
    ctx.fillPath()

    // white keys: square top, rounded bottom (r 18) — rect plus two corner circles
    for x: CGFloat in [160, 226, 292] {
        let p = CGMutablePath()
        p.addRect(CGRect(x: x, y: 112, width: 56, height: 271), transform: toDevice)            // 112...383
        p.addEllipse(in: CGRect(x: x, y: 383 - 36, width: 36, height: 36), transform: toDevice)      // bottom-left r18
        p.addEllipse(in: CGRect(x: x + 20, y: 383 - 36, width: 36, height: 36), transform: toDevice) // bottom-right r18
        ctx.addPath(p)
        ctx.setFillColor(keyWhite)
        ctx.fillPath()
    }

    // black keys
    for x: CGFloat in [200, 266] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 112, width: 32, height: 168),
                           cornerWidth: 6, cornerHeight: 6, transform: &toDevice))
        ctx.setFillColor(dark)
        ctx.fillPath()
    }

    // red LED dot on the first key
    ctx.addPath(CGPath(ellipseIn: CGRect(x: 188 - 8, y: 152 - 8, width: 16, height: 16),
                       transform: &toDevice))
    ctx.setFillColor(red)
    ctx.fillPath()

    img.unlockFocus()
    return img
}
