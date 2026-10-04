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
    static func rounded(_ image: CGImage, pointSize: CGSize, points: CGFloat = 12) -> (image: CGImage, pointSize: CGSize)? {
        guard min(image.width, image.height) >= 48, let px = Pixels(image) else { return nil }
        let scale = pointSize.width > 0 ? CGFloat(image.width) / pointSize.width : 2

        // A background showing in all four corners is the page behind a rounded element.
        var crop = (top: 0, left: 0, bottom: 0, right: 0)
        var sourceRadius: CGFloat = 0
        let corners = [px.at(0, 0), px.at(px.w - 1, 0), px.at(0, px.h - 1), px.at(px.w - 1, px.h - 1)]
        if let bg = corners.first, corners.allSatisfy({ Pixels.near($0, bg, 18) }) {
            // Edges that are almost all background are bleed: trim them (a few pixels at most).
            func edge(_ points: [(Int, Int)]) -> Bool {
                points.filter { Pixels.near(px.at($0.0, $0.1), bg, 18) }.count * 10 >= points.count * 9
            }
            let maxTrim = 4
            while crop.top < maxTrim, edge((crop.left..<(px.w - crop.right)).map { ($0, crop.top) }) { crop.top += 1 }
            while crop.bottom < maxTrim, edge((crop.left..<(px.w - crop.right)).map { ($0, px.h - 1 - crop.bottom) }) { crop.bottom += 1 }
            while crop.left < maxTrim, edge((crop.top..<(px.h - crop.bottom)).map { (crop.left, $0) }) { crop.left += 1 }
            while crop.right < maxTrim, edge((crop.top..<(px.h - crop.bottom)).map { (px.w - 1 - crop.right, $0) }) { crop.right += 1 }
            // How round the source is: walk in diagonally from each corner until the content
            // starts. For a circular corner of radius R, that's R × (1 − 1/√2) pixels in on each axis.
            let x0 = crop.left, y0 = crop.top, x1 = px.w - 1 - crop.right, y1 = px.h - 1 - crop.bottom
            let depthPerRadius: CGFloat = 1 - 1 / 2.0.squareRoot()
            let limit = Int(CGFloat(min(x1 - x0, y1 - y0)) * 0.2 * depthPerRadius)
            var depths: [Int] = []
            for (cx, cy, dx, dy) in [(x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)] {
                var d = 0
                while d < limit, Pixels.near(px.at(cx + dx * d, cy + dy * d), bg, 18) { d += 1 }
                depths.append(d)
            }
            if depths.contains(where: { $0 >= limit }) {
                // The "background" runs deep into the picture: it's the picture itself
                // (a flat color, a product on white). Leave it whole.
                crop = (0, 0, 0, 0)
            } else if let deepest = depths.max() {
                sourceRadius = CGFloat(deepest) / depthPerRadius
            }
        }

        let w = px.w - crop.left - crop.right, h = px.h - crop.top - crop.bottom
        guard w >= 48, h >= 48 else { return nil }
        let short = CGFloat(min(w, h))
        // Our corners, or rounder than the source's own so they fully cover its background.
        // A continuous corner of radius r cuts 0.214 r deep at 45°, a circular one of radius
        // R cuts 0.293 R, hence the 1.4.
        let radius = min(max(points * max(scale, 1), sourceRadius > 0 ? sourceRadius * 1.4 + 2 : 0), short * 0.3)
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
