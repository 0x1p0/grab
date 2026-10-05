// Draws the background of Grab's disk image window (the "drag to Applications" view).
//
//   swift scripts/make_dmg_background.swift packaging
//
// Writes dmg-background.png (660×460) and dmg-background@2x.png; release.sh combines
// them into one Retina-ready dmg-background.tiff. Icon spots must match
// packaging/dmg_settings.py: Grab at (165, 196), Applications at (495, 196), 128 pt icons.
//
// Finder writes the icons' names in black (light mode) or white (dark mode), so the
// area under the icons is a mid-tone that both read on. Everything that matters sits in
// the top 400 points: if Finder's path and status bars are on (a global Finder setting),
// they cover the bottom 60.
import AppKit
import SwiftUI

let size = CGSize(width: 660, height: 460)
let grab = CGPoint(x: 165, y: 196)
let apps = CGPoint(x: 495, y: 196)

struct Background: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.30, green: 0.22, blue: 0.55), Color(red: 0.47, green: 0.27, blue: 0.56), Color(red: 0.60, green: 0.30, blue: 0.47)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Warm and cool light, like the app icon.
            RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.24).opacity(0.45), .clear], center: UnitPoint(x: 0.05, y: 0.0), startRadius: 0, endRadius: 330)
            RadialGradient(colors: [Color(red: 0.49, green: 0.36, blue: 1).opacity(0.5), .clear], center: UnitPoint(x: 1.0, y: 1.0), startRadius: 0, endRadius: 360)
            // A soft pool of light under each icon, so its name reads in light and dark mode.
            ForEach([grab, apps], id: \.x) { p in
                Ellipse()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.26), Color.white.opacity(0)], center: .center, startRadius: 0, endRadius: 110))
                    .frame(width: 230, height: 210)
                    .position(x: p.x, y: p.y + 14)
            }

            // Title.
            VStack(spacing: 6) {
                Text("Drag Grab into Applications")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Then hold ⌥, point at anything, and press C.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .position(x: size.width / 2, y: 58)

            // The arrow, from the app to the folder.
            Arrow()
                .stroke(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.95)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [0.1, 11]))
                .frame(width: 150, height: 40)
                .position(x: size.width / 2, y: grab.y - 6)
            ArrowHead()
                .fill(Color.white.opacity(0.95))
                .frame(width: 16, height: 18)
                .rotationEffect(.degrees(12))
                .position(x: size.width / 2 + 78, y: grab.y - 2)

            // What to do if macOS hesitates the first time.
            VStack(spacing: 3) {
                Text("Opening it for the first time?")
                    .font(.system(size: 11, weight: .semibold))
                Text("If macOS says it can't verify Grab, open System Settings → Privacy & Security and click Open Anyway.")
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(.white.opacity(0.82))
            .multilineTextAlignment(.center)
            .frame(width: 470)
            .position(x: size.width / 2, y: 356)
        }
        .frame(width: size.width, height: size.height)
    }

    /// A gentle arc of dots from left to right.
    struct Arrow: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.midY + 6))
            p.addQuadCurve(to: CGPoint(x: r.maxX - 6, y: r.midY + 4), control: CGPoint(x: r.midX, y: r.minY - 8))
            return p
        }
    }

    struct ArrowHead: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.minX + r.width * 0.35, y: r.midY))
            return p
        }
    }
}

@MainActor func render(scale: CGFloat, to path: String) {
    let r = ImageRenderer(content: Background())
    r.scale = scale
    guard let img = r.cgImage, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
        fatalError("couldn't render the background")
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging"
MainActor.assumeIsolated {
    render(scale: 1, to: "\(dir)/dmg-background.png")
    render(scale: 2, to: "\(dir)/dmg-background@2x.png")
}
