import SwiftUI

private let targetSpring = Animation.spring(response: 0.3, dampingFraction: 0.82)

/// Root of each display's overlay. Split into layers so that, for example, the
/// colour loupe following the cursor doesn't re-render the highlight.
struct OverlayRootView: View {
    let geo: ScreenGeometry
    let model: OverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            HighlightCanvas(geo: geo, model: model)
                .frame(width: geo.size.width, height: geo.size.height)
            ScopeTagLayer(geo: geo, model: model)
            LoupeLayer(geo: geo, model: model)
            HUDLayer(geo: geo, model: model)
            MascotLayer(geo: geo, model: model)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Geometry helpers

private func padded(_ r: CGRect, text: Bool) -> CGRect {
    text ? r.insetBy(dx: -4, dy: -3) : r.insetBy(dx: -4, dy: -4)
}

// MARK: - Highlight

/// The label pinned to the border's top-left corner ("Paragraph ●○○").
private struct ScopeTagLayer: View {
    let geo: ScreenGeometry
    let model: OverlayModel

    var body: some View {
        let bounds = CGRect(origin: .zero, size: geo.size)
        let show = model.visible && !model.pixelColor
        ZStack(alignment: .topLeading) {
            if show, let t = model.target {
                let r = padded(geo.local(t), text: model.targetIsText)
                if r.intersects(bounds) {
                    ScopeTag(label: model.scopeLabel, colors: model.tint, index: model.scopeIndex, count: model.scopeCount)
                        .fixedSize()
                        .offset(x: max(r.minX, 6), y: r.minY - 26 >= 4 ? r.minY - 26 : r.minY + 5)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .animation(targetSpring, value: model.target)
        .animation(.easeOut(duration: 0.16), value: show)
    }
}

private struct ScopeTag: View {
    let label: String
    let colors: [Color]
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .contentTransition(.interpolate)
            if count > 1 {
                let shown = min(count, 7)
                let active = count <= 7 ? index : Int((Double(index) / Double(count - 1) * Double(shown - 1)).rounded())
                HStack(spacing: 2.5) {
                    ForEach(0..<shown, id: \.self) { i in
                        Capsule()
                            .frame(width: i == active ? 8 : 3.5, height: 3.5)
                            .opacity(i == active ? 1 : 0.45)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: colors.first?.opacity(0.4) ?? .clear, radius: 6, y: 2)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: index)
        .animation(.easeInOut(duration: 0.15), value: label)
    }
}

// MARK: - Loupe

private let loupeDiameter: CGFloat = 132

private struct LoupeLayer: View {
    let geo: ScreenGeometry
    let model: OverlayModel

    var body: some View {
        let show = model.visible && model.pixelColor && geo.frame.contains(model.cursor)
        ZStack(alignment: .topLeading) {
            if show {
                LoupeView(sample: model.loupe)
                    .position(geo.local(model.cursor))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .animation(.spring(response: 0.26, dampingFraction: 0.75), value: show)
    }
}

private struct LoupeView: View {
    let sample: LoupeSample?

    var body: some View {
        let ring = sample.map { Color(nsColor: $0.color.nsColor) } ?? Color.gray.opacity(0.4)
        ZStack {
            if let s = sample {
                Image(decorative: s.image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                PixelGrid(pixels: s.pixels, centerX: s.centerX, centerY: s.centerY)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .frame(width: loupeDiameter, height: loupeDiameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ring, lineWidth: 6))
        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
        .overlay(Circle().inset(by: 6).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }
}

private struct PixelGrid: View {
    let pixels: Int
    let centerX: Int
    let centerY: Int

    var body: some View {
        Canvas { ctx, size in
            let cell = size.width / CGFloat(pixels)
            var grid = Path()
            for i in 1..<pixels {
                let v = CGFloat(i) * cell
                grid.move(to: CGPoint(x: v, y: 0)); grid.addLine(to: CGPoint(x: v, y: size.height))
                grid.move(to: CGPoint(x: 0, y: v)); grid.addLine(to: CGPoint(x: size.width, y: v))
            }
            ctx.stroke(grid, with: .color(.black.opacity(0.12)), lineWidth: 0.5)
            let c = CGRect(x: CGFloat(centerX) * cell, y: CGFloat(centerY) * cell, width: cell, height: cell)
            ctx.stroke(Path(c.insetBy(dx: -0.5, dy: -0.5)), with: .color(.black.opacity(0.7)), lineWidth: 1)
            ctx.stroke(Path(c.insetBy(dx: 0.75, dy: 0.75)), with: .color(.white), lineWidth: 1.5)
        }
    }
}

// MARK: - HUD

/// Places the HUD under its anchor, flipping above or inside when there's no room.
private struct AnchoredLayout: Layout {
    var anchor: CGRect
    var bounds: CGRect
    var gap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in rect: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let v = subviews.first else { return }
        let size = v.sizeThatFits(.unspecified)
        let m: CGFloat = 8
        var x = anchor.midX - size.width / 2
        x = min(max(x, bounds.minX + m), bounds.maxX - size.width - m)
        let y: CGFloat
        if anchor.maxY + gap + size.height <= bounds.maxY - m {
            y = anchor.maxY + gap
        } else if anchor.minY - gap - size.height - 24 >= bounds.minY + m {
            y = anchor.minY - gap - size.height - 24
        } else {
            y = min(max(anchor.maxY - size.height - 14, bounds.minY + m), bounds.maxY - size.height - m)
        }
        v.place(at: CGPoint(x: rect.minX + x, y: rect.minY + y), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

private struct HUDLayer: View {
    let geo: ScreenGeometry
    let model: OverlayModel

    var body: some View {
        let colorMode = model.pixelColor || (model.mode == .color && model.toast != nil && model.literalColor == nil)
        let anchorGlobal: CGRect? = colorMode
            ? CGRect(x: model.cursor.x - loupeDiameter / 2, y: model.cursor.y - loupeDiameter / 2,
                     width: loupeDiameter, height: loupeDiameter)
            : model.target.map { padded($0, text: model.targetIsText) }
        let here = anchorGlobal.map { geo.frame.contains($0.center) } ?? false
        let show = here && (model.visible || model.toast != nil) && (model.target != nil || colorMode)

        AnchoredLayout(
            anchor: anchorGlobal.map { geo.local($0) } ?? .zero,
            bounds: geo.local(geo.visible)
        ) {
            if show {
                HUDView(model: model)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .animation(targetSpring, value: model.target)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: show)
    }
}

struct HUDView: View {
    let model: OverlayModel
    @Namespace private var ns

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let toast = model.toast {
                ToastContent(toast: toast)
                    .transition(.blurReplace)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ModeBar(options: model.options, selected: model.mode, selectedTint: model.tint, ns: ns)
                    PreviewRow(preview: model.preview, tint: model.tint, busy: model.busy)
                    if !model.formats.isEmpty {
                        FormatBar(formats: model.formats, selected: model.format, tint: model.tint)
                    }
                    if let w = model.warning {
                        Label(w, systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    if model.hints {
                        HintsRow()
                    }
                }
                .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(minWidth: model.toast == nil ? 250 : 200, maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(HUDBackground(cornerRadius: 17))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        )
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(.black.opacity(0.22))
                .blur(radius: 14)
                .offset(y: 7)
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.toast)
        .animation(.easeInOut(duration: 0.18), value: model.preview)
    }
}

private struct ModeBar: View {
    let options: [ModeOption]
    let selected: GrabMode
    let selectedTint: [Color]
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { o in
                let isSel = o.mode == selected && o.enabled
                HStack(spacing: 5) {
                    Image(systemName: o.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 15)
                    if isSel {
                        Text(o.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .fixedSize()
                            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                    }
                }
                .foregroundStyle(isSel ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .opacity(o.enabled ? 1 : 0.35)
                .overlay(alignment: .topTrailing) {
                    if !o.enabled {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .offset(x: 5, y: -3)
                    }
                }
                .padding(.horizontal, isSel ? 10 : 7)
                .frame(height: 26)
                .background {
                    if isSel {
                        Capsule()
                            .fill(LinearGradient(colors: selectedTint, startPoint: .leading, endPoint: .trailing))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                            .shadow(color: (selectedTint.first ?? .clear).opacity(0.45), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "selection", in: ns)
                    }
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: selected)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: options)
    }
}

private struct PreviewRow: View {
    let preview: Preview
    let tint: [Color]
    let busy: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            content
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small).transition(.opacity)
            }
        }
        .frame(minHeight: 30)
    }

    private func badge(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 28, height: 28)
            .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
    }

    private func lines(_ primary: String, _ secondary: String?, mono: Bool = false, primaryLines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(primary)
                .font(mono ? .system(size: 13, weight: .semibold, design: .monospaced) : .system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(primaryLines)
                .truncationMode(.middle)
            if let secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch preview {
        case .none:
            EmptyView()
        case .loading(let s):
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .unavailable(let s):
            Label(s, systemImage: "circle.slash")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .snippet(let code, let meta):
            VStack(alignment: .leading, spacing: 5) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        case .text(let s, let meta):
            VStack(alignment: .leading, spacing: 3) {
                Text(s)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        case .link(let host, let path):
            badge("globe")
            lines(host, path)
        case .code(let s, let kind):
            badge(kind == "QR" ? "qrcode" : "barcode")
            lines(s, "\(kind) payload", primaryLines: 2)
        case .file(let name, let folder, let url):
            Image(nsImage: FileIcon.icon(for: url))
                .resizable()
                .frame(width: 30, height: 30)
            lines(name, folder)
        case .image(let w, let h, let thumb):
            if let thumb {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 62, maxHeight: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            } else {
                badge("photo")
            }
            lines("\(w) × \(h)", "PNG · full resolution", mono: true)
        case .color(let c, let formatted):
            Circle()
                .fill(Color(nsColor: c.nsColor))
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
                .overlay(Circle().inset(by: 2).strokeBorder(.white.opacity(0.5), lineWidth: 1))
            let hsl = c.hsl
            lines(formatted, formatted == c.hex ? "rgb \(Int(c.r * 255)) \(Int(c.g * 255)) \(Int(c.b * 255)) · hsl \(hsl.h)° \(hsl.s)% \(hsl.l)%" : c.hex, mono: true)
        }
    }
}

/// The formats ⌥ + Tab cycles through, with the current one lit.
private struct FormatBar: View {
    let formats: [FormatOption]
    let selected: String?
    let tint: [Color]

    /// Up to five at a time, sliding with the selection.
    private var visible: (items: [FormatOption], more: (before: Bool, after: Bool)) {
        let n = 5
        guard formats.count > n else { return (formats, (false, false)) }
        let i = formats.firstIndex { $0.id == selected } ?? 0
        let start = min(max(0, i - 2), formats.count - n)
        return (Array(formats[start..<(start + n)]), (start > 0, start + n < formats.count))
    }

    var body: some View {
        let v = visible
        HStack(spacing: 6) {
            Keycap(key: "⇥")
            HStack(spacing: 2) {
                if v.more.before { Text("‹").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.leading, 3) }
                ForEach(v.items) { f in
                    let on = f.id == selected
                    Text(f.title)
                        .font(.system(size: 10.5, weight: on ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background {
                            if on {
                                Capsule().fill(LinearGradient(colors: tint, startPoint: .leading, endPoint: .trailing).opacity(0.85))
                            }
                        }
                }
                if v.more.after { Text("›").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.trailing, 3) }
            }
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: selected)
        }
    }
}

private struct Keycap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .frame(minWidth: 15, minHeight: 15)
            .padding(.horizontal, key.count > 1 ? 3 : 0)
            .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
    }
}

private struct HintsRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                hint(["←", "→"], "type")
                hint(["↑", "↓"], "area")
                hint(["⇥"], "format")
                hint(["C"], "copy")
                hint(["⇧C"], "shelf")
            }
            HStack(spacing: 8) {
                hint(["⏎"], "open")
                hint(["␣"], "peek")
                hint(["P"], "pin")
                hint(["S"], "say")
                hint(["T"], "translate")
                hint(["E"], "ask")
                hint(["Z"], "undo")
            }
            .opacity(0.8)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { Keycap(key: $0) }
            Text(label).padding(.leading, 1)
        }
    }
}

// MARK: - Toast

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.27, y: r.minY + r.height * 0.53))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.69))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.35))
        return p
    }
}

private struct ToastContent: View {
    let toast: Toast
    @State private var drawn = false

    var body: some View {
        let colors = toast.success
            ? Theme.colors(for: toast.mode, sample: toast.color)
            : [Color(hex: 0xFF9F0A), Color(hex: 0xFF453A)]
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: colors[0].opacity(0.5), radius: 6, y: 2)
                if toast.success {
                    CheckShape()
                        .trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                } else {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 28, height: 28)
            .scaleEffect(drawn ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(toast.detail)
                    .font(.system(size: 11.5, design: toast.mode == .color ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(toast.mode == .text ? .tail : .middle)
            }
            Spacer(minLength: 0)
            if let thumb = toast.thumb {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 52, maxHeight: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else if let c = toast.color {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: c.nsColor))
                    .frame(width: 34, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.6).delay(0.03)) { drawn = true }
        }
    }
}
