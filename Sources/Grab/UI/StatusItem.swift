import AppKit
import SwiftUI

/// The menu bar icon and its panel: status, recent grabs, and a few actions.
///
/// A custom panel rather than an NSMenu, so it can show real thumbnails, keep to a few
/// calm rows and draw a quiet selection instead of the system's full-width blue bar.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let app: AppDelegate
    private var celebrateWork: [DispatchWorkItem] = []
    private var panel: MenuPanel?
    private var closedAt = Date.distantPast
    private var keyMonitor: Any?

    init(app: AppDelegate) {
        self.app = app
        super.init()
        item.button?.image = Icons.statusIcon()
        item.button?.toolTip = "Grab — hold \(Trigger.current.symbol) and hover anything"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    /// Lights the icon up as the grab lands.
    func celebrate(at landing: TimeInterval = 0.58) {
        celebrateWork.forEach { $0.cancel() }
        let on = DispatchWorkItem { [weak self] in self?.item.button?.image = Icons.statusIcon(filled: true) }
        let off = DispatchWorkItem { [weak self] in self?.item.button?.image = Icons.statusIcon() }
        celebrateWork = [on, off]
        DispatchQueue.main.asyncAfter(deadline: .now() + landing, execute: on)
        DispatchQueue.main.asyncAfter(deadline: .now() + landing + 0.67, execute: off)
    }

    // MARK: Panel

    func openMenu() {
        if panel == nil { show() }
    }

    func closeMenu() {
        hide()
    }

    @objc private func toggle() {
        if panel != nil {
            hide()
            return
        }
        // The click that closed the panel (by taking focus away) shouldn't reopen it.
        guard Date().timeIntervalSince(closedAt) > 0.25 else { return }
        show()
    }

    private func show() {
        History.shared.ensureLoaded()
        guard let button = item.button, let bw = button.window else { return }
        let anchor = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let front = lastForeignApp
        let view = MenuPanelView(
            frontApp: front.flatMap { a in a.bundleIdentifier.map { (a.localizedName ?? $0, $0) } },
            actions: MenuPanelView.Actions(
                copy: { [weak self] h in self?.recopy(h) },
                close: { [weak self] in self?.hide() },
                history: { [weak self] in self?.hide(); Panels.shared.showHistory() },
                shelf: { [weak self] in self?.hide(); Panels.shared.showShelf() },
                settings: { [weak self] in self?.hide(); self?.app.openSettings() },
                welcome: { [weak self] in self?.hide(); self?.app.openOnboarding() },
                updates: { [weak self] in self?.hide(); self?.app.checkForUpdates() },
                showUpdate: { [weak self] in self?.hide(); Panels.shared.showUpdate() },
                pause: { Settings.shared.paused.toggle() },
                toggleApp: { bid in
                    var list = Settings.shared.excludedApps
                    if let i = list.firstIndex(of: bid) { list.remove(at: i) } else { list.append(bid) }
                    Settings.shared.excludedApps = list
                },
                prefer: { bid, mode in
                    var rules = Settings.shared.appRules
                    rules[bid] = mode?.rawValue
                    Settings.shared.appRules = rules
                },
                quit: { NSApp.terminate(nil) }
            )
        )
        let p = MenuPanel(content: view)
        p.delegate = self
        let size = p.contentView?.fittingSize ?? NSSize(width: 340, height: 420)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.minX - 8
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - 6 - size.height
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
        panel = p
        button.highlight(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let p = self.panel, e.window === p else { return e }
            return p.handle(e) ? nil : e
        }
    }

    private func hide() {
        guard let p = panel else { return }
        panel = nil
        closedAt = Date()
        item.button?.highlight(false)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        p.delegate = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { p.orderOut(nil) }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func recopy(_ h: History.Item) {
        Clipboard.write(h.payload, secret: h.isSecret)
        Sound.shared.play(.copy)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.hide() }
    }

    /// The app the user was in before opening our panel.
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

/// A borderless panel that takes keys without activating Grab, like a menu.
final class MenuPanel: NSPanel {
    let model = MenuPanelModel()

    init<V: View>(content: V) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: content.environment(model))
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// Keyboard: ↑ ↓ to move, ⏎ to copy, 1–5 to copy directly, ⌘F history, ⌘, settings, esc closes.
    func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch (e.keyCode, cmd) {
        case (53, _): model.send(.close)
        case (125, false): model.send(.move(1))
        case (126, false): model.send(.move(-1))
        case (36, false), (76, false): model.send(.activate)
        default:
            guard let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
            if cmd {
                switch ch {
                case "f": model.send(.history)
                case ",": model.send(.settings)
                case "p": model.send(.pause)
                case "q": model.send(.quit)
                default: return false
                }
            } else if let n = Int(ch), (1...MenuPanelView.recentCount).contains(n) {
                model.send(.copyIndex(n - 1))
            } else {
                return false
            }
        }
        return true
    }
}

/// Keyboard events from the panel to its SwiftUI content.
@Observable
final class MenuPanelModel {
    enum Command: Equatable { case close, move(Int), activate, copyIndex(Int), history, settings, pause, quit }
    var command: (id: Int, value: Command)?
    func send(_ c: Command) { command = ((command?.id ?? 0) + 1, c) }
}

struct MenuPanelView: View {
    static let recentCount = 5

    struct Actions {
        var copy: (History.Item) -> Void
        var close: () -> Void
        var history: () -> Void
        var shelf: () -> Void
        var settings: () -> Void
        var welcome: () -> Void
        var updates: () -> Void
        var showUpdate: () -> Void
        var pause: () -> Void
        var toggleApp: (String) -> Void
        var prefer: (String, GrabMode?) -> Void
        var quit: () -> Void
    }

    let frontApp: (name: String, bundleID: String)?
    let actions: Actions

    @Environment(MenuPanelModel.self) private var model
    @State private var history = History.shared
    @State private var settings = Settings.shared
    @State private var selected: Int?
    @State private var copied: UUID?

    private var recent: [History.Item] { Array(history.items.prefix(Self.recentCount)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let update = Updater.shared.available { updateBanner(update) }
            divider
            recentSection
            divider
            footer
        }
        .padding(6)
        .frame(width: 340)
        .background(HUDBackground(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
        .onChange(of: model.command?.id) { _, _ in
            guard let c = model.command?.value else { return }
            handle(c)
        }
    }

    // MARK: Header

    private var header: some View {
        let p = Permissions.shared
        let (color, text): (Color, String) = {
            if !p.accessibility { return (.orange, "Needs Accessibility access") }
            if settings.paused { return (.secondary, "Paused") }
            if !p.screenRecording { return (.yellow, "Text and links only") }
            return (.green, "Ready")
        }()
        return HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grab").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if !p.accessibility || !p.screenRecording {
                Button("Finish Setup", action: actions.welcome)
                    .buttonStyle(PillButtonStyle(prominent: true))
            } else {
                HStack(spacing: 3) {
                    TriggerKeys(size: 9)
                    KeyView(key: "C", size: 9)
                }
                .opacity(0.85)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func updateBanner(_ u: Updater.Release) -> some View {
        Button(action: actions.showUpdate) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Grab \(u.version) is ready").fontWeight(.semibold)
                Spacer()
                Text("Update").fontWeight(.semibold)
            }
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: Theme.brand, startPoint: .leading, endPoint: .trailing)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 8)
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !history.items.isEmpty {
                    Button(action: actions.history) {
                        HStack(spacing: 4) {
                            Text("All History")
                            Text("⌘F").foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 4)

            if recent.isEmpty {
                HStack(spacing: 10) {
                    MascotIdle(kind: MascotKind(rawValue: settings.mascot) ?? .snap).frame(width: 44, height: 40).scaleEffect(0.75)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing grabbed yet").font(.system(size: 12.5, weight: .medium))
                        Text("Hold \(settings.trigger.symbol) over anything and press C").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            } else {
                ForEach(Array(recent.enumerated()), id: \.element.id) { i, h in
                    RecentRow(item: h, number: i + 1, selected: selected == i, copied: copied == h.id)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { selected = i } else if selected == i { selected = nil }
                        }
                        .onTapGesture { copy(h) }
                }
            }
            if !Shelf.shared.items.isEmpty {
                Button(action: actions.shelf) {
                    Label("Shelf · \(Shelf.shared.items.count) items", systemImage: "tray.full")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button(action: actions.pause) {
                Label(settings.paused ? "Resume" : "Pause", systemImage: settings.paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(PillButtonStyle())
            .help(settings.paused ? "Resume Grab (⌘P)" : "Pause Grab (⌘P)")
            Button(action: actions.settings) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(PillButtonStyle())
            .help("Settings (⌘,)")
            Spacer(minLength: 0)
            Menu {
                if let app = frontApp {
                    let off = settings.excludedApps.contains(app.bundleID)
                    Section(app.name) {
                        Button(off ? "Turn Grab On in \(app.name)" : "Turn Grab Off in \(app.name)") { actions.toggleApp(app.bundleID) }
                        Picker("Preferred Type", selection: Binding(
                            get: { settings.appRules[app.bundleID] ?? -1 },
                            set: { actions.prefer(app.bundleID, $0 < 0 ? nil : GrabMode(rawValue: $0)) }
                        )) {
                            Text("Automatic").tag(-1)
                            ForEach(GrabMode.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    }
                }
                Section {
                    Button("Welcome & Practice…", action: actions.welcome)
                    Button("Check for Updates…", action: actions.updates)
                }
                Section {
                    Button("Quit Grab", action: actions.quit)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Actions

    private func copy(_ h: History.Item) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { copied = h.id }
        actions.copy(h)
    }

    private func handle(_ c: MenuPanelModel.Command) {
        switch c {
        case .close: actions.close()
        case .move(let d):
            guard !recent.isEmpty else { return }
            let n = (selected ?? (d > 0 ? -1 : recent.count)) + d
            selected = min(max(n, 0), recent.count - 1)
        case .activate:
            if let i = selected, recent.indices.contains(i) { copy(recent[i]) }
        case .copyIndex(let i):
            if recent.indices.contains(i) { copy(recent[i]) }
        case .history: actions.history()
        case .settings: actions.settings()
        case .pause: actions.pause()
        case .quit: actions.quit()
        }
    }
}

/// One recent grab: a small preview tile, what it is, where it came from.
private struct RecentRow: View {
    let item: History.Item
    let number: Int
    let selected: Bool
    let copied: Bool

    var body: some View {
        HStack(spacing: 11) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if copied {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(selected ? 0.1 : 0.05)))
                    .opacity(selected ? 1 : 0.6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : 0))
        )
        .padding(.horizontal, 2)
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private var title: String {
        if item.isSecret { return "Secret ••••••" }
        if let t = item.text, t.uppercased().hasPrefix("WIFI:") { return "Wi-Fi “\(Formats.wifi(t).network ?? "network")”" }
        if case .file(let u) = item.payload { return u.lastPathComponent }
        return Formats.oneLine(item.text ?? item.title).truncated(80)
    }

    private var subtitle: String {
        var parts: [String] = [item.mode.title]
        if let a = item.appName { parts.append(a) }
        parts.append(Self.when(item.date))
        return parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func when(_ d: Date) -> String {
        Date().timeIntervalSince(d) < 60 ? "just now" : relative.localizedString(for: d, relativeTo: Date())
    }

    @ViewBuilder private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let c = item.color {
                shape.fill(Color(nsColor: c.nsColor))
            } else if let t = item.thumbnail {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
            } else if case .file(let u) = item.payload {
                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().padding(2)
            } else {
                ZStack {
                    shape.fill(LinearGradient(colors: Theme.colors(for: item.mode).map { $0.opacity(0.22) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: Theme.colors(for: item.mode), startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.08 : 0))))
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Small rounded buttons for the footer.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary.opacity(0.85)))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(prominent
                    ? AnyShapeStyle(LinearGradient(colors: Theme.brand, startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.1 : 0.06))))
            )
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}
