import AppKit
import CoreImage
import SwiftUI

/// Copies that are a little bit of fun: a die-cut sticker, an instant photo, a receipt.
enum FunFormats {
    // MARK: Sticker

    /// A cut-out subject with a white die-cut border and a soft shadow, like a sticker.
    /// `subject` has a transparent background, cropped to fit.
    static func sticker(_ subject: CGImage, scale: CGFloat) -> CGImage? {
        let s = max(1, scale)
        let border = 7 * s, blur = 9 * s, drop = 3 * s
        let pad = (border + blur * 1.8 + drop).rounded(.up)
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(subject.width) + pad * 2, height: CGFloat(subject.height) + pad * 2)
        let ci = CIImage(cgImage: subject).transformed(by: CGAffineTransform(translationX: pad, y: pad))
        // The subject's shape in white, grown by the border, with a crisp edge.
        let shape = ci
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
            .composited(over: CIImage(color: .clear).cropped(to: canvas))
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": border])
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.8 * s])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 3),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: -1),
            ])
            .applyingFilter("CIColorClamp", parameters: [:])
            .cropped(to: canvas)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let white = CIContext().createCGImage(shape, from: canvas, format: .RGBA8, colorSpace: space),
              let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -drop), blur: blur, color: CGColor(gray: 0, alpha: 0.3))
        ctx.draw(white, in: canvas)
        ctx.restoreGState()
        // A whisper of grey along the edge, so a white sticker still reads on white.
        ctx.setShadow(offset: .zero, blur: 0.8 * s, color: CGColor(gray: 0, alpha: 0.18))
        ctx.draw(white, in: canvas)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.draw(subject, in: CGRect(x: pad, y: pad, width: CGFloat(subject.width), height: CGFloat(subject.height)))
        return ctx.makeImage()
    }

    // MARK: Instant photo

    /// The picture as an instant photo: film tones, a wide white bottom edge with a
    /// handwritten caption, tilted a touch.
    @MainActor
    static func polaroid(_ image: CGImage, pointSize: CGSize, caption: String) -> (image: CGImage, pointSize: CGSize)? {
        let toned = filmTone(image) ?? image
        // A sensible print size, whatever the source.
        let longest = max(pointSize.width, pointSize.height)
        let k = longest > 0 ? min(1, 460 / longest) : 1
        var photo = CGSize(width: max(1, pointSize.width * k), height: max(1, pointSize.height * k))
        if min(photo.width, photo.height) < 160 {
            let up = 160 / max(1, min(photo.width, photo.height))
            photo = CGSize(width: photo.width * up, height: photo.height * up)
        }
        let r = ImageRenderer(content: PolaroidView(photo: toned, size: photo, caption: caption))
        r.scale = 2
        guard let out = r.cgImage else { return nil }
        return (out, CGSize(width: CGFloat(out.width) / 2, height: CGFloat(out.height) / 2))
    }

    /// Instant-film color, if Core Image has it.
    static func filmTone(_ image: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: image).applyingFilter("CIPhotoEffectInstant", parameters: [:])
        return CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    // MARK: Receipt

    /// A list, or any text, printed as a till receipt.
    @MainActor
    static func receipt(lines: [String], isList: Bool, store: String, cashier: String, date: Date = Date()) -> (image: CGImage, pointSize: CGSize)? {
        let r = ImageRenderer(content: ReceiptView(lines: lines, isList: isList, store: store, cashier: cashier, date: date))
        r.scale = 2
        guard let out = r.cgImage else { return nil }
        return (out, CGSize(width: CGFloat(out.width) / 2, height: CGFloat(out.height) / 2))
    }

    /// A made-up but stable price for an item, from its text: $0.99 … $14.99.
    static func price(_ item: String) -> Int { 99 + Int(stableHash(item) % 15) * 100 }

    /// The same number for the same text on every run (Swift's own hash changes per launch).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }

    /// Wraps text to a receipt's width.
    static func wrap(_ text: String, width: Int) -> [String] {
        var out: [String] = []
        for para in text.components(separatedBy: .newlines) {
            let words = para.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if words.isEmpty { out.append(""); continue }
            var line = ""
            for w in words {
                var word = w
                while word.count > width {
                    if !line.isEmpty { out.append(line); line = "" }
                    out.append(String(word.prefix(width)))
                    word = String(word.dropFirst(width))
                }
                if line.isEmpty { line = word } else if line.count + 1 + word.count <= width { line += " " + word } else { out.append(line); line = word }
            }
            if !line.isEmpty { out.append(line) }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out
    }
}

private struct PolaroidView: View {
    let photo: CGImage
    let size: CGSize
    let caption: String

    var body: some View {
        let side = max(12, min(size.width, size.height) * 0.06)
        let bottom = max(side * 3.6, 52)
        VStack(spacing: 0) {
            Image(decorative: photo, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            Text(caption)
                .font(.custom("Noteworthy-Bold", size: min(22, max(13, size.width * 0.05))))
                .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.32))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: size.width, height: bottom)
        }
        .padding(.horizontal, side)
        .padding(.top, side)
        .background(
            LinearGradient(colors: [Color(red: 0.99, green: 0.985, blue: 0.97), Color(red: 0.955, green: 0.95, blue: 0.93)],
                           startPoint: .top, endPoint: .bottom)
        )
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        .rotationEffect(.degrees(-2))
        .padding(26)
    }
}

private struct ReceiptView: View {
    let lines: [String]
    let isList: Bool
    let store: String
    let cashier: String
    let date: Date

    private let width = 32
    private let ink = Color(red: 0.17, green: 0.17, blue: 0.2)

    var body: some View {
        let items = Array(lines.prefix(isList ? 40 : 60))
        let cents = isList ? items.map(FunFormats.price) : []
        let subtotal = cents.reduce(0, +)
        let tax = Int((Double(subtotal) * 0.0825).rounded())
        VStack(alignment: .leading, spacing: 3) {
            center("★ " + store.uppercased().prefix(24) + " ★").font(mono(14, .bold))
            center("STORE #\(FunFormats.stableHash(store) % 9000 + 1000) · REG 2")
            center(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year()) + "  " + date.formatted(.dateTime.hour().minute()))
            rule
            if isList {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    row(String(item.prefix(width - 8)), money(cents[i]))
                }
                if lines.count > items.count { Text("… \(lines.count - items.count) MORE").font(mono(11)) }
                rule
                row("SUBTOTAL", money(subtotal))
                row("TAX 8.25%", money(tax))
                row("TOTAL", money(subtotal + tax)).font(mono(15, .heavy))
                row("PAID WITH ⌥C", money(subtotal + tax))
                row("CHANGE", "0.00")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, line in Text(line.isEmpty ? " " : line) }
                if lines.count > items.count { Text("…") }
                rule
                let words = lines.joined(separator: " ").split(separator: " ").count
                row("WORDS", "\(words)")
                row("LINES", "\(lines.count)")
                row("TOTAL", "1 GRAB").font(mono(15, .heavy))
            }
            rule
            center("SERVED BY: \(cashier.uppercased())")
            center("ITEMS: \(isList ? items.count : 1)")
            center("THANK YOU FOR GRABBING!").font(mono(12, .bold)).padding(.top, 4)
            Barcode(seed: lines.joined()).frame(height: 38).padding(.top, 6)
            center(String(format: "%012llu", FunFormats.stableHash(lines.joined()) % 1_000_000_000_000)).font(mono(10))
        }
        .font(mono(12))
        .foregroundStyle(ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .frame(width: CGFloat(width) * 7.3 + 36, alignment: .leading)
        .background(Color(red: 0.995, green: 0.99, blue: 0.975))
        .clipShape(TornEdges())
        .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
        .padding(22)
    }

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    private var rule: some View {
        Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: 1000, y: 0))
        }
        .stroke(ink.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .frame(height: 1)
        .clipped()
        .padding(.vertical, 6)
    }

    private func center(_ s: some StringProtocol) -> some View { Text(String(s)).frame(maxWidth: .infinity) }

    private func row(_ left: String, _ right: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(left).lineLimit(1)
            Spacer(minLength: 4)
            Text(right).monospacedDigit()
        }
    }

    private func money(_ cents: Int) -> String { String(format: "%d.%02d", cents / 100, cents % 100) }

    /// Paper torn off the roll: zigzags top and bottom.
    struct TornEdges: Shape {
        func path(in r: CGRect) -> Path {
            let tooth: CGFloat = 7, depth: CGFloat = 4
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY + depth))
            var x = r.minX
            while x < r.maxX {
                p.addLine(to: CGPoint(x: min(r.maxX, x + tooth / 2), y: r.minY))
                p.addLine(to: CGPoint(x: min(r.maxX, x + tooth), y: r.minY + depth))
                x += tooth
            }
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - depth))
            x = r.maxX
            while x > r.minX {
                p.addLine(to: CGPoint(x: max(r.minX, x - tooth / 2), y: r.maxY))
                p.addLine(to: CGPoint(x: max(r.minX, x - tooth), y: r.maxY - depth))
                x -= tooth
            }
            p.closeSubpath()
            return p
        }
    }

    /// Bars that look like a barcode, the same every time for the same text.
    struct Barcode: View {
        let seed: String
        var body: some View {
            Canvas { ctx, size in
                var h = FunFormats.stableHash(seed)
                var x: CGFloat = 0
                var dark = true
                while x < size.width {
                    h = h &* 6364136223846793005 &+ 1442695040888963407
                    let w = CGFloat(1 + Int(h >> 60) % 3) * 1.4
                    if dark { ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(Color(red: 0.12, green: 0.12, blue: 0.15))) }
                    x += w
                    dark.toggle()
                }
            }
        }
    }
}
