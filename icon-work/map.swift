import AppKit
import ImageIO
let path = CommandLine.arguments[1]
let scale = Double(CommandLine.arguments[2])! // px per svg unit
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = cg.width, h = cg.height
var data = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
func kind(_ svgx: Double, _ svgy: Double) -> Character {
    let x = Int(svgx * scale), y = Int(svgy * scale)
    guard x >= 0, y >= 0, x < w, y < h else { return " " }
    let i = (y * w + x) * 4
    let r = data[i], g = data[i+1]
    if r > 200 && g < 80 { return "R" }
    if r > 200 { return "W" }
    if r < 40 { return "." }
    return "?"
}
var svgy = 430.0
while svgy >= 90 {
    var line = String(format: "y=%3.0f ", svgy)
    var svgx = 150.0
    while svgx <= 250 { line.append(kind(svgx, svgy)); svgx += 4 }
    print(line)
    svgy -= 6
}
