import AppKit
import SwiftUI

/// The menu bar icon and its menu: status, recent grabs, settings.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private unowned let app: AppDelegate
    private var celebrateWork: [DispatchWorkItem] = []

    init(app: AppDelegate) {
        self.app = app
        super.init()
        item.button?.image = Icons.statusIcon()
        item.button?.toolTip = "Grab — hold \(Trigger.current.symbol) and hover anything"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        trackFrontmost()
        refresh()
    }

    func refresh() {
        item.button?.appearsDisabled = Settings.shared.paused || !Permissions.shared.accessibility
    }

    /// The icon's frame in global top-left points, for the "fly to menu bar" animation.
    func buttonFrame() -> CGRect? {
        guard let b = item.button, let w = b.window else { return nil }
        return ScreenSpace.toAX(w.convertToScreen(b.convert(b.bounds, to: nil)))
    }

    /// Lights the icon up as the flying chip lands.
    func celebrate(at landing: TimeInterval = 0.58) {
        celebrateWork.forEach { $0.cancel() }
        let on = DispatchWorkItem { [weak self] in self?.item.button?.image = Icons.statusIcon(filled: true) }
        let off = DispatchWorkItem { [weak self] in self?.item.button?.image = Icons.statusIcon() }
        celebrateWork = [on, off]
        DispatchQueue.main.asyncAfter(deadline: .now() + landing, execute: on)
        DispatchQueue.main.asyncAfter(deadline: .now() + landing + 0.67, execute: off)
    }

    // MARK: Menu

    func openMenu() {
        item.button?.performClick(nil)
    }

    func closeMenu() {
        menu.cancelTracking()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        History.shared.ensureLoaded()

        let header = NSMenuItem()
        let hv = NSHostingView(rootView: MenuHeader())
        hv.frame = NSRect(x: 0, y: 0, width: 300, height: 58)
        header.view = hv
        menu.addItem(header)
        menu.addItem(.separator())

        let history = History.shared.items
        if history.isEmpty {
            let none = NSMenuItem(title: "Nothing grabbed yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(NSMenuItem.sectionHeader(title: "Recent Grabs"))
            for (i, h) in history.prefix(8).enumerated() {
                menu.addItem(historyItem(h, key: i < 9 ? "\(i + 1)" : ""))
            }
            // Everything, grouped by the app it came from.
            let groups = History.shared.byApp(history)
            if groups.count > 1 || history.count > 8 {
                let byApp = NSMenuItem(title: "By App", action: nil, keyEquivalent: "")
                byApp.image = Icons.symbol("square.stack.3d.up")
                let sub = NSMenu()
                for g in groups {
                    let app = NSMenuItem(title: g.app, action: nil, keyEquivalent: "")
                    let icon = AppIcons.icon(g.bundleID).copy() as! NSImage
                    icon.size = NSSize(width: 16, height: 16)
                    app.image = icon
                    if #available(macOS 14.4, *) { app.subtitle = g.items.count == 1 ? "1 grab" : "\(g.items.count) grabs" }
                    let items = NSMenu()
                    for h in g.items.prefix(30) { items.addItem(historyItem(h, key: "", showApp: false)) }
                    app.submenu = items
                    sub.addItem(app)
                }
                byApp.submenu = sub
                menu.addItem(byApp)
            }
            let search = NSMenuItem(title: "Open History…", action: #selector(showHistory), keyEquivalent: "f")
            search.target = self
            search.image = Icons.symbol("magnifyingglass")
            menu.addItem(search)
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        if !Shelf.shared.items.isEmpty {
            let shelf = NSMenuItem(title: "Show Shelf (\(Shelf.shared.items.count))", action: #selector(showShelf), keyEquivalent: "")
            shelf.target = self
            shelf.image = Icons.symbol("tray.full")
            menu.addItem(shelf)
        }

        menu.addItem(.separator())
        let pause = NSMenuItem(title: Settings.shared.paused ? "Resume Grab" : "Pause Grab", action: #selector(AppDelegate.togglePause), keyEquivalent: "p")
        pause.target = app
        pause.image = Icons.symbol(Settings.shared.paused ? "play.fill" : "pause.fill")
        menu.addItem(pause)

        if let front = lastForeignApp, let bid = front.bundleIdentifier, let name = front.localizedName {
            let off = Settings.shared.excludedApps.contains(bid)
            let mi = NSMenuItem(title: off ? "Enable in \(name)" : "Disable in \(name)", action: #selector(toggleExcluded(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = bid
            mi.image = front.icon.map { icon in
                let i = icon.copy() as! NSImage
                i.size = NSSize(width: 16, height: 16)
                return i
            }
            menu.addItem(mi)

            // "In Figma, prefer Color": a per-app default for the grab type.
            let rules = NSMenuItem(title: "In \(name), Prefer", action: nil, keyEquivalent: "")
            rules.image = Icons.symbol("slider.horizontal.3")
            let sub = NSMenu()
            let current = Settings.shared.appRules[bid]
            let auto = NSMenuItem(title: "Automatic", action: #selector(setRule(_:)), keyEquivalent: "")
            auto.target = self
            auto.representedObject = [bid, -1] as [Any]
            auto.state = current == nil ? .on : .off
            sub.addItem(auto)
            sub.addItem(.separator())
            for m in GrabMode.allCases {
                let r = NSMenuItem(title: m.title, action: #selector(setRule(_:)), keyEquivalent: "")
                r.target = self
                r.representedObject = [bid, m.rawValue] as [Any]
                r.image = Icons.symbol(m.symbol)
                r.state = current == m.rawValue ? .on : .off
                sub.addItem(r)
            }
            rules.submenu = sub
            menu.addItem(rules)
        }

        if !Permissions.shared.accessibility || !Permissions.shared.screenRecording {
            let setup = NSMenuItem(title: "Finish Setup…", action: #selector(AppDelegate.openOnboarding), keyEquivalent: "")
            setup.target = app
            setup.image = Icons.symbol("exclamationmark.triangle.fill")
            menu.addItem(setup)
        }

        let welcome = NSMenuItem(title: "Welcome & Playground…", action: #selector(AppDelegate.openOnboarding), keyEquivalent: "")
        welcome.target = app
        welcome.image = Icons.symbol("sparkles")
        menu.addItem(welcome)

        if let update = Updater.shared.available {
            let u = NSMenuItem(title: "Update to Grab \(update.version)…", action: #selector(showUpdate), keyEquivalent: "")
            u.target = self
            u.image = Icons.symbol("arrow.down.circle.fill")
            menu.addItem(u)
        }

        let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settings.target = app
        settings.image = Icons.symbol("gearshape")
        menu.addItem(settings)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
        updates.target = app
        updates.image = Icons.symbol("arrow.triangle.2.circlepath")
        menu.addItem(updates)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Grab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func showUpdate() {
        Panels.shared.showUpdate()
    }

    private func historyItem(_ h: History.Item, key: String, showApp: Bool = true) -> NSMenuItem {
        var title = h.isSecret ? "Secret ••••••" : Formats.oneLine(h.text ?? h.title).truncated(48)
        if let t = h.text, t.uppercased().hasPrefix("WIFI:") { title = "Wi-Fi “\(Formats.wifi(t).network ?? "network")”" }
        if case .file(let u) = h.payload { title = u.lastPathComponent }
        let mi = NSMenuItem(title: title, action: #selector(recopy(_:)), keyEquivalent: key)
        mi.keyEquivalentModifierMask = []
        mi.target = self
        mi.representedObject = h.id
        mi.image = image(for: h)
        if #available(macOS 14.4, *) {
            let when = Date().timeIntervalSince(h.date) < 60 ? "just now" : Self.relative.localizedString(for: h.date, relativeTo: Date())
            mi.subtitle = ([h.mode.title] + (showApp ? [h.appName].compactMap { $0 } : []) + [when])
                .joined(separator: " · ")
        }
        return mi
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func image(for h: History.Item) -> NSImage? {
        if let c = h.color { return Icons.swatch(c) }
        if let t = h.thumbnail {
            return NSImage(size: NSSize(width: 18, height: 16), flipped: false) { r in
                let s = t.size
                let k = min(r.width / max(s.width, 1), r.height / max(s.height, 1))
                let d = NSRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
                NSBezierPath(roundedRect: d, xRadius: 2.5, yRadius: 2.5).addClip()
                t.draw(in: d)
                return true
            }
        }
        return Icons.symbol(h.mode.symbol)
    }

    @objc private func recopy(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let h = History.shared.items.first(where: { $0.id == id }) else { return }
        Clipboard.write(h.payload, secret: h.isSecret)
        Sound.shared.play(.copy)
    }

    @objc private func clearHistory() {
        History.shared.clear()
    }

    @objc private func showHistory() {
        Panels.shared.showHistory()
    }

    @objc private func showShelf() {
        Panels.shared.showShelf()
    }

    @objc private func setRule(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any], let bid = info.first as? String, let raw = info.last as? Int else { return }
        var rules = Settings.shared.appRules
        rules[bid] = raw < 0 ? nil : raw
        Settings.shared.appRules = rules
    }

    @objc private func toggleExcluded(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        var list = Settings.shared.excludedApps
        if let i = list.firstIndex(of: bid) { list.remove(at: i) } else { list.append(bid) }
        Settings.shared.excludedApps = list
    }

    /// The app the user was in before opening our menu.
    private var lastForeignApp: NSRunningApplication? {
        let me = Bundle.main.bundleIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.bundleIdentifier != me { return f }
        return previousApp
    }

    private var previousApp: NSRunningApplication?

    func trackFrontmost() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier { self?.previousApp = app }
            }
        }
    }
}

private struct MenuHeader: View {
    var body: some View {
        let p = Permissions.shared
        let s = Settings.shared
        let (color, text): (Color, String) = {
            if !p.accessibility { return (.orange, "Needs Accessibility access") }
            if s.paused { return (.gray, "Paused") }
            if !p.screenRecording { return (.yellow, "Text & links only (no Screen Recording)") }
            return (.green, "Ready. Hold \(s.trigger.symbol) and hover")
        }()
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grab").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                TriggerKeys(size: 8.5)
                KeyView(key: "C", size: 8.5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
