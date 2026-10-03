import AppKit
import CoreImage
import Vision

/// Text read from pixels, with its structure: paragraphs → lines → words, all in
/// global screen points. Plus any barcodes seen along the way.
struct TextLayout {
    struct Word {
        var text: String
        var rect: CGRect
        init(text: String, rect: CGRect) {
            // Like double-clicking a word: no sentence punctuation or wrapping quotes.
            var t = text.trimmingCharacters(in: .whitespaces)
            while let l = t.last, ".,;:!?)]}\"'”’".contains(l), t.count > 1 { t.removeLast() }
            while let f = t.first, "([{\"'“‘".contains(f), t.count > 1 { t.removeFirst() }
            self.text = t
            self.rect = rect
        }
    }
    struct Line { var text: String; var rect: CGRect; var words: [Word] }
    struct Paragraph { var text: String; var rect: CGRect; var lines: [Line] }

    struct Table { var rect: CGRect; var rows: [[String]]
        var tsv: String { rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") }
    }

    var paragraphs: [Paragraph] = []
    var barcodes: [Barcode] = []
    var tables: [Table] = []

    var isEmpty: Bool { paragraphs.isEmpty }
    var text: String { paragraphs.map(\.text).joined(separator: "\n") }

    /// What's under `p`: the paragraph and line containing it, and the word if the
    /// cursor is right on one.
    func hit(_ p: CGPoint) -> (word: Word?, line: Line, paragraph: Paragraph)? {
        for para in paragraphs where para.rect.insetBy(dx: -6, dy: -4).contains(p) {
            guard let line = para.lines.first(where: { $0.rect.insetBy(dx: -6, dy: -max(2, $0.rect.height * 0.25)).contains(p) })
            else { continue }
            let word = line.words.first { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }
            return (word, line, para)
        }
        return nil
    }
}

enum TextReader {
    /// Reads text (and barcodes) in a capture. Accurate recognition only: the fast
    /// model misses small text and garbles punctuation, which is what made OCR flaky.
    static func read(_ cap: Capture, correction: Bool = true, barcodes: Bool = true) async -> TextLayout {
        // Text down to ~7 px tall, whatever the size of the capture.
        let minHeight = Float(min(0.05, max(0.0015, 7.0 / Double(max(cap.image.height, 1)))))
        if #available(macOS 26.0, *) {
            if let layout = await readDocument(cap, minHeight: minHeight, correction: correction, barcodes: barcodes) {
                return layout
            }
        }
        return readLines(cap, minHeight: minHeight, correction: correction, barcodes: barcodes)
    }

    @available(macOS 26.0, *)
    private static func readDocument(_ cap: Capture, minHeight: Float, correction: Bool, barcodes: Bool) async -> TextLayout? {
        var req = RecognizeDocumentsRequest()
        req.textRecognitionOptions.minimumTextHeightFraction = minHeight
        req.textRecognitionOptions.useLanguageCorrection = correction
        req.textRecognitionOptions.automaticallyDetectLanguage = true
        req.barcodeDetectionOptions.enabled = barcodes
        guard let observations = try? await req.perform(on: cap.image) else { return nil }

        var layout = TextLayout()
        for o in observations {
            var containers = o.document.paragraphs
            if let title = o.document.title,
               !containers.contains(where: { $0.boundingRegion.boundingBox.cgRect.intersects(title.boundingRegion.boundingBox.cgRect) }) {
                containers.insert(title, at: 0)
            }
            for p in containers {
                var lines: [TextLayout.Line] = p.lines.compactMap { l in
                    guard let c = l.topCandidates(1).first, c.string.nonBlank != nil else { return nil }
                    return TextLayout.Line(text: c.string, rect: cap.screenRect(forNormalized: l.boundingBox.cgRect), words: [])
                }
                guard !lines.isEmpty else { continue }
                // Words: from the document if it has them, else from each line's own boxes.
                let words: [TextLayout.Word] = (p.words ?? []).compactMap { w in
                    guard let c = w.topCandidates(1).first, let t = c.string.nonBlank else { return nil }
                    return TextLayout.Word(text: t.trimmingCharacters(in: .whitespaces), rect: cap.screenRect(forNormalized: w.boundingBox.cgRect))
                }
                for i in lines.indices {
                    let lr = lines[i].rect
                    lines[i].words = words.filter { w in
                        let mid = w.rect.midY
                        return mid >= lr.minY - 2 && mid <= lr.maxY + 2 && w.rect.midX >= lr.minX - 2 && w.rect.midX <= lr.maxX + 2
                    }.sorted { $0.rect.minX < $1.rect.minX }
                }
                for (i, l) in p.lines.enumerated() where i < lines.count && lines[i].words.isEmpty {
                    if let c = l.topCandidates(1).first { lines[i].words = splitWords(c, cap: cap) }
                }
                let rect = cap.screenRect(forNormalized: p.boundingRegion.boundingBox.cgRect)
                    .union(lines.reduce(CGRect.null) { $0.union($1.rect) })
                let text = lines.map(\.text).joined(separator: "\n")
                layout.paragraphs.append(TextLayout.Paragraph(text: text, rect: rect, lines: lines))
            }
            for t in o.document.tables {
                let rows = t.rows.map { row in
                    row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
                }
                guard rows.count >= 2, (rows.first?.count ?? 0) >= 2 else { continue }
                layout.tables.append(TextLayout.Table(rect: cap.screenRect(forNormalized: t.boundingRegion.boundingBox.cgRect), rows: rows))
            }
            for b in o.document.barcodes {
                guard let payload = b.payloadString ?? b.payloadData.flatMap({ String(data: $0, encoding: .utf8) }), payload.nonBlank != nil
                else { continue }
                layout.barcodes.append(Barcode(payload: payload, kind: VisionEngine.name(of: b.symbology), rect: cap.screenRect(forNormalized: b.boundingBox.cgRect)))
            }
        }
        layout.paragraphs.sort { $0.rect.minY != $1.rect.minY ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        return layout
    }

    @available(macOS 26.0, *)
    private static func splitWords(_ c: RecognizedText, cap: Capture) -> [TextLayout.Word] {
        var out: [TextLayout.Word] = []
        let s = c.string
        s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byWords) { sub, range, _, _ in
            guard let sub, let box = c.boundingBox(for: range) else { return }
            out.append(TextLayout.Word(text: sub, rect: cap.screenRect(forNormalized: box.boundingBox.cgRect)))
        }
        return out
    }

    /// Older systems: accurate line recognition, words from each line's boxes, and
    /// paragraphs from layout (lines close together, aligned, of similar height).
    private static func readLines(_ cap: Capture, minHeight: Float, correction: Bool, barcodes: Bool) -> TextLayout {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = correction
        req.automaticallyDetectsLanguage = true
        req.minimumTextHeight = minHeight
        let handler = VNImageRequestHandler(cgImage: cap.image, options: [:])
        try? handler.perform([req])
        var lines: [TextLayout.Line] = []
        for o in req.results ?? [] {
            guard let c = o.topCandidates(1).first, c.string.nonBlank != nil else { continue }
            var words: [TextLayout.Word] = []
            let s = c.string
            s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byWords) { sub, range, _, _ in
                guard let sub, let box = try? c.boundingBox(for: range) else { return }
                words.append(TextLayout.Word(text: sub, rect: cap.screenRect(forNormalized: box.boundingBox)))
            }
            lines.append(TextLayout.Line(text: s, rect: cap.screenRect(forNormalized: o.boundingBox), words: words))
        }
        var layout = TextLayout()
        layout.paragraphs = cluster(lines)
        if barcodes { layout.barcodes = VisionEngine.barcodes(cap) }
        return layout
    }

    static func cluster(_ input: [TextLayout.Line]) -> [TextLayout.Paragraph] {
        let lines = input.sorted { $0.rect.minY < $1.rect.minY }
        var groups: [[TextLayout.Line]] = []
        for l in lines {
            if let gi = groups.lastIndex(where: { g in
                guard let last = g.last else { return false }
                let gap = l.rect.minY - last.rect.maxY
                let h = max(last.rect.height, l.rect.height)
                let similar = abs(l.rect.height - last.rect.height) < h * 0.35
                let aligned = abs(l.rect.minX - last.rect.minX) < h * 1.5 || (l.rect.minX < last.rect.maxX && l.rect.maxX > last.rect.minX)
                return gap < h * 0.9 && gap > -h * 0.5 && similar && aligned
            }) {
                groups[gi].append(l)
            } else {
                groups.append([l])
            }
        }
        return groups.map { g in
            TextLayout.Paragraph(text: g.map(\.text).joined(separator: "\n"), rect: g.reduce(CGRect.null) { $0.union($1.rect) }, lines: g)
        }
    }

    // MARK: Warm-up

    /// The first accurate recognition after a reboot can take many seconds while the
    /// model loads. Do that in the background at launch, not on your first grab.
    static func warmUp() async {
        let size = NSSize(width: 360, height: 120)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 360, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("Grab warm up 123" as NSString).draw(at: NSPoint(x: 12, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 28)])
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return }
        let cap = Capture(image: cg, rect: CGRect(origin: .zero, size: size))
        _ = await read(cap)
        _ = BarcodeScanner.detect(in: cap)
    }
}

/// Finds QR codes and barcodes near the cursor. Detectors work at a fixed internal
/// resolution, so a code in a big capture is often too small to read; scanning a
/// tight square around the cursor (then a wider one) reads them reliably.
enum BarcodeScanner {
    static func detect(in cap: Capture) -> [Barcode] {
        var found = VisionEngine.barcodes(cap)
        if found.isEmpty {
            // Second opinion: Core Image's QR reader handles some stylised codes better.
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            for f in detector?.features(in: CIImage(cgImage: cap.image)) ?? [] {
                guard let q = f as? CIQRCodeFeature, let msg = q.messageString, msg.nonBlank != nil else { continue }
                // Core Image bounds are in image pixels, bottom-left origin.
                let b = q.bounds
                let n = CGRect(x: b.minX / CGFloat(cap.image.width), y: b.minY / CGFloat(cap.image.height),
                               width: b.width / CGFloat(cap.image.width), height: b.height / CGFloat(cap.image.height))
                found.append(Barcode(payload: msg, kind: "QR", rect: cap.screenRect(forNormalized: n)))
            }
        }
        return found
    }

    /// The code under (or right next to) `p`, if any.
    static func scan(at p: CGPoint, within bounds: CGRect) async -> Barcode? {
        for side in [300.0, 720.0] as [CGFloat] {
            let r = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side).intersection(bounds)
            guard r.width > 24, r.height > 24, let cap = try? await ScreenGrabber.shared.capture(r, maxPixels: 4_000_000) else { continue }
            let codes = detect(in: cap)
            if let hit = codes.first(where: { $0.rect.insetBy(dx: -10, dy: -10).contains(p) }) { return hit }
        }
        return nil
    }
}
