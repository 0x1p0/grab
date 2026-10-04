import AppKit
import SwiftUI

final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A screen's geometry in global top-left points.
struct ScreenGeometry: Equatable {
    let frame: CGRect
    let visible: CGRect

    init(_ s: NSScreen) {
        frame = ScreenSpace.toAX(s.frame)
        visible = ScreenSpace.toAX(s.visibleFrame)
    }

    init(frame: CGRect) {
        self.frame = frame
        visible = frame
    }

    var size: CGSize { frame.size }
    func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -frame.minX, dy: -frame.minY) }
    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }
}

/// One transparent, click-through window per display, above everything (including
/// full-screen apps), never taking focus.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private var windows: [OverlayWindow] = []
    private var hideWork: DispatchWorkItem?
    private var shown = false

    init() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func rebuild() {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows = NSScreen.screens.map(makeWindow)
        let ids = Set(windows.map { CGWindowID($0.windowNumber) })
        Task { await ScreenGrabber.shared.setExcludedWindows(ids) }
        applySharing()
        if shown { windows.forEach { $0.orderFrontRegardless() } }
    }

    /// By default the overlay is invisible to screen capture, so it never ends up
    /// in your screenshots, recordings, OCR or colour picks. Recording a demo?
    /// Settings can make it visible.
    func applySharing() {
        let visible = Settings.shared.overlayInRecordings
        windows.forEach { $0.sharingType = visible ? .readOnly : .none }
        Task { await ScreenGrabber.shared.setOverlayHidden(!visible) }
    }

    private func makeWindow(for screen: NSScreen) -> OverlayWindow {
        let w = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.isFloatingPanel = true
        w.becomesKeyOnlyIfNeeded = true
        w.animationBehavior = .none
        w.setAccessibilityElement(false)

        let host = NSHostingView(rootView: OverlayRootView(geo: ScreenGeometry(screen), model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        host.setAccessibilityElement(false)
        w.contentView = host
        w.setFrame(screen.frame, display: false)
        return w
    }

    func show() {
        hideWork?.cancel()
        hideWork = nil
        guard !shown else { return }
        shown = true
        windows.forEach { $0.orderFrontRegardless() }
    }

    func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.visible, self.model.toast == nil, self.model.fly == nil else { return }
            self.shown = false
            self.windows.forEach { $0.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
