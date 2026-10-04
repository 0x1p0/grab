import AppKit
import SwiftUI

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var onboarding: NSWindow?
    private var settings: NSWindow?

    func showOnboarding() {
        if onboarding == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 720),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.title = "Welcome to Grab"
            w.contentView = NSHostingView(rootView: OnboardingView { [weak w] in w?.close() })
            w.center()
            w.delegate = self
            onboarding = w
        }
        present(onboarding)
    }

    func showSettings() {
        if settings == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.title = "Grab Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(openOnboarding: { [weak self] in self?.showOnboarding() }))
            w.center()
            w.delegate = self
            settings = w
        }
        present(settings)
    }

    private func present(_ w: NSWindow?) {
        guard let w else { return }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === onboarding {
            Settings.shared.hasOnboarded = true
        }
    }
}
