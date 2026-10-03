// Renders Grab's 30-second promo: 1920×1080 at 60 fps, every frame drawn with SwiftUI
// from a timeline, plus a soundtrack synthesized to match. See render.sh.
//
//   GrabPromo out.mp4                 full render (needs ffmpeg)
//   GrabPromo --stills dir t1 t2 …    PNG stills at the given seconds, for checking
//   GrabPromo --audio out.wav         soundtrack only

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

let W: CGFloat = 1920
let H: CGFloat = 1080
let FPS = 60
let DURATION = 30.0

// MARK: - Motion helpers

@inline(__always) func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(max(x, a), b) }
/// 0 → 1 as `t` goes from `start` to `start + dur`.
func ramp(_ t: Double, _ start: Double, _ dur: Double) -> Double { clamp((t - start) / dur) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
func easeIn(_ x: Double) -> Double { pow(clamp(x), 3) }
func easeInOut(_ x: Double) -> Double { let x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
/// A damped spring: overshoots ~9% and settles by x = 1.
func spring(_ x: Double) -> Double {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    return 1 - exp(-6.2 * x) * cos(2 * .pi * 1.25 * x)
}
func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }
func lerp(_ a: CGRect, _ b: CGRect, _ x: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, x), y: lerp(a.minY, b.minY, x), width: lerp(a.width, b.width, x), height: lerp(a.height, b.height, x))
}
/// Fade in over `fin`, out over `fout`, inside [start, end].
func window(_ t: Double, _ start: Double, _ end: Double, fin: Double = 0.35, fout: Double = 0.35) -> Double {
    min(easeOut(ramp(t, start, fin)), 1 - easeIn(ramp(t, end - fout, fout)))
}

// MARK: - Color

struct RGB {
    var r, g, b: Double
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    func c(_ a: Double = 1) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    static func mix(_ a: RGB, _ b: RGB, _ x: Double) -> RGB {
        RGB(r: a.r + (b.r - a.r) * x, g: a.g + (b.g - a.g) * x, b: a.b + (b.b - a.b) * x)
    }
}

enum Mode: Int {
    case text, link, qr, file, image, color, code

    var pair: (RGB, RGB) {
        switch self {
        case .text, .code: (RGB(0x2F7BFF), RGB(0x22C3EE))
        case .link: (RGB(0x7C5CFF), RGB(0xD946EF))
        case .qr: (RGB(0x10B981), RGB(0x84CC16))
        case .file: (RGB(0x0EA5E9), RGB(0x6366F1))
        case .image: (RGB(0xFF7A1A), RGB(0xF43F5E))
        case .color: (RGB(0xF59E0B), RGB(0xEF4444))
        }
    }
    var colors: [Color] { [pair.0.c(), pair.1.c()] }
    var symbol: String {
        switch self {
        case .text: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .qr: "qrcode"
        case .file: "doc.fill"
        case .image: "photo"
        case .color: "eyedropper.halffull"
        }
    }
    var title: String {
        switch self {
        case .text: "Text"
        case .code: "Code"
        case .link: "Link"
        case .qr: "QR"
        case .file: "File"
        case .image: "Image"
        case .color: "Color"
        }
    }
}

let brand = [RGB(0xFF8A3D), RGB(0xEC4F7C), RGB(0x7C5CFF)]
let ink = RGB(0x07070C)

// MARK: - Text measuring (SwiftUI's system font is SF, same as NSFont's)

func textWidth(_ s: String, _ size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> CGFloat {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    return NSAttributedString(string: s, attributes: [.font: font]).size().width
}

extension View {
    /// Centers the view on a rectangle and gives it that size.
    func placed(_ r: CGRect) -> some View {
        frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
    }
    /// Puts the view's top-left corner at (x, y) in a top-leading ZStack.
    func at(_ x: CGFloat, _ y: CGFloat) -> some View {
        fixedSize().offset(x: x, y: y)
    }
}

// MARK: - Shapes

struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [CGPoint] = [(0, 0), (0, 16.6), (4, 12.8), (6.8, 19.2), (9.5, 18.1), (6.8, 11.9), (12.1, 11.9)].map { CGPoint(x: $0.0, y: $0.1) }
        let k = r.width / 12.1
        var p = Path()
        p.move(to: CGPoint(x: r.minX + pts[0].x * k, y: r.minY + pts[0].y * k))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: r.minX + q.x * k, y: r.minY + q.y * k)) }
        p.closeSubpath()
        return p
    }
}

struct Cursor: View {
    var scale: CGFloat = 1.9
    var body: some View {
        ZStack {
            ArrowShape().fill(Color.white)
            ArrowShape().stroke(Color.black, style: StrokeStyle(lineWidth: 1.3 / scale * 1.9, lineJoin: .round))
        }
        .frame(width: 12.1 * scale, height: 19.2 * scale)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

/// One L-shaped corner of the viewfinder, pointing into the top-left; rotate for the others.
struct CornerShape: Shape {
    var arm: CGFloat
    var radius: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + arm))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + arm, y: r.minY))
        return p
    }
}

struct SparkleShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let R = r.width / 2
        let k: CGFloat = 0.16
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - R))
        p.addQuadCurve(to: CGPoint(x: c.x + R, y: c.y), control: CGPoint(x: c.x + R * k, y: c.y - R * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + R), control: CGPoint(x: c.x + R * k, y: c.y + R * k))
        p.addQuadCurve(to: CGPoint(x: c.x - R, y: c.y), control: CGPoint(x: c.x - R * k, y: c.y + R * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - R), control: CGPoint(x: c.x - R * k, y: c.y - R * k))
        return p
    }
}

// MARK: - Logo (assembles itself from `build` seconds)

struct Logo: View {
    var size: CGFloat
    var build: Double

    var body: some View {
        let s = size
        let sq = spring(ramp(build, 0.1, 0.75))
        let corners = (0..<4).map { spring(ramp(build, 0.38 + Double($0) * 0.06, 0.7)) }
        let cur = spring(ramp(build, 0.72, 0.65))
        let spark = spring(ramp(build, 1.1, 0.55))
        ZStack {
            // Glow behind the tile.
            RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [RGB(0xFF9F6B).c(), RGB(0xE5577E).c(), RGB(0x7650E0).c()], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: s, height: s)
                .blur(radius: s * 0.22)
                .opacity(0.55 * sq)
            RoundedRectangle(cornerRadius: s * 0.235, style: .continuous)
                .fill(LinearGradient(colors: [RGB(0xFFB27F).c(), RGB(0xEC6A7E).c(), RGB(0xC2508F).c(), RGB(0x6E4FE0).c()],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.235, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                )
                .overlay(RoundedRectangle(cornerRadius: s * 0.235, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: s * 0.006))
                .frame(width: s, height: s)
                .scaleEffect(0.55 + 0.45 * sq)
                .opacity(clamp(sq * 1.6))
            ForEach(0..<4, id: \.self) { i in
                let rot = Double(i) * 90
                let spread = (1 - corners[i]) * Double(s) * 0.45
                CornerShape(arm: s * 0.17, radius: s * 0.075)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: s * 0.072, lineCap: .round, lineJoin: .round))
                    .frame(width: s * 0.56, height: s * 0.56)
                    .rotationEffect(.degrees(rot))
                    .offset(x: CGFloat(i == 1 || i == 2 ? spread : -spread), y: CGFloat(i >= 2 ? spread : -spread))
                    .opacity(clamp(corners[i] * 2))
            }
            Cursor(scale: s * 0.026)
                .rotationEffect(.degrees(-14 * (1 - cur)))
                .offset(x: s * 0.03, y: s * 0.04 - CGFloat(1 - cur) * s * 0.55)
                .opacity(clamp(cur * 2.5))
            SparkleShape()
                .fill(RGB(0xFFF4DA).c())
                .frame(width: s * 0.13, height: s * 0.13)
                .rotationEffect(.degrees(90 * (1 - spark)))
                .scaleEffect(spark)
                .offset(x: s * 0.2, y: -s * 0.2)
                .shadow(color: .white.opacity(0.8), radius: s * 0.03)
        }
        .frame(width: s, height: s)
    }
}

// MARK: - Grab's UI, at video scale

struct Keycap: View {
    var label: String
    var size: CGFloat = 72
    var width: CGFloat? = nil
    var pressed: Double = 0
    var lit: Double = 0
    var colors: [Color] = brand.map { $0.c() }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .blur(radius: size * 0.28)
                .opacity(lit * 0.75)
            shape.fill(Color.black.opacity(0.45)).offset(y: size * 0.06 * CGFloat(1 - pressed))
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.2 + 0.1 * lit), Color.white.opacity(0.08 + 0.06 * lit)], startPoint: .top, endPoint: .bottom))
                .background(shape.fill(ink.c(0.85)))
            shape.strokeBorder(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.2)
                .opacity(lit)
            shape.strokeBorder(Color.white.opacity(0.22 * (1 - lit)), lineWidth: 1.4)
            Text(label)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.75 + 0.25 * lit))
        }
        .frame(width: width ?? size, height: size)
        .offset(y: size * 0.06 * CGFloat(pressed))
        .scaleEffect(1 - 0.05 * pressed)
    }
}

/// The border Grab draws around what it will copy, with its sweeping sheen.
struct GrabBorder: View {
    var rect: CGRect
    var colors: [Color]
    var t: Double
    var flash: Double = 0
    var radius: CGFloat = 12
    var opacity: Double = 1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let grad = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack {
            shape.fill(LinearGradient(colors: colors.map { $0.opacity(0.13) }, startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.stroke(grad, lineWidth: 7).blur(radius: 11).opacity(0.9)
            shape.stroke(grad, lineWidth: 3)
            shape.stroke(AngularGradient(gradient: Gradient(stops: [
                .init(color: .clear, location: 0), .init(color: .clear, location: 0.6),
                .init(color: .white.opacity(0.95), location: 0.78), .init(color: .clear, location: 0.96),
            ]), center: .center, angle: .degrees(-t * 220)), lineWidth: 3)
            shape.fill(Color.white.opacity(0.45 * flash))
        }
        .placed(rect)
        .opacity(opacity)
    }
}

/// The dim around the target.
struct Spotlight: View {
    var hole: CGRect
    var radius: CGFloat = 12
    var amount: Double
    var body: some View {
        Path { p in
            p.addRect(CGRect(x: -50, y: -50, width: W + 100, height: H + 100))
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        .fill(Color.black.opacity(0.42 * amount), style: FillStyle(eoFill: true))
    }
}

struct ScopeTag: View {
    var label: String
    var colors: [Color]
    var dots: Int = 4
    var index: Int = 1
    var body: some View {
        HStack(spacing: 9) {
            Text(label).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            HStack(spacing: 4) {
                ForEach(0..<dots, id: \.self) { i in
                    Capsule().fill(.white.opacity(i == index ? 0.95 : 0.45)).frame(width: i == index ? 14 : 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)))
        .shadow(color: (colors.first ?? .blue).opacity(0.5), radius: 10, y: 3)
    }
}

enum PreviewContent {
    case text(String, String)
    case link(String, String)
    case image(String, String)
    case qr(String)
    case color(RGB, String)
    case file(String, String)
    case snippet([String], String)
}

struct ModeBar: View {
    var modes: [Mode]
    var selected: Mode
    var body: some View {
        HStack(spacing: 3) {
            ForEach(modes, id: \.rawValue) { m in
                let on = m == selected
                HStack(spacing: 8) {
                    Image(systemName: m.symbol).font(.system(size: 17, weight: .semibold)).frame(width: 22)
                    if on { Text(m.title).font(.system(size: 18, weight: .semibold, design: .rounded)) }
                }
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.5))
                .padding(.horizontal, on ? 15 : 11)
                .frame(height: 40)
                .background {
                    if on {
                        Capsule().fill(LinearGradient(colors: m.colors, startPoint: .leading, endPoint: .trailing))
                            .shadow(color: m.colors[0].opacity(0.5), radius: 9, y: 3)
                    }
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

struct HUDCard<Content: View>: View {
    var width: CGFloat = 480
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 15) { content }
            .padding(18)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [RGB(0x23232B).c(0.97), RGB(0x16161C).c(0.97)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
    }
}

struct Badge: View {
    var symbol: String
    var colors: [Color]
    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 44, height: 44)
            .overlay(Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white))
    }
}

struct PreviewRow: View {
    var content: PreviewContent
    var mode: Mode

    func lines(_ a: String, _ b: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(a).font(mono ? .system(size: 21, weight: .semibold, design: .monospaced) : .system(size: 20, weight: .medium))
                .foregroundStyle(.white).lineLimit(1)
            Text(b).font(.system(size: 15.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            switch content {
            case .text(let a, let b):
                lines(a, b)
            case .link(let host, let path):
                Badge(symbol: "globe", colors: mode.colors)
                lines(host, path)
            case .image(let a, let b):
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.clear)
                    .frame(width: 66, height: 44)
                    .overlay(Sunset().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
                lines(a, b, mono: true)
            case .qr(let payload):
                Badge(symbol: "qrcode", colors: mode.colors)
                lines(payload, "QR payload")
            case .color(let c, let hex):
                Circle().fill(c.c()).frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 2).padding(3))
                lines(hex, "rgb \(Int(c.r * 255)) \(Int(c.g * 255)) \(Int(c.b * 255))", mono: true)
            case .file(let a, let b):
                PDFIcon().frame(width: 40, height: 48)
                lines(a, b)
            case .snippet(let code, let meta):
                VStack(alignment: .leading, spacing: 7) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(code.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 15.5, design: .monospaced)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                    Text(meta).font(.system(size: 15.5)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct FormatBar: View {
    var formats: [String]
    var selected: Int
    var colors: [Color]
    var body: some View {
        HStack(spacing: 8) {
            Keycap(label: "⇥", size: 30)
            HStack(spacing: 2) {
                ForEach(Array(formats.enumerated()), id: \.offset) { i, f in
                    Text(f)
                        .font(.system(size: 15.5, weight: i == selected ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(i == selected ? Color.white : Color.white.opacity(0.55))
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background { if i == selected { Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)) } }
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.white.opacity(0.07)))
        }
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.27, y: r.minY + r.height * 0.53))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.69))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.35))
        return p
    }
}

struct ToastCard: View {
    var title: String
    var detail: String
    var colors: [Color]
    var progress: Double

    var body: some View {
        HUDCard(width: 480) {
            HStack(spacing: 15) {
                ZStack {
                    Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: colors[0].opacity(0.6), radius: 10, y: 3)
                    CheckShape().trim(from: 0, to: easeOut(ramp(progress, 0.05, 0.35)))
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                .frame(width: 46, height: 46)
                .scaleEffect(0.6 + 0.4 * spring(ramp(progress, 0, 0.6)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    Text(detail).font(.system(size: 16.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Illustrations

struct Sunset: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                LinearGradient(colors: [RGB(0x3B2A8F).c(), RGB(0xC2508F).c(), RGB(0xFF8A5B).c(), RGB(0xFFC58A).c()], startPoint: .top, endPoint: .bottom)
                Circle().fill(RGB(0xFFE6B0).c()).frame(width: w * 0.3, height: w * 0.3).position(x: w * 0.62, y: h * 0.58)
                    .shadow(color: RGB(0xFFD28A).c(0.9), radius: w * 0.06)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.7))
                    p.addLine(to: CGPoint(x: w * 0.22, y: h * 0.48))
                    p.addLine(to: CGPoint(x: w * 0.42, y: h * 0.66))
                    p.addLine(to: CGPoint(x: w * 0.6, y: h * 0.52))
                    p.addLine(to: CGPoint(x: w, y: h * 0.76))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                }
                .fill(RGB(0x5A2D7A).c(0.92))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.84))
                    p.addLine(to: CGPoint(x: w * 0.3, y: h * 0.7))
                    p.addLine(to: CGPoint(x: w * 0.55, y: h * 0.82))
                    p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.68))
                    p.addLine(to: CGPoint(x: w, y: h * 0.8))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                }
                .fill(RGB(0x2A1747).c())
            }
        }
    }
}

struct PDFIcon: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: w * 0.08))
                    p.addQuadCurve(to: CGPoint(x: w * 0.08, y: 0), control: .zero)
                    p.addLine(to: CGPoint(x: w * 0.68, y: 0))
                    p.addLine(to: CGPoint(x: w, y: w * 0.32))
                    p.addLine(to: CGPoint(x: w, y: h - w * 0.08))
                    p.addQuadCurve(to: CGPoint(x: w * 0.92, y: h), control: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w * 0.08, y: h))
                    p.addQuadCurve(to: CGPoint(x: 0, y: h - w * 0.08), control: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.68, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.68, y: w * 0.32))
                    p.addLine(to: CGPoint(x: w, y: w * 0.32))
                }
                .fill(Color(white: 0.85))
                Text("PDF").font(.system(size: w * 0.26, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, w * 0.07).padding(.vertical, w * 0.03)
                    .background(RoundedRectangle(cornerRadius: w * 0.06).fill(RGB(0xE5484D).c()))
                    .position(x: w * 0.5, y: h * 0.66)
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(Color(white: 0.85)).frame(width: w * (i == 2 ? 0.35 : 0.55), height: w * 0.05)
                        .position(x: w * (i == 2 ? 0.32 : 0.42), y: h * (0.2 + Double(i) * 0.1))
                }
            }
        }
    }
}

let qrImage: CGImage = {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data("https://grab.app/beta".utf8)
    f.correctionLevel = "M"
    let img = f.outputImage!
    return CIContext().createCGImage(img, from: img.extent)!
}()

struct WindowChrome<Content: View>: View {
    var rect: CGRect
    var dark = false
    var title: String
    var urlBar = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(dark ? RGB(0x1A1B22).c() : RGB(0xFBFAF7).c())
            // Title bar.
            Rectangle().fill(dark ? RGB(0x24252E).c() : RGB(0xF1EFEA).c()).frame(height: 56)
            Rectangle().fill(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)).frame(height: 1).offset(y: 56)
            HStack(spacing: 9) {
                Circle().fill(RGB(0xFF5F57).c())
                Circle().fill(RGB(0xFEBC2E).c())
                Circle().fill(RGB(0x28C840).c())
            }
            .frame(width: 70, height: 15)
            .offset(x: 22, y: 21)
            Group {
                if urlBar {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill").font(.system(size: 13, weight: .semibold))
                        Text(title).font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(Color.black.opacity(0.55))
                    .padding(.horizontal, 22).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.06)))
                } else {
                    Text(title).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
                }
            }
            .frame(width: rect.width, height: 56)
            content
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.12 : 0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 50, y: 30)
        .position(x: rect.midX, y: rect.midY)
    }
}

// MARK: - Background

struct Background: View {
    var t: Double
    var accent: RGB

    var body: some View {
        ZStack {
            ink.c()
            blob(brand[0], 1100, x: 280 + 90 * sin(t * 0.23), y: 180 + 70 * cos(t * 0.19), a: 0.30)
            blob(brand[2], 1200, x: 1700 + 80 * cos(t * 0.21), y: 900 + 60 * sin(t * 0.17), a: 0.32)
            blob(brand[1], 900, x: 1550 + 70 * sin(t * 0.13 + 1), y: 140 + 50 * cos(t * 0.25), a: 0.20)
            blob(accent, 1000, x: 420 + 60 * cos(t * 0.15), y: 980 + 40 * sin(t * 0.2), a: 0.22)
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 500, endRadius: 1250)
        }
        .frame(width: W, height: H)
    }

    func blob(_ c: RGB, _ size: CGFloat, x: Double, y: Double, a: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [c.c(a), c.c(a * 0.45), c.c(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .position(x: x, y: y)
    }
}

// MARK: - Captions

struct Caption: View {
    var headline: String
    var sub: String?
    var t: Double
    var start: Double
    var end: Double
    var y: CGFloat = 952

    var body: some View {
        let a = window(t, start, end, fin: 0.5, fout: 0.4)
        let rise = easeOut(ramp(t, start, 0.6))
        VStack(spacing: 12) {
            Text(headline).font(.system(size: 60, weight: .bold)).foregroundStyle(.white)
                .tracking(-0.8)
            if let sub {
                Text(sub).font(.system(size: 27, weight: .medium)).foregroundStyle(.white.opacity(0.62))
            }
        }
        .multilineTextAlignment(.center)
        .offset(y: CGFloat(1 - rise) * 22)
        .blur(radius: CGFloat(1 - a) * 8)
        .opacity(a)
        .position(x: W / 2, y: y)
    }
}

/// Wraps a scene: fades and scales in, blurs and fades out.
struct SceneFX: ViewModifier {
    var t: Double
    var start: Double
    var end: Double
    func body(content: Content) -> some View {
        let i = easeOut(ramp(t, start, 0.55))
        let o = easeIn(ramp(t, end - 0.45, 0.45))
        content
            .scaleEffect(1.035 - 0.035 * i - 0.025 * o)
            .blur(radius: CGFloat((1 - i) * 14 + o * 14))
            .opacity(min(i, 1 - o))
    }
}

// MARK: - Scene 1 · Intro (0 – 3.4)

struct IntroScene: View {
    var t: Double
    var body: some View {
        let out = easeIn(ramp(t, 2.95, 0.45))
        ZStack {
            Logo(size: 230, build: t)
                .position(x: W / 2, y: 420)
                .scaleEffect(1 + out * 0.25, anchor: UnitPoint(x: 0.5, y: 420 / H))
            Text("Grab")
                .font(.system(size: 132, weight: .bold, design: .rounded))
                .tracking(-2)
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                .opacity(easeOut(ramp(t, 1.05, 0.6)))
                .offset(y: CGFloat(1 - easeOut(ramp(t, 1.05, 0.7))) * 36)
                .blur(radius: CGFloat(1 - easeOut(ramp(t, 1.05, 0.5))) * 10)
                .position(x: W / 2, y: 660)
            Text("Copy anything. Just point at it.")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .opacity(easeOut(ramp(t, 1.6, 0.6)))
                .offset(y: CGFloat(1 - easeOut(ramp(t, 1.6, 0.7))) * 24)
                .position(x: W / 2, y: 770)
        }
        .frame(width: W, height: H)
        .opacity(1 - out)
        .blur(radius: CGFloat(out * 12))
    }
}

// MARK: - Scene 2 · How it works (3.4 – 8.6)

enum S2 {
    static let win = CGRect(x: 330, y: 92, width: 1260, height: 760)
    static let x0: CGFloat = 400
    static let p1Top: CGFloat = 336
    static let lineH: CGFloat = 40
    static let p1 = [
        "Great work rarely comes from doing more. It comes",
        "from removing everything that isn't the work, until",
        "what's left is simple, clear and honest.",
    ]
    static let p2 = [
        "Start each morning with one question: what would",
        "make today count? Then protect that answer like it's",
        "the only thing on your calendar.",
    ]
    static let p1Rect: CGRect = {
        let w = p1.map { textWidth($0, 25) }.max() ?? 600
        return CGRect(x: x0 - 12, y: p1Top - 6, width: w + 24, height: CGFloat(p1.count) * lineH + 10)
    }()
    static let menuIcon = CGPoint(x: W - 236, y: 19)
}

struct MenuBar: View {
    var t: Double
    var lit: Double
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.35)).frame(width: W, height: 38)
            HStack(spacing: 30) {
                Text("Reader").font(.system(size: 16.5, weight: .bold))
                ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 16.5)) }
            }
            .foregroundStyle(.white.opacity(0.92))
            .offset(x: 30, y: 9)
            HStack(spacing: 24) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.35 * lit)).frame(width: 34, height: 34).blur(radius: 6)
                    MiniViewfinder(filled: lit > 0.5).frame(width: 19, height: 19)
                }
                .frame(width: 22, height: 22)
                Image(systemName: "wifi").font(.system(size: 16, weight: .semibold))
                Image(systemName: "battery.100percent").font(.system(size: 17))
                Text("Fri 9:41 AM").font(.system(size: 16.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: W - 30, height: 38, alignment: .trailing)
        }
    }
}

struct MiniViewfinder: View {
    var filled = false
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                CornerShape(arm: 6, radius: 2.6)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Circle().fill(Color.white).frame(width: filled ? 7 : 4, height: filled ? 7 : 4)
        }
    }
}

struct StepsBar: View {
    var t: Double
    var body: some View {
        let s1 = ramp(t, 4.05, 0.25), s2 = ramp(t, 4.95, 0.25), s3 = ramp(t, 6.2, 0.25)
        let cPress = ramp(t, 6.3, 0.08) * (1 - ramp(t, 6.52, 0.12))
        HStack(spacing: 26) {
            step(Keycap(label: "⌥", size: 60, pressed: s1 * (1 - ramp(t, 7.9, 0.2)), lit: s1), "Hold", s1)
            arrow(s2)
            step(Cursor(scale: 1.7).frame(width: 60, height: 60), "Point", s2)
            arrow(s3)
            step(Keycap(label: "C", size: 60, pressed: cPress, lit: s3), "Copy", s3)
        }
        .opacity(window(t, 3.7, 8.6, fin: 0.5, fout: 0.4))
        .position(x: W / 2, y: 962)
    }

    func step<V: View>(_ icon: V, _ label: String, _ on: Double) -> some View {
        HStack(spacing: 16) {
            icon
            Text(label).font(.system(size: 40, weight: .bold)).foregroundStyle(.white.opacity(0.35 + 0.65 * on))
        }
    }

    func arrow(_ on: Double) -> some View {
        Image(systemName: "arrow.right").font(.system(size: 26, weight: .bold)).foregroundStyle(.white.opacity(0.25 + 0.45 * on))
    }
}

struct HowItWorksScene: View {
    var t: Double

    var body: some View {
        let appear = easeOut(ramp(t, 3.4, 0.6))
        let border = spring(ramp(t, 4.95, 0.6))
        let borderOn = ramp(t, 4.95, 0.12)
        let flash = (1 - ramp(t, 6.4, 0.5)) * ramp(t, 6.38, 0.02)
        let hudIn = spring(ramp(t, 5.05, 0.55))
        let toast = ramp(t, 6.42, 0.22)
        let target = S2.p1Rect
        let grown = target.insetBy(dx: -18, dy: -14)
        ZStack(alignment: .topLeading) {
            MenuBar(t: t, lit: ramp(t, 7.42, 0.1) * (1 - ramp(t, 8.1, 0.2)))
                .opacity(appear)
            article
                .offset(y: CGFloat(1 - appear) * 50)
                .opacity(appear)
            Spotlight(hole: target, amount: borderOn).allowsHitTesting(false)
            GrabBorder(rect: lerp(grown, target, border), colors: Mode.text.colors, t: t, flash: flash, opacity: borderOn)
            ScopeTag(label: "Paragraph", colors: Mode.text.colors, dots: 4, index: 3)
                .at(target.minX, target.minY - 46)
                .opacity(borderOn)
            hud
                .scaleEffect(0.9 + 0.1 * hudIn, anchor: .topLeading)
                .opacity(hudIn * (1 - toast))
                .at(target.minX, target.maxY + 18)
            ToastCard(title: "Copied text", detail: "“Great work rarely comes from doing more…”", colors: Mode.text.colors, progress: ramp(t, 6.42, 1))
                .scaleEffect(0.94 + 0.06 * spring(ramp(t, 6.42, 0.5)), anchor: .topLeading)
                .opacity(toast)
                .at(target.minX, target.maxY + 18)
            cursor
            fly
            StepsBar(t: t)
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    var article: some View {
        WindowChrome(rect: S2.win, title: "focus.journal/quiet-work", urlBar: true) {
            ZStack(alignment: .topLeading) {
                Text("The quiet art of focus")
                    .font(.system(size: 50, weight: .bold)).foregroundStyle(RGB(0x15151A).c()).tracking(-0.6)
                    .at(S2.x0 - S2.win.minX, 150 - S2.win.minY)
                Text("Maya Lin · 6 min read").font(.system(size: 20)).foregroundStyle(Color.black.opacity(0.45))
                    .at(S2.x0 - S2.win.minX, 224 - S2.win.minY)
                paragraph(S2.p1, top: S2.p1Top)
                paragraph(S2.p2, top: S2.p1Top + 160)
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.clear)
                    .overlay(Sunset().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
                    .frame(width: 380, height: 270)
                    .at(1140 - S2.win.minX, 300 - S2.win.minY)
                Text("Read the full essay →").font(.system(size: 21, weight: .medium)).foregroundStyle(RGB(0x2F6FEB).c())
                    .at(1140 - S2.win.minX, 592 - S2.win.minY)
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)).frame(width: 380, height: 12)
                    .at(1140 - S2.win.minX, 648 - S2.win.minY)
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)).frame(width: 300, height: 12)
                    .at(1140 - S2.win.minX, 672 - S2.win.minY)
            }
        }
    }

    func paragraph(_ lines: [String], top: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                Text(l).font(.system(size: 25)).foregroundStyle(RGB(0x2A2A31).c())
                    .at(S2.x0 - S2.win.minX, top - S2.win.minY + CGFloat(i) * S2.lineH)
            }
        }
    }

    var hud: some View {
        HUDCard {
            ModeBar(modes: [.text, .link, .image, .color], selected: .text)
            PreviewRow(content: .text("“Great work rarely comes from doing more…”", "3 lines · 25 words"), mode: .text)
        }
    }

    var cursor: some View {
        let from = CGPoint(x: 1240, y: 760), to = CGPoint(x: 712, y: 376)
        let m = easeInOut(ramp(t, 4.2, 0.8))
        let drift = CGFloat(ramp(t, 5.0, 3.6)) * 8
        return Cursor()
            .at(lerp(from.x, to.x, m) + drift, lerp(from.y, to.y, m) + drift * 0.4)
            .opacity(easeOut(ramp(t, 3.85, 0.3)))
    }

    var fly: some View {
        let f = ramp(t, 6.62, 0.8)
        let from = CGPoint(x: S2.p1Rect.midX, y: S2.p1Rect.midY)
        let to = S2.menuIcon
        let ctrl = CGPoint(x: from.x + (to.x - from.x) * 0.35, y: min(from.y, to.y) - 120)
        let u = easeInOut(f)
        let p = CGPoint(x: (1 - u) * (1 - u) * from.x + 2 * (1 - u) * u * ctrl.x + u * u * to.x,
                        y: (1 - u) * (1 - u) * from.y + 2 * (1 - u) * u * ctrl.y + u * u * to.y)
        let scale = f < 0.12 ? 0.6 + f / 0.12 * 0.5 : 1.1 - 0.75 * f
        return Circle()
            .fill(LinearGradient(colors: Mode.text.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 46, height: 46)
            .overlay(Image(systemName: Mode.text.symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(.white))
            .shadow(color: Mode.text.colors[0].opacity(0.6), radius: 12, y: 4)
            .scaleEffect(scale)
            .position(p)
            .opacity(f > 0 && f < 1 ? (f > 0.85 ? (1 - f) / 0.15 : 1) : 0)
    }
}

// MARK: - Scene 3 · Anything (8.6 – 14.0)

enum S3 {
    static let win = CGRect(x: 230, y: 92, width: 1460, height: 770)
    static let cardW: CGFloat = 238, cardH: CGFloat = 300, gap: CGFloat = 32
    static let top: CGFloat = 238
    static func card(_ i: Int) -> CGRect {
        let total = cardW * 5 + gap * 4
        let x = win.minX + (win.width - total) / 2 + CGFloat(i) * (cardW + gap)
        return CGRect(x: x, y: top, width: cardW, height: cardH)
    }
    static let hops: [Double] = [9.05, 10.0, 10.95, 11.9, 12.85]
    static let modes: [Mode] = [.link, .image, .qr, .color, .file]
    static var targets: [CGRect] {
        let c = (0..<5).map(card)
        return [
            CGRect(x: c[0].minX + 16, y: c[0].minY + 206, width: textWidth("northwind.design", 20, weight: .medium) + 16, height: 38),
            CGRect(x: c[1].minX + 10, y: c[1].minY + 10, width: cardW - 20, height: 200),
            CGRect(x: c[2].midX - 92, y: c[2].minY + 26, width: 184, height: 184),
            CGRect(x: c[3].minX + 10, y: c[3].minY + 10, width: cardW - 20, height: 128),
            CGRect(x: c[4].minX + 34, y: c[4].minY + 30, width: cardW - 68, height: 214),
        ]
    }
}

struct AnythingScene: View {
    var t: Double

    var hop: (index: Int, x: Double) {
        var i = 0
        for (k, h) in S3.hops.enumerated() where t >= h { i = k }
        return (i, spring(ramp(t, S3.hops[i], 0.5)))
    }

    var body: some View {
        let appear = easeOut(ramp(t, 8.6, 0.6))
        let targets = S3.targets
        let (i, x) = hop
        let rect = i == 0 ? targets[0] : lerp(targets[i - 1], targets[i], x)
        let m = S3.modes[i]
        let prev = S3.modes[max(0, i - 1)]
        let pc = i == 0 ? m.pair : (RGB.mix(prev.pair.0, m.pair.0, clamp(x)), RGB.mix(prev.pair.1, m.pair.1, clamp(x)))
        let colors = [pc.0.c(), pc.1.c()]
        let on = ramp(t, S3.hops[0], 0.15)
        let firstIn = spring(ramp(t, S3.hops[0], 0.55))
        let r = i == 0 ? lerp(targets[0].insetBy(dx: -16, dy: -14), targets[0], firstIn) : rect
        let copyAt = 13.38
        let flash = (1 - ramp(t, copyAt, 0.5)) * ramp(t, copyAt - 0.02, 0.02)
        let toast = ramp(t, copyAt + 0.02, 0.2)
        let hudSwap = ramp(t, S3.hops[i] + 0.04, 0.16)
        let hudX = min(max(r.minX - 6, S3.win.minX + 40), S3.win.maxX - 520)
        let hudY = S3.card(0).maxY + 26
        ZStack(alignment: .topLeading) {
            board.offset(y: CGFloat(1 - appear) * 50).opacity(appear)
            Spotlight(hole: r, radius: 14, amount: on)
            GrabBorder(rect: r, colors: colors, t: t, flash: flash, radius: 14, opacity: on)
            ScopeTag(label: tag(i), colors: colors, dots: 3, index: 1)
                .at(r.minX, r.minY - 46)
                .opacity(on)
            hudFor(i)
                .opacity(on * (i == 0 ? 1 : 0.35 + 0.65 * hudSwap) * (1 - toast))
                .at(hudX, hudY)
            ToastCard(title: "Copied file", detail: "Launch Plan.pdf", colors: Mode.file.colors, progress: ramp(t, copyAt, 1))
                .opacity(toast)
                .at(hudX, hudY)
            Cursor().at(r.midX + 18, r.midY + 10).opacity(on)
            Caption(headline: "Copy anything.", sub: nil, t: t, start: 8.75, end: 14.0, y: 925)
            typeList(i).opacity(window(t, 9.0, 14.0, fin: 0.5, fout: 0.4)).position(x: W / 2, y: 1000)
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    func tag(_ i: Int) -> String {
        ["Link", "Image", "QR code", "Swatch", "File"][i]
    }

    func typeList(_ i: Int) -> some View {
        let items: [(String, Mode)] = [("Text", .text), ("Links", .link), ("Images", .image), ("QR codes", .qr), ("Colors", .color), ("Files", .file)]
        let active = t < S3.hops[0] ? 0 : i + 1
        return HStack(spacing: 18) {
            ForEach(Array(items.enumerated()), id: \.offset) { k, item in
                if k > 0 { Text("·").foregroundStyle(.white.opacity(0.3)) }
                Text(item.0)
                    .foregroundStyle(k == active
                        ? AnyShapeStyle(LinearGradient(colors: item.1.colors.map { RGB.mix(RGB(r: 1, g: 1, b: 1), $0 == item.1.colors[0] ? item.1.pair.0 : item.1.pair.1, 0.55).c() }, startPoint: .leading, endPoint: .trailing))
                        : AnyShapeStyle(Color.white.opacity(0.42)))
                    .scaleEffect(k == active ? 1.06 : 1)
            }
        }
        .font(.system(size: 31, weight: .semibold))
    }

    @ViewBuilder func hudFor(_ i: Int) -> some View {
        let m = S3.modes[i]
        switch i {
        case 0:
            HUDCard { ModeBar(modes: [.text, .link, .image, .color], selected: m); PreviewRow(content: .link("northwind.design", "/studio"), mode: m) }
        case 1:
            HUDCard { ModeBar(modes: [.image, .link, .color], selected: m); PreviewRow(content: .image("2400 × 1600", "PNG · full resolution"), mode: m) }
        case 2:
            HUDCard { ModeBar(modes: [.qr, .image, .color], selected: m); PreviewRow(content: .qr("grab.app/beta"), mode: m) }
        case 3:
            HUDCard { ModeBar(modes: [.color, .image], selected: m); PreviewRow(content: .color(RGB(0xED6E2A), "#ED6E2A"), mode: m) }
        default:
            HUDCard { ModeBar(modes: [.file, .image, .color], selected: m); PreviewRow(content: .file("Launch Plan.pdf", "~/Documents · 2.4 MB"), mode: m) }
        }
    }

    var board: some View {
        WindowChrome(rect: S3.win, title: "Moodboard — Launch") {
            ZStack(alignment: .topLeading) {
                ForEach(0..<5, id: \.self) { i in
                    let c = S3.card(i).offsetBy(dx: -S3.win.minX, dy: -S3.win.minY)
                    cardBody(i)
                        .frame(width: c.width, height: c.height, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.09), radius: 14, y: 6)
                        .at(c.minX, c.minY)
                }
            }
        }
    }

    @ViewBuilder func cardBody(_ i: Int) -> some View {
        switch i {
        case 0:
            ZStack(alignment: .topLeading) {
                Circle().fill(LinearGradient(colors: Mode.link.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 58, height: 58)
                    .overlay(Image(systemName: "globe").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white))
                    .at(24, 26)
                Text("Northwind Studio").font(.system(size: 23, weight: .bold)).foregroundStyle(RGB(0x15151A).c()).at(24, 100)
                Text("Calm software studio").font(.system(size: 16)).foregroundStyle(.black.opacity(0.45)).at(24, 132)
                Text("northwind.design").font(.system(size: 20, weight: .medium)).foregroundStyle(RGB(0x2F6FEB).c()).underline()
                    .at(24, 213)
            }
        case 1:
            VStack(alignment: .leading, spacing: 12) {
                Sunset().frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("golden-hour.png").font(.system(size: 17, weight: .medium)).foregroundStyle(.black.opacity(0.6))
                Text("Hero image").font(.system(size: 15)).foregroundStyle(.black.opacity(0.4))
            }
            .padding(10)
        case 2:
            VStack(spacing: 18) {
                Image(decorative: qrImage, scale: 1).interpolation(.none).resizable().frame(width: 168, height: 168)
                    .padding(.top, 34)
                Text("Scan for the beta").font(.system(size: 17, weight: .medium)).foregroundStyle(.black.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
        case 3:
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RGB(0xED6E2A).c()).frame(height: 128)
                    .overlay(Text("Ember").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).padding(12), alignment: .bottomLeading)
                HStack(spacing: 6) {
                    ForEach([0x2F7BFF, 0x10B981, 0x7C5CFF, 0x1F2937] as [UInt32], id: \.self) { c in
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(RGB(c).c()).frame(height: 70)
                    }
                }
                Text("Palette").font(.system(size: 16, weight: .medium)).foregroundStyle(.black.opacity(0.45)).padding(.top, 8)
            }
            .padding(10)
        default:
            VStack(spacing: 16) {
                PDFIcon().frame(width: 110, height: 134).padding(.top, 44)
                VStack(spacing: 4) {
                    Text("Launch Plan.pdf").font(.system(size: 18, weight: .semibold)).foregroundStyle(RGB(0x15151A).c())
                    Text("2.4 MB").font(.system(size: 15)).foregroundStyle(.black.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Scene 4 · Precision (14.0 – 18.6)

enum S4 {
    static let win = CGRect(x: 150, y: 96, width: 1110, height: 760)
    static let fontSize: CGFloat = 27
    static let lineH: CGFloat = 44
    static let codeX: CGFloat = 268
    static let codeY: CGFloat = 186
    static let cw: CGFloat = textWidth("M", fontSize, mono: true)
    static let code = [
        "import SwiftUI",
        "",
        "struct Feed: View {",
        "    let posts: [Post]",
        "",
        "    func render(_ post: Post) -> some View {",
        "        if post.isPinned {",
        "            PinnedRow(post)",
        "        } else {",
        "            PostRow(post)",
        "        }",
        "    }",
        "}",
    ]
    /// Lines a…b from column c0 to `c1`, or to the end of the longest line.
    static func rect(line a: Int, _ b: Int, col c0: Int, _ c1: Int? = nil) -> CGRect {
        let end = c1 ?? code[a...b].map(\.count).max() ?? c0
        return CGRect(x: codeX + CGFloat(c0) * cw - 9, y: codeY + CGFloat(a) * lineH - 3,
                      width: CGFloat(end - c0) * cw + 18, height: CGFloat(b - a + 1) * lineH + 6)
    }
    static let levels: [(CGRect, String)] = [
        (rect(line: 7, 7, col: 12, 21), "Symbol"),
        (rect(line: 7, 7, col: 12), "Line"),
        (rect(line: 6, 10, col: 8), "if block"),
        (rect(line: 5, 11, col: 4), "Function · render"),
    ]
    static let steps: [Double] = [14.65, 15.55, 16.4, 17.25]
}

struct PrecisionScene: View {
    var t: Double

    var level: (Int, Double) {
        var i = 0
        for (k, s) in S4.steps.enumerated() where t >= s { i = k }
        return (i, spring(ramp(t, S4.steps[i], 0.5)))
    }

    var body: some View {
        let appear = easeOut(ramp(t, 14.0, 0.6))
        let (i, x) = level
        let first = S4.levels[0].0
        let r = i == 0 ? lerp(first.insetBy(dx: -14, dy: -10), first, x) : lerp(S4.levels[i - 1].0, S4.levels[i].0, x)
        let on = ramp(t, S4.steps[0], 0.15)
        let copyAt = 17.95
        let flash = (1 - ramp(t, copyAt, 0.5)) * ramp(t, copyAt - 0.02, 0.02)
        let toast = ramp(t, copyAt + 0.02, 0.2)
        let hudPos = CGPoint(x: 1300, y: 250)
        ZStack(alignment: .topLeading) {
            editor.offset(y: CGFloat(1 - appear) * 50).opacity(appear)
            Spotlight(hole: r, radius: 10, amount: on * 0.8)
            GrabBorder(rect: r, colors: Mode.code.colors, t: t, flash: flash, radius: 10, opacity: on)
            ScopeTag(label: S4.levels[i].1, colors: Mode.code.colors, dots: 4, index: i)
                .at(r.minX, r.minY - 46)
                .opacity(on)
            hud(i)
                .opacity(on * (1 - toast))
                .scaleEffect(0.92 + 0.08 * spring(ramp(t, S4.steps[0], 0.5)), anchor: .topLeading)
                .at(hudPos.x, hudPos.y)
            ToastCard(title: "Copied function render", detail: "7 lines · Swift", colors: Mode.code.colors, progress: ramp(t, copyAt, 1))
                .opacity(toast)
                .at(hudPos.x, hudPos.y)
            keys.opacity(window(t, 14.4, 18.6)).at(hudPos.x + 4, 640)
            Cursor().at(S4.levels[0].0.minX + 70, S4.levels[0].0.midY + 6).opacity(on)
            Caption(headline: "Exactly the right size.", sub: "Press ↑ to grow it: word, line, block, whole function.", t: t, start: 14.2, end: 18.6)
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    var keys: some View {
        let presses = S4.steps.dropFirst().map { s in ramp(t, s - 0.06, 0.06) * (1 - ramp(t, s + 0.12, 0.12)) }
        let pressed = presses.max() ?? 0
        return HStack(spacing: 14) {
            VStack(spacing: 10) {
                Keycap(label: "↑", size: 66, pressed: pressed, lit: pressed > 0 ? 1 : 0.25, colors: Mode.code.colors)
                Keycap(label: "↓", size: 66, lit: 0, colors: Mode.code.colors)
            }
            VStack(alignment: .leading, spacing: 46) {
                Text("bigger").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text("smaller").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    func hud(_ i: Int) -> some View {
        let previews: [([String], String)] = [
            (["PinnedRow"], "Swift · symbol"),
            (["PinnedRow(post)"], "Swift · Feed.swift:8"),
            (["if post.isPinned {", "    PinnedRow(post)", "} else {", "…"], "Swift · 5 lines · Feed.swift:7"),
            (["func render(_ post: Post) -> some View {", "    if post.isPinned {", "        PinnedRow(post)", "…"], "Swift · 7 lines · Feed.swift:6"),
        ]
        return HUDCard(width: 500) {
            ModeBar(modes: [.code, .image, .color], selected: .code)
            PreviewRow(content: .snippet(previews[i].0, previews[i].1), mode: .code)
            FormatBar(formats: ["Code", "Markdown", "file:line", "GitHub"], selected: 0, colors: Mode.code.colors)
        }
    }

    var editor: some View {
        WindowChrome(rect: S4.win, dark: true, title: "Feed.swift") {
            ZStack(alignment: .topLeading) {
                ForEach(Array(S4.code.enumerated()), id: \.offset) { n, line in
                    Text("\(n + 1)").font(.system(size: 22, design: .monospaced)).foregroundStyle(.white.opacity(0.25))
                        .frame(width: 44, alignment: .trailing)
                        .at(S4.codeX - 80 - S4.win.minX, S4.codeY - S4.win.minY + CGFloat(n) * S4.lineH + 4)
                    highlighted(line)
                        .at(S4.codeX - S4.win.minX, S4.codeY - S4.win.minY + CGFloat(n) * S4.lineH)
                }
            }
        }
    }

    /// Minimal Swift highlighting, enough to read like an editor.
    func highlighted(_ line: String) -> Text {
        let keywords: Set<String> = ["import", "struct", "let", "func", "if", "else", "some"]
        let types: Set<String> = ["SwiftUI", "View", "Post", "Feed", "PinnedRow", "PostRow"]
        var out = Text("")
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            let color: Color
            if keywords.contains(token) { color = RGB(0xFF7AB2).c() }
            else if types.contains(token) { color = RGB(0x7DD3FC).c() }
            else if token.first?.isLetter == true || token.first == "_" { color = RGB(0xE6E6EE).c() }
            else { color = RGB(0xB8B8C6).c() }
            out = out + Text(token).foregroundColor(color)
            token = ""
        }
        for ch in line {
            if ch.isLetter || ch.isNumber || ch == "_" { token.append(ch) }
            else { flush(); out = out + Text(String(ch)).foregroundColor(RGB(0xB8B8C6).c()) }
        }
        flush()
        return out.font(.system(size: S4.fontSize, design: .monospaced))
    }
}

// MARK: - Scene 5 · Smart formats (18.6 – 23.4)

struct SmartScene: View {
    var t: Double
    static let rows: [(kind: String, input: String, format: String, output: String, inMono: Bool, outMono: Bool, mode: Mode)] = [
        ("DATE", "Team sync · Oct 7, 3:00 PM", "ISO 8601", "2026-10-07T15:00", false, true, .text),
        ("MATH", "1,240 × 12%", "Result", "148.8", false, false, .qr),
        ("UNITS", "12 ft", "Metric", "3.66 m", false, false, .link),
        ("BASE64", "eyJuYW1lIjoiQWRhIn0=", "Decoded", "{\"name\": \"Ada\"}", true, true, .image),
    ]
    static func start(_ i: Int) -> Double { 18.95 + Double(i) * 0.95 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<4, id: \.self) { i in row(i) }
            Caption(headline: "It understands what it sees.", sub: "Press ⇥ to switch format: dates, sums, units, JSON, phone numbers…", t: t, start: 18.8, end: 23.4)
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    func row(_ i: Int) -> some View {
        let r = Self.rows[i]
        let s = Self.start(i)
        let appear = easeOut(ramp(t, s, 0.45))
        let hover = ramp(t, s + 0.18, 0.15)
        let press = ramp(t, s + 0.42, 0.06) * (1 - ramp(t, s + 0.6, 0.12))
        let reveal = easeOut(ramp(t, s + 0.5, 0.4))
        let y: CGFloat = 196 + CGFloat(i) * 152
        let inputW: CGFloat = 560, outputW: CGFloat = 520
        let inRect = CGRect(x: 250, y: y, width: inputW, height: 100)
        return ZStack(alignment: .topLeading) {
            // Input
            VStack(alignment: .leading, spacing: 8) {
                Text(r.kind).font(.system(size: 15, weight: .bold, design: .rounded)).tracking(1.6).foregroundStyle(.white.opacity(0.45))
                Text(r.input).font(.system(size: 32, weight: .medium, design: r.inMono ? .monospaced : .default)).foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 26)
            .frame(width: inputW, height: 100, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .at(inRect.minX, inRect.minY)
            GrabBorder(rect: inRect.insetBy(dx: -5, dy: -5), colors: Mode.text.colors, t: t, radius: 23, opacity: hover * (1 - reveal * 0.7))
            // Tab key + format chip
            VStack(spacing: 10) {
                Keycap(label: "⇥", size: 58, pressed: press, lit: hover, colors: r.mode.colors)
                Text(r.format).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(LinearGradient(colors: r.mode.colors, startPoint: .leading, endPoint: .trailing)))
                    .opacity(reveal)
                    .scaleEffect(0.7 + 0.3 * spring(ramp(t, s + 0.5, 0.5)))
            }
            .frame(width: 180)
            .at(inRect.maxX + 30, y + 6)
            // Output
            Text(r.output).font(.system(size: 36, weight: .bold, design: r.outMono ? .monospaced : .default)).foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(width: outputW, height: 100, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: r.mode.colors.map { $0.opacity(0.22) }, startPoint: .leading, endPoint: .trailing)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(LinearGradient(colors: r.mode.colors, startPoint: .leading, endPoint: .trailing), lineWidth: 2))
                .shadow(color: r.mode.colors[0].opacity(0.45 * reveal), radius: 18)
                .blur(radius: CGFloat(1 - reveal) * 10)
                .opacity(reveal)
                .offset(x: CGFloat(1 - reveal) * -30)
                .at(inRect.maxX + 240, y)
        }
        .opacity(appear)
        .offset(x: CGFloat(1 - appear) * -40)
    }
}

// MARK: - Scene 6 · Actions (23.4 – 27.2)

struct ActionsScene: View {
    var t: Double
    static let keys: [(key: String, title: String, detail: String, symbol: String)] = [
        ("⏎", "Open", "links, maps, files", "arrow.up.forward.app"),
        ("␣", "Peek", "Quick Look", "eye"),
        ("P", "Pin", "float it on screen", "pin.fill"),
        ("S", "Speak", "read it aloud", "speaker.wave.2.fill"),
        ("T", "Translate", "on-device", "translate"),
        ("E", "Ask AI", "explain, summarize", "sparkles"),
        ("Z", "Undo", "restore clipboard", "arrow.uturn.backward"),
    ]
    static func at(_ i: Int) -> Double { 23.95 + Double(i) * 0.3 }

    var body: some View {
        let size: CGFloat = 104, gap: CGFloat = 46
        let total = size * 7 + gap * 6
        let x0 = (W - total) / 2
        ZStack(alignment: .topLeading) {
            HStack(spacing: 14) {
                Keycap(label: "⌥", size: 58, pressed: ramp(t, 23.7, 0.1), lit: ramp(t, 23.7, 0.2))
                Text("+").font(.system(size: 34, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                Text("one key").font(.system(size: 34, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            }
            .opacity(window(t, 23.55, 27.2))
            .position(x: W / 2, y: 330)
            ForEach(0..<7, id: \.self) { i in
                let k = Self.keys[i]
                let s = Self.at(i)
                let lit = easeOut(ramp(t, s, 0.25))
                let press = ramp(t, s, 0.06) * (1 - ramp(t, s + 0.12, 0.14))
                let pop = spring(ramp(t, s, 0.55))
                let colors = [brand[i % 3].c(), brand[(i + 1) % 3].c()]
                VStack(spacing: 18) {
                    Image(systemName: k.symbol).font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 38)
                        .scaleEffect(0.5 + 0.5 * pop)
                        .opacity(lit)
                    Keycap(label: k.key, size: size, pressed: press, lit: lit, colors: colors)
                    VStack(spacing: 6) {
                        Text(k.title).font(.system(size: 27, weight: .bold)).foregroundStyle(.white.opacity(0.4 + 0.6 * lit))
                        Text(k.detail).font(.system(size: 17)).foregroundStyle(.white.opacity(0.25 + 0.35 * lit))
                    }
                    .frame(width: 170)
                }
                .frame(width: 170)
                .position(x: x0 + size / 2 + CGFloat(i) * (size + gap), y: 560)
                .opacity(easeOut(ramp(t, 23.45 + Double(i) * 0.05, 0.4)))
            }
            Caption(headline: "Do more than copy.", sub: "Open, peek, pin, speak, translate, ask on-device AI, undo.", t: t, start: 23.5, end: 27.2)
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }
}

// MARK: - Scene 7 · Outro (27.2 – 30)

struct OutroScene: View {
    var t: Double
    var body: some View {
        let b = t - 27.15
        let fade = easeIn(ramp(t, 29.35, 0.65))
        ZStack {
            Logo(size: 190, build: b).position(x: W / 2, y: 380)
            Text("Grab")
                .font(.system(size: 112, weight: .bold, design: .rounded)).tracking(-2)
                .foregroundStyle(.white)
                .opacity(easeOut(ramp(b, 0.75, 0.55)))
                .offset(y: CGFloat(1 - easeOut(ramp(b, 0.75, 0.6))) * 28)
                .position(x: W / 2, y: 585)
            Text("Hold ⌥. Point. Copy anything.")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [RGB(0xFFB27F).c(), RGB(0xEC6A7E).c(), RGB(0x9C7CFF).c()], startPoint: .leading, endPoint: .trailing))
                .opacity(easeOut(ramp(b, 1.15, 0.55)))
                .offset(y: CGFloat(1 - easeOut(ramp(b, 1.15, 0.6))) * 20)
                .position(x: W / 2, y: 685)
            HStack(spacing: 34) {
                pill("lock.fill", "Private")
                pill("cpu", "On-device")
                pill("macwindow.on.rectangle", "Works everywhere on your Mac")
            }
            .opacity(easeOut(ramp(b, 1.5, 0.55)))
            .position(x: W / 2, y: 790)
        }
        .frame(width: W, height: H)
        .overlay(Color.black.opacity(fade))
    }

    func pill(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
            Text(text).font(.system(size: 24, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.7))
    }
}

// MARK: - The frame

struct Frame: View {
    var t: Double

    var accent: RGB {
        let stops: [(Double, RGB)] = [(0, brand[1]), (3.4, RGB(0x2F7BFF)), (8.6, RGB(0x7C5CFF)), (14, RGB(0x22C3EE)), (18.6, RGB(0x10B981)), (23.4, brand[0]), (27.2, brand[1])]
        var a = stops[0], b = stops[0]
        for s in stops where s.0 <= t { a = s }
        b = stops.first { $0.0 > t } ?? a
        let x = b.0 > a.0 ? easeInOut(ramp(t, b.0 - 1, 1)) : 0
        return RGB.mix(a.1, b.1, x)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Background(t: t, accent: accent)
            if t < 3.5 { IntroScene(t: t) }
            if t > 3.3 && t < 8.7 { HowItWorksScene(t: t).modifier(SceneFX(t: t, start: 3.4, end: 8.6)) }
            if t > 8.5 && t < 14.1 { AnythingScene(t: t).modifier(SceneFX(t: t, start: 8.6, end: 14.0)) }
            if t > 13.9 && t < 18.7 { PrecisionScene(t: t).modifier(SceneFX(t: t, start: 14.0, end: 18.6)) }
            if t > 18.5 && t < 23.5 { SmartScene(t: t).modifier(SceneFX(t: t, start: 18.6, end: 23.4)) }
            if t > 23.3 && t < 27.3 { ActionsScene(t: t).modifier(SceneFX(t: t, start: 23.4, end: 27.2)) }
            if t > 27.1 { OutroScene(t: t).modifier(SceneFX(t: t, start: 27.2, end: 31)) }
            // Fade up from black.
            Color.black.opacity(1 - easeOut(ramp(t, 0, 0.5)))
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Sound

/// A tiny synth and mixer: pads, bass, drums, plucks and the sound effects, all
/// generated sample by sample.
final class Mixer {
    let rate = 48_000.0
    var L: [Float]
    var R: [Float]
    var sendL: [Float]
    var sendR: [Float]
    var duck: [Float]

    init(seconds: Double) {
        let n = Int(seconds * rate)
        L = [Float](repeating: 0, count: n)
        R = L
        sendL = L
        sendR = L
        duck = [Float](repeating: 1, count: n)
    }

    var count: Int { L.count }

    func add(_ start: Double, _ samples: [Float], gain: Float, pan: Float = 0, send: Float = 0.2, ducked: Bool = false) {
        let s0 = Int(start * rate)
        let gl = gain * (pan <= 0 ? 1 : 1 - pan), gr = gain * (pan >= 0 ? 1 : 1 + pan)
        for (i, v) in samples.enumerated() {
            let j = s0 + i
            guard j >= 0, j < count else { continue }
            let d: Float = ducked ? duck[j] : 1
            L[j] += v * gl * d
            R[j] += v * gr * d
            sendL[j] += v * gl * d * send
            sendR[j] += v * gr * d * send
        }
    }

    // Instruments

    func mtof(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

    /// Warm, slightly detuned additive saw through a gentle low-pass.
    func pad(_ note: Double, _ dur: Double, attack: Double = 0.6, release: Double = 0.9, bright: Double = 1) -> [Float] {
        let n = Int((dur + release) * rate)
        var out = [Float](repeating: 0, count: n)
        let f0 = mtof(note)
        for detune in [-0.09, 0.0, 0.08] {
            let f = f0 * pow(2, detune / 12)
            let phase0 = Double.random(in: 0..<1)
            for h in 1...9 {
                let fh = f * Double(h)
                guard fh < 9000 else { break }
                // Softer upper harmonics = warmer pad.
                let amp = 1 / Double(h) * exp(-Double(h) * 0.32 / bright)
                let w = 2 * Double.pi * fh / rate
                var ph = phase0 * 2 * .pi * Double(h)
                for i in 0..<n {
                    out[i] += Float(sin(ph) * amp)
                    ph += w
                }
            }
        }
        for i in 0..<n {
            let t = Double(i) / rate
            var env = min(1, t / attack)
            if t > dur { env *= max(0, 1 - (t - dur) / release) }
            out[i] *= Float(env * env * 0.22)
        }
        return out
    }

    func bass(_ note: Double, _ dur: Double) -> [Float] {
        let n = Int((dur + 0.1) * rate)
        let f = mtof(note)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = min(1, t / 0.01) * exp(-t * 1.6) * (t > dur ? max(0, 1 - (t - dur) / 0.1) : 1)
            return Float((sin(2 * .pi * f * t) + 0.25 * sin(4 * .pi * f * t)) * env)
        }
    }

    func kick() -> [Float] {
        let n = Int(0.45 * rate)
        var ph = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let f = 54 + 110 * exp(-t * 30)
            ph += 2 * .pi * f / rate
            let env = exp(-t * 9)
            let click = t < 0.004 ? (Double.random(in: -1...1) * (1 - t / 0.004) * 0.3) : 0
            return Float(sin(ph) * env + click)
        }
    }

    func noise(_ dur: Double) -> [Float] { (0..<Int(dur * rate)).map { _ in Float.random(in: -1...1) } }

    func hat() -> [Float] {
        var prev: Float = 0
        return noise(0.09).enumerated().map { i, v in
            let hp = v - prev
            prev = v
            return hp * Float(exp(-Double(i) / rate * 55))
        }
    }

    func clap() -> [Float] {
        let src = bandpass(noise(0.28), center: 1400, q: 1.4)
        return src.enumerated().map { i, v in
            let t = Double(i) / rate
            let bursts = (t < 0.012 ? 1 : 0.0) + (t > 0.014 && t < 0.024 ? 0.8 : 0) + (t > 0.026 ? exp(-(t - 0.026) * 22) : 0)
            return v * Float(bursts)
        }
    }

    func pluck(_ note: Double, decay: Double = 6) -> [Float] {
        let f = mtof(note)
        let n = Int(0.7 * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = min(1, t / 0.003) * exp(-t * decay)
            return Float((sin(2 * .pi * f * t) + 0.35 * sin(4 * .pi * f * t) * exp(-t * 12) + 0.12 * sin(6 * .pi * f * t) * exp(-t * 20)) * env)
        }
    }

    func bell(_ freqs: [Double], decay: Double = 3.5) -> [Float] {
        let n = Int(1.6 * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            var v = 0.0
            for (k, f) in freqs.enumerated() {
                v += sin(2 * .pi * f * t) * exp(-t * decay * (1 + Double(k) * 0.4)) / Double(k + 1)
                v += 0.3 * sin(2 * .pi * f * 2.76 * t) * exp(-t * decay * 3)
            }
            return Float(v * min(1, t / 0.002))
        }
    }

    /// Band-passed noise sweeping between two frequencies.
    func whoosh(_ dur: Double, from: Double, to: Double, q: Double = 1.6) -> [Float] {
        let src = noise(dur)
        var low = 0.0, band = 0.0
        return src.enumerated().map { i, v in
            let x = Double(i) / Double(src.count)
            let fc = from * pow(to / from, x)
            let f = 2 * sin(.pi * fc / rate)
            let high = Double(v) - low - band / q
            band += f * high
            low += f * band
            let env = sin(.pi * x) * sin(.pi * x)
            return Float(band * env)
        }
    }

    func bandpass(_ src: [Float], center: Double, q: Double) -> [Float] {
        var low = 0.0, band = 0.0
        let f = 2 * sin(.pi * center / rate)
        return src.map { v in
            let high = Double(v) - low - band / q
            band += f * high
            low += f * band
            return Float(band)
        }
    }

    func tick(_ freq: Double = 1800) -> [Float] {
        let n = Int(0.07 * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            return Float(sin(2 * .pi * freq * t) * exp(-t * 70) + (t < 0.002 ? Double.random(in: -0.5...0.5) : 0))
        }
    }

    func keyClick() -> [Float] {
        let body = bandpass(noise(0.05), center: 2400, q: 2.5)
        return body.enumerated().map { i, v in
            let t = Double(i) / rate
            return v * Float(exp(-t * 90)) + Float(sin(2 * .pi * 180 * t) * exp(-t * 60) * 0.5)
        }
    }

    // Effects

    /// Ducks everything marked `ducked` under each kick, so the groove breathes.
    func sidechain(at times: [Double]) {
        for t0 in times {
            let s = Int(t0 * rate)
            for i in 0..<Int(0.3 * rate) where s + i < count {
                let x = Double(i) / (0.3 * rate)
                duck[s + i] = min(duck[s + i], Float(0.6 + 0.4 * x * x))
            }
        }
    }

    /// Schroeder reverb over the send bus, mixed back in.
    func reverb(mix: Float) {
        func process(_ input: [Float], offset: Int) -> [Float] {
            let combs = [1557, 1617, 1491, 1422].map { $0 + offset }
            var out = [Float](repeating: 0, count: input.count)
            for d in combs {
                let delay = d * 2
                var buf = [Float](repeating: 0, count: delay)
                var idx = 0
                var lp: Float = 0
                for i in 0..<input.count {
                    let y = buf[idx]
                    lp = y * 0.75 + lp * 0.25
                    buf[idx] = input[i] + lp * 0.86
                    idx = (idx + 1) % delay
                    out[i] += y
                }
            }
            for d in [225, 556] {
                let delay = d * 2 + offset
                var buf = [Float](repeating: 0, count: delay)
                var idx = 0
                for i in 0..<out.count {
                    let b = buf[idx]
                    let y = -out[i] + b
                    buf[idx] = out[i] + b * 0.5
                    idx = (idx + 1) % delay
                    out[i] = y
                }
            }
            return out
        }
        // Keep the low end out of the room.
        func highpass(_ x: [Float], _ fc: Double) -> [Float] {
            let a = Float(exp(-2 * .pi * fc / rate))
            var y: [Float] = x
            var prevX: Float = 0, prevY: Float = 0
            for i in 0..<x.count {
                prevY = a * (prevY + x[i] - prevX)
                prevX = x[i]
                y[i] = prevY
            }
            return y
        }
        let wl = process(highpass(sendL, 320), offset: 0)
        let wr = process(highpass(sendR, 320), offset: 23)
        for i in 0..<count {
            L[i] += wl[i] * mix
            R[i] += wr[i] * mix
        }
    }

    /// Ping-pong echo for the plucks.
    func echo(_ src: [Float], delay: Double, feedback: Float) -> ([Float], [Float]) {
        let d = Int(delay * rate)
        var l = src + [Float](repeating: 0, count: d * 6)
        var r = [Float](repeating: 0, count: l.count)
        for i in d..<l.count {
            r[i] += l[i - d] * feedback
            if i >= 2 * d { l[i] += r[i - d] * feedback }
        }
        return (l, r)
    }

    func master(fadeOut: Double) -> [Int16] {
        let a = Float(exp(-2 * .pi * 30 / rate))
        var pl: Float = 0, yl: Float = 0, pr: Float = 0, yr: Float = 0
        for i in 0..<count {
            yl = a * (yl + L[i] - pl); pl = L[i]; L[i] = yl
            yr = a * (yr + R[i] - pr); pr = R[i]; R[i] = yr
        }
        var peak: Float = 0
        for i in 0..<count {
            let t = Double(i) / rate
            let fadeIn = Float(min(1, t / 0.3))
            let fo = Float(clamp((DURATION - t) / fadeOut))
            L[i] = tanhf(L[i] * 1.15) * fadeIn * fo
            R[i] = tanhf(R[i] * 1.15) * fadeIn * fo
            peak = max(peak, abs(L[i]), abs(R[i]))
        }
        let k = peak > 0 ? 0.75 / peak : 1
        var out = [Int16]()
        out.reserveCapacity(count * 2)
        for i in 0..<count {
            out.append(Int16(clamping: Int(L[i] * k * 32767)))
            out.append(Int16(clamping: Int(R[i] * k * 32767)))
        }
        return out
    }
}

func soundtrack() -> [Int16] {
    let m = Mixer(seconds: DURATION)
    let beat = 0.6
    let bar = beat * 4

    // Harmony: Fmaj7 · G6 · Em7 · Am9, three times, resolving to Cmaj9 for the outro.
    let chords: [[Double]] = [[53, 57, 60, 64, 69], [55, 59, 62, 64, 67], [52, 55, 59, 62, 67], [57, 60, 64, 67, 71]]
    let roots: [Double] = [41, 43, 40, 45]
    var times: [(Double, [Double], Double, Double)] = []
    for b in 0..<11 {
        let t0 = Double(b) * bar
        let dur = b == 10 ? 27.0 - t0 : bar
        times.append((t0, chords[b % 4], roots[b % 4], dur))
    }
    times.append((27.0, [48, 55, 59, 62, 64, 71], 36, 3.0))

    // Kicks from the first scene change to the outro, with sidechain.
    var kicks: [Double] = []
    var k = 3.6
    while k < 26.99 { kicks.append(k); k += beat }
    m.sidechain(at: kicks)

    for (t0, notes, root, dur) in times {
        let isLast = t0 >= 27
        for (i, n) in notes.enumerated() {
            let pan = Float(i % 2 == 0 ? -0.35 : 0.35) * Float(i) / Float(notes.count)
            m.add(t0, m.pad(n, dur, attack: t0 == 0 ? 1.4 : 0.5, release: isLast ? 2.0 : 0.9, bright: isLast ? 1.7 : 1.35),
                  gain: isLast ? 0.24 : 0.2, pan: pan, send: 0.45, ducked: true)
        }
        if t0 >= 3.6 - 0.01 || isLast {
            if isLast {
                m.add(t0, m.bass(root, 2.6), gain: 0.3, send: 0)
            } else {
                for b in 0..<4 {
                    let tb = t0 + Double(b) * beat
                    guard tb >= 3.59, tb < 27 else { continue }
                    m.add(tb, m.bass(root, beat * 0.9), gain: 0.22, send: 0)
                }
            }
        }
    }
    // The first bar's bass enters with the drums.
    m.add(3.6, m.bass(43, 1.2), gain: 0.22, send: 0)

    for t in kicks { m.add(t, m.kick(), gain: 0.4, send: 0) }
    // Hats on the off-beats, claps on 2 and 4, from the third scene.
    var h = 8.7
    while h < 27 { m.add(h, m.hat(), gain: 0.2, pan: 0.25, send: 0.08); h += beat }
    var c = 9.0
    while c < 27 { m.add(c, m.clap(), gain: 0.26, pan: -0.1, send: 0.25); c += beat * 2 }

    // Plucked arpeggio through a ping-pong echo, scenes 3–5.
    let arpPattern = [0, 2, 4, 3, 1, 3, 4, 2]
    var arp = [Float](repeating: 0, count: m.count)
    var a = 8.4
    var step = 0
    while a < 23.4 {
        let barIndex = min(times.count - 1, Int(a / bar))
        let chord = times[barIndex].1
        let note = chord[arpPattern[step % arpPattern.count] % chord.count] + 12
        let p = m.pluck(note)
        let s0 = Int(a * m.rate)
        for (i, v) in p.enumerated() where s0 + i < arp.count { arp[s0 + i] += v }
        a += beat / 2
        step += 1
    }
    let (al, ar) = m.echo(arp, delay: beat * 0.75, feedback: 0.35)
    for i in 0..<m.count {
        m.L[i] += al[i] * 0.075 * m.duck[i]
        m.R[i] += ar[i] * 0.075 * m.duck[i]
        m.sendL[i] += al[i] * 0.03
        m.sendR[i] += ar[i] * 0.03
    }

    // Sound effects, on the picture's cues.
    m.add(0.0, m.whoosh(1.1, from: 300, to: 5000, q: 2.5), gain: 0.22, send: 0.4)
    m.add(0.92, m.pluck(84, decay: 9), gain: 0.22, send: 0.4)
    m.add(0.92, m.kick(), gain: 0.22, send: 0)
    m.add(1.22, m.bell([2637, 3520], decay: 3), gain: 0.07, pan: 0.3, send: 0.6)
    for t in [3.2, 8.4, 13.8, 18.4, 23.2, 27.0] {
        m.add(t, m.whoosh(0.55, from: 4500, to: 500, q: 1.4), gain: 0.3, send: 0.35)
    }
    // Reverse swell into the outro, then a soft impact.
    m.add(26.0, m.whoosh(1.0, from: 200, to: 7000, q: 3), gain: 0.2, send: 0.5)
    m.add(27.0, m.kick(), gain: 0.45, send: 0)
    m.add(27.0, m.bell([523.25, 783.99, 1046.5], decay: 1.2), gain: 0.1, send: 0.8)
    m.add(28.15, m.pluck(84, decay: 9), gain: 0.2, send: 0.4)
    m.add(28.42, m.bell([2637, 3520], decay: 3), gain: 0.06, pan: 0.3, send: 0.6)

    // Scene 2: ⌥ down, the border snaps on, C, the copy chime, the chip lands.
    let copyChime = { m.bell([1318.5, 1975.5], decay: 4) }
    m.add(4.05, m.keyClick(), gain: 0.35, pan: -0.2, send: 0.1)
    m.add(4.95, m.tick(1500), gain: 0.18, send: 0.2)
    m.add(6.3, m.keyClick(), gain: 0.35, pan: 0.2, send: 0.1)
    m.add(6.4, copyChime(), gain: 0.12, send: 0.5)
    m.add(6.65, m.whoosh(0.7, from: 800, to: 4000, q: 2), gain: 0.1, pan: 0.4, send: 0.3)
    m.add(7.42, m.tick(2600), gain: 0.1, pan: 0.6, send: 0.4)
    // Scene 3: a tick for each hop, rising.
    for (i, t) in [9.05, 10.0, 10.95, 11.9, 12.85].enumerated() {
        m.add(t, m.tick(1400 + Double(i) * 180), gain: 0.16, pan: Float(i - 2) * 0.15, send: 0.25)
    }
    m.add(13.32, m.keyClick(), gain: 0.33, send: 0.1)
    m.add(13.38, copyChime(), gain: 0.12, send: 0.5)
    // Scene 4: ↑ grows the selection, then a copy.
    m.add(14.65, m.tick(1500), gain: 0.16, send: 0.2)
    for (i, t) in [15.55, 16.4, 17.25].enumerated() {
        m.add(t - 0.06, m.keyClick(), gain: 0.3, send: 0.1)
        m.add(t, m.pluck(72 + Double([0, 4, 7][i]), decay: 10), gain: 0.12, send: 0.35)
    }
    m.add(17.89, m.keyClick(), gain: 0.33, send: 0.1)
    m.add(17.95, copyChime(), gain: 0.12, send: 0.5)
    // Scene 5: each format switch.
    for i in 0..<4 {
        let s = 18.95 + Double(i) * 0.95
        m.add(s, m.whoosh(0.35, from: 900, to: 2600, q: 2), gain: 0.06, send: 0.2)
        m.add(s + 0.42, m.keyClick(), gain: 0.3, send: 0.1)
        m.add(s + 0.5, m.bell([1567.98 * pow(2, Double([0, 2, 4, 7][i]) / 12)], decay: 6), gain: 0.07, send: 0.5)
    }
    // Scene 6: a rising pentatonic run as the keys light up.
    m.add(23.7, m.keyClick(), gain: 0.3, send: 0.1)
    let penta: [Double] = [72, 74, 76, 79, 81, 84, 86]
    for i in 0..<7 {
        let t = 23.95 + Double(i) * 0.3
        m.add(t, m.keyClick(), gain: 0.22, pan: Float(i - 3) * 0.12, send: 0.1)
        m.add(t, m.pluck(penta[i], decay: 7), gain: 0.13, pan: Float(i - 3) * 0.12, send: 0.45)
    }

    m.reverb(mix: 0.16)
    return m.master(fadeOut: 0.9)
}

func writeWAV(_ samples: [Int16], to path: String, rate: Int = 48_000) {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let bytes = UInt32(samples.count * 2)
    d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
    d.append("data".data(using: .ascii)!); u32(bytes)
    samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
    try! d.write(to: URL(fileURLWithPath: path))
}

// MARK: - Rendering

@MainActor
final class FrameRenderer {
    let bytesPerRow = Int(W) * 4
    let buffer: UnsafeMutableRawPointer
    let ctx: CGContext

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * Int(H), alignment: 64)
        ctx = CGContext(data: buffer, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    func render(_ t: Double) -> CGImage? {
        let r = ImageRenderer(content: Frame(t: t))
        r.scale = 1
        r.proposedSize = ProposedViewSize(width: W, height: H)
        return r.cgImage
    }

    /// Renders into the BGRA buffer.
    func draw(_ t: Double) -> Data {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        if let img = render(t) { ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H)) }
        return Data(bytesNoCopy: buffer, count: bytesPerRow * Int(H), deallocator: .none)
    }
}

@MainActor
func main() {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.first == "--stills" {
        let dir = args[1]
        let r = FrameRenderer()
        for s in args.dropFirst(2) {
            guard let t = Double(s), let img = r.render(t) else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/still_\(s).png"))
        }
        return
    }
    if args.first == "--audio" {
        writeWAV(soundtrack(), to: args[1])
        return
    }

    let out = args.first ?? "Grab-promo.mp4"
    let wav = NSTemporaryDirectory() + "grab-promo.wav"
    let started = Date()
    print("▸ Soundtrack")
    writeWAV(soundtrack(), to: wav)

    print("▸ Frames → ffmpeg")
    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    ff.arguments = [
        "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(Int(W))x\(Int(H))", "-r", "\(FPS)", "-i", "-",
        "-i", wav,
        "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,noise=c0s=3:c0f=t",
        "-c:v", "libx264", "-preset", "slow", "-crf", "14", "-profile:v", "high",
        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-c:a", "aac", "-b:a", "256k",
        "-movflags", "+faststart", "-shortest", out,
    ]
    let pipe = Pipe()
    ff.standardInput = pipe
    try! ff.run()

    let renderer = FrameRenderer()
    let frames = Int(DURATION * Double(FPS))
    for f in 0..<frames {
        autoreleasepool {
            let t = Double(f) / Double(FPS)
            pipe.fileHandleForWriting.write(renderer.draw(t))
        }
        if f % 120 == 0 { print("  \(f)/\(frames)  \(Int(Date().timeIntervalSince(started)))s") }
    }
    try? pipe.fileHandleForWriting.close()
    ff.waitUntilExit()
    print("✓ \(out) in \(Int(Date().timeIntervalSince(started)))s")
}

MainActor.assumeIsolated { main() }
