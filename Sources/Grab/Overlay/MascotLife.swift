import AppKit
import SwiftUI

// MARK: - The notch

enum Notch {
    /// The notch on this screen, in global top-left points; nil on screens without one.
    static func rect(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return nil }
        // The side areas are given in screen coordinates; keep them on this screen either way.
        let f = screen.frame
        var minX = l.maxX, maxX = r.minX
        if minX < f.minX || maxX > f.maxX { minX += f.minX; maxX += f.minX }
        guard maxX - minX > 20 else { return nil }
        let h = screen.safeAreaInsets.top
        return ScreenSpace.toAX(CGRect(x: minX, y: f.maxY - h, width: maxX - minX, height: h))
    }

    /// The notch nearest a global point: on the screen under it.
    static func rect(near p: CGPoint) -> CGRect? {
        guard let s = NSScreen.screens.first(where: { ScreenSpace.toAX($0.frame).contains(p) }) else { return nil }
        return rect(on: s)
    }
}

/// The notch growing a little, like it's opening to let the mascot out (or swallowing a grab).
struct NotchBulge: View {
    /// The notch, in this view's coordinates.
    let notch: CGRect
    /// 0 = just the notch, 1 = fully open.
    let amount: Double

    var body: some View {
        if amount > 0.02 {
            NotchShape(notch: notch, amount: CGFloat(amount)).fill(Color.black)
        }
    }

    struct NotchShape: Shape {
        let notch: CGRect
        let amount: CGFloat
        func path(in _: CGRect) -> Path {
            let grow = 16 * amount, drop = 10 * amount, shoulder = 7 * amount
            let minX = notch.minX - grow, maxX = notch.maxX + grow
            let top = notch.minY, bottom = notch.maxY + drop
            let r = min(14, (bottom - top) / 2)
            var p = Path()
            p.move(to: CGPoint(x: minX - shoulder, y: top))
            p.addQuadCurve(to: CGPoint(x: minX, y: top + shoulder), control: CGPoint(x: minX, y: top))
            p.addLine(to: CGPoint(x: minX, y: bottom - r))
            p.addQuadCurve(to: CGPoint(x: minX + r, y: bottom), control: CGPoint(x: minX, y: bottom))
            p.addLine(to: CGPoint(x: maxX - r, y: bottom))
            p.addQuadCurve(to: CGPoint(x: maxX, y: bottom - r), control: CGPoint(x: maxX, y: bottom))
            p.addLine(to: CGPoint(x: maxX, y: top + shoulder))
            p.addQuadCurve(to: CGPoint(x: maxX + shoulder, y: top), control: CGPoint(x: maxX, y: top))
            p.closeSubpath()
            return p
        }
    }
}

// MARK: - Peeking

/// The mascot peeking out from under the menu bar (or the notch) while ⌥ is held.
struct Peek: Equatable, Identifiable {
    let id = UUID()
    /// Global: x of the spot it peeks from, y of the menu bar's bottom edge.
    var anchor: CGPoint
    var kind: MascotKind
    /// It was dozing: wakes with a start.
    var sleepy: Bool
    var notch: CGRect?
    var start: Date
    /// When it ducks back up, out of the way of whatever's under it. Pointing at it keeps it out.
    var retractAt: Date

    init(anchor: CGPoint, kind: MascotKind, sleepy: Bool, notch: CGRect?, start: Date = Date()) {
        self.anchor = anchor
        self.kind = kind
        self.sleepy = sleepy
        self.notch = notch
        self.start = start
        retractAt = start.addingTimeInterval(sleepy ? 4.2 : 3.2)
    }

    func isOut(at now: Date = Date()) -> Bool { now < retractAt }

    /// Where to point to pet it (global).
    var hitRect: CGRect { CGRect(x: anchor.x - 30, y: anchor.y - 2, width: 60, height: 40) }

    /// How far below the edge its middle sits, fully out.
    var depth: CGFloat {
        switch kind {
        case .snap: 12
        case .clawsy: 22
        case .beamy: 21
        case .ribbit: 25
        default: 0
        }
    }
}

/// A poke: a giggle, or the last straw.
struct PetEvent: Equatable, Identifiable {
    let id = UUID()
    var reaction: Buddy.PetReaction
    var start = Date()
}

struct PeekScene: View {
    let peek: Peek
    let t: Double
    let geo: ScreenGeometry
    let pet: PetEvent?
    let hovering: Bool

    var body: some View {
        let rim = geo.local(peek.anchor).y
        let x = geo.local(peek.anchor).x
        let mood = Buddy.shared.mood()
        // Out from behind the edge; a dozing one is slower about it.
        let rise = Choreo.spring(Choreo.ramp(t, peek.sleepy ? 0.05 : 0, peek.sleepy ? 0.6 : 0.34))
        let asleep = peek.sleepy && t < 0.85
        let jolt = peek.sleepy ? sin(.pi * Choreo.ramp(t, 0.85, 0.22)) : 0
        let tp = pet.map { Date().timeIntervalSince($0.start) } ?? 99
        let annoyed = pet?.reaction == .annoyed && tp < 2
        let giggle = pet.map { if case .giggle = $0.reaction { return tp < 0.9 } else { return false } } ?? false
        // Walking off in a huff: sideways and up behind the edge.
        let leave = annoyed ? Choreo.easeIn(Choreo.ramp(tp, 0.7, 0.8)) : 0
        let bob = sin(t * 2.4) * 1.5
        // Back up behind the edge once it's had its look.
        let back = Choreo.easeIn(Choreo.ramp(Date().timeIntervalSince(peek.retractAt), 0, 0.32))
        let center = CGPoint(x: x + CGFloat(leave) * 160,
                             y: rim - 34 + (34 + peek.depth) * CGFloat(rise * (1 - back)) - CGFloat(jolt) * 7 + CGFloat(bob) - CGFloat(leave) * 40)
        let wriggle = giggle ? sin(tp * 34) * 13 * (1 - tp / 0.9) : (annoyed && tp < 0.6 ? sin(tp * 44) * 9 : 0)
        let squash = giggle ? sin(tp * 22) * 0.09 * (1 - tp / 0.9) : 0
        let mouse = ScreenSpace.mouseLocation()
        let look = Choreo.look(from: CGPoint(x: peek.anchor.x, y: peek.anchor.y + peek.depth), to: mouse)
        let blinkPhase = (t + 1.3).truncatingRemainder(dividingBy: 3.4)
        let blink: Double = asleep || giggle ? 1 : (blinkPhase < 0.12 ? 1 : 0)
        let pose = MascotPose(body: .zero, look: CGVector(dx: look.dx, dy: max(0.2, look.dy)), blink: blink,
                              mouth: giggle ? 0.9 : 0, puff: annoyed ? 0.7 : 0)

        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                character(pose)
                    .overlay { MascotWear(kind: peek.kind) }
                    .scaleEffect(x: peek.kind.size * 0.92 * (1 + squash), y: peek.kind.size * 0.92 * (1 - squash))
                    .rotationEffect(.degrees(wriggle))
                    .position(center)
                if peek.kind == .clawsy {
                    // Its cable, from the edge.
                    Path { p in
                        p.move(to: CGPoint(x: center.x, y: rim - 40))
                        p.addLine(to: CGPoint(x: center.x, y: center.y - 10))
                    }
                    .stroke(Color(white: 0.75), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                }
            }
            .clipShape(Below(y: rim))

            // Little extras, outside the clip.
            if asleep, rise > 0.5 {
                Zzz(t: t).position(x: center.x + 26, y: center.y + 2)
            }
            if peek.sleepy, t >= 0.85, t < 1.6 {
                Bubble(text: "!", t: t - 0.85).position(x: center.x + 26, y: center.y + 4)
            }
            if mood == .pumped, !annoyed {
                Sparkles(t: t).position(x: center.x, y: center.y + 4)
            }
            if giggle {
                Hearts(t: tp).position(x: center.x + 18, y: center.y + 6)
            }
            if annoyed, tp < 1.2 {
                AngerMark().stroke(Color(hex: 0xFF3B30), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .frame(width: 14, height: 14)
                    .scaleEffect(Choreo.spring(Choreo.ramp(tp, 0, 0.25)))
                    .position(x: center.x + 22, y: center.y + 4)
            }
            if hovering, pet == nil || tp > 1, rise > 0.9, back == 0 {
                Text("C to pet")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(LinearGradient(colors: Theme.brand, startPoint: .leading, endPoint: .trailing)))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .position(x: center.x + 58, y: rim + 18)
                    .transition(.opacity)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    @ViewBuilder private func character(_ p: MascotPose) -> some View {
        switch peek.kind {
        case .snap: SnapBody(pose: p, t: t)
        case .clawsy: ClawHead(open: sin(t * 1.6) * 0.3 + 0.35)
        case .beamy: Saucer(t: t).rotationEffect(.degrees(sin(t * 1.7) * 5))
        case .ribbit: FrogBody(pose: p)
        default: EmptyView()
        }
    }

    /// Everything below a horizontal line: the mascot comes out from behind the edge.
    struct Below: Shape {
        let y: CGFloat
        func path(in r: CGRect) -> Path { Path(CGRect(x: r.minX - 400, y: y, width: r.width + 800, height: max(0, r.maxY - y))) }
    }
}

/// Z's drifting up off a dozing mascot.
struct Zzz: View {
    let t: Double
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { k in
                let u = (t * 0.7 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: 9 + CGFloat(k) * 2, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(hex: 0x9AA8FF))
                    .shadow(color: .black.opacity(0.3), radius: 1)
                    .offset(x: CGFloat(u) * 12, y: -CGFloat(u) * 18)
                    .opacity(sin(.pi * u))
            }
        }
    }
}

/// A speech bubble with one character in it ("!", "?").
struct Bubble: View {
    let text: String
    let t: Double
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(hex: 0xEC4F7C))
            .frame(width: 19, height: 19)
            .background(Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 3, y: 1))
            .scaleEffect(Choreo.spring(Choreo.ramp(t, 0, 0.25)))
            .opacity(1 - Choreo.ramp(t, 0.5, 0.25))
    }
}

/// Three sparkles circling a mascot that's on a roll.
struct Sparkles: View {
    let t: Double
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { k in
                let a = t * 2.2 + Double(k) * 2.094
                SparkleStar().fill(Color(hex: 0xFFD166))
                    .frame(width: 7, height: 7)
                    .shadow(color: Color(hex: 0xFF8A3D), radius: 3)
                    .scaleEffect(0.7 + 0.3 * sin(t * 6 + Double(k)))
                    .offset(x: CGFloat(cos(a)) * 27, y: CGFloat(sin(a)) * 13)
            }
        }
    }
}

/// Hearts floating up from a happy mascot.
struct Hearts: View {
    let t: Double
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { k in
                let u = Choreo.clamp((t - Double(k) * 0.12) / 0.8)
                Image(systemName: "heart.fill")
                    .font(.system(size: 9 + CGFloat(k), weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFF6FA5), Color(hex: 0xEC4F7C)], startPoint: .top, endPoint: .bottom))
                    .offset(x: CGFloat(k) * 7 + CGFloat(sin(u * 6 + Double(k))) * 3, y: -CGFloat(u) * 26)
                    .opacity(u > 0 ? 1 - u : 0)
                    .scaleEffect(0.6 + 0.6 * Choreo.spring(min(1, u * 3)))
            }
        }
    }
}

/// The cartoon "annoyed" mark: four little curved strokes.
struct AngerMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), s = r.width / 2
        for (dx, dy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
            let a = CGPoint(x: c.x + CGFloat(dx) * s * 0.25, y: c.y + CGFloat(dy) * s)
            let b = CGPoint(x: c.x + CGFloat(dx) * s, y: c.y + CGFloat(dy) * s * 0.25)
            p.move(to: a)
            p.addQuadCurve(to: b, control: CGPoint(x: c.x + CGFloat(dx) * s * 0.35, y: c.y + CGFloat(dy) * s * 0.35))
        }
        return p
    }
}

// MARK: - Outfits

/// Everything the mascot has on: the season's hat, a nightcap after midnight, or the
/// crown it earned; sunglasses from 100 grabs.
struct MascotWear: View {
    let kind: MascotKind
    var outfit = Buddy.shared.outfit()

    var body: some View {
        ZStack {
            if outfit.shades, let face = Self.face(kind) {
                Shades(width: face.width).offset(face.offset)
            }
            if let spot = SeasonHat.spot(for: kind) {
                Group {
                    if let season = Season.current() {
                        SeasonHat(season: season)
                    } else if outfit.nightcap {
                        Nightcap()
                    } else if outfit.crown {
                        Crown()
                    }
                }
                .rotationEffect(.degrees(spot.tilt))
                .offset(spot.offset)
            }
        }
    }

    /// Where the eyes are, and how wide sunglasses need to be.
    static func face(_ kind: MascotKind) -> (offset: CGSize, width: CGFloat)? {
        switch kind {
        case .snap: (CGSize(width: 0, height: -2), 27)
        case .clawsy: (CGSize(width: 0, height: -1), 23)
        case .beamy: (CGSize(width: 0, height: -9), 17)
        case .ribbit: (CGSize(width: 0, height: -14), 44)
        default: nil
        }
    }
}

struct Shades: View {
    let width: CGFloat
    var body: some View {
        let lensW = width * 0.43, lensH = width * 0.3
        let lens = RoundedRectangle(cornerRadius: lensH * 0.45, style: .continuous)
        ZStack {
            Capsule().fill(Color(hex: 0x111111)).frame(width: width * 0.24, height: max(1.2, width * 0.06)).offset(y: -lensH * 0.22)
            HStack(spacing: width * 0.14) {
                ForEach(0..<2, id: \.self) { _ in
                    lens.fill(LinearGradient(colors: [Color(hex: 0x2A2A35), Color(hex: 0x050508)], startPoint: .top, endPoint: .bottom))
                        .overlay(lens.strokeBorder(Color.black, lineWidth: max(0.8, width * 0.04)))
                        .overlay(alignment: .topLeading) {
                            Capsule().fill(Color.white.opacity(0.75)).frame(width: lensW * 0.35, height: max(1, lensH * 0.16))
                                .rotationEffect(.degrees(-20)).offset(x: lensW * 0.18, y: lensH * 0.2)
                        }
                        .frame(width: lensW, height: lensH)
                }
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
    }
}

struct Crown: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            CrownShape()
                .fill(LinearGradient(colors: [Color(hex: 0xFFE27A), Color(hex: 0xF5A623)], startPoint: .top, endPoint: .bottom))
                .overlay(CrownShape().stroke(Color(hex: 0xB9770E), lineWidth: 0.8))
                .frame(width: 19, height: 13)
            HStack(spacing: 3.5) {
                ForEach([0xEC4F7C, 0x2F7BFF, 0xEC4F7C], id: \.self) { c in Circle().fill(Color(hex: UInt32(c))).frame(width: 2.8, height: 2.8) }
            }
            .offset(y: -2.5)
        }
        .frame(width: 22, height: 18, alignment: .bottom)
        .shadow(color: Color(hex: 0xF5A623).opacity(0.6), radius: 3)
    }

    struct CrownShape: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.25))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.25, y: r.minY + r.height * 0.6))
            p.addLine(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - r.width * 0.25, y: r.minY + r.height * 0.6))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.25))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}

/// A floppy navy nightcap with stars, for after midnight.
struct Nightcap: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            SeasonHat.HatCone(bend: 0.7)
                .fill(LinearGradient(colors: [Color(hex: 0x4F5BD5), Color(hex: 0x2A2F7A)], startPoint: .top, endPoint: .bottom))
                .frame(width: 18, height: 18)
                .overlay {
                    ForEach(0..<2, id: \.self) { k in
                        SparkleStar().fill(Color(hex: 0xFFE27A)).frame(width: 3.5, height: 3.5).offset(x: CGFloat(k) * 5 - 3, y: CGFloat(k) * 4)
                    }
                }
                .offset(y: -3)
            Circle().fill(.white).frame(width: 6, height: 6).offset(x: 12, y: -14)
            Capsule().fill(Color(hex: 0xE8ECFF)).frame(width: 21, height: 5.5)
        }
        .frame(width: 26, height: 24)
    }
}

// MARK: - Combos

/// Every fifth grab in a row: a burst of confetti and the count.
struct Burst: Equatable, Identifiable {
    let id = UUID()
    var at: CGPoint
    var combo: Int
    var colors: [Color]
    var start = Date()
}

struct BurstScene: View {
    let burst: Burst
    let t: Double
    let at: CGPoint

    var body: some View {
        ZStack {
            ForEach(0..<28, id: \.self) { i in
                let seed = Double(i) * 12.9898
                let angle = Double(i) / 28 * 2 * .pi + sin(seed) * 0.3
                let speed = 140 + (sin(seed * 3.1) * 0.5 + 0.5) * 120
                let x = cos(angle) * speed * t
                let y = sin(angle) * speed * t * 0.8 + 260 * t * t - 40 * t
                let colors = burst.colors + Theme.brand
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(colors[i % colors.count])
                    .frame(width: i % 3 == 0 ? 5 : 7, height: i % 3 == 0 ? 5 : 3.5)
                    .rotationEffect(.radians(t * (6 + Double(i % 5)) + seed))
                    .offset(x: CGFloat(x), y: CGFloat(y))
                    .opacity(1 - Choreo.ramp(t, 0.7, 0.4))
            }
            Text("COMBO ×\(burst.combo)")
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFD166), Color(hex: 0xFF8A3D), Color(hex: 0xEC4F7C)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .scaleEffect(Choreo.spring(Choreo.ramp(t, 0, 0.3)) * 1.1)
                .offset(y: -34 - CGFloat(t) * 16)
                .opacity(1 - Choreo.ramp(t, 0.8, 0.35))
        }
        .position(at)
    }
}
