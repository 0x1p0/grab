import AppKit
import CoreImage
import Vision

/// Image formats for ⌥ Tab: the subject without its background, a color palette,
/// a data URI, and app or file icons at full size.
enum ImageTools {
    /// The photo's subject(s) on a transparent background, cropped to fit.
    static func subject(of image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }
            let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
            let ci = CIImage(cvPixelBuffer: buffer)
            return CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        } catch {
            return nil
        }
    }

    /// The image's main colors, most common first, without near-duplicates.
    static func palette(of image: CGImage, count: Int = 6) -> [RGBAColor] {
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return [] }
        let px = data.assumingMemoryBound(to: UInt8.self)
        var points: [SIMD3<Double>] = []
        points.reserveCapacity(side * side)
        for i in 0..<(side * side) where px[i * 4 + 3] > 200 {
            points.append(SIMD3(Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2])) / 255)
        }
        guard points.count >= 8 else { return [] }

        // k-means, seeded across the brightness range so results are stable.
        let k = min(10, points.count)
        let sorted = points.sorted { ($0.x + $0.y + $0.z) < ($1.x + $1.y + $1.z) }
        var centers = (0..<k).map { sorted[$0 * (sorted.count - 1) / max(1, k - 1)] }
        var assignment = [Int](repeating: 0, count: points.count)
        for _ in 0..<12 {
            for (i, p) in points.enumerated() {
                var best = 0, bestD = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d = p - center
                    let dist = (d * d).sum()
                    if dist < bestD { bestD = dist; best = c }
                }
                assignment[i] = best
            }
            var sums = [SIMD3<Double>](repeating: .zero, count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, p) in points.enumerated() { sums[assignment[i]] += p; counts[assignment[i]] += 1 }
            for c in 0..<k where counts[c] > 0 { centers[c] = sums[c] / Double(counts[c]) }
        }
        var counts = [Int](repeating: 0, count: k)
        for a in assignment { counts[a] += 1 }
        let ranked = (0..<k).filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }.map { centers[$0] }
        var out: [SIMD3<Double>] = []
        for c in ranked where !out.contains(where: { o in let d = o - c; return (d * d).sum() < 0.012 }) {
            out.append(c)
            if out.count == count { break }
        }
        return out.map { RGBAColor(r: $0.x, g: $0.y, b: $0.z) }
    }

    /// The image with smooth, Apple-style rounded corners (transparent outside).
    ///
    /// What's under the pointer is often already rounded (video players, cards, avatars),
    /// so its rectangle carries bits of the page behind those corners. That background is
    /// trimmed off the edges first, and the new corners are cut at least as round as the
    /// source's own, so no slivers of the page are left showing.
    static func rounded(_ image: CGImage, pointSize: CGSize, points: CGFloat = 12, trimBleed: Bool = true) -> (image: CGImage, pointSize: CGSize)? {
        let minSide = trimBleed ? 48 : 16
        guard min(image.width, image.height) >= minSide, let px = Pixels(image) else { return nil }
        let scale = pointSize.width > 0 ? CGFloat(image.width) / pointSize.width : 2

        // A background showing in all four corners is the page behind a rounded element.
        // Pages are one exact color, so the match is strict: dark video frames and photos
        // with dark corners are not a page.
        var crop = (top: 0, left: 0, bottom: 0, right: 0)
        var sourceRadius: CGFloat = 0
        let corners = [px.at(0, 0), px.at(px.w - 1, 0), px.at(0, px.h - 1), px.at(px.w - 1, px.h - 1)]
        if trimBleed, let bg = corners.first, corners.allSatisfy({ Pixels.near($0, bg, 8) }) {
            func isPage(_ x: Int, _ y: Int) -> Bool { Pixels.near(px.at(x, y), bg, 8) }
            // Edges that are almost all background are bleed: trim them (a few pixels at most).
            func edge(_ points: [(Int, Int)]) -> Bool {
                points.filter { isPage($0.0, $0.1) }.count * 10 >= points.count * 9
            }
            let maxTrim = 4
            while crop.top < maxTrim, edge((crop.left..<(px.w - crop.right)).map { ($0, crop.top) }) { crop.top += 1 }
            while crop.bottom < maxTrim, edge((crop.left..<(px.w - crop.right)).map { ($0, px.h - 1 - crop.bottom) }) { crop.bottom += 1 }
            while crop.left < maxTrim, edge((crop.top..<(px.h - crop.bottom)).map { (crop.left, $0) }) { crop.left += 1 }
            while crop.right < maxTrim, edge((crop.top..<(px.h - crop.bottom)).map { (px.w - 1 - crop.right, $0) }) { crop.right += 1 }
            // How round the source is: walk in diagonally from each corner until the content
            // starts. For a circular corner of radius R, that's R × (1 − 1/√2) pixels in on each
            // axis, and the page runs about R along both edges. A corner only counts when it
            // has that shape; anything else is the picture, not the page.
            let x0 = crop.left, y0 = crop.top, x1 = px.w - 1 - crop.right, y1 = px.h - 1 - crop.bottom
            let depthPerRadius: CGFloat = 1 - 1 / 2.0.squareRoot()
            let limit = Int(CGFloat(min(x1 - x0, y1 - y0)) * 0.2 * depthPerRadius)
            var radii: [CGFloat] = []
            var deep = false
            for (cx, cy, dx, dy) in [(x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)] {
                var d = 0
                while d < limit, isPage(cx + dx * d, cy + dy * d) { d += 1 }
                if d >= limit { deep = true; break }
                guard d >= 2 else { continue }
                let r = CGFloat(d) / depthPerRadius
                let reach = Int(r * 1.6) + 3
                var a = 0, b = 0
                while a < reach, isPage(cx + dx * a, cy) { a += 1 }
                while b < reach, isPage(cx, cy + dy * b) { b += 1 }
                let fits = { (run: Int) in CGFloat(run) >= r * 0.5 && run < reach }
                if fits(a) && fits(b) { radii.append(r) }
            }
            if deep || radii.count < 2 {
                // The "background" runs into the picture (a flat color, a product on white),
                // or the corners aren't round: leave the edges whole.
                if deep { crop = (0, 0, 0, 0) }
            } else {
                sourceRadius = radii.max() ?? 0
            }
        }

        let w = px.w - crop.left - crop.right, h = px.h - crop.top - crop.bottom
        guard w >= minSide, h >= minSide else { return nil }
        let short = CGFloat(min(w, h))
        // Our corners, or rounder than the source's own so they fully cover its background.
        // A continuous corner of radius r cuts 0.214 r deep at 45°, a circular one of radius
        // R cuts 0.293 R, hence the 1.4.
        // Never more than 28 points: soft, not bubbly.
        let radius = min(max(points * max(scale, 1), sourceRadius > 0 ? sourceRadius * 1.4 + 2 : 0), 28 * max(scale, 1), short * 0.3)
        guard radius >= 2, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.addPath(continuousRoundedRect(rect, radius: radius))
        ctx.clip()
        ctx.interpolationQuality = .none
        // CG's origin is bottom-left: shift so the cropped region lands in the context.
        ctx.draw(image, in: CGRect(x: -CGFloat(crop.left), y: -CGFloat(crop.bottom), width: CGFloat(px.w), height: CGFloat(px.h)))
        guard let out = ctx.makeImage() else { return nil }
        let k = pointSize.width > 0 ? pointSize.width / CGFloat(px.w) : 0.5
        return (out, CGSize(width: CGFloat(w) * k, height: CGFloat(h) * k))
    }

    /// A picture of text, framed like a card: cropped to the writing itself, then given the
    /// same room on every side in the text's own background color, so it never hugs one
    /// edge and floats away from another.
    ///
    /// With `tidyEdges`, what belongs to the box around the text (a border, the page showing
    /// behind its rounded corners) is left out. Nil unless the background is one solid
    /// color: nothing is invented around text over a photo.
    static func textCard(_ image: CGImage, pointSize: CGSize, tidyEdges: Bool = true) -> (image: CGImage, pointSize: CGSize)? {
        guard let px = Pixels(image), px.w >= 8, px.h >= 8 else { return nil }
        let w = px.w, h = px.h
        let scale = pointSize.width > 0 ? CGFloat(w) / pointSize.width : 2
        guard let found = px.dominant(), found.share >= 0.5 else { return nil }
        let bg = found.color

        // Ink: anything clearly not background.
        var ink = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = px.at(x, y)
                ink[y * w + x] = p.3 > 128 && max(abs(p.0 - bg.0), abs(p.1 - bg.1), abs(p.2 - bg.2)) > 40
            }
        }

        // What belongs to the box around the text, not the text.
        var corners: [(x: Int, y: Int, side: Int)] = []
        var frame = [Bool](repeating: false, count: w * h)
        if tidyEdges {
            // The page behind a rounded box shows in its corners. Walk in diagonally to see how
            // round the box is (R × (1 − 1/√2) pixels for radius R) and ignore that corner square
            // when finding the text. Letters reaching a corner still count by their other strokes.
            let limit = min(w, h) / 2
            for (cx, cy, dx, dy) in [(0, 0, 1, 1), (w - 1, 0, -1, 1), (0, h - 1, 1, -1), (w - 1, h - 1, -1, -1)] {
                var d = 0
                while d < limit, !Pixels.near(px.at(cx + dx * d, cy + dy * d), bg, 24) { d += 1 }
                guard d > 0, d < limit else { continue }
                corners.append((cx, cy, min(Int(CGFloat(d) / (1 - 1 / 2.0.squareRoot())) + 2, limit)))
            }
            // A border or divider is ink joined to the edge that runs (nearly) all along it;
            // a letter cut off by the edge is small. Borders are left out.
            let thin = max(2, Int((2 * scale).rounded()))
            var seen = [Bool](repeating: false, count: w * h)
            let edge = (0..<w).flatMap { [$0, (h - 1) * w + $0] } + (0..<h).flatMap { [$0 * w, $0 * w + w - 1] }
            for start in edge where ink[start] && !seen[start] {
                var stack = [start], members: [Int] = []
                var bx0 = w, bx1 = -1, by0 = h, by1 = -1
                seen[start] = true
                while let i = stack.popLast() {
                    members.append(i)
                    let x = i % w, y = i / w
                    bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y)
                    for ny in max(0, y - 1)...min(h - 1, y + 1) {
                        for nx in max(0, x - 1)...min(w - 1, x + 1) where ink[ny * w + nx] && !seen[ny * w + nx] {
                            seen[ny * w + nx] = true
                            stack.append(ny * w + nx)
                        }
                    }
                }
                let spanW = bx1 - bx0 + 1, spanH = by1 - by0 + 1
                let long = (spanW * 10 >= w * 8, spanH * 10 >= h * 8)
                let ring = long.0 && long.1 && members.count <= 2 * (w + h) * thin * 2
                let line = (long.0 && spanH <= thin) || (long.1 && spanW <= thin)
                guard ring || line else { continue }
                for i in members { frame[i] = true; ink[i] = false }
            }
        }
        func counts(_ x: Int, _ y: Int) -> Bool {
            guard ink[y * w + x] else { return false }
            return !corners.contains { c in abs(x - c.x) < c.side && abs(y - c.y) < c.side }
        }

        // Where the writing is, and how tall its lines run.
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        var rowHasInk = [Bool](repeating: false, count: h)
        for y in 0..<h {
            for x in 0..<w where counts(x, y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                rowHasInk[y] = true
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        var runs: [Int] = [], run = 0
        for y in minY...(maxY + 1) {
            if y <= maxY, rowHasInk[y] { run += 1 } else if run > 0 { runs.append(run); run = 0 }
        }
        let lineHeight = CGFloat(runs.sorted()[runs.count / 2]) / scale

        // Room in proportion to the type: about a line's height, 14 to 32 points.
        let pad = Int((min(32, max(14, lineHeight * 1.1)) * scale).rounded())
        // Keep a point around the ink for the soft edges of letters (where the picture has it),
        // measuring the room from the letters themselves so every side gets the same.
        let keep = max(1, Int(scale.rounded()))
        let x0 = max(0, minX - keep), x1 = min(w - 1, maxX + keep)
        let y0 = max(0, minY - keep), y1 = min(h - 1, maxY + keep)
        let outW = (maxX - minX + 1) + pad * 2, outH = (maxY - minY + 1) + pad * 2
        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        for i in 0..<(outW * outH) {
            out[i * 4] = UInt8(bg.0); out[i * 4 + 1] = UInt8(bg.1); out[i * 4 + 2] = UInt8(bg.2); out[i * 4 + 3] = 255
        }
        for y in y0...y1 {
            for x in x0...x1 where !frame[y * w + x] {
                let p = px.at(x, y)
                // Anything see-through lands on the background (premultiplied).
                let a = 255 - p.3
                let o = ((y - minY + pad) * outW + (x - minX + pad)) * 4
                out[o] = UInt8(min(255, p.0 + bg.0 * a / 255))
                out[o + 1] = UInt8(min(255, p.1 + bg.1 * a / 255))
                out[o + 2] = UInt8(min(255, p.2 + bg.2 * a / 255))
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(out) as CFData),
              let card = CGImage(width: outW, height: outH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outW * 4, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (card, CGSize(width: CGFloat(outW) / scale, height: CGFloat(outH) / scale))
    }

    /// A rounded rectangle with Apple-style continuous corners: each corner is a superellipse
    /// that eases into the straight edge instead of meeting it with a circle's sudden bend.
    static func continuousRoundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
        let e = min(radius * 1.528, min(r.width, r.height) / 2)
        let n: CGFloat = 4.6, steps = 24
        let p = CGMutablePath()
        // Corner centers and the directions to their edges.
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: r.maxX - e, y: r.minY + e), 1, -1),
            (CGPoint(x: r.maxX - e, y: r.maxY - e), 1, 1),
            (CGPoint(x: r.minX + e, y: r.maxY - e), -1, 1),
            (CGPoint(x: r.minX + e, y: r.minY + e), -1, -1),
        ]
        for (i, (c, sx, sy)) in corners.enumerated() {
            for k in 0...steps {
                // Sweep each quarter so the outline goes around in one direction.
                let t = CGFloat(k) / CGFloat(steps) * .pi / 2
                let (u, v): (CGFloat, CGFloat) = i % 2 == 0 ? (sin(t), cos(t)) : (cos(t), sin(t))
                let pt = CGPoint(x: c.x + sx * e * pow(u, 2 / n), y: c.y + sy * e * pow(v, 2 / n))
                if i == 0 && k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
        p.closeSubpath()
        return p
    }

    /// Read access to an image's pixels as sRGB bytes, top row first.
    struct Pixels {
        let w: Int, h: Int
        private let data: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width, height = image.height
            var buf = [UInt8](repeating: 0, count: width * height * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let ok = buf.withUnsafeMutableBytes { b -> Bool in
                guard let ctx = CGContext(data: b.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard ok else { return nil }
            w = width
            h = height
            data = buf
        }

        /// (r, g, b, a) at column x, row y from the top.
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }

        /// The most common opaque color, and the share of the picture that's (nearly) it.
        func dominant(tolerance tol: Int = 6) -> (color: (Int, Int, Int, Int), share: Double)? {
            let step = max(1, Int((Double(w * h) / 40_000).squareRoot()))
            var counts: [UInt32: Int] = [:]
            var samples = 0
            for y in stride(from: 0, to: h, by: step) {
                for x in stride(from: 0, to: w, by: step) {
                    let i = (y * w + x) * 4
                    samples += 1
                    guard data[i + 3] > 240 else { continue }
                    counts[UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]), default: 0] += 1
                }
            }
            guard let top = counts.max(by: { $0.value < $1.value })?.key else { return nil }
            let c = (Int(top >> 16 & 0xff), Int(top >> 8 & 0xff), Int(top & 0xff), 255)
            let close = counts.reduce(0) { sum, kv in
                let k = kv.key
                let near = abs(Int(k >> 16 & 0xff) - c.0) <= tol && abs(Int(k >> 8 & 0xff) - c.1) <= tol && abs(Int(k & 0xff) - c.2) <= tol
                return near ? sum + kv.value : sum
            }
            return (c, Double(close) / Double(max(samples, 1)))
        }

        static func near(_ a: (Int, Int, Int, Int), _ b: (Int, Int, Int, Int), _ tol: Int) -> Bool {
            abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol && abs(a.2 - b.2) <= tol && abs(a.3 - b.3) <= tol
        }
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func dataURI(_ image: CGImage) -> String? {
        pngData(image).map { "data:image/png;base64," + $0.base64EncodedString() }
    }

    /// A file's or app's icon rendered at 1024 × 1024.
    static func icon(for url: URL, side: Int = 1024) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: side, height: side)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Writes an image to a temporary PNG (for Quick Look, opening in Preview…).
    static func temporaryPNG(_ image: CGImage, name: String = "Grab") -> URL? {
        guard let data = pngData(image) else { return nil }
        let url = TempFiles.url(name: name, ext: "png")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}

/// Grab's scratch files (calendar events, Quick Look previews), cleared at launch.
enum TempFiles {
    static let directory: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("Grab", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(name: String, ext: String) -> URL {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).truncated(60)
        let base = safe.isEmpty ? "Grab" : safe
        var url = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    static func write(_ text: String, name: String, ext: String) -> URL? {
        let url = url(name: name, ext: ext)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    static func clear() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
    }
}
