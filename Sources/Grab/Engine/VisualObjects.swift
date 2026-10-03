import CoreGraphics
import Foundation

/// Finds the visual "thing" under the cursor from pixels alone: a picture, an icon,
/// a colored block, a button. Useful wherever accessibility doesn't describe what's
/// drawn (decorative images, CSS backgrounds, canvases, games, remote desktops).
///
/// It estimates the surrounding background color, then flood-fills outward from the
/// cursor through everything that isn't background. The filled area's bounds are
/// the object.
final class PixelMap {
    struct Object {
        var rect: CGRect
        /// Nearly one color throughout: a swatch rather than a picture.
        var isSolid: Bool
    }

    private let w: Int
    private let h: Int
    private let rgba: [UInt8]
    private let origin: CGPoint
    /// Screen points per cell.
    private let cell: CGFloat
    private let background: (Int, Int, Int)

    init?(_ cap: Capture, maxSide: Int = 320) {
        let iw = cap.image.width, ih = cap.image.height
        guard iw > 4, ih > 4 else { return nil }
        let k = min(1, CGFloat(maxSide) / CGFloat(max(iw, ih)))
        w = max(4, Int(CGFloat(iw) * k))
        h = max(4, Int(CGFloat(ih) * k))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cap.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        rgba = px
        origin = cap.rect.origin
        cell = cap.rect.width / CGFloat(w)

        // Background: the most common (quantised) color along the border.
        var counts: [Int: Int] = [:]
        let width = w, height = h
        func add(_ x: Int, _ y: Int) {
            let i = (y * width + x) * 4
            let key = (Int(px[i]) >> 3) << 10 | (Int(px[i + 1]) >> 3) << 5 | (Int(px[i + 2]) >> 3)
            counts[key, default: 0] += 1
        }
        for x in 0..<width { add(x, 0); add(x, height - 1) }
        for y in 0..<height { add(0, y); add(width - 1, y) }
        let top = counts.max { $0.value < $1.value }?.key ?? 0
        background = (((top >> 10) & 31) << 3 + 4, ((top >> 5) & 31) << 3 + 4, (top & 31) << 3 + 4)
    }

    @inline(__always) private func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        // Bitmap rows are stored top-first.
        let i = (y * w + x) * 4
        return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
    }

    @inline(__always) private func isForeground(_ x: Int, _ y: Int) -> Bool {
        let c = color(x, y)
        return max(abs(c.0 - background.0), abs(c.1 - background.1), abs(c.2 - background.2)) > 22
    }

    func object(at p: CGPoint) -> Object? {
        guard cell > 0, cell.isFinite else { return nil }
        let cx = ((p.x - origin.x) / cell).rounded(.down).clampedInt, cy = ((p.y - origin.y) / cell).rounded(.down).clampedInt
        guard cx >= 0, cy >= 0, cx < w, cy < h, isForeground(cx, cy) else { return nil }

        var seen = [Bool](repeating: false, count: w * h)
        var stack = [(cx, cy)]
        seen[cy * w + cx] = true
        var minX = cx, maxX = cx, minY = cy, maxY = cy, count = 0
        var sum = (0, 0, 0)
        var colors: [(Int, Int, Int)] = []
        while let (x, y) = stack.popLast() {
            count += 1
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            let c = color(x, y)
            sum = (sum.0 + c.0, sum.1 + c.1, sum.2 + c.2)
            if count % 7 == 0 { colors.append(c) }
            // 8-connected, bridging one-cell gaps so anti-aliased edges hold together.
            for dy in -2...2 {
                for dx in -2...2 where (dx != 0 || dy != 0) && abs(dx) + abs(dy) <= 2 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h, !seen[ny * w + nx] else { continue }
                    seen[ny * w + nx] = true
                    if isForeground(nx, ny) { stack.append((nx, ny)) }
                }
            }
        }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        // Spilling over most of the capture means we can't see the object's edges.
        let touches = (minX == 0 ? 1 : 0) + (minY == 0 ? 1 : 0) + (maxX == w - 1 ? 1 : 0) + (maxY == h - 1 ? 1 : 0)
        guard touches < 3, CGFloat(bw * bh) < CGFloat(w * h) * 0.9 else { return nil }
        let rect = CGRect(x: origin.x + CGFloat(minX) * cell, y: origin.y + CGFloat(minY) * cell,
                          width: CGFloat(bw) * cell, height: CGFloat(bh) * cell)
        guard rect.width >= 12, rect.height >= 12 else { return nil }

        let mean = (sum.0 / count, sum.1 / count, sum.2 / count)
        let close = colors.filter { max(abs($0.0 - mean.0), abs($0.1 - mean.1), abs($0.2 - mean.2)) < 14 }.count
        let solid = !colors.isEmpty && Double(close) / Double(colors.count) > 0.9 && Double(count) > Double(bw * bh) * 0.8
        return Object(rect: rect, isSolid: solid)
    }
}
