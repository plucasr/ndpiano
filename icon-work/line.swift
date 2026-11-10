import AppKit
import ImageIO
func load(_ path: String) -> (UnsafeMutablePointer<UInt8>, Int, Int) {
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
let (a, aw, ah) = load("/tmp/nordpiano.iconset/icon_512x512@2x.png")
let (b, bw, bh) = load("/tmp/icon.svg.png")
// x svg 190 -> my px 760, svgrender px 380; scan svg y 370..410
var svgy = 410.0
while svgy >= 368 {
    let ya = Int(svgy * 4), yb = Int(svgy * 2)
    let ia = (ya * aw + 760) * 4, ib = (yb * bw + 380) * 4
    print(String(format: "y=%5.1f  mine=%02X%02X%02X  svg=%02X%02X%02X", svgy,
        a[ia], a[ia+1], a[ia+2], b[ib], b[ib+1], b[ib+2]))
    svgy -= 1
}
