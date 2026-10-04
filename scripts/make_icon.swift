// Renders Grab's app icon at every size macOS wants and writes an .iconset.
// Usage: swift scripts/make_icon.swift <output.iconset> [logo.png]
//
// The look: an obsidian glass tile, Grab's viewfinder corners glowing in its warm-to-violet
// gradient, and a glass pointer reaching in to grab.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func gradient(_ c: [CGColor], _ l: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: c as CFArray, locations: l)! }

/// Apple-style continuous-corner tile (superellipse).
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, c = CGPoint(x: r.midX, y: r.midY)
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = c.x + a * (ct >= 0 ? 1 : -1) * pow(abs(ct), 2 / n)
        let y = c.y + b * (st >= 0 ? 1 : -1) * pow(abs(st), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

func brackets(_ frame: CGRect, arm: CGFloat, bend: CGFloat) -> CGPath {
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
    return path
}

func star(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    // Four-point sparkle with curved sides.
    let p = CGMutablePath()
    let k: CGFloat = 0.16
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * k, y: c.y - r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + r * k, y: c.y + r * k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * k, y: c.y + r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - r * k, y: c.y - r * k))
    return p
}

func pointer(_ tip: CGPoint, _ h: CGFloat) -> CGPath {
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.80), (0.205, 0.62), (0.34, 0.93), (0.47, 0.875), (0.335, 0.575), (0.6, 0.565)]
    let p = CGMutablePath()
    for (i, q) in pts.enumerated() {
        let pt = CGPoint(x: tip.x + q.0 * h, y: tip.y + q.1 * h)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

/// Fills a stroked path with a gradient, with a glow underneath.
func gradientStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, colors: [CGColor], from: CGPoint, to: CGPoint, glow: CGColor?, glowBlur: CGFloat) {
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    if let glow {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: glowBlur, color: glow)
        ctx.addPath(stroked)
        ctx.setFillColor(rgb(0x000000, 1))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(stroked)
    ctx.clip()
    let locs = (0..<colors.count).map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
    ctx.drawLinearGradient(gradient(colors, locs), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // A specular sheen along the top of each stroke.
    let sheen = gradient([rgb(0xFFFFFF, 0.45), rgb(0xFFFFFF, 0)], [0, 1])
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: from.y - width), end: CGPoint(x: 0, y: from.y + width * 3), options: [])
    ctx.restoreGState()
}


func draw(_ ctx: CGContext, _ s: CGFloat) {
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tile = squircle(body)

    // Shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.014), blur: s * 0.035, color: rgb(0x000000, 0.4))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0x101018))
    ctx.fillPath()
    ctx.restoreGState()

    // Obsidian body: graphite at the top to near-black, with a warm bloom behind the glyph.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x2E2D3A), rgb(0x17161F), rgb(0x0A0A10)], [0, 0.55, 1]),
                           start: CGPoint(x: body.midX, y: body.minY), end: CGPoint(x: body.midX, y: body.maxY), options: [])
    ctx.drawRadialGradient(gradient([rgb(0xEC4F7C, 0.30), rgb(0x7C5CFF, 0.12), rgb(0x7C5CFF, 0)], [0, 0.5, 1]),
                           startCenter: CGPoint(x: body.midX, y: body.midY + s * 0.03), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.midY + s * 0.03), endRadius: s * 0.43, options: [])
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: body.midX, y: body.minY), end: CGPoint(x: body.midX, y: body.minY + body.height * 0.45), options: [])
    ctx.restoreGState()

    // Edge: lit along the top, fading away at the bottom.
    ctx.saveGState()
    ctx.addPath(tile.copy(strokingWithWidth: max(1, s * 0.006), lineCap: .round, lineJoin: .round, miterLimit: 1))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0.04)], [0, 1]),
                           start: CGPoint(x: body.midX, y: body.minY), end: CGPoint(x: body.midX, y: body.maxY), options: [])
    ctx.restoreGState()

    // The viewfinder, glowing in Grab's gradient.
    let frame = CGRect(x: s * 0.25, y: s * 0.25, width: s * 0.5, height: s * 0.5)
    let warm: [CGColor] = [rgb(0xFFC069), rgb(0xFF6F61), rgb(0xF0457F), rgb(0x9D5BFF)]
    gradientStroke(ctx, brackets(frame, arm: s * 0.14, bend: s * 0.065), width: s * 0.068, colors: warm,
                   from: CGPoint(x: frame.minX, y: frame.minY), to: CGPoint(x: frame.maxX, y: frame.maxY),
                   glow: rgb(0xF0457F, 0.55), glowBlur: s * 0.05)

    // The pointer, in white glass.
    let tip = CGPoint(x: s * 0.457, y: s * 0.425)
    let h = s * 0.285
    let ptr = pointer(tip, h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.016), blur: s * 0.035, color: rgb(0x000000, 0.65))
    ctx.addPath(ptr)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(ptr)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xECE8F6)], [0, 1]), start: CGPoint(x: 0, y: tip.y), end: CGPoint(x: 0, y: tip.y + h), options: [])
    ctx.restoreGState()
    // A crisp hairline keeps the pointer readable at small sizes.
    ctx.saveGState()
    ctx.addPath(ptr)
    ctx.setStrokeColor(rgb(0x0C0B12, 0.55))
    ctx.setLineWidth(max(0.6, s * 0.006))
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // A small spark at the top-right corner: the moment of the grab.
    let sp = star(CGPoint(x: s * 0.705, y: s * 0.295), s * 0.04)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.025, color: rgb(0xFFF1D6, 0.95))
    ctx.addPath(sp)
    ctx.setFillColor(rgb(0xFFF6E4))
    ctx.fillPath()
    ctx.restoreGState()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(px))
    return ctx.makeImage()!
}

func write(_ img: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes { write(render(px), to: out.appendingPathComponent("\(name).png")) }
if CommandLine.arguments.count > 2 { write(render(1024), to: URL(fileURLWithPath: CommandLine.arguments[2])) }
print("Wrote \(out.path)")
