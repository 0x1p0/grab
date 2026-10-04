import AppKit
import SwiftUI

struct OnboardingView: View {
    var close: () -> Void

    @State private var permissions = Permissions.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var pasted = ""
    @State private var appeared = false
    @State private var settings = Settings.shared
    @State private var optionChars = KeyLayout.optionOnlyCharacters()

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 22) {
                hero
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                permissionCards
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
                Playground(pasted: $pasted, enabled: permissions.accessibility)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                footer
            }
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .frame(width: 800, height: 720)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.05)) { appeared = true }
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .shadow(color: Color(hex: 0xEC4F7C).opacity(0.35), radius: 18, y: 8)
            VStack(spacing: 6) {
                Text("Everything on your screen is copyable.")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Text, code, links, images, QR codes, colors, files, tables, even text inside pictures and video.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Hold").foregroundStyle(.secondary)
                TriggerKeys(size: 12)
                Text("hover anything, press").foregroundStyle(.secondary)
                KeyView(key: "C", size: 12)
                Text("· switch type").foregroundStyle(.secondary)
                KeyView(key: "←", size: 12)
                KeyView(key: "→", size: 12)
                Text("· area").foregroundStyle(.secondary)
                KeyView(key: "↑", size: 12)
                KeyView(key: "↓", size: 12)
            }
            .font(.system(size: 12.5))
            .padding(.top, 2)
            if settings.trigger == .option, !optionChars.isEmpty {
                LayoutTip(characters: optionChars) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { settings.trigger = .rightOption }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 480)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.orange.opacity(0.1)))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private var permissionCards: some View {
        HStack(spacing: 14) {
            PermissionCard(
                symbol: "hand.point.up.left.fill",
                colors: [Color(hex: 0x2F7BFF), Color(hex: 0x22C3EE)],
                title: "Accessibility",
                badge: "Required",
                detail: "Lets Grab notice \(Settings.shared.trigger.symbol) and read what's under your pointer, like VoiceOver does. It never clicks or reads passwords, and types only when you ask.",
                granted: permissions.accessibility,
                reason: .accessibility,
                actionTitle: "Grant Access",
                action: { permissions.requestAccessibility() }
            )
            PermissionCard(
                symbol: "rectangle.dashed.badge.record",
                colors: [Color(hex: 0xFF7A1A), Color(hex: 0xF43F5E)],
                title: "Screen Recording",
                badge: "For images & colors",
                detail: "Lets Grab look around your pointer while you hold \(Settings.shared.trigger.symbol), for images, colors, QR codes and text in pictures. Never recorded or saved.",
                granted: permissions.screenRecording,
                reason: .screenRecording,
                actionTitle: permissions.screenRecordingNeedsRelaunch ? "Relaunch Grab" : "Grant Access",
                action: {
                    if permissions.screenRecordingNeedsRelaunch { Permissions.relaunch() } else { permissions.requestScreenRecording() }
                },
                note: permissions.screenRecordingNeedsRelaunch ? "Switch Grab on in System Settings, then relaunch." : nil,
                secondaryTitle: permissions.screenRecordingNeedsRelaunch ? "Open Settings" : nil,
                secondary: { permissions.requestScreenRecording() }
            )
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open Grab at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
            Spacer()
            Text("Grab lives in your menu bar")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            Image(nsImage: Icons.statusIcon())
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Done") {
                Settings.shared.hasOnboarded = true
                close()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
    }
}

private struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color(hex: 0xFF8A3D).opacity(0.22), .clear], center: UnitPoint(x: 0.12, y: 0.0), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(hex: 0x7C5CFF).opacity(0.2), .clear], center: UnitPoint(x: 0.92, y: 0.08), startRadius: 0, endRadius: 440)
            RadialGradient(colors: [Color(hex: 0xEC4F7C).opacity(0.12), .clear], center: UnitPoint(x: 0.5, y: 1.0), startRadius: 0, endRadius: 500)
        }
        .ignoresSafeArea()
    }
}

private struct PermissionCard: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let badge: String
    let detail: String
    let granted: Bool
    var reason: PermissionReason?
    let actionTitle: String
    let action: () -> Void
    var note: String?
    var secondaryTitle: String?
    var secondary: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: colors[0].opacity(0.35), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let reason { WhyButton(reason: reason) }
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if granted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            if let note {
                                Text(note)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                            HStack(spacing: 8) {
                                Button(actionTitle, action: action)
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                if let secondaryTitle {
                                    Button(secondaryTitle, action: secondary)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(granted ? Color.green.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: granted ? 1.2 : 0.75)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: granted)
    }
}

/// The practice checklist: each tile ticks off when you grab it the right way.
@Observable
final class Practice {
    enum Task: String, CaseIterable {
        case text, function, color, qr, ocr, box

        var instruction: String {
            let k = Settings.shared.trigger.symbol
            switch self {
            case .text: return "Hold \(k) over the sentence and press C"
            case .function: return "Over the code, press ↑ until the whole function lights up, then C"
            case .color: return "Point at the orange swatch and press C for its color"
            case .qr: return "Point at the QR code and press C to read it"
            case .ocr: return "Point at the picture, press ← until the HUD says OCR, then C: its words are only pixels"
            case .box: return "Press R at one corner of a tile, move to the other corner, press C"
            }
        }

        var needsScreenRecording: Bool { self != .text && self != .function }
    }

    static let sentence = "The quick brown fox jumps over the lazy dog."
    static let qrText = "Grab decoded this QR code ✨ hello from the pixels"

    var done: Set<Task> = []
    var finished = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .grabDidCopy, object: nil, queue: .main) { [weak self] note in
            guard let e = note.object as? GrabEvent else { return }
            MainActor.assumeIsolated { self?.handle(e) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func next(screenRecording: Bool) -> Task? {
        Task.allCases.first { !done.contains($0) && (screenRecording || !$0.needsScreenRecording) }
    }

    @MainActor private func handle(_ e: GrabEvent) {
        guard e.bundleID == Bundle.main.bundleIdentifier else { return }
        var task: Task?
        let text = e.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if e.box {
            task = .box
        } else {
            switch e.mode {
            case .color: task = .color
            case .qr: task = .qr
            case .text:
                if e.codeKind == "function" || (text.contains("func greet") && text.hasSuffix("}")) { task = .function }
                else if text.contains("Pixels") || text.contains("still reads") { task = .ocr }
                else if text.count >= 3, Self.sentence.localizedCaseInsensitiveContains(text) { task = .text }
            default: break
            }
        }
        guard let task, !done.contains(task) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { _ = done.insert(task) }
        if done.count == Task.allCases.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                withAnimation(.easeOut(duration: 0.3)) { self?.finished = true }
                Sound.shared.play(.boing)
                Haptics.perform(.levelChange)
            }
        }
    }
}

/// A row of things to practise on, right inside the welcome window.
private struct Playground: View {
    @Binding var pasted: String
    let enabled: Bool
    @State private var practice = Practice()
    @State private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Practice")
                    .font(.system(size: 14, weight: .semibold))
                progress
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: practice.finished ? "party.popper.fill" : "arrow.turn.down.right")
                    .foregroundStyle(LinearGradient(colors: Theme.brand, startPoint: .leading, endPoint: .trailing))
                Text(instruction)
                    .font(.system(size: 12.5, weight: .medium))
                    .contentTransition(.opacity)
                    .id(instruction)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: instruction)
            HStack(spacing: 12) {
                Tile(caption: "Text", done: practice.done.contains(.text)) {
                    Text(Practice.sentence)
                        .font(.system(size: 13.5, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(10)
                }
                Tile(caption: "Code: ↑ ↓ resize", done: practice.done.contains(.function)) {
                    Text(verbatim: "func greet(_ name: String) -> String {\n    if name.isEmpty {\n        return \"Hello!\"\n    }\n    return \"Hi, \\(name)\"\n}")
                        .font(.system(size: 9.5, design: .monospaced))
                        .lineLimit(6)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                }
                .frame(width: 214)
                Tile(caption: "Color", done: practice.done.contains(.color)) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: 0xED6E2A))
                        .padding(10)
                }
                Tile(caption: "QR code", done: practice.done.contains(.qr)) {
                    if let qr = Icons.qrCode(Practice.qrText, size: 300) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(1, contentMode: .fit)
                            .padding(10)
                    }
                }
                Tile(caption: "Text in an image", done: practice.done.contains(.ocr)) {
                    Image(nsImage: PixelArt.ocrSample)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(10)
                }
            }
            .frame(height: 128)
            .opacity(enabled ? 1 : 0.45)

            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                TextField("Paste here with ⌘V to check what you grabbed", text: $pasted)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !pasted.isEmpty {
                    Button { pasted = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
        .overlay(Confetti(fire: practice.finished).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
    }

    private var instruction: String {
        if !enabled { return "Grant Accessibility first, then try each tile" }
        if practice.finished { return "You've got it. Grab lives in your menu bar, ready when you hold \(Settings.shared.trigger.symbol)." }
        if let t = practice.next(screenRecording: permissions.screenRecording) { return t.instruction }
        return "Turn on Screen Recording to try colors, QR codes, pictures and boxes"
    }

    private var progress: some View {
        HStack(spacing: 4) {
            ForEach(Practice.Task.allCases, id: \.self) { t in
                Capsule()
                    .fill(practice.done.contains(t)
                          ? AnyShapeStyle(LinearGradient(colors: Theme.brand, startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(Color.primary.opacity(0.12)))
                    .frame(width: practice.done.contains(t) ? 18 : 10, height: 6)
            }
            Text("\(practice.done.count) of \(Practice.Task.allCases.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.leading, 4)
        }
    }
}

private struct Tile<Content: View>: View {
    let caption: String
    var done = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 6) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(done ? AnyShapeStyle(LinearGradient(colors: Theme.brand, startPoint: .topLeading, endPoint: .bottomTrailing))
                                           : AnyShapeStyle(Color.primary.opacity(0.08)), lineWidth: done ? 1.6 : 0.75)
                )
                .overlay(alignment: .topTrailing) {
                    if done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(hex: 0xEC4F7C))
                            .background(Circle().fill(.white).padding(2))
                            .offset(x: 6, y: -6)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
            Text(caption)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(done ? .primary : .secondary)
        }
    }
}

/// A burst of brand-colored confetti when the practice is done.
private struct Confetti: View {
    let fire: Bool

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<48, id: \.self) { i in
                    ConfettiPiece(index: i, fire: fire, size: g.size)
                }
            }
        }
        .allowsHitTesting(false)
        .opacity(fire ? 1 : 0)
    }
}

private struct ConfettiPiece: View {
    let index: Int
    let fire: Bool
    let size: CGSize

    private static let colors: [Color] = [Color(hex: 0xFF8A3D), Color(hex: 0xEC4F7C), Color(hex: 0x7C5CFF), Color(hex: 0x22C3EE), Color(hex: 0xFFD166)]

    var body: some View {
        let i = index
        let small = i % 3 == 0
        let startX: CGFloat = CGFloat((i * 37) % 97) / 97 * size.width
        let drift: CGFloat = CGFloat((i * 53) % 60) - 30
        let spin: Double = fire ? Double((i * 47) % 360) + 600 : 0
        let x: CGFloat = fire ? startX + drift : startX
        let y: CGFloat = fire ? size.height + 30 : -30
        let duration: Double = 1.4 + Double(i % 7) * 0.13
        let delay: Double = Double(i % 12) * 0.05
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(Self.colors[i % Self.colors.count])
            .frame(width: small ? 5 : 7, height: small ? 5 : 11)
            .rotationEffect(.degrees(spin))
            .position(x: x, y: y)
            .opacity(fire ? 0 : 1)
            .animation(.easeIn(duration: duration).delay(delay), value: fire)
    }
}

/// Bitmaps for the playground, drawn in code so the text in them is real pixels.
enum PixelArt {
    static let ocrSample: NSImage = render(size: NSSize(width: 300, height: 220)) { r in
        let g = NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.11, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.27, green: 0.16, blue: 0.42, alpha: 1)])
        g?.draw(in: r, angle: -60)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .heavy),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 1, green: 0.62, blue: 0.4, alpha: 1),
            .paragraphStyle: style,
        ]
        NSAttributedString(string: "Pixels, not text", attributes: attrs).draw(in: NSRect(x: 0, y: 112, width: r.width, height: 50))
        NSAttributedString(string: "and Grab still reads it", attributes: small).draw(in: NSRect(x: 0, y: 70, width: r.width, height: 30))
    }

    static let sunset: NSImage = render(size: NSSize(width: 300, height: 220)) { r in
        NSGradient(colors: [
            NSColor(srgbRed: 0.99, green: 0.55, blue: 0.24, alpha: 1),
            NSColor(srgbRed: 0.93, green: 0.31, blue: 0.49, alpha: 1),
            NSColor(srgbRed: 0.49, green: 0.36, blue: 1.0, alpha: 1),
        ])?.draw(in: r, angle: -90)
        NSColor(srgbRed: 1, green: 0.93, blue: 0.7, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.midX - 42, y: 70, width: 84, height: 84)).fill()
        let hill = NSBezierPath()
        hill.move(to: NSPoint(x: 0, y: 0))
        hill.line(to: NSPoint(x: 0, y: 70))
        hill.curve(to: NSPoint(x: r.width, y: 60), controlPoint1: NSPoint(x: 90, y: 120), controlPoint2: NSPoint(x: 200, y: 20))
        hill.line(to: NSPoint(x: r.width, y: 0))
        NSColor(srgbRed: 0.16, green: 0.10, blue: 0.30, alpha: 1).setFill()
        hill.fill()
    }

    private static func render(size: NSSize, _ draw: (NSRect) -> Void) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }
}

/// "Why?" next to a permission: the full explanation in a popover.
private struct WhyButton: View {
    let reason: PermissionReason
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Text("Why?").font(.system(size: 10.5, weight: .semibold))
        }
        .buttonStyle(.link)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Why Grab needs \(reason.title)").font(.system(size: 13, weight: .bold))
                PermissionExplainer(reason: reason)
            }
            .padding(16)
            .frame(width: 340)
        }
    }
}
