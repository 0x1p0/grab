import AppKit
import QuartzCore
import SwiftUI

/// The spotlight and the glowing border, drawn with Core Animation layers.
///
/// Springs, the sweeping sheen and the copy pulse all run in the render server, so
/// moving between targets costs the main thread almost nothing — SwiftUI only
/// hands over the target rectangle.
final class HighlightCanvasView: NSView {
    struct Look: Equatable {
        var hole: CGRect?
        var isText = false
        var colors: [CGColor] = []
        var spotlight = true
        var visible = false
        var flash = 0
        var busy = false
        var reduceMotion = false
        /// "Increase contrast": a thicker, solid border with no glow.
        var highContrast = false

        static func == (a: Look, b: Look) -> Bool {
            a.hole == b.hole && a.isText == b.isText && a.spotlight == b.spotlight && a.visible == b.visible
                && a.flash == b.flash && a.busy == b.busy && a.reduceMotion == b.reduceMotion && a.highContrast == b.highContrast
                && a.colors.count == b.colors.count && zip(a.colors, b.colors).allSatisfy { $0 == $1 }
        }
    }

    private let spot = CAShapeLayer()
    private let box = CALayer()
    private let glow = CALayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let border = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    private let sheenHolder = CALayer()
    private let sheen = CAGradientLayer()
    private let sheenMask = CAShapeLayer()
    private let flashLayer = CAShapeLayer()

    private var look = Look()
    private var shown = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        spot.fillRule = .evenOdd
        spot.fillColor = NSColor.black.withAlphaComponent(0.13).cgColor
        spot.opacity = 0

        glow.shadowOpacity = 0.75
        glow.shadowRadius = 9
        glow.shadowOffset = .zero
        fill.mask = fillMask
        fill.startPoint = CGPoint(x: 0, y: 0)
        fill.endPoint = CGPoint(x: 1, y: 1)
        border.mask = borderMask
        border.startPoint = CGPoint(x: 0, y: 0)
        border.endPoint = CGPoint(x: 1, y: 1)
        for m in [borderMask, sheenMask] {
            m.fillColor = nil
            m.strokeColor = NSColor.black.cgColor
            m.lineWidth = 1.75
        }
        sheen.type = .conic
        sheen.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)
        let clear = NSColor.white.withAlphaComponent(0).cgColor
        sheen.colors = [clear, clear, NSColor.white.withAlphaComponent(0.95).cgColor, clear, clear]
        sheen.locations = [0, 0.62, 0.8, 0.97, 1]
        sheen.compositingFilter = "plusL"
        sheenHolder.mask = sheenMask
        sheenHolder.addSublayer(sheen)
        flashLayer.fillColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        flashLayer.compositingFilter = "plusL"

        box.opacity = 0
        for l in [glow, fill, border, sheenHolder, flashLayer] { box.addSublayer(l) }
        layer?.addSublayer(spot)
        layer?.addSublayer(box)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Geometry

    private static func radius(for size: CGSize, text: Bool) -> CGFloat {
        if text { return min(7, size.height / 2) }
        return min(12, max(5, min(size.width, size.height) * 0.16))
    }

    private func outline(_ size: CGSize, radius r: CGFloat, inset: CGFloat) -> CGPath {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let rr = max(0, min(r - inset, min(rect.width, rect.height) / 2))
        return CGPath(roundedRect: rect, cornerWidth: rr, cornerHeight: rr, transform: nil)
    }

    private func spotPath(hole: CGRect, radius r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addRect(bounds.insetBy(dx: -40, dy: -40))
        let rr = max(0, min(r, min(hole.width, hole.height) / 2))
        p.addRoundedRect(in: hole, cornerWidth: rr, cornerHeight: rr)
        return p
    }

    // MARK: Updates

    func apply(_ new: Look) {
        let old = look
        look = new
        let colors = new.colors.isEmpty ? [NSColor.systemBlue.cgColor, NSColor.systemTeal.cgColor] : new.colors

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.colors = colors
        fill.colors = colors.map { $0.copy(alpha: new.highContrast ? 0.18 : 0.11) ?? $0 }
        glow.shadowColor = colors.first
        glow.isHidden = new.highContrast
        borderMask.lineWidth = new.highContrast ? 3.5 : 1.75
        spot.fillColor = NSColor.black.withAlphaComponent(new.highContrast ? 0.3 : 0.13).cgColor
        CATransaction.commit()

        guard new.visible, let rawHole = new.hole else {
            if shown { fade(to: 0) }
            shown = false
            return
        }
        let hole = rawHole.insetBy(dx: new.isText ? -4 : -4, dy: new.isText ? -3 : -4)
        let r = Self.radius(for: hole.size, text: new.isText)
        let animate = shown && !new.reduceMotion && old.hole != new.hole

        setGeometry(hole: hole, radius: r, animated: animate)
        if !shown {
            shown = true
            appear()
        }
        spot.isHidden = !new.spotlight
        if new.busy != old.busy || sheen.animation(forKey: "spin") == nil { spin(fast: new.busy, still: new.reduceMotion && !new.busy) }
        if new.flash != old.flash && new.flash > 0 { pulse() }
    }

    private func setGeometry(hole: CGRect, radius r: CGFloat, animated: Bool) {
        let size = hole.size
        let values: [(CALayer, String, Any)] = [
            (box, "position", NSValue(point: CGPoint(x: hole.midX, y: hole.midY))),
            (box, "bounds", NSValue(rect: CGRect(origin: .zero, size: size))),
            (glow, "shadowPath", outline(size, radius: r, inset: 0).copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 1)),
            (fillMask, "path", outline(size, radius: r, inset: 0)),
            (borderMask, "path", outline(size, radius: r, inset: 0.875)),
            (sheenMask, "path", outline(size, radius: r, inset: 0.875)),
            (flashLayer, "path", outline(size, radius: r, inset: 0)),
            (spot, "path", spotPath(hole: hole, radius: r)),
        ]
        let side = hypot(size.width, size.height)
        let frames: [(CALayer, CGRect)] = [
            (glow, CGRect(origin: .zero, size: size)), (fill, CGRect(origin: .zero, size: size)),
            (border, CGRect(origin: .zero, size: size)), (sheenHolder, CGRect(origin: .zero, size: size)),
            (flashLayer, CGRect(origin: .zero, size: size)),
            (sheen, CGRect(x: size.width / 2 - side / 2, y: size.height / 2 - side / 2, width: side, height: side)),
            (fillMask, CGRect(origin: .zero, size: size)), (borderMask, CGRect(origin: .zero, size: size)),
            (sheenMask, CGRect(origin: .zero, size: size)), (spot, bounds),
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, key, value) in values {
            if animated, let from = l.presentation()?.value(forKeyPath: key) ?? l.value(forKeyPath: key) {
                let a = CASpringAnimation(keyPath: key)
                a.mass = 1
                a.stiffness = 440
                a.damping = 34
                a.fromValue = from
                a.toValue = value
                a.duration = a.settlingDuration
                l.add(a, forKey: "spring.\(key)")
            }
            l.setValue(value, forKeyPath: key)
        }
        for (l, f) in frames {
            if animated, l !== spot {
                for key in ["bounds", "position"] {
                    let to: Any = key == "bounds" ? NSValue(rect: CGRect(origin: .zero, size: f.size)) : NSValue(point: CGPoint(x: f.midX, y: f.midY))
                    let a = CASpringAnimation(keyPath: key)
                    a.stiffness = 440
                    a.damping = 34
                    a.fromValue = l.presentation()?.value(forKeyPath: key) ?? l.value(forKeyPath: key)
                    a.toValue = to
                    a.duration = a.settlingDuration
                    l.add(a, forKey: "spring.\(key)")
                }
            }
            l.frame = f
        }
        CATransaction.commit()
    }

    private func appear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.opacity = 1
        spot.opacity = 1
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        box.add(fade, forKey: "appear")
        spot.add(fade, forKey: "appear")
        guard !look.reduceMotion else { return }
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.05
        scale.toValue = 1
        scale.stiffness = 440
        scale.damping = 30
        scale.duration = scale.settlingDuration
        box.add(scale, forKey: "appearScale")
    }

    private func fade(to value: Float) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = box.presentation()?.opacity ?? box.opacity
        a.toValue = value
        a.duration = 0.18
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.opacity = value
        spot.opacity = value
        CATransaction.commit()
        box.add(a, forKey: "fade")
        spot.add(a, forKey: "fade")
    }

    private func spin(fast: Bool, still: Bool) {
        sheen.removeAnimation(forKey: "spin")
        sheenHolder.isHidden = still
        guard !still else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi
        a.duration = fast ? 0.45 : 1.8
        a.repeatCount = .infinity
        sheen.add(a, forKey: "spin")
    }

    private func pulse() {
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 0.22, 0]
        flash.keyTimes = [0, 0.12, 1]
        flash.duration = 0.5
        flashLayer.add(flash, forKey: "flash")
        guard !look.reduceMotion else { return }
        let squeeze = CAKeyframeAnimation(keyPath: "transform.scale")
        squeeze.values = [1, 0.955, 1.012, 1]
        squeeze.keyTimes = [0, 0.16, 0.55, 1]
        squeeze.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        squeeze.duration = 0.5
        box.add(squeeze, forKey: "squeeze")
    }
}

/// SwiftUI bridge: hands the current target and look to the canvas, no animation on this side.
struct HighlightCanvas: NSViewRepresentable {
    let geo: ScreenGeometry
    let model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> HighlightCanvasView {
        HighlightCanvasView(frame: CGRect(origin: .zero, size: geo.size))
    }

    func updateNSView(_ v: HighlightCanvasView, context: Context) {
        var look = HighlightCanvasView.Look()
        look.hole = model.target.map { geo.local($0) }
        look.isText = model.targetIsText
        look.colors = model.tint.map { NSColor($0).cgColor }
        look.spotlight = model.spotlight
        look.visible = model.visible && !model.pixelColor && model.target != nil
        look.flash = model.flash
        look.busy = model.busy
        look.reduceMotion = reduceMotion
        look.highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        v.apply(look)
    }
}
