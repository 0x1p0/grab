import SwiftUI
import Observation

enum Preview: Equatable {
    case none
    case loading(String)
    case text(String, meta: String)
    case link(host: String, path: String)
    case code(String, kind: String)
    case file(name: String, folder: String, url: URL)
    case image(width: Int, height: Int, thumb: CGImage?)
    case color(RGBAColor, formatted: String)
    case snippet(String, meta: String)
    case unavailable(String)
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var success: Bool
    var title: String
    var detail: String
    var mode: GrabMode
    var color: RGBAColor?
    var thumb: CGImage?
}

struct Fly: Equatable, Identifiable {
    let id = UUID()
    var from: CGPoint
    var to: CGPoint
    var mode: GrabMode
    var color: RGBAColor?
}

/// Everything the overlay draws. Coordinates are global top-left points.
@Observable
final class OverlayModel {
    var visible = false
    var session = 0
    var target: CGRect?
    var targetIsText = false
    var scopeLabel = ""
    var scopeIndex = 0
    var scopeCount = 0
    var mode: GrabMode = .text
    var options: [ModeOption] = []
    var preview: Preview = .none
    var cursor: CGPoint = .zero
    var loupe: LoupeSample?
    var toast: Toast?
    var flash = 0
    var busy = false
    var hints = true
    var spotlight = true
    var warning: String?
    var fly: Fly?
    var formats: [FormatOption] = []
    var format: String?
    /// A color written in text (#ED6E2A) rather than picked from pixels.
    var literalColor: RGBAColor?

    /// Color mode reading pixels: show the loupe instead of a border.
    var pixelColor: Bool { mode == .color && literalColor == nil }

    var tint: [Color] { Theme.colors(for: mode, sample: mode == .color ? (literalColor ?? loupe?.color) : nil) }

    func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<OverlayModel, T>, _ value: T) {
        if self[keyPath: kp] != value { self[keyPath: kp] = value }
    }
}

enum Theme {
    static let brand: [Color] = [Color(hex: 0xFF8A3D), Color(hex: 0xEC4F7C), Color(hex: 0x7C5CFF)]

    static func colors(for mode: GrabMode, sample: RGBAColor? = nil) -> [Color] {
        switch mode {
        case .text: return [Color(hex: 0x2F7BFF), Color(hex: 0x22C3EE)]
        case .link: return [Color(hex: 0x7C5CFF), Color(hex: 0xD946EF)]
        case .qr: return [Color(hex: 0x10B981), Color(hex: 0x84CC16)]
        case .file: return [Color(hex: 0x0EA5E9), Color(hex: 0x6366F1)]
        case .image: return [Color(hex: 0xFF7A1A), Color(hex: 0xF43F5E)]
        case .color:
            if let s = sample {
                let c = Color(nsColor: s.nsColor)
                return [c, c.opacity(0.75)]
            }
            return [Color(hex: 0xF59E0B), Color(hex: 0xEF4444)]
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Collection {
    subscript(safe i: Index) -> Element? { indices.contains(i) ? self[i] : nil }
}
