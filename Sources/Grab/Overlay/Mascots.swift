import SwiftUI

/// Who carries a grab to the menu bar.
enum MascotKind: String, CaseIterable, Identifiable {
    case snap, clawsy, beamy, ribbit, classic, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .snap: "Snap"
        case .clawsy: "Clawsy"
        case .beamy: "Beamy"
        case .ribbit: "Ribbit"
        case .classic: "Classic"
        case .off: "Off"
        }
    }

    var blurb: String {
        switch self {
        case .snap: "A jelly critter whose hands are Grab's viewfinder corners"
        case .clawsy: "An arcade claw that drops from the menu bar"
        case .beamy: "A tiny saucer with a tractor beam"
        case .ribbit: "A frog with a very sticky tongue"
        case .classic: "A chip that flies to the menu bar"
        case .off: "Just the sound and the toast"
        }
    }

    /// How long the whole trip takes, and when the cargo lands in the menu bar icon.
    var duration: Double {
        switch self {
        case .snap: 1.15
        case .clawsy: 1.2
        case .beamy: 1.2
        case .ribbit: 1.1
        case .classic: 0.75
        case .off: 0
        }
    }

    var dropTime: Double {
        switch self {
        case .snap: 1.0
        case .clawsy: 1.06
        case .beamy: 1.06
        case .ribbit: 0.97
        case .classic: 0.6
        case .off: 0
        }
    }

    /// How big the character is drawn, and how far below it the cargo hangs.
    var size: CGFloat {
        switch self {
        case .snap: 1.3
        case .clawsy: 1.35
        case .beamy: 1.4
        case .ribbit: 1.25
        default: 1
        }
    }

    var carry: CGFloat {
        switch self {
        case .snap: 41
        case .clawsy: 44
        case .beamy: 46
        default: 30
        }
    }

    /// Little sounds along the way (seconds after the copy).
    var cues: [(Double, Sound.Effect)] {
        switch self {
        case .snap: [(0.03, .boing), (0.42, .zip), (0.98, .plop)]
        case .clawsy: [(0.0, .zip), (0.27, .zip), (0.5, .clank), (0.6, .zip), (1.04, .plop)]
        case .beamy: [(0.0, .zip), (0.33, .beam), (0.64, .zip), (1.04, .plop)]
        case .ribbit: [(0.02, .boing), (0.15, .zip), (0.4, .plop), (0.76, .gulp), (0.95, .plop)]
        case .classic, .off: []
        }
    }
}

/// What the mascot carries: a little card showing the grab.
struct Cargo {
    enum Content {
        case text(String)
        case code(String)
        case image(CGImage)
        case color(RGBAColor)
        case symbol(String, String)
    }
    var content: Content
    var colors: [Color]
}

/// Where everything is at one moment of a trip. Global top-left coordinates.
struct MascotPose {
    var body: CGPoint
    var scale: CGFloat = 1
    var stretch: CGSize = CGSize(width: 1, height: 1)
    var tilt: Double = 0
    var opacity: Double = 1
    var look = CGVector(dx: 0, dy: 0)
    var blink: Double = 0
    var mouth: Double = 0
    var grip: CGRect = .null
    var gripOpacity: Double = 0
    var open: Double = 0
    var cargo: CGRect = .null
    var cargoOpacity: Double = 0
    var cargoTilt: Double = 0
    var line: (CGPoint, CGPoint)?
    var beam: Double = 0
    var puff: Double = 0
    var trail: [CGPoint] = []
}

// MARK: - Choreography

enum Choreo {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func ramp(_ t: Double, _ a: Double, _ d: Double) -> Double { clamp((t - a) / d) }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    static func easeIn(_ x: Double) -> Double { pow(clamp(x), 3) }
    static func easeInOut(_ x: Double) -> Double { let x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func spring(_ x: Double) -> Double {
        x <= 0 ? 0 : x >= 1 ? 1 : 1 - exp(-6.5 * x) * cos(2 * .pi * 1.3 * x)
    }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ x: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, x), y: lerp(a.y, b.y, x)) }
    static func lerp(_ a: CGRect, _ b: CGRect, _ x: Double) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, x), y: lerp(a.minY, b.minY, x), width: lerp(a.width, b.width, x), height: lerp(a.height, b.height, x))
    }
    static func bezier(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ u: Double) -> CGPoint {
        let v = 1 - u
        return CGPoint(x: v * v * p0.x + 2 * v * u * c.x + u * u * p1.x, y: v * v * p0.y + 2 * v * u * c.y + u * u * p1.y)
    }
    static func card(at center: CGPoint, _ size: CGSize = CGSize(width: 54, height: 38)) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
    static func look(from a: CGPoint, to b: CGPoint) -> CGVector {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = max(1, hypot(dx, dy))
        return CGVector(dx: dx / d, dy: dy / d)
    }

    /// Where the grab starts: the thing itself, reasonably sized.
    static func source(_ fly: Fly) -> CGRect {
        let t = fly.target.isNull || fly.target.width < 4 ? CGRect(x: fly.from.x - 20, y: fly.from.y - 20, width: 40, height: 40) : fly.target
        // Huge targets (a whole window) lift off as a big card around the cursor, not the window.
        let w = min(t.width, 240), h = min(t.height, 150)
        let x = min(max(fly.from.x - w / 2, t.minX), t.maxX - w)
        let y = min(max(fly.from.y - h / 2, t.minY), t.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func pose(_ fly: Fly, at t: Double) -> MascotPose {
        switch fly.kind {
        case .snap: snap(fly, t)
        case .clawsy: clawsy(fly, t)
        case .beamy: beamy(fly, t)
        case .ribbit: ribbit(fly, t)
        case .classic, .off: MascotPose(body: fly.to, opacity: 0)
        }
    }

    // Snap: pops out of the grab, clamps it with its corner-hands, hops to the menu bar.
    static func snap(_ f: Fly, _ t: Double) -> MascotPose {
        let src = source(f)
        let p0 = CGPoint(x: src.midX, y: src.midY)
        let icon = CGPoint(x: f.to.x, y: f.to.y + 6)
        var p = MascotPose(body: p0)
        let pop = spring(ramp(t, 0, 0.32))
        let clamp = easeInOut(ramp(t, 0.12, 0.3))
        let hop = easeInOut(ramp(t, 0.42, 0.55))
        let dive = easeIn(ramp(t, 0.92, 0.2))
        let ctrl = CGPoint(x: p0.x + (icon.x - p0.x) * 0.45, y: min(p0.y, icon.y) - 150)
        let rest = CGPoint(x: p0.x, y: p0.y - 22)
        var body = hop > 0 ? bezier(rest, ctrl, icon, hop) : rest
        body = lerp(body, icon, dive)
        p.body = body
        p.scale = CGFloat(pop * (1 - 0.82 * dive))
        // Squash before jumping, stretch while flying.
        let squash = sin(.pi * ramp(t, 0.32, 0.12)) * 0.16
        let speed = sin(.pi * hop)
        p.stretch = CGSize(width: 1 + squash - 0.07 * speed, height: 1 - squash + 0.11 * speed)
        if hop > 0 && hop < 1 {
            let ahead = bezier(rest, ctrl, icon, min(1, hop + 0.02))
            p.tilt = Double(atan2(ahead.y - body.y, ahead.x - body.x)) * 180 / .pi * 0.18 * speed
            p.look = look(from: body, to: icon)
        } else {
            p.look = look(from: body, to: hop >= 1 ? icon : p0)
        }
        p.blink = t > 0.64 && t < 0.72 ? 1 : 0
        p.mouth = sin(.pi * ramp(t, 0.18, 0.32))
        let off = MascotKind.snap.carry
        let hold = card(at: CGPoint(x: body.x, y: body.y + off * p.scale), CGSize(width: 54 * p.scale, height: 38 * p.scale))
        p.cargo = clamp < 1 ? lerp(src, card(at: CGPoint(x: rest.x, y: rest.y + off)), clamp) : hold
        p.cargoOpacity = ramp(t, 0.1, 0.1) * (1 - ramp(t, 1.0, 0.12))
        p.cargoTilt = p.tilt * 0.6
        p.grip = p.cargo.insetBy(dx: -4, dy: -4)
        p.gripOpacity = ramp(t, 0.02, 0.12) * (1 - ramp(t, 0.98, 0.1))
        p.opacity = 1 - ramp(t, 1.04, 0.1)
        if hop > 0.05 && hop < 0.98 {
            p.trail = (1...5).map { k in bezier(rest, ctrl, icon, max(0, hop - Double(k) * 0.045)) }
        }
        return p
    }

    // Clawsy: a claw machine. Rides along the top of the screen, drops straight down
    // on its cable, clamps, lifts, and slides home to the menu bar icon.
    static func clawsy(_ f: Fly, _ t: Double) -> MascotPose {
        let src = source(f)
        let p0 = CGPoint(x: src.midX, y: src.midY)
        let anchor = f.to
        let rail = anchor.y + 14
        let hang: CGFloat = 26
        let off = MascotKind.clawsy.carry
        let over = easeInOut(ramp(t, 0, 0.27))
        let drop = easeIn(ramp(t, 0.27, 0.22))
        let lift = easeOut(ramp(t, 0.6, 0.22))
        let home = easeInOut(ramp(t, 0.82, 0.22))
        let gone = easeIn(ramp(t, 1.04, 0.14))
        let x = lerp(lerp(anchor.x, p0.x, over), anchor.x, home)
        let low = max(rail + hang, p0.y - off)
        let y = lerp(lerp(rail + hang, low, drop), rail + hang, lift)
        let trolley = CGPoint(x: x, y: rail)
        var head = CGPoint(x: x, y: y)
        // A little swing when the trolley starts and stops.
        let swing = sin(.pi * over) * 10 + sin(.pi * home) * -12 + sin(.pi * 2 * lift) * 4
        head.x += CGFloat(swing * 0.4)
        head = lerp(head, anchor, gone)
        var p = MascotPose(body: head)
        p.open = t < 0.5 ? ramp(t, 0.05, 0.3) : 1 - ramp(t, 0.5, 0.06)
        p.tilt = swing
        p.scale = CGFloat(1 - 0.75 * gone)
        p.line = (lerp(trolley, anchor, gone), head)
        let grab = easeInOut(ramp(t, 0.5, 0.1))
        let hold = card(at: CGPoint(x: head.x, y: head.y + off * p.scale), CGSize(width: 54 * p.scale, height: 38 * p.scale))
        p.cargo = grab < 1 ? lerp(src, hold, grab) : hold
        p.cargoOpacity = ramp(t, 0.48, 0.06) * (1 - ramp(t, 1.06, 0.1))
        p.cargoTilt = swing * 0.8
        p.opacity = ramp(t, 0, 0.06) * (1 - ramp(t, 1.1, 0.08))
        return p
    }

    // Beamy: a saucer that abducts the grab.
    static func beamy(_ f: Fly, _ t: Double) -> MascotPose {
        let src = source(f)
        let p0 = CGPoint(x: src.midX, y: src.midY)
        let icon = f.to
        let hover = CGPoint(x: p0.x, y: max(p0.y - 110, 56))
        let arrive = easeOut(ramp(t, 0, 0.34))
        let leave = easeIn(ramp(t, 0.62, 0.44))
        let gone = easeIn(ramp(t, 1.04, 0.14))
        let ctrlIn = CGPoint(x: (icon.x + hover.x) / 2, y: min(icon.y, hover.y) - 40)
        var body = arrive < 1 ? bezier(icon, ctrlIn, hover, arrive) : hover
        body = lerp(body, CGPoint(x: icon.x, y: icon.y + 4), leave)
        body.y += CGFloat(sin(t * 18) * 2 * (1 - leave))
        var p = MascotPose(body: body)
        p.tilt = arrive < 1 ? -10 * (1 - arrive) : (leave > 0 && leave < 1 ? 12 * sin(.pi * leave) : 0)
        p.scale = CGFloat(1 - 0.8 * gone)
        p.beam = ramp(t, 0.32, 0.08) * (1 - ramp(t, 0.9, 0.12))
        let lift = easeInOut(ramp(t, 0.36, 0.26))
        let held = card(at: CGPoint(x: body.x, y: body.y + MascotKind.beamy.carry * p.scale), CGSize(width: 54 * p.scale, height: 38 * p.scale))
        p.cargo = lift < 1 ? lerp(src, held, lift) : held
        p.cargoOpacity = ramp(t, 0.34, 0.08) * (1 - ramp(t, 1.06, 0.1))
        p.cargoTilt = sin(t * 9) * 6 * (1 - leave)
        p.opacity = ramp(t, 0, 0.08) * (1 - ramp(t, 1.1, 0.08))
        return p
    }

    // Ribbit: a frog under the menu bar icon, tongue first.
    static func ribbit(_ f: Fly, _ t: Double) -> MascotPose {
        let src = source(f)
        let p0 = CGPoint(x: src.midX, y: src.midY)
        let seat = CGPoint(x: f.to.x, y: f.to.y + 34)
        let pop = spring(ramp(t, 0, 0.3))
        let duck = easeIn(ramp(t, 0.9, 0.18))
        var p = MascotPose(body: lerp(seat, f.to, duck))
        p.scale = CGFloat(pop * (1 - 0.8 * duck))
        let mouth = CGPoint(x: p.body.x, y: p.body.y + 9 * p.scale)
        let shoot = easeOut(ramp(t, 0.14, 0.24))
        let reel = easeIn(ramp(t, 0.46, 0.28))
        let tip = lerp(lerp(mouth, p0, shoot), mouth, reel)
        p.line = shoot > 0 && reel < 1 ? (mouth, tip) : nil
        p.look = look(from: p.body, to: p0)
        let stick = easeInOut(ramp(t, 0.38, 0.08))
        let gulp = easeIn(ramp(t, 0.72, 0.12))
        let held = card(at: tip, CGSize(width: 54 * (1 - gulp), height: 38 * (1 - gulp)))
        p.cargo = stick < 1 ? lerp(src, card(at: p0), stick) : held
        p.cargoOpacity = ramp(t, 0.37, 0.05) * (1 - ramp(t, 0.82, 0.04))
        p.cargoTilt = reel > 0 ? sin(reel * .pi * 2) * 10 : 0
        p.puff = sin(.pi * ramp(t, 0.76, 0.22))
        p.blink = p.puff > 0.4 ? 1 : 0
        p.mouth = p.line != nil ? 1 : 0
        p.opacity = 1 - ramp(t, 1.0, 0.1)
        return p
    }
}

// MARK: - Drawing

struct CargoCard: View {
    var cargo: Cargo
    var size: CGSize

    var body: some View {
        let r = min(10, min(size.width, size.height) * 0.22)
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        ZStack {
            shape.fill(Color(white: 0.985))
            content.clipShape(shape)
            shape.strokeBorder(LinearGradient(colors: cargo.colors, startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.6)
        }
        .frame(width: max(1, size.width), height: max(1, size.height))
        .shadow(color: (cargo.colors.first ?? .black).opacity(0.45), radius: 7, y: 3)
    }

    @ViewBuilder private var content: some View {
        let s = min(size.width, size.height)
        switch cargo.content {
        case .image(let img):
            Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                .frame(width: max(1, size.width), height: max(1, size.height))
        case .color(let c):
            Color(nsColor: c.nsColor)
        case .text(let t):
            VStack(alignment: .leading, spacing: 1) {
                Text("Aa").font(.system(size: max(4, s * 0.32), weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: cargo.colors, startPoint: .leading, endPoint: .trailing))
                Text(t).font(.system(size: max(3, s * 0.17), weight: .medium)).foregroundStyle(.black.opacity(0.7)).lineLimit(2)
            }
            .padding(max(1, s * 0.1))
            .frame(width: max(1, size.width), height: max(1, size.height), alignment: .topLeading)
        case .code(let t):
            Text(t).font(.system(size: max(3, s * 0.16), design: .monospaced)).foregroundStyle(.black.opacity(0.75)).lineLimit(3)
                .padding(max(1, s * 0.1))
                .frame(width: max(1, size.width), height: max(1, size.height), alignment: .topLeading)
        case .symbol(let sym, let t):
            VStack(spacing: max(0, s * 0.04)) {
                Image(systemName: sym).font(.system(size: max(4, s * 0.36), weight: .bold))
                    .foregroundStyle(LinearGradient(colors: cargo.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(t).font(.system(size: max(3, s * 0.16), weight: .semibold)).foregroundStyle(.black.opacity(0.65)).lineLimit(1)
            }
            .padding(.horizontal, 3)
            .frame(width: max(1, size.width), height: max(1, size.height))
        }
    }
}

private let snapGradient = [Color(red: 1, green: 0.70, blue: 0.50), Color(red: 0.93, green: 0.42, blue: 0.50), Color(red: 0.55, green: 0.36, blue: 0.96)]

/// Big glossy eye that looks where it's going.
struct MascotEye: View {
    var size: CGFloat
    var look: CGVector
    var blink: Double
    var body: some View {
        ZStack {
            Ellipse().fill(Color.white)
            Circle().fill(Color(red: 0.12, green: 0.08, blue: 0.2))
                .frame(width: size * 0.56, height: size * 0.56)
                .offset(x: look.dx * size * 0.17, y: look.dy * size * 0.2)
            Circle().fill(Color.white).frame(width: size * 0.18, height: size * 0.18)
                .offset(x: look.dx * size * 0.17 - size * 0.1, y: look.dy * size * 0.2 - size * 0.12)
        }
        .frame(width: size, height: size * 1.18)
        .scaleEffect(x: 1, y: 1 - 0.9 * blink)
    }
}

/// Snap: a jelly bean in Grab's colors with a sparkle antenna.
struct SnapBody: View {
    var pose: MascotPose
    var t: Double
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: snapGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: snapGradient[1].opacity(0.7), radius: 9, y: 3)
            Ellipse().fill(Color.white.opacity(0.45)).frame(width: 12, height: 7).offset(x: -8, y: -10).rotationEffect(.degrees(-20))
            HStack(spacing: 3) {
                MascotEye(size: 10, look: pose.look, blink: pose.blink)
                MascotEye(size: 10, look: pose.look, blink: pose.blink)
            }
            .offset(y: -2)
            Group {
                if pose.mouth > 0.3 {
                    Ellipse().fill(Color(red: 0.3, green: 0.05, blue: 0.2)).frame(width: 5, height: 5 * pose.mouth + 1)
                } else {
                    SmileShape().stroke(Color(red: 0.3, green: 0.05, blue: 0.2), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 8, height: 3)
                }
            }
            .offset(y: 8)
            // Sparkle antenna, borrowed from the app icon.
            VStack(spacing: 0) {
                SparkleStar().fill(Color(red: 1, green: 0.95, blue: 0.82)).frame(width: 9, height: 9)
                    .shadow(color: .white, radius: 3)
                    .rotationEffect(.degrees(sin(t * 9) * 18))
                Capsule().fill(snapGradient[0]).frame(width: 2, height: 6)
            }
            .offset(x: 6 + sin(t * 7) * 1.5, y: -20)
        }
        .frame(width: 36, height: 32)
    }
}

struct SmileShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY + r.height))
        return p
    }
}

struct SparkleStar: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), R = r.width / 2, k: CGFloat = 0.18
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - R))
        p.addQuadCurve(to: CGPoint(x: c.x + R, y: c.y), control: CGPoint(x: c.x + R * k, y: c.y - R * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + R), control: CGPoint(x: c.x + R * k, y: c.y + R * k))
        p.addQuadCurve(to: CGPoint(x: c.x - R, y: c.y), control: CGPoint(x: c.x - R * k, y: c.y + R * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - R), control: CGPoint(x: c.x - R * k, y: c.y - R * k))
        return p
    }
}

/// One of Snap's hands: a viewfinder corner.
struct PincerShape: Shape {
    var arm: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let rad = min(arm * 0.45, 5)
        p.move(to: CGPoint(x: r.minX, y: r.minY + arm))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + arm, y: r.minY))
        return p
    }
}

struct Pincers: View {
    var rect: CGRect
    var body: some View {
        let arm = max(5, min(15, min(rect.width, rect.height) * 0.32))
        ZStack(alignment: .topLeading) {
            ForEach(0..<4, id: \.self) { i in
                PincerShape(arm: arm)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
                    .frame(width: arm + 2, height: arm + 2)
                    .rotationEffect(.degrees(Double(i) * 90))
                    .shadow(color: snapGradient[1].opacity(0.9), radius: 4)
                    .position(corner(i, arm))
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
    }

    func corner(_ i: Int, _ arm: CGFloat) -> CGPoint {
        let h = (arm + 2) / 2
        switch i {
        case 0: return CGPoint(x: h, y: h)
        case 1: return CGPoint(x: rect.width - h, y: h)
        case 2: return CGPoint(x: rect.width - h, y: rect.height - h)
        default: return CGPoint(x: h, y: rect.height - h)
        }
    }
}

/// Clawsy's head: a shiny hub with two hooked fingers. Closed, the fingers sit
/// exactly where the carried card's sides are; open, they swing out.
struct ClawHead: View {
    var open: Double
    var body: some View {
        let metal = LinearGradient(colors: [Color(white: 0.98), Color(white: 0.55), Color(white: 0.85)], startPoint: .leading, endPoint: .trailing)
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                ClawFinger(side: side, open: open)
                    .stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 4.4, lineCap: .round, lineJoin: .round))
                    .offset(x: 0.6, y: 1)
                ClawFinger(side: side, open: open)
                    .stroke(metal, style: StrokeStyle(lineWidth: 3.4, lineCap: .round, lineJoin: .round))
            }
            ZStack {
                Capsule().fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                Capsule().strokeBorder(LinearGradient(colors: snapGradient, startPoint: .leading, endPoint: .trailing), lineWidth: 2.4)
                Capsule().fill(Color.white.opacity(0.85)).frame(width: 9, height: 3).offset(x: -4, y: -4)
            }
            .frame(width: 26, height: 16)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
        }
        .frame(width: 64, height: 84)
    }
}

/// One finger, drawn around the hub at the frame's center.
struct ClawFinger: Shape {
    var side: Double
    var open: Double
    func path(in r: CGRect) -> Path {
        let s = CGFloat(side)
        let pivot = CGPoint(x: r.midX + 9 * s, y: r.midY + 5)
        let a = -s * open * 0.6
        func rot(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let c = CGFloat(cos(a)), n = CGFloat(sin(a))
            return CGPoint(x: pivot.x + x * c - y * n, y: pivot.y + x * n + y * c)
        }
        var p = Path()
        p.move(to: pivot)
        p.addCurve(to: rot(14 * s, 18), control1: rot(9 * s, 1), control2: rot(15 * s, 8))
        p.addQuadCurve(to: rot(7 * s, 30), control: rot(14 * s, 27))
        return p
    }
}

/// Beamy's saucer.
struct Saucer: View {
    var t: Double
    var body: some View {
        ZStack {
            Ellipse().fill(LinearGradient(colors: [Color(red: 0.7, green: 0.95, blue: 1).opacity(0.85), Color(red: 0.35, green: 0.75, blue: 0.95).opacity(0.6)],
                                          startPoint: .top, endPoint: .bottom))
                .frame(width: 22, height: 18).offset(y: -7)
                .overlay(
                    HStack(spacing: 2) {
                        Circle().fill(Color(red: 0.1, green: 0.1, blue: 0.2)).frame(width: 3, height: 3)
                        Circle().fill(Color(red: 0.1, green: 0.1, blue: 0.2)).frame(width: 3, height: 3)
                    }
                    .offset(y: -8)
                )
            Ellipse().fill(LinearGradient(colors: [snapGradient[2], snapGradient[1]], startPoint: .leading, endPoint: .trailing))
                .frame(width: 46, height: 14)
                .overlay(Ellipse().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                .shadow(color: snapGradient[2].opacity(0.7), radius: 6)
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color(red: 1, green: 0.9, blue: 0.4).opacity(0.4 + 0.6 * (sin(t * 22 + Double(i) * 2) * 0.5 + 0.5)))
                        .frame(width: 4, height: 4)
                }
            }
            .offset(y: 2)
        }
        .frame(width: 50, height: 34)
    }
}

/// Ribbit's head and cheeks.
struct FrogBody: View {
    var pose: MascotPose
    var body: some View {
        let green = [Color(red: 0.45, green: 0.9, blue: 0.5), Color(red: 0.1, green: 0.62, blue: 0.32)]
        ZStack {
            Ellipse().fill(LinearGradient(colors: green, startPoint: .top, endPoint: .bottom))
                .frame(width: 40 + 6 * pose.puff, height: 28 + 3 * pose.puff)
                .shadow(color: green[1].opacity(0.6), radius: 6, y: 2)
            HStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { _ in
                    ZStack {
                        Circle().fill(LinearGradient(colors: green, startPoint: .top, endPoint: .bottom)).frame(width: 15, height: 15)
                        MascotEye(size: 10, look: pose.look, blink: pose.blink).offset(y: -1)
                    }
                }
            }
            .offset(y: -13)
            HStack(spacing: 18 + 4 * pose.puff) {
                Ellipse().fill(Color(red: 1, green: 0.5, blue: 0.6).opacity(0.55)).frame(width: 7 + 6 * pose.puff, height: 4 + 4 * pose.puff)
                Ellipse().fill(Color(red: 1, green: 0.5, blue: 0.6).opacity(0.55)).frame(width: 7 + 6 * pose.puff, height: 4 + 4 * pose.puff)
            }
            .offset(y: 4)
            Group {
                if pose.mouth > 0.5 {
                    Ellipse().fill(Color(red: 0.45, green: 0.08, blue: 0.15)).frame(width: 9, height: 6)
                } else {
                    SmileShape().stroke(Color(red: 0.08, green: 0.3, blue: 0.15), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 16, height: 3)
                }
            }
            .offset(y: 7)
        }
        .frame(width: 52, height: 46)
    }
}

// MARK: - The layer

/// Draws the trip on every display; each shows its part of the path.
struct MascotLayer: View {
    let geo: ScreenGeometry
    let model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !reduceMotion, let fly = model.fly {
                if fly.kind == .classic {
                    if geo.frame.contains(fly.from) {
                        ClassicChip(fly: fly, from: geo.local(fly.from), to: geo.local(fly.to)).id(fly.id)
                    }
                } else if fly.kind != .off {
                    TimelineView(.animation) { ctx in
                        MascotScene(fly: fly, t: ctx.date.timeIntervalSince(fly.start), geo: geo)
                    }
                    .id(fly.id)
                }
            }
            if !reduceMotion, let oops = model.oops, geo.frame.contains(oops.at) {
                TimelineView(.animation) { ctx in
                    OopsScene(oops: oops, t: ctx.date.timeIntervalSince(oops.start), at: geo.local(oops.at))
                }
                .id(oops.id)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

struct MascotScene: View {
    let fly: Fly
    let t: Double
    let geo: ScreenGeometry

    var body: some View {
        let p = Choreo.pose(fly, at: t)
        let body = geo.local(p.body)
        ZStack(alignment: .topLeading) {
            // Cable, tongue or beam behind everything.
            if let line = p.line {
                let a = geo.local(line.0), b = geo.local(line.1)
                if fly.kind == .clawsy {
                    Path { path in
                        path.move(to: a)
                        path.addLine(to: b)
                    }
                    .stroke(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.5)], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, x: 1, y: 1)
                    .opacity(p.opacity)
                    // The trolley riding along the top.
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: snapGradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: 26 * p.scale, height: 10 * p.scale)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                        .shadow(color: snapGradient[1].opacity(0.6), radius: 4)
                        .position(a)
                        .opacity(p.opacity)
                } else if fly.kind == .ribbit {
                    Path { path in
                        path.move(to: a)
                        let mid = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) * 0.06, y: (a.y + b.y) / 2 - (b.x - a.x) * 0.06)
                        path.addQuadCurve(to: b, control: mid)
                    }
                    .stroke(LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.55), Color(red: 0.95, green: 0.3, blue: 0.45)],
                                           startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                    Circle().fill(Color(red: 1, green: 0.42, blue: 0.55)).frame(width: 12, height: 12).position(b)
                }
            }
            if fly.kind == .beamy, p.beam > 0, !p.cargo.isNull {
                let c = geo.local(p.cargo)
                Path { path in
                    path.move(to: CGPoint(x: body.x - 8 * p.scale, y: body.y + 4))
                    path.addLine(to: CGPoint(x: body.x + 8 * p.scale, y: body.y + 4))
                    path.addLine(to: CGPoint(x: c.maxX + 10, y: c.maxY + 6))
                    path.addLine(to: CGPoint(x: c.minX - 10, y: c.maxY + 6))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.95, blue: 0.75).opacity(0.55 * p.beam),
                                              Color(red: 0.3, green: 0.75, blue: 1).opacity(0.18 * p.beam)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Path { path in
                        path.move(to: CGPoint(x: body.x - 8 * p.scale, y: body.y + 4))
                        path.addLine(to: CGPoint(x: c.minX - 10, y: c.maxY + 6))
                        path.move(to: CGPoint(x: body.x + 8 * p.scale, y: body.y + 4))
                        path.addLine(to: CGPoint(x: c.maxX + 10, y: c.maxY + 6))
                    }
                    .stroke(Color(red: 0.2, green: 0.85, blue: 0.75).opacity(0.7 * p.beam), lineWidth: 1.2)
                )
                ForEach(0..<5, id: \.self) { k in
                    let u = (t * 1.6 + Double(k) * 0.2).truncatingRemainder(dividingBy: 1)
                    let y = c.maxY - CGFloat(u) * (c.maxY - body.y)
                    let spread = (c.width / 2 + 6) * CGFloat(1 - u)
                    SparkleStar().fill(Color.white)
                        .frame(width: 5, height: 5)
                        .shadow(color: Color(red: 0.3, green: 0.95, blue: 0.8), radius: 3)
                        .position(x: body.x + spread * CGFloat(sin(Double(k) * 2.1)), y: y)
                        .opacity(p.beam * (1 - u))
                }
            }
            // Sparkle trail.
            ForEach(Array(p.trail.enumerated()), id: \.offset) { k, pt in
                SparkleStar().fill(Color.white.opacity(0.85 - Double(k) * 0.15))
                    .frame(width: CGFloat(9 - k), height: CGFloat(9 - k))
                    .shadow(color: snapGradient[1], radius: 3)
                    .position(geo.local(pt))
            }
            // The cargo.
            if !p.cargo.isNull, p.cargoOpacity > 0 {
                let c = geo.local(p.cargo)
                CargoCard(cargo: fly.cargo, size: c.size)
                    .rotationEffect(.degrees(p.cargoTilt))
                    .opacity(p.cargoOpacity)
                    .position(x: c.midX, y: c.midY)
            }
            // The character, wobbling if the cargo is heavy.
            let strain = fly.heavy && p.cargoOpacity > 0.6 ? 1.0 : 0
            character(p)
                .overlay { SeasonHat.on(fly.kind) }
                .scaleEffect(x: p.scale * p.stretch.width * fly.kind.size, y: p.scale * p.stretch.height * fly.kind.size)
                .rotationEffect(.degrees(p.tilt + strain * sin(t * 31) * 6))
                .offset(y: strain * CGFloat(abs(sin(t * 15))) * 2.5)
                .opacity(p.opacity)
                .position(body)
            if strain > 0 {
                SweatDrops(t: t).opacity(p.opacity).position(x: body.x + 20 * fly.kind.size, y: body.y - 12 * fly.kind.size)
            }
            if fly.kind == .snap, p.gripOpacity > 0, !p.grip.isNull {
                let g = geo.local(p.grip)
                Pincers(rect: g)
                    .rotationEffect(.degrees(p.cargoTilt))
                    .opacity(p.gripOpacity)
                    .position(x: g.midX, y: g.midY)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    @ViewBuilder func character(_ p: MascotPose) -> some View {
        switch fly.kind {
        case .snap: SnapBody(pose: p, t: t)
        case .clawsy: ClawHead(open: p.open)
        case .beamy: Saucer(t: t)
        case .ribbit: FrogBody(pose: p)
        default: EmptyView()
        }
    }
}

/// The original chip, for people who like it plain.
struct ClassicChip: View {
    let fly: Fly
    let from: CGPoint
    let to: CGPoint

    var body: some View {
        let colors = Theme.colors(for: fly.mode, sample: fly.color)
        let control = CGPoint(x: from.x + (to.x - from.x) * 0.35, y: min(from.y, to.y) - 140)
        Circle()
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 30, height: 30)
            .overlay(Image(systemName: fly.mode.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
            .shadow(color: colors[0].opacity(0.5), radius: 8, y: 3)
            .keyframeAnimator(initialValue: CGFloat(0), repeating: false) { content, t in
                let u = 1 - t
                let p = CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x, y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
                content
                    .scaleEffect(t < 0.12 ? 0.6 + t / 0.12 * 0.5 : 1.1 - 0.7 * t)
                    .opacity(t > 0.82 ? Double((1 - t) / 0.18) : 1)
                    .position(p)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.7)
            }
    }
}

// MARK: - Settings preview

/// A mascot idling in place, for Settings.
struct MascotIdle: View {
    var kind: MascotKind
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let bob = sin(t * 2.6) * 2.5
            let blink = (t.truncatingRemainder(dividingBy: 3.2)) < 0.12 ? 1.0 : 0
            let look = CGVector(dx: sin(t * 0.9) * 0.6, dy: 0.1)
            let pose = MascotPose(body: .zero, look: look, blink: blink)
            Group {
                switch kind {
                case .snap:
                    ZStack {
                        Pincers(rect: CGRect(x: 0, y: 0, width: 50, height: 46)).opacity(0.9)
                        SnapBody(pose: pose, t: t).scaleEffect(0.95)
                    }
                    .frame(width: 50, height: 46)
                case .clawsy:
                    ClawHead(open: sin(t * 1.8) * 0.5 + 0.5).overlay { SeasonHat.on(.clawsy) }.scaleEffect(0.8).offset(y: -12)
                case .beamy:
                    Saucer(t: t).rotationEffect(.degrees(sin(t * 1.5) * 6))
                case .ribbit:
                    FrogBody(pose: MascotPose(body: .zero, look: look, blink: blink, puff: max(0, sin(t * 1.3)) * 0.6))
                case .classic:
                    Circle().fill(LinearGradient(colors: Theme.brand, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                        .overlay(Image(systemName: "text.quote").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                case .off:
                    Image(systemName: "moon.zzz.fill").font(.system(size: 24)).foregroundStyle(.secondary)
                }
            }
            .overlay { if kind != .clawsy { SeasonHat.on(kind) } }
            .offset(y: kind == .off ? 0 : bob)
        }
    }
}

// MARK: - Reactions

/// Two drops of sweat flicking off a mascot carrying something heavy.
struct SweatDrops: View {
    let t: Double
    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { k in
                let u = (t * 2.2 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                Drop()
                    .fill(LinearGradient(colors: [Color(red: 0.75, green: 0.95, blue: 1), Color(red: 0.35, green: 0.75, blue: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 5, height: 7)
                    .offset(x: CGFloat(u) * 9 + CGFloat(k) * 3, y: CGFloat(u * u) * 12 - CGFloat(k) * 6)
                    .opacity(1 - u)
            }
        }
    }

    struct Drop: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.maxX + r.width * 0.2, y: r.midY + r.height * 0.1),
                       control2: CGPoint(x: r.maxX, y: r.maxY))
            p.addCurve(to: CGPoint(x: r.midX, y: r.minY), control1: CGPoint(x: r.minX, y: r.maxY),
                       control2: CGPoint(x: r.minX - r.width * 0.2, y: r.midY + r.height * 0.1))
            return p
        }
    }
}

/// When a grab fails, the mascot pops up by the pointer, shakes its head and shrugs a "?".
struct OopsScene: View {
    let oops: Oops
    let t: Double
    let at: CGPoint

    var body: some View {
        let pop = t < 0.22 ? Choreo.spring(t / 0.22) : 1
        let fade = 1 - Choreo.ramp(t, 0.95, 0.25)
        let shake = sin(t * 24) * 11 * (1 - Choreo.ramp(t, 0.25, 0.6)) * Choreo.ramp(t, 0.12, 0.08)
        ZStack {
            MascotIdle(kind: oops.kind)
                .scaleEffect(0.82 * pop)
                .rotationEffect(.degrees(shake))
            if oops.kind == .ribbit {
                // Ptooey.
                let u = Choreo.ramp(t, 0.3, 0.45)
                Circle().fill(Color(red: 1, green: 0.45, blue: 0.58))
                    .frame(width: 5, height: 5)
                    .offset(x: 10 + CGFloat(u) * 26, y: 4 - CGFloat(sin(u * .pi)) * 14 + CGFloat(u) * 10)
                    .opacity(u > 0 && u < 1 ? 1 : 0)
            }
            Text("?")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(hex: 0xEC4F7C))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 3, y: 1))
                .scaleEffect(Choreo.spring(Choreo.ramp(t, 0.15, 0.25)))
                .offset(x: 24, y: -26)
        }
        .opacity(fade)
        .position(x: at.x + 40, y: at.y - 34)
    }
}

// MARK: - Seasons

/// Mascots dress up a little around Halloween and the winter holidays.
enum Season: String, CaseIterable {
    case halloween, winter, newYear

    static func current(_ date: Date = Date()) -> Season? {
        guard Settings.shared.seasonal else { return nil }
        #if DEBUG
        if let o = MascotDebug.seasonOverride { return o }
        #endif
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        switch (c.month ?? 0, c.day ?? 0) {
        case (10, 24...31), (11, 1): return .halloween
        case (12, 13...30): return .winter
        case (12, 31), (1, 1...2): return .newYear
        default: return nil
        }
    }
}

struct SeasonHat: View {
    let season: Season

    /// The current season's hat, sitting on `kind`'s head (nothing out of season).
    @ViewBuilder static func on(_ kind: MascotKind) -> some View {
        if let season = Season.current(), let spot = spot(for: kind) {
            SeasonHat(season: season).rotationEffect(.degrees(spot.tilt)).offset(spot.offset)
        }
    }

    private static func spot(for kind: MascotKind) -> (offset: CGSize, tilt: Double)? {
        switch kind {
        case .snap: (CGSize(width: -5, height: -21), -10)
        case .clawsy: (CGSize(width: 0, height: -18), 0)
        case .beamy: (CGSize(width: 0, height: -19), 6)
        case .ribbit: (CGSize(width: 0, height: -27), -6)
        case .classic, .off: nil
        }
    }

    var body: some View {
        switch season {
        case .halloween:
            ZStack(alignment: .bottom) {
                Ellipse().fill(Color(hex: 0x2B1740)).frame(width: 26, height: 6)
                HatCone(bend: 0.35).fill(Color(hex: 0x3A1F57)).frame(width: 15, height: 17).offset(y: -3)
                Rectangle().fill(Color(hex: 0xFF8A3D)).frame(width: 13, height: 2.5).offset(y: -4)
            }
            .frame(width: 26, height: 22)
        case .winter:
            ZStack(alignment: .bottom) {
                HatCone(bend: 0.55).fill(Color(hex: 0xE5303F)).frame(width: 18, height: 18).offset(y: -3)
                Circle().fill(.white).frame(width: 6, height: 6).offset(x: 9, y: -17)
                Capsule().fill(.white).frame(width: 21, height: 6)
            }
            .frame(width: 26, height: 24)
        case .newYear:
            ZStack(alignment: .bottom) {
                HatCone(bend: 0).fill(LinearGradient(colors: Theme.brand, startPoint: .bottomLeading, endPoint: .topTrailing))
                    .frame(width: 14, height: 18)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: 11, height: 2).offset(y: -5)
                    }
                Circle().fill(Color(hex: 0xFFD166)).frame(width: 5, height: 5).offset(y: -18)
            }
            .frame(width: 20, height: 24)
        }
    }

    /// A cone whose tip flops over by `bend`.
    struct HatCone: Shape {
        var bend: CGFloat
        func path(in r: CGRect) -> Path {
            var p = Path()
            let tip = CGPoint(x: r.midX + r.width * bend, y: r.minY + r.height * bend * 0.3)
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: tip, control: CGPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.2))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - r.width * 0.1, y: r.midY))
            p.closeSubpath()
            return p
        }
    }
}

#if DEBUG
/// Renders each mascot's trip offscreen into PNG frames (debug hook `mascotstills:<dir>`).
enum MascotDebug {
    nonisolated(unsafe) static var seasonOverride: Season?

    /// Every mascot in every season's hat, plus the oops and heavy poses (`seasonstills:<dir>`).
    @MainActor
    static func renderSeasons(to dir: String) {
        let kinds: [MascotKind] = [.snap, .clawsy, .beamy, .ribbit]
        for season in [nil] + Season.allCases.map(Optional.some) {
            seasonOverride = season
            let view = HStack(spacing: 30) {
                ForEach(kinds) { k in MascotIdle(kind: k).frame(width: 90, height: 100) }
            }
            .padding(30)
            .background(Color(white: 0.93))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.cgImage {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/season_\(season?.rawValue ?? "none").png"))
            }
        }
        seasonOverride = nil
        for k in kinds {
            let frames = HStack(spacing: 10) {
                ForEach([0.1, 0.3, 0.5, 0.8], id: \.self) { t in
                    OopsScene(oops: Oops(at: CGPoint(x: 30, y: 90), kind: k), t: t, at: CGPoint(x: 30, y: 90))
                        .frame(width: 140, height: 120)
                        .background(Color(white: 0.9))
                }
            }
            let r = ImageRenderer(content: frames)
            r.scale = 2
            if let img = r.cgImage {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/oops_\(k.rawValue).png"))
            }
        }
    }

    @MainActor
    static func renderStills(to dir: String) {
        let size = CGSize(width: 1200, height: 640)
        let geo = ScreenGeometry(frame: CGRect(origin: .zero, size: size))
        let thumb: CGImage? = {
            let r = ImageRenderer(content: LinearGradient(colors: Theme.brand, startPoint: .topLeading, endPoint: .bottomTrailing).frame(width: 120, height: 80))
            return r.cgImage
        }()
        let samples: [(MascotKind, Cargo)] = [
            (.snap, Cargo(content: .text("Great work rarely comes from doing more"), colors: Theme.colors(for: .text))),
            (.clawsy, Cargo(content: .image(thumb!), colors: Theme.colors(for: .image))),
            (.beamy, Cargo(content: .symbol("link", "example.com"), colors: Theme.colors(for: .link))),
            (.ribbit, Cargo(content: .color(RGBAColor(r: 0.93, g: 0.43, b: 0.16)), colors: Theme.colors(for: .color))),
        ]
        for (kind, cargo) in samples {
            let fly = Fly(from: CGPoint(x: 330, y: 470), to: CGPoint(x: 1080, y: 14), mode: .text, color: nil,
                          target: CGRect(x: 180, y: 440, width: 300, height: 60), kind: kind, cargo: cargo)
            for t in [0.06, 0.22, 0.4, 0.52, 0.7, 0.88, 1.0] {
                let dark = kind == .clawsy || kind == .ribbit
                let view = ZStack(alignment: .topLeading) {
                    Color(white: dark ? 0.12 : 0.96)
                    Rectangle().fill(Color.black.opacity(0.85)).frame(width: size.width, height: 28)
                    MiniStatusIcon().position(x: 1080, y: 14)
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue.opacity(t < 0.2 ? 0.8 : 0), lineWidth: 3)
                        .frame(width: 300, height: 60).position(x: 330, y: 470)
                    Text("Great work rarely comes from doing more").font(.system(size: 17)).foregroundStyle(dark ? .white.opacity(0.85) : .black.opacity(0.8))
                        .position(x: 330, y: 470)
                    MascotScene(fly: fly, t: t, geo: geo)
                    Text("\(kind.title)  t=\(String(format: "%.2f", t))").font(.system(size: 22, weight: .bold)).foregroundStyle(.black.opacity(0.5))
                        .position(x: 120, y: 600)
                }
                .frame(width: size.width, height: size.height)
                let r = ImageRenderer(content: view)
                r.scale = 1
                guard let img = r.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(kind.rawValue)_\(String(format: "%.2f", t)).png"))
            }
        }
    }
}

private struct MiniStatusIcon: View {
    var body: some View {
        Image(systemName: "viewfinder").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
    }
}
#endif
