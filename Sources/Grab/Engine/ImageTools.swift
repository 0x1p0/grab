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

    /// The image with softly rounded corners (transparent outside), about 10 points at the
    /// image's own scale, never more than 6% of its shorter side. Nil for tiny images.
    static func rounded(_ image: CGImage, pointSize: CGSize, points: CGFloat = 10) -> CGImage? {
        let w = image.width, h = image.height
        guard min(w, h) >= 48 else { return nil }
        let scale = pointSize.width > 0 ? CGFloat(w) / pointSize.width : 2
        let radius = min(points * max(scale, 1), CGFloat(min(w, h)) * 0.06)
        guard radius >= 2, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(image, in: rect)
        return ctx.makeImage()
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
