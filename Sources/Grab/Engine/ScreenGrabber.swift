import AppKit
import ScreenCaptureKit
import Vision

/// A screenshot of a rectangle, with enough geometry to map pixels back to the screen.
struct Capture {
    let image: CGImage
    /// The captured rectangle in global top-left points.
    let rect: CGRect

    var scale: CGFloat { CGFloat(image.width) / max(rect.width, 1) }
    var pointSize: CGSize { rect.size }

    /// Vision's normalised, bottom-left rectangles → global top-left points.
    func screenRect(forNormalized n: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + n.minX * rect.width,
            y: rect.minY + (1 - n.maxY) * rect.height,
            width: n.width * rect.width,
            height: n.height * rect.height
        )
    }
}

struct LoupeSample: Equatable {
    let image: CGImage
    let color: RGBAColor
    let centerX: Int
    let centerY: Int
    let pixels: Int
}

enum GrabError: LocalizedError {
    case noDisplay, empty, noText, nothing, noFile
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display under the cursor"
        case .empty: "Nothing to capture"
        case .noText: "No text found"
        case .nothing: "Nothing to grab here"
        case .noFile: "That file doesn't exist"
        case .failed(let why): why
        }
    }
}

/// ScreenCaptureKit wrapper. Our own overlay windows are always excluded, so the
/// glowing border never ends up in your screenshots, OCR or colour picks.
actor ScreenGrabber {
    static let shared = ScreenGrabber()

    private var content: SCShareableContent?
    private var fetchedAt = Date.distantPast
    private var excluded = Set<CGWindowID>()
    /// Whether the overlay is hidden from screen capture (`sharingType = .none`).
    /// When it is, the system's region capture can be used directly, which is the
    /// only path that applies EDR tone mapping and colour management correctly.
    private var overlayHidden = true

    func setOverlayHidden(_ hidden: Bool) {
        overlayHidden = hidden
    }

    private var useSystemCapture: Bool {
        if #available(macOS 15.2, *) { return overlayHidden }
        return false
    }

    /// Native backing scale of the display containing `p`, without AppKit.
    private static func display(containing p: CGPoint) -> (bounds: CGRect, scale: CGFloat)? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        guard let id = ids.first(where: { CGDisplayBounds($0).contains(p) }) else { return nil }
        let b = CGDisplayBounds(id)
        let px = CGDisplayCopyDisplayMode(id).map { CGFloat($0.pixelWidth) } ?? b.width * 2
        return (b, max(1, px / max(b.width, 1)))
    }

    func setExcludedWindows(_ ids: Set<CGWindowID>) {
        excluded = ids
        content = nil
    }

    func invalidate() {
        content = nil
    }

    func warmUp() async {
        _ = try? await shareable()
    }

    private func shareable() async throws -> SCShareableContent {
        if let c = content, Date().timeIntervalSince(fetchedAt) < 20 {
            return c
        }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        content = c
        fetchedAt = Date()
        return c
    }

    private func filter(for display: SCDisplay, in c: SCShareableContent) -> SCContentFilter {
        let skip = c.windows.filter { excluded.contains($0.windowID) }
        return SCContentFilter(display: display, excludingWindows: skip)
    }

    /// Captures `rect` (global top-left points). `maxPixels` downsamples huge areas
    /// for analysis; copies use full resolution.
    func capture(_ rect: CGRect, maxPixels: CGFloat? = nil) async throws -> Capture {
        if #available(macOS 15.2, *), useSystemCapture {
            guard let d = Self.display(containing: rect.center) else { throw GrabError.noDisplay }
            let r = rect.intersection(d.bounds)
            guard !r.isNull, r.width >= 1, r.height >= 1 else { throw GrabError.empty }
            var image = try await SCScreenshotManager.captureImage(in: r)
            if let maxPixels, CGFloat(image.width * image.height) > maxPixels {
                let side = (maxPixels / CGFloat(image.width * image.height)).squareRoot() * CGFloat(max(image.width, image.height))
                image = Thumbnail.make(image, maxSide: side) ?? image
            }
            return Capture(image: image, rect: r)
        }

        let c = try await shareable()
        guard let display = c.displays.first(where: { $0.frame.contains(rect.center) })
            ?? c.displays.first(where: { $0.frame.intersects(rect) }) else { throw GrabError.noDisplay }

        let r = rect.intersection(display.frame)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { throw GrabError.empty }

        let f = filter(for: display, in: c)
        var scale = CGFloat(f.pointPixelScale)
        if let maxPixels, r.width * r.height * scale * scale > maxPixels {
            scale = max(0.25, (maxPixels / (r.width * r.height)).squareRoot())
        }

        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: r.minX - display.frame.minX, y: r.minY - display.frame.minY, width: r.width, height: r.height)
        cfg.width = max(1, Int((r.width * scale).rounded()))
        cfg.height = max(1, Int((r.height * scale).rounded()))
        cfg.showsCursor = false
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
        return Capture(image: image, rect: r)
    }

    /// A small block of native pixels centred on `p`, for the colour loupe.
    func loupe(at p: CGPoint, pixels n: Int = 15) async throws -> LoupeSample {
        if #available(macOS 15.2, *), useSystemCapture {
            guard let d = Self.display(containing: p) else { throw GrabError.noDisplay }
            let s = d.scale
            let dw = Int((d.bounds.width * s).rounded())
            let dh = Int((d.bounds.height * s).rounded())
            let px = Int(((p.x - d.bounds.minX) * s).rounded(.down))
            let py = Int(((p.y - d.bounds.minY) * s).rounded(.down))
            let half = n / 2
            let ox = min(max(px - half, 0), max(dw - n, 0))
            let oy = min(max(py - half, 0), max(dh - n, 0))
            let rect = CGRect(x: d.bounds.minX + CGFloat(ox) / s, y: d.bounds.minY + CGFloat(oy) / s,
                              width: CGFloat(n) / s, height: CGFloat(n) / s)
            var image = try await SCScreenshotManager.captureImage(in: rect)
            // The system may round the region up by a pixel; keep exactly n×n.
            if image.width > n || image.height > n, let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: n, height: n)) {
                image = cropped
            }
            let cx = min(max(px - ox, 0), image.width - 1)
            let cy = min(max(py - oy, 0), image.height - 1)
            guard let color = PixelReader.color(in: image, x: cx, y: cy) else { throw GrabError.empty }
            return LoupeSample(image: image, color: color, centerX: cx, centerY: cy, pixels: image.width)
        }

        let c = try await shareable()
        guard let display = c.displays.first(where: { $0.frame.contains(p) }) else { throw GrabError.noDisplay }
        let f = filter(for: display, in: c)
        let s = CGFloat(f.pointPixelScale)
        let dw = Int((display.frame.width * s).rounded())
        let dh = Int((display.frame.height * s).rounded())
        let px = Int(((p.x - display.frame.minX) * s).rounded(.down))
        let py = Int(((p.y - display.frame.minY) * s).rounded(.down))
        let half = n / 2
        let ox = min(max(px - half, 0), max(dw - n, 0))
        let oy = min(max(py - half, 0), max(dh - n, 0))

        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: CGFloat(ox) / s, y: CGFloat(oy) / s, width: CGFloat(n) / s, height: CGFloat(n) / s)
        cfg.width = n
        cfg.height = n
        cfg.showsCursor = false
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg)
        let cx = min(max(px - ox, 0), image.width - 1)
        let cy = min(max(py - oy, 0), image.height - 1)
        guard let color = PixelReader.color(in: image, x: cx, y: cy) else { throw GrabError.empty }
        return LoupeSample(image: image, color: color, centerX: cx, centerY: cy, pixels: n)
    }
}

enum PixelReader {
    /// Reads one pixel (top-left origin) as sRGB.
    static func color(in image: CGImage, x: Int, y: Int) -> RGBAColor? {
        let w = image.width, h = image.height
        guard x >= 0, y >= 0, x < w, y < h,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -x, y: -(h - 1 - y), width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self)
        let a = Double(p[3]) / 255
        guard a > 0 else { return RGBAColor(r: 0, g: 0, b: 0, a: 0) }
        return RGBAColor(r: Double(p[0]) / 255 / a, g: Double(p[1]) / 255 / a, b: Double(p[2]) / 255 / a, a: a)
    }
}

// MARK: - Vision

struct OCRLine {
    let text: String
    let rect: CGRect
    let candidate: VNRecognizedText
}

struct Barcode {
    let payload: String
    let kind: String
    let rect: CGRect
}

enum VisionEngine {
    static func recognize(_ cap: Capture, accurate: Bool, correction: Bool? = nil) -> [OCRLine] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = accurate ? .accurate : .fast
        req.usesLanguageCorrection = correction ?? accurate
        req.automaticallyDetectsLanguage = true
        req.minimumTextHeight = Float(min(0.05, max(0.0015, 7.0 / Double(max(cap.image.height, 1)))))
        let handler = VNImageRequestHandler(cgImage: cap.image, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first, let t = c.string.nonBlank else { return nil }
            // Icons and textures produce stray one-letter "words"; skip the unconfident ones.
            let letters = t.filter { $0.isLetter || $0.isNumber }.count
            if c.confidence < 0.3 || (letters < 2 && c.confidence < 0.95) { return nil }
            return OCRLine(text: c.string, rect: cap.screenRect(forNormalized: o.boundingBox), candidate: c)
        }
    }

    /// Joins lines top-to-bottom, keeping lines that sit side by side on one row.
    static func join(_ lines: [OCRLine]) -> String {
        let sorted = lines.sorted { a, b in
            if abs(a.rect.midY - b.rect.midY) < min(a.rect.height, b.rect.height) * 0.5 { return a.rect.minX < b.rect.minX }
            return a.rect.midY < b.rect.midY
        }
        var out = ""
        var prev: CGRect?
        for l in sorted {
            if let p = prev {
                let sameRow = abs(l.rect.midY - p.midY) < min(l.rect.height, p.height) * 0.5
                out += sameRow ? "  " : "\n"
            }
            out += l.text
            prev = l.rect
        }
        return out
    }

    static func word(in line: OCRLine, at p: CGPoint, capture: Capture) -> (String, CGRect)? {
        let s = line.candidate.string
        var result: (String, CGRect)?
        s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byWords) { sub, range, _, stop in
            guard let sub, let box = try? line.candidate.boundingBox(for: range) else { return }
            let r = capture.screenRect(forNormalized: box.boundingBox)
            if r.insetBy(dx: -2, dy: -3).contains(p) {
                result = (sub, r)
                stop = true
            }
        }
        return result
    }

    static func barcodes(_ cap: Capture) -> [Barcode] {
        let req = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cap.image, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        var seen = Set<String>()
        return (req.results ?? []).compactMap { o in
            guard let payload = o.payloadStringValue, payload.nonBlank != nil, seen.insert(payload).inserted else { return nil }
            return Barcode(payload: payload, kind: name(of: o.symbology), rect: cap.screenRect(forNormalized: o.boundingBox))
        }
    }

    @available(macOS 15.0, *)
    static func name(of s: BarcodeSymbology) -> String {
        switch s {
        case .qr, .microQR: "QR"
        case .aztec: "Aztec"
        case .pdf417, .microPDF417: "PDF417"
        case .dataMatrix: "Data Matrix"
        default: "Barcode"
        }
    }

    static func name(of s: VNBarcodeSymbology) -> String {
        switch s {
        case .qr, .microQR: "QR"
        case .aztec: "Aztec"
        case .pdf417, .microPDF417: "PDF417"
        case .dataMatrix: "Data Matrix"
        default: "Barcode"
        }
    }
}
