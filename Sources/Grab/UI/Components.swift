import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

/// Blurs whatever is behind the window: Liquid Glass on macOS 26+, vibrancy before that.
struct HUDBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = cornerRadius
            // A touch of tint keeps the HUD legible over busy or bright content.
            g.tintColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.black.withAlphaComponent(0.32)
                    : NSColor.white.withAlphaComponent(0.5)
            }
            return g
        }
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum Icons {
    /// The menu bar glyph: viewfinder corners around a dot.
    static func statusIcon(filled: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let inset: CGFloat = 2.25
            let arm: CGFloat = 4.6
            let rad: CGFloat = 2.2
            let box = r.insetBy(dx: inset, dy: inset)
            let p = NSBezierPath()
            p.lineWidth = 1.6
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            // Each corner: an L with a rounded bend.
            func corner(_ c: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
                p.move(to: CGPoint(x: c.x, y: c.y + dy * arm))
                p.line(to: CGPoint(x: c.x, y: c.y + dy * rad))
                p.curve(to: CGPoint(x: c.x + dx * rad, y: c.y),
                        controlPoint1: CGPoint(x: c.x, y: c.y + dy * rad * 0.45),
                        controlPoint2: CGPoint(x: c.x + dx * rad * 0.45, y: c.y))
                p.line(to: CGPoint(x: c.x + dx * arm, y: c.y))
            }
            corner(CGPoint(x: box.minX, y: box.maxY), 1, -1)
            corner(CGPoint(x: box.maxX, y: box.maxY), -1, -1)
            corner(CGPoint(x: box.minX, y: box.minY), 1, 1)
            corner(CGPoint(x: box.maxX, y: box.minY), -1, 1)
            NSColor.black.setStroke()
            p.stroke()
            NSColor.black.setFill()
            let d: CGFloat = filled ? 6 : 3.6
            NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    static func qrCode(_ text: String, size: CGFloat) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let k = size / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    static func swatch(_ c: RGBAColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            c.nsColor.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        return img
    }

    static func symbol(_ name: String, size: CGFloat = 13) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }
}

/// A keyboard key, as drawn in onboarding and settings.
struct KeyView: View {
    let key: String
    var wide = false
    var size: CGFloat = 15

    var body: some View {
        Text(key)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .frame(minWidth: wide ? size * 3.4 : size * 2.1, minHeight: size * 2.1)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: size * 0.45, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.45, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75)
            )
    }
}

struct BrandGradientText: View {
    let text: String
    var size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(LinearGradient(colors: Theme.brand, startPoint: .leading, endPoint: .trailing))
    }
}

enum FileIcon {
    /// An icon from the file's type alone. Reading the file itself could trigger a
    /// privacy prompt for protected folders just because the cursor passed over it.
    static func icon(for url: URL) -> NSImage {
        if url.pathExtension.isEmpty {
            return NSWorkspace.shared.icon(for: url.hasDirectoryPath ? .folder : .data)
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }
}

// MARK: - Permission explanations

/// Why Grab asks for each permission, in plain words. Shown in onboarding and Settings.
enum PermissionReason: String, CaseIterable, Identifiable {
    case accessibility, screenRecording
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    var summary: String {
        switch self {
        case .accessibility: "Required. Lets Grab notice ⌥ and read what's under your pointer, the same way VoiceOver does."
        case .screenRecording: "Optional. Lets Grab look at the pixels around your pointer for images, colors, QR codes and text inside pictures."
        }
    }

    /// (symbol, heading, text)
    var points: [(String, String, String)] {
        switch self {
        case .accessibility:
            return [
                ("keyboard", "Notices ⌥ and C",
                 "Grab watches only modifier keys like ⌥. While you hold ⌥ it also sees key presses, so C, the arrows, Tab and the action keys work. Nothing you type is recorded, and keys that aren't Grab's go straight through to your app."),
                ("cursorarrow.rays", "Reads what's under the pointer",
                 "Apps describe their text, links, files, tables and buttons to accessibility tools. Grab asks for the thing under your pointer so it can copy the exact word, paragraph, link or file."),
                ("hand.raised", "Never controls anything",
                 "Grab doesn't click, type, move windows or change apps. It never reads password fields. What it reads isn't stored or sent anywhere; history lives in memory only."),
                ("xmark.circle", "Without it",
                 "Grab can't work: macOS won't tell it when ⌥ is held or what's under the pointer."),
            ]
        case .screenRecording:
            return [
                ("photo", "Copies what you see",
                 "Images exactly as they appear, colors from any pixel, QR codes and barcodes, and text inside pictures, videos, games and apps that don't describe their content (on-device OCR)."),
                ("scope", "Only while you hold ⌥",
                 "Grab looks only at the area around your pointer, only during a hold. Its own border and HUD are left out of every capture."),
                ("lock.shield", "Never records",
                 "No video, nothing uploaded, no screenshots kept. OCR runs on your Mac in a short-lived helper that quits when you're done. (Quick Look and Open use a temporary file only when you ask, cleared at next launch.)"),
                ("xmark.circle", "Without it",
                 "Text, links, files and code still copy. Images, colors, QR codes and OCR are switched off. macOS asks you to relaunch Grab after you turn this on."),
            ]
        }
    }
}

/// The full "why" for one permission.
struct PermissionExplainer: View {
    let reason: PermissionReason

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(reason.points.enumerated()), id: \.offset) { _, p in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: p.0)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.1).font(.system(size: 12, weight: .semibold))
                        Text(p.2).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Everything else Grab touches, for completeness.
struct OtherAccessNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No other permissions", systemImage: "checkmark.shield").font(.system(size: 12, weight: .semibold))
            Text("Grab never asks for your files, contacts, camera, microphone or location. It goes online only for currency exchange rates (only currency codes are sent; you can turn it off) and, when you copy a web image, to fetch the original file from the address your browser already loaded it from. Translation and AI run on-device with Apple's frameworks.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
