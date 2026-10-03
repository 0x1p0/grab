import Foundation

/// Where each line of a piece of code sits on screen.
///
/// Code is laid out on a monospaced grid, so a handful of anchors (OCR'd line
/// numbers in the gutter, or OCR'd rows matched to the real text) pin down the
/// whole thing: line height, which line is where, column 0 and character width.
/// That lets Grab outline any function or line exactly, even in editors that
/// draw text without telling accessibility about it (VS Code, Cursor, Chrome…).
struct CodeGrid {
    var lineHeight: CGFloat
    /// Line index (fractional) whose centre is at `refY`.
    var refLine: Double
    var refY: CGFloat
    var left: CGFloat
    var charWidth: CGFloat
    var region: CGRect

    func yCenter(_ line: Int) -> CGFloat {
        refY + CGFloat(Double(line) - refLine) * lineHeight
    }

    func line(atY y: CGFloat) -> Int {
        guard lineHeight > 0 else { return -1 }
        return CGFloat((refLine + Double((y - refY) / lineHeight)).rounded()).clampedInt
    }

    /// The character under `p`, or nil if `p` isn't over a line of `analysis`.
    func offset(at p: CGPoint, in analysis: CodeAnalysis) -> Int? {
        guard region.insetBy(dx: -2, dy: -2).contains(p) else { return nil }
        let l = line(atY: p.y)
        guard l >= 0, l < analysis.lineCount else { return nil }
        let content = analysis.contentRange(l)
        guard content.length > 0 else { return nil }
        let col = ((p.x - left) / max(charWidth, 1)).rounded(.down).clampedInt
        let target = max(col, analysis.indent(l))
        let start = offsetForColumn(target, line: l, in: analysis)
        return min(start, NSMaxRange(content) - 1)
    }

    private func offsetForColumn(_ col: Int, line l: Int, in a: CodeAnalysis) -> Int {
        let r = a.lineRange(l)
        var c = 0
        var i = r.location
        while i < NSMaxRange(r) {
            let ch = a.text.character(at: i)
            let w = ch == 9 ? 4 - (c % 4) : 1
            if c + w > col { return i }
            c += w
            i += 1
        }
        return max(r.location, NSMaxRange(r) - 1)
    }

    private func column(of offset: Int, in a: CodeAnalysis) -> Int {
        let l = a.line(of: offset)
        let r = a.lineRange(l)
        var c = 0
        var i = r.location
        while i < offset && i < NSMaxRange(r) {
            c += a.text.character(at: i) == 9 ? 4 - (c % 4) : 1
            i += 1
        }
        return c
    }

    /// Screen rectangle for a range of the text, clipped to the visible region.
    func rect(for range: NSRange, in a: CodeAnalysis) -> CGRect? {
        guard range.length > 0 else { return nil }
        let first = a.line(of: range.location)
        let last = a.line(of: NSMaxRange(range) - 1)
        var x0: CGFloat, x1: CGFloat
        if first == last {
            x0 = left + CGFloat(column(of: range.location, in: a)) * charWidth
            x1 = left + CGFloat(column(of: NSMaxRange(range), in: a)) * charWidth
        } else {
            var minIndent = Int.max, maxEnd = 0
            for l in first...last where !a.isBlank(l) {
                minIndent = min(minIndent, a.indent(l))
                let cr = a.contentRange(l)
                maxEnd = max(maxEnd, column(of: NSMaxRange(cr), in: a))
            }
            if minIndent == .max { minIndent = 0 }
            x0 = left + CGFloat(minIndent) * charWidth
            x1 = left + CGFloat(maxEnd) * charWidth
        }
        let top = yCenter(first) - lineHeight / 2
        let bottom = yCenter(last) + lineHeight / 2
        let r = CGRect(x: x0, y: top, width: max(x1 - x0, charWidth), height: bottom - top).intersection(region)
        return r.isNull || r.width < 1 || r.height < 2 ? nil : r
    }
}

enum CodeGridBuilder {
    struct Row {
        var y: CGFloat
        var height: CGFloat
        var minX: CGFloat
        var maxX: CGFloat
        var text: String
        var lineNumber: Int?
    }

    /// OCR observations → rows of code, with gutter line numbers split off.
    static func rows(from lines: [OCRLine]) -> [Row] {
        let sorted = lines.sorted { $0.rect.midY < $1.rect.midY }
        var groups: [[OCRLine]] = []
        for l in sorted {
            if let last = groups.last?.last, abs(l.rect.midY - last.rect.midY) < min(l.rect.height, last.rect.height) * 0.5 {
                groups[groups.count - 1].append(l)
            } else {
                groups.append([l])
            }
        }
        var rows: [Row] = []
        for var g in groups {
            g.sort { $0.rect.minX < $1.rect.minX }
            var number: Int?
            var parts = g
            // A separate leading observation made only of digits is a gutter line number.
            if g.count > 1, let n = Int(g[0].text.trimmingCharacters(in: .whitespaces)), g[0].text.count <= 6 {
                number = n
                parts.removeFirst()
            } else if g.count == 1, let m = g[0].text.range(of: #"^\s*(\d{1,6})\s{2,}"#, options: .regularExpression) {
                // Number and code merged into one observation: keep the number, but don't trust minX.
                number = Int(g[0].text[m].trimmingCharacters(in: .whitespaces))
            }
            guard let first = parts.first else {
                // A row that is only a number: an empty line with a line number.
                rows.append(Row(y: g[0].rect.midY, height: g[0].rect.height, minX: .nan, maxX: .nan, text: "", lineNumber: number))
                continue
            }
            let text = parts.map(\.text).joined(separator: " ")
            let merged = g.count == 1 && number != nil
            rows.append(Row(
                y: g.map(\.rect.midY).reduce(0, +) / CGFloat(g.count),
                height: g.map(\.rect.height).max() ?? first.rect.height,
                minX: merged ? .nan : first.rect.minX,
                maxX: parts.map(\.rect.maxX).max() ?? first.rect.maxX,
                text: text,
                lineNumber: number
            ))
        }
        return rows
    }

    /// Editors put a column of line numbers left of the code. Each such gutter
    /// starts a band of code that runs to the next gutter (split editors) or the edge.
    static func bands(in lines: [OCRLine], region: CGRect) -> [CGRect] {
        let digits = lines.filter { l in
            let t = l.text.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t.count <= 6 && t.allSatisfy(\.isNumber)
        }
        // Cluster right-aligned numbers by their right edge.
        var clusters: [[OCRLine]] = []
        for d in digits.sorted(by: { $0.rect.maxX < $1.rect.maxX }) {
            if let last = clusters.last?.last, abs(d.rect.maxX - last.rect.maxX) < 7 {
                clusters[clusters.count - 1].append(d)
            } else {
                clusters.append([d])
            }
        }
        struct Gutter { var minX, maxX, top, bottom: CGFloat }
        let gutters: [Gutter] = clusters.compactMap { c in
            guard c.count >= 3 else { return nil }
            // Numbers should go up as we go down.
            let sorted = c.sorted { $0.rect.midY < $1.rect.midY }
            let numbered = sorted.compactMap { l in Int(l.text.trimmingCharacters(in: .whitespaces)).map { (n: $0, y: l.rect.midY) } }
            let rising = zip(numbered, numbered.dropFirst()).filter { $0.n < $1.n }.count
            guard rising >= max(2, numbered.count * 2 / 3) else { return nil }
            // Vertical extent: from the first visible line to the last. OCR often misses
            // single digits, so when the smallest number found is ≤ 10, assume line 1 is there too.
            var pitches: [CGFloat] = []
            for (p, q) in zip(numbered, numbered.dropFirst()) where q.n > p.n { pitches.append((q.y - p.y) / CGFloat(q.n - p.n)) }
            let lh = pitches.sorted()[safe: pitches.count / 2] ?? 18
            guard let first = numbered.min(by: { $0.n < $1.n }), let last = numbered.max(by: { $0.n < $1.n }) else { return nil }
            let firstLine = first.n <= 10 ? 1 : first.n
            let top = first.y - (CGFloat(first.n - firstLine) + 0.6) * lh
            let bottom = last.y + 1.6 * lh
            return Gutter(minX: c.map(\.rect.minX).min()!, maxX: c.map(\.rect.maxX).max()!, top: top, bottom: bottom)
        }
        .sorted { $0.maxX < $1.maxX }
        guard !gutters.isEmpty else { return [] }
        var out: [CGRect] = []
        for (i, g) in gutters.enumerated() {
            let end = i + 1 < gutters.count ? gutters[i + 1].minX - 4 : region.maxX
            let top = max(region.minY, g.top), bottom = min(region.maxY, g.bottom)
            out.append(CGRect(x: g.minX - 2, y: top, width: end - g.minX + 2, height: max(0, bottom - top)))
        }
        return out
    }

    /// File names visible above a band of code (the tab or breadcrumb), most specific first.
    static func fileNames(above band: CGRect, in lines: [OCRLine]) -> [String] {
        let header = lines.filter { $0.rect.maxY <= band.minY + 4 && $0.rect.maxY > band.minY - 90 && $0.rect.maxX > band.minX }
            .sorted { $0.rect.minY > $1.rect.minY }
        var names: [String] = []
        let re = try? NSRegularExpression(pattern: #"[A-Za-z0-9_.+-]+\.[A-Za-z][A-Za-z0-9]{0,9}"#)
        for l in header {
            let ns = l.text as NSString
            for m in re?.matches(in: l.text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                let name = ns.substring(with: m.range)
                if CodeLanguage.forFile(URL(fileURLWithPath: name)) != nil, !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    /// Letters and digits only, with common OCR confusions folded together.
    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.lowercased() {
            switch ch {
            case "0": out.append("o")
            case "1", "i", "|", "!", "l": out.append("l")
            case "5": out.append("s")
            case "8": out.append("b")
            default:
                if ch.isLetter || ch.isNumber { out.append(ch) }
            }
        }
        return out
    }

    /// 0…1, how alike two normalized lines are (1 − edit distance / length).
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a.utf8), y = Array(b.utf8)
        let n = x.count, m = y.count
        guard n > 0, m > 0 else { return 0 }
        if Double(min(n, m)) / Double(max(n, m)) < 0.6 { return 0 }
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[m]) / Double(max(n, m))
    }

    /// Do an OCR'd row and a source line say the same thing?
    static func agrees(_ row: String, _ line: String) -> Bool {
        if row == line { return true }
        if row.count >= 6 && (line.hasPrefix(row) || row.hasPrefix(line) || line.contains(row)) { return true }
        // Rows cut off at the viewport's edge: compare against the line's start.
        if line.count > row.count + 4, row.count >= 10 {
            return similarity(row, String(line.prefix(row.count))) >= 0.72
        }
        return similarity(row, line) >= 0.72
    }

    private static func median(_ xs: [CGFloat]) -> CGFloat? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    private static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    /// Typical spacing between consecutive rows.
    private static func rowPitch(_ rows: [Row]) -> CGFloat? {
        let ys = rows.map(\.y).sorted()
        let deltas = zip(ys.dropFirst(), ys).map { $0 - $1 }.filter { $0 > 3 }
        guard let smallest = deltas.min() else { return nil }
        return median(deltas.filter { $0 < smallest * 1.35 })
    }

    /// Aligns OCR rows to the lines of a known text.
    static func align(rows: [Row], to a: CodeAnalysis, region: CGRect) -> CodeGrid? {
        guard rows.count >= 2 else { return nil }
        var normalized: [String] = []
        var byNorm: [String: [Int]] = [:]
        for l in 0..<a.lineCount {
            let n = normalize(a.content(l))
            normalized.append(n)
            if n.count >= 3 { byNorm[n, default: []].append(l) }
        }

        // Anchors: (line index, y). Gutter numbers first, then unique content matches.
        var anchors: [(line: Int, y: CGFloat, row: Int)] = []
        for (i, r) in rows.enumerated() {
            if let n = r.lineNumber, n >= 1, n <= a.lineCount {
                anchors.append((n - 1, r.y, i))
                continue
            }
            let rn = normalize(r.text)
            guard rn.count >= 4 else { continue }
            if let hits = byNorm[rn], hits.count == 1 {
                anchors.append((hits[0], r.y, i))
            } else if rn.count >= 10 {
                // Lines cut off by the viewport's right edge still match as prefixes.
                var hits = normalized.indices.filter { normalized[$0].count >= 10 && (normalized[$0].hasPrefix(rn) || rn.hasPrefix(normalized[$0])) }
                // Small texts can afford a fuzzy search for rows OCR garbled a little.
                if hits.isEmpty, a.lineCount <= 800 {
                    let scored = normalized.indices.map { ($0, similarity(rn, normalized[$0])) }.filter { $0.1 >= 0.8 }
                    if let best = scored.max(by: { $0.1 < $1.1 }), scored.filter({ $0.1 >= best.1 - 0.05 }).count == 1 { hits = [best.0] }
                }
                if hits.count == 1 { anchors.append((hits[0], r.y, i)) }
            }
        }
        guard !anchors.isEmpty else { return nil }

        // Line height: from anchor pairs, falling back to row spacing.
        let sortedAnchors = anchors.sorted { $0.y < $1.y }
        var pitches: [CGFloat] = []
        for (p, q) in zip(sortedAnchors, sortedAnchors.dropFirst()) where q.line > p.line && q.line - p.line <= 40 {
            pitches.append((q.y - p.y) / CGFloat(q.line - p.line))
        }
        guard let lh = median(pitches.filter { $0 > 4 }) ?? rowPitch(rows), lh > 4 else { return nil }

        // Offset: the line at the first row's y, by consensus.
        let y0 = rows[0].y
        let bases = anchors.map { Double($0.line) - Double(($0.y - y0) / lh) }
        guard let base = median(bases) else { return nil }
        let inliers = anchors.filter { abs(Double($0.line) - Double(($0.y - y0) / lh) - base) < 0.4 }
        guard inliers.count >= 2 || (inliers.count == 1 && rows.count <= 3) else { return nil }

        var grid = CodeGrid(lineHeight: lh, refLine: base, refY: y0, left: region.minX, charWidth: 7, region: region)

        // Validate: most rows should agree with the text at their predicted line.
        var checked = 0, agreed = 0
        for r in rows {
            let rn = normalize(r.text)
            guard rn.count >= 4 else { continue }
            let l = grid.line(atY: r.y)
            guard l >= 0, l < a.lineCount else { checked += 1; continue }
            checked += 1
            if agrees(rn, normalized[l]) { agreed += 1 }
        }
        guard checked > 0, Double(agreed) / Double(checked) >= 0.55 else { return nil }

        // Columns: where indentation and line ends land on screen.
        var widths: [CGFloat] = []
        for anchor in inliers {
            let r = rows[anchor.row]
            guard !r.minX.isNaN else { continue }
            let cr = a.contentRange(anchor.line)
            var len = 0
            for k in cr.location..<NSMaxRange(cr) { len += a.text.character(at: k) == 9 ? 4 : 1 }
            if len >= 8, r.maxX < region.maxX - 4 { widths.append((r.maxX - r.minX) / CGFloat(len)) }
        }
        guard let cw = median(widths) else { return nil }
        var colLefts: [CGFloat] = []
        for anchor in inliers {
            let r = rows[anchor.row]
            guard !r.minX.isNaN else { continue }
            colLefts.append(r.minX - CGFloat(a.indent(anchor.line)) * cw)
        }
        guard let left = median(colLefts) else { return nil }
        grid.charWidth = cw
        grid.left = left
        return grid
    }

    /// No source text: rebuild the code (indentation included) from OCR rows alone.
    static func reconstruct(rows: [Row], region: CGRect) -> (text: String, grid: CodeGrid)? {
        let usable = rows.filter { !$0.minX.isNaN && !$0.text.isEmpty }
        guard usable.count >= 2, let lh = rowPitch(usable) else { return nil }
        let widths = usable.filter { $0.text.count >= 8 }.map { ($0.maxX - $0.minX) / CGFloat($0.text.count) }
        guard let cw = median(widths), cw > 2 else { return nil }
        let left = usable.map(\.minX).min() ?? region.minX
        let y0 = usable[0].y
        var lines: [String] = []
        for r in usable {
            let index = ((r.y - y0) / lh).rounded().clampedInt
            guard index >= 0, index < 20_000 else { continue }
            while lines.count < index { lines.append("") }
            let indent = min(400, max(0, ((r.minX - left) / cw).rounded().clampedInt))
            let row = String(repeating: " ", count: indent) + r.text
            if lines.count == index { lines.append(row) } else { lines[index] += " " + r.text }
        }
        let grid = CodeGrid(lineHeight: lh, refLine: 0, refY: y0, left: left, charWidth: cw, region: region)
        return (lines.joined(separator: "\n"), grid)
    }
}
