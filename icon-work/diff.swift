import AppKit
import ImageIO
func load(_ path: String, _ scale: Int) -> (UnsafeMutablePointer<UInt8>?, Int, Int) {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = cg.width, h = cg.height
    let data = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
    let ctx = CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (data, w, h)
}
// my render 2048px (4x) vs svg render 1024px (2x): sample my render at even pixels
let (a, aw, ah) = load("/tmp/nordpiano.iconset/icon_512x512@2x.png", 4)
let (b, bw, bh) = load("/tmp/icon.svg.png", 2)
var diff = 0, total = 0, maxd = 0
for y in 0..<bh {
    for x in 0..<bw {
        let ia = ((y * 2) * aw + x * 2) * 4
        let ib = (y * bw + x) * 4
        for c in 0..<3 {
            let d = abs(Int(a![ia + c]) - Int(b![ib + c]))
            if d > 12 { diff += 1; if d > maxd { maxd = d } }
            total += 1
        }
    }
}
print("channels differing: \(diff)/\(total), max delta \(maxd)")
