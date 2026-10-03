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
