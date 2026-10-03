// Renders Grab's app icon at every size macOS wants and writes an .iconset.
// Usage: swift scripts/make_icon.swift <output.iconset>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: a
    )
}

func draw(_ ctx: CGContext, _ s: CGFloat) {
    // Work in top-left coordinates.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.32))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(0xEC4F7C))
    ctx.fillPath()
    ctx.restoreGState()

    // Warm-to-violet gradient body.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let body1 = CGGradient(colorsSpace: space, colors: [rgb(0xFFA24C), rgb(0xF2643E), rgb(0xE8457A), rgb(0x7457F6)] as CFArray,
                           locations: [0, 0.32, 0.6, 1])!
    ctx.drawLinearGradient(body1, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])

    // Soft light from the top-left, depth at the bottom-right.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.minX + body.width * 0.22, y: body.minY + body.height * 0.12), startRadius: 0,
                           endCenter: CGPoint(x: body.minX + body.width * 0.22, y: body.minY + body.height * 0.12), endRadius: body.width * 0.75, options: [])
    let shade = CGGradient(colorsSpace: space, colors: [rgb(0x2A1060, 0), rgb(0x2A1060, 0.28)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: body.midX, y: body.midY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: s * 0.003, dy: s * 0.003), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.28))
    ctx.setLineWidth(s * 0.004)
    ctx.strokePath()
    ctx.restoreGState()

    // Viewfinder corners.
    let frame = CGRect(x: s * 0.255, y: s * 0.255, width: s * 0.49, height: s * 0.49)
    let arm = s * 0.135
    let bend = s * 0.06
    let path = CGMutablePath()
    func corner(_ c: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
        path.move(to: CGPoint(x: c.x, y: c.y + dy * arm))
        path.addLine(to: CGPoint(x: c.x, y: c.y + dy * bend))
        path.addQuadCurve(to: CGPoint(x: c.x + dx * bend, y: c.y), control: c)
        path.addLine(to: CGPoint(x: c.x + dx * arm, y: c.y))
    }
    corner(CGPoint(x: frame.minX, y: frame.minY), 1, 1)
    corner(CGPoint(x: frame.maxX, y: frame.minY), -1, 1)
    corner(CGPoint(x: frame.minX, y: frame.maxY), 1, -1)
    corner(CGPoint(x: frame.maxX, y: frame.maxY), -1, -1)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.008), blur: s * 0.02, color: rgb(0x3A0F55, 0.35))
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(s * 0.056)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // The pointer, reaching in to grab.
    let h = s * 0.3
    let tip = CGPoint(x: s * 0.455, y: s * 0.43)
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.80), (0.205, 0.62), (0.34, 0.93), (0.47, 0.875), (0.335, 0.575), (0.6, 0.565)]
    let pointer = CGMutablePath()
    for (i, p) in pts.enumerated() {
        let q = CGPoint(x: tip.x + p.0 * h, y: tip.y + p.1 * h)
        if i == 0 { pointer.move(to: q) } else { pointer.addLine(to: q) }
    }
    pointer.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.014), blur: s * 0.03, color: rgb(0x240A40, 0.5))
    ctx.addPath(pointer)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(pointer)
    ctx.setStrokeColor(rgb(0x1E1030, 0.9))
    ctx.setLineWidth(max(1, s * 0.016))
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // A small spark where the pointer meets the frame.
    let spark = CGPoint(x: s * 0.68, y: s * 0.33)
    let r1 = s * 0.05, r2 = s * 0.012
    let star = CGMutablePath()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 - .pi / 2
        let r = i % 2 == 0 ? r1 : r2
        let p = CGPoint(x: spark.x + cos(a) * r, y: spark.y + sin(a) * r)
        if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
    }
    star.closeSubpath()
    ctx.addPath(star)
    ctx.setFillColor(rgb(0xFFF4D6))
    ctx.fillPath()
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(px))
    let img = ctx.makeImage()!
    let url = out.appendingPathComponent("\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
print("Wrote \(out.path)")
