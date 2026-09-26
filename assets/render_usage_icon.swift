import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// UsageDesk's approved two-provider remaining-capacity mark.
let dark = CommandLine.arguments[1] == "dark"
let output = CommandLine.arguments[2]
let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setAllowsAntialiasing(true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

let tile = CGPath(roundedRect: CGRect(x: 48, y: 48, width: 928, height: 928),
                  cornerWidth: 208, cornerHeight: 208, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34,
              color: color(0, 0, 0, 0.16))
ctx.addPath(tile)
ctx.setFillColor(dark ? color(36, 38, 42) : color(250, 250, 248))
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(tile)
ctx.setStrokeColor(dark ? color(103, 106, 112) : color(215, 216, 214))
ctx.setLineWidth(4)
ctx.strokePath()

let center = CGPoint(x: 512, y: 512)
func arc(radius: CGFloat, width: CGFloat, start: CGFloat, end: CGFloat, ink: CGColor) {
    ctx.beginPath()
    ctx.addArc(center: center, radius: radius,
               startAngle: start * .pi / 180, endAngle: end * .pi / 180,
               clockwise: false)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

let track = dark ? color(91, 96, 103) : color(221, 224, 228)
let codex = dark ? color(245, 245, 242) : color(45, 49, 55)
let deepSeek = dark ? color(136, 161, 255) : color(54, 97, 220)

// Two open rings show remaining capacity for two independent providers.
arc(radius: 302, width: 82, start: -45, end: 225, ink: track)
arc(radius: 302, width: 82, start: -45, end: 140, ink: codex)
arc(radius: 189, width: 75, start: -45, end: 225, ink: track)
arc(radius: 189, width: 75, start: -45, end: 75, ink: deepSeek)

let image = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                   UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination))
