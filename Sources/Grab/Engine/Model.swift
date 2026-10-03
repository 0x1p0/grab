import AppKit
import ApplicationServices

/// What a grab produces.
enum GrabMode: Int, CaseIterable, Identifiable {
    case text, link, qr, file, image, color
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .qr: "QR"
        case .file: "File"
        case .image: "Image"
        case .color: "Color"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.quote"
        case .link: "link"
        case .qr: "qrcode"
        case .file: "doc.fill"
        case .image: "photo"
        case .color: "eyedropper.halffull"
        }
    }

    var needsScreenRecording: Bool { self == .image || self == .color }
}

/// One option in the HUD's mode bar.
struct ModeOption: Equatable, Identifiable {
    var mode: GrabMode
    var enabled: Bool
    var title: String
    var symbol: String
    var id: Int { mode.rawValue }
}

/// The granularity of a scope, used to keep the user's choice sticky as they move.
enum ScopeKind: Equatable {
    case word, line, sentence, paragraph
    case ocrWord, ocrLine, ocrParagraph
    case barcode
    case element
    case window
    /// Code-aware: symbol, line, block, function… (see `Scope.codeKind`).
    case code
    /// Tables: a cell, row, column or the whole table.
    case table
    /// Every item of a list, menu or sidebar.
    case list

    var isTextRange: Bool {
        switch self {
        case .word, .line, .sentence, .paragraph, .ocrWord, .ocrLine, .ocrParagraph, .code: true
        default: false
        }
    }
}

/// What Grab knows about a piece of code it found.
struct CodeInfo: Equatable {
    var kind: CodeScope.Kind
    var language: String
    var fileURL: URL?
    /// 1-based, inclusive; nil when line numbers don't mean anything (web snippets).
    var lines: ClosedRange<Int>?
    var isTerminal = false
}

/// A region of the screen showing code whose text we can get, but whose layout
/// has to be learned from pixels (Chrome, Electron editors…).
struct CodeRegion {
    enum Source {
        case text(String)
        case file(URL)
        case ocr
    }

    var rect: CGRect
    var source: Source
    var language: CodeLanguage?
    var title: String
    var isTerminal = false

    var key: String {
        var id = ""
        switch source {
        case .text(let t): id = "t\(t.count):\(t.hashValue)"
        case .file(let u): id = "f" + u.path
        case .ocr: id = "o"
        }
        return "\(rect.gridKey ?? "none")|\(id)"
    }
}

/// A table Grab can read rows and columns from.
struct TableRef {
    var table: AXUIElement
    var row: AXUIElement?
    var column: Int?
    enum Part { case row, column, table, list }
    var part: Part
}

/// A rectangle on screen that could be grabbed, plus whatever we know about it.
/// Frames are in global "top-left origin" points (the accessibility coordinate space).
struct Scope: Identifiable {
    let id = UUID()
    var kind: ScopeKind
    var frame: CGRect
    var label: String
    var element: AXUIElement?
    var role: String?
    /// Distance from the element under the cursor (0 = the leaf).
    var depth = 0

    /// Text known from accessibility (or OCR for OCR scopes).
    var text: String?
    /// The element may have text we haven't fetched yet (containers).
    var textPending = false
    /// Recognised from pixels when there's no accessibility text.
    var ocrText: String?
    /// `text` came from OCR rather than accessibility.
    var textIsOCR = false
    var analysisDone = false

    var linkURL: URL?
    /// The scope *is* the link (as opposed to text inside one).
    var linkIsSelf = false
    var fileURL: URL?
    var imageURL: URL?
    var barcode: String?
    var barcodeKind: String?
    /// Images, video, canvases: things whose content is pixels.
    var isVisual = false
    var code: CodeInfo?
    var tableRef: TableRef?
    /// Identifies a table part's lazily-read text.
    var tableKey: String? {
        guard let t = tableRef else { return nil }
        return "\(CFHash(t.table))|\(t.part)|\(t.column ?? -1)|\(t.row.map { CFHash($0) } ?? 0)"
    }
    /// The inspector's strong suggestion for the default (e.g. the function whose signature you're pointing at).
    var isPreferred = false
    /// A file path mentioned in the text under the cursor (offered as File, never the default).
    var pathURL: URL?
    /// A color written in the text under the cursor (#ED6E2A, rgb(…)).
    var colorLiteral: RGBAColor?
    /// A big, featureless container directly under the cursor (page background,
    /// a window, a canvas). Pointing at one most likely means "this colour".
    var isBackdrop = false
    var thumbnail: CGImage?
    var pixelSize: CGSize?
    /// A date, phone number, price, JSON… recognized in the text (extra ⌥ Tab formats).
    var smart: SmartValue?
    /// A container with form controls inside: offers "Fields" as JSON.
    var hasFields = false
    /// Lives inside a web page (offers a CSS selector).
    var inWeb = false
    /// A video on a page whose links can carry a timestamp (YouTube…).
    var videoPage: URL?

    var bestText: String? {
        if let t = text?.nonBlank { return t }
        return ocrText?.nonBlank
    }

    var area: CGFloat { frame.width * frame.height }

    func sameTarget(as other: Scope) -> Bool {
        guard kind == other.kind else { return false }
        if let a = element, let b = other.element { return CFEqual(a, b) && (kind == .element || kind == .window) }
        return frame.isNearlyEqual(other.frame, tolerance: 1.5)
    }
}

/// Everything known about the point under the cursor.
struct Inspection {
    var point: CGPoint
    var pid: pid_t
    var appName: String?
    var bundleID: String?
    var leaf: AXUIElement?
    var webArea: AXUIElement?
    var scopes: [Scope]
    var defaultID: UUID?
    /// Code that still needs its layout read from pixels.
    var codeRegion: CodeRegion?
    /// Directory the frontmost terminal/editor window is showing, for relative paths.
    var workingDirectory: URL?
    /// Where the content comes from, for "Cite" (page or window title, page URL).
    var sourceTitle: String?
    var sourceURL: URL?
    #if DEBUG
    var debugChain: [String] = []
    #endif

    var defaultIndex: Int {
        guard let id = defaultID, let i = scopes.firstIndex(where: { $0.id == id }) else { return 0 }
        return i
    }

    mutating func sortScopes() {
        scopes = Inspection.ordered(scopes)
    }

    /// Smallest first; near-identical rectangles collapse to the most useful one.
    static func ordered(_ input: [Scope]) -> [Scope] {
        let sorted = input.enumerated().sorted { a, b in
            if abs(a.element.area - b.element.area) < 1 { return a.offset < b.offset }
            return a.element.area < b.element.area
        }.map(\.element)

        var out: [Scope] = []
        for s in sorted {
            if let i = out.lastIndex(where: { $0.frame.isNearlyEqual(s.frame, tolerance: max(3, 0.015 * max($0.frame.width, $0.frame.height))) }) {
                if s.wins(over: out[i]) { out[i] = merged(keep: s, drop: out[i]) }
                else { out[i] = merged(keep: out[i], drop: s) }
                continue
            }
            out.append(s)
        }
        return out
    }

    private static func merged(keep: Scope, drop: Scope) -> Scope {
        var k = keep
        if k.text?.nonBlank == nil, let t = drop.text?.nonBlank, !k.isVisual { k.text = t; k.textPending = false }
        if k.linkURL == nil { k.linkURL = drop.linkURL }
        if k.fileURL == nil { k.fileURL = drop.fileURL }
        if k.imageURL == nil { k.imageURL = drop.imageURL }
        if k.pathURL == nil { k.pathURL = drop.pathURL }
        if k.colorLiteral == nil { k.colorLiteral = drop.colorLiteral }
        return k
    }
}

extension Scope {
    /// Decides which of two scopes covering the same rectangle to keep.
    func wins(over other: Scope) -> Bool {
        if richness != other.richness { return richness > other.richness }
        // Same box, both text: the one with more text is what the box really shows.
        if kind.isTextRange && other.kind.isTextRange { return (text?.count ?? 0) > (other.text?.count ?? 0) }
        return false
    }

    /// Used when two scopes cover the same rectangle.
    var richness: Int {
        if kind == .barcode { return 7 }
        if fileURL != nil { return 6 }
        if isVisual && kind == .element { return 5 }
        if linkIsSelf { return 4 }
        if kind == .table || kind == .list { return 3 }
        if kind.isTextRange { return 3 }
        if role == "AXButton" || role == "AXMenuItem" || role == "AXDockItem" { return 1 }
        return 0
    }
}

/// A pixel colour in sRGB.
struct RGBAColor: Equatable {
    var r: Double, g: Double, b: Double, a: Double = 1

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    private func byte(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }

    var hex: String { String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b)) }

    var hsl: (h: Int, s: Int, l: Int) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        var h = 0.0, s = 0.0
        let d = maxC - minC
        if d > 0.00001 {
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            switch maxC {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h /= 6
        }
        return (Int((h * 360).rounded()) % 360, Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    /// Perceived brightness, for picking legible text on top of the colour.
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func formatted(_ format: ColorFormat) -> String {
        switch format {
        case .hex: return hex
        case .hexLower: return hex.lowercased()
        case .rgb: return "rgb(\(byte(r)), \(byte(g)), \(byte(b)))"
        case .hsl:
            let v = hsl
            return "hsl(\(v.h), \(v.s)%, \(v.l)%)"
        case .swiftUI:
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b)
        }
    }
}

enum ColorFormat: String, CaseIterable, Identifiable {
    case hex, hexLower, rgb, hsl, swiftUI
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hex: "HEX"
        case .hexLower: "hex (lowercase)"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .swiftUI: "SwiftUI"
        }
    }
}

/// The thing that lands on the clipboard.
enum Payload {
    case text(String)
    case link(URL)
    case code(String)
    case file(URL)
    case image(CGImage, pointSize: CGSize)
    case color(RGBAColor, String)
}

// MARK: - Small helpers

extension String {
    var nonBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : self
    }

    /// Normalises text pulled from accessibility: drops attachment placeholders,
    /// unifies line endings and trims the edges.
    var cleanedForClipboard: String {
        var s = replacingOccurrences(of: "\u{FFFC}", with: "")
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func truncated(_ n: Int) -> String {
        count > n ? String(prefix(n - 1)) + "…" : self
    }

    /// A single-line version for previews.
    var oneLine: String {
        components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
    }
}

extension CGRect {
    func isNearlyEqual(_ o: CGRect, tolerance t: CGFloat) -> Bool {
        abs(minX - o.minX) <= t && abs(minY - o.minY) <= t && abs(maxX - o.maxX) <= t && abs(maxY - o.maxY) <= t
    }

    var isUsable: Bool { isFinite && width >= 2 && height >= 2 }

    /// Real numbers in every field: not null, not infinite, no NaN from a confused app.
    var isFinite: Bool {
        !isNull && !isInfinite && origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }

    /// A short cache key for this rectangle on a whole-point grid, or nil when it
    /// isn't a real rectangle (converting those to Int would trap).
    var gridKey: String? {
        guard isFinite else { return nil }
        let f = integral
        return "\(f.minX.clampedInt),\(f.minY.clampedInt),\(f.width.clampedInt),\(f.height.clampedInt)"
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

enum ScreenSpace {
    /// Height of the primary display, which anchors both coordinate systems.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// Cocoa (bottom-left) → accessibility (top-left).
    static func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func mouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Screen frames in AX coordinates. Safe to call off the main thread because
    /// it goes through CoreGraphics rather than NSScreen.
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { CGDisplayBounds($0) }
    }
}

extension CGFloat {
    /// Int conversion that never traps: NaN becomes 0, infinities and huge values clamp.
    var clampedInt: Int {
        guard !isNaN else { return 0 }
        return Int(Swift.max(-1e9, Swift.min(1e9, self)))
    }
}
