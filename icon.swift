import AppKit
import CoreGraphics

// nordpiano app icon: dark rounded square, red accent bar, three piano keys.
func drawIcon(_ size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // background
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.addPath(bg)
    ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
    ctx.fillPath()

    // red accent bar, like the UI header stripe
    let bar = CGPath(roundedRect: CGRect(x: s * 0.14, y: s * 0.2, width: s * 0.09, height: s * 0.6),
                     cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil)
    ctx.addPath(bar)
    ctx.setFillColor(CGColor(red: 0.855, green: 0.0, blue: 0.07, alpha: 1))
    ctx.fillPath()

    // keys: two white keys with a black key rising between them
    let keyW = s * 0.17, keyH = s * 0.52, baseY = s * 0.2
    let x1 = s * 0.30, x2 = s * 0.52
    for x in [x1, x2] {
        let p = CGPath(roundedRect: CGRect(x: x, y: baseY, width: keyW, height: keyH),
                       cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil)
        ctx.addPath(p)
        ctx.setFillColor(.white)
        ctx.fillPath()
    }
    let black = CGPath(roundedRect: CGRect(x: x1 + keyW * 0.72, y: baseY + keyH * 0.32,
                                           width: keyW * 0.56, height: keyH * 0.68),
                       cornerWidth: s * 0.02, cornerHeight: s * 0.02, transform: nil)
    ctx.addPath(black)
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
    ctx.fillPath()

    // red dot marking the sampled note
    let dot = CGPath(ellipseIn: CGRect(x: x1 + keyW / 2 - s * 0.025, y: baseY + keyH - s * 0.09,
                                       width: s * 0.05, height: s * 0.05), transform: nil)
    ctx.addPath(dot)
    ctx.setFillColor(CGColor(red: 0.855, green: 0.0, blue: 0.07, alpha: 1))
    ctx.fillPath()

    img.unlockFocus()
    return img
}

let out = CommandLine.arguments[1] // iconset dir
let fm = FileManager.default
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let name = scale == 2 ? "icon_\(size)x\(size)@2x.png" : "icon_\(size)x\(size).png"
        let img = drawIcon(px)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
print("iconset written to \(out)")
