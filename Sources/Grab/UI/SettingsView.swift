import AppKit
import SwiftUI

struct SettingsView: View {
    var openOnboarding: () -> Void

    @Bindable private var settings = Settings.shared
    @State private var permissions = Permissions.shared
    @State private var history = History.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var spotlightFiles = UserDefaults.standard.object(forKey: "spotlightFiles") as? Bool ?? true

    private let sample = RGBAColor(r: 237 / 255, g: 110 / 255, b: 42 / 255)

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Grab").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        KeyView(key: "⌥", size: 11)
                        Text("+").foregroundStyle(.tertiary)
                        KeyView(key: "C", size: 11)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent {
                    HStack {
                        Slider(value: $settings.armDelay, in: 0.05...0.6)
                            .frame(width: 180)
                        Text("\(Int(settings.armDelay * 1000)) ms")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .trailing)
                    }
                } label: {
                    Text("Overlay delay")
                    Text("How long to hold ⌥ before the border appears.")
                }
                Toggle(isOn: $settings.quickCopy) {
                    Text("Instant ⌥C")
                    Text("⌥C grabs even before the overlay shows. Turn off if you type ç with ⌥C.")
                }
                Toggle("Pause Grab", isOn: $settings.paused)
            } header: {
                Text("Activation")
            }

            Section {
                Toggle("Sounds", isOn: $settings.soundEnabled)
                if settings.soundEnabled {
                    LabeledContent("Volume") {
                        HStack {
                            Image(systemName: "speaker.fill").foregroundStyle(.tertiary)
                            Slider(value: $settings.soundVolume, in: 0...1) { editing in
                                if !editing { Sound.shared.play(.copy) }
                            }
                            .frame(width: 160)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.tertiary)
                        }
                    }
                }
                Toggle(isOn: $settings.hapticsEnabled) {
                    Text("Haptic feedback")
                    Text("A tap on Force Touch trackpads as you switch and copy.")
                }
                if settings.hapticsEnabled {
                    Toggle(isOn: $settings.snapHaptics) {
                        Text("Tick when the border snaps")
                        Text("A light tap each time Grab lands on something new as you move.")
                    }
                }
                Toggle(isOn: $settings.spotlight) {
                    Text("Spotlight")
                    Text("Gently dims everything except what you're about to grab.")
                }
                MascotPicker(selection: $settings.mascot)
                Toggle("Keyboard hints in the HUD", isOn: $settings.showHints)
                Toggle(isOn: $settings.overlayInRecordings) {
                    Text("Show overlay in screen recordings")
                    Text("Off keeps Grab's border out of every capture. Turn on to record a demo; colors may then read slightly off on HDR-capable displays.")
                }
            } header: {
                Text("Feel")
            }

            Section {
                if settings.excludedApps.isEmpty {
                    Text("Grab works everywhere. Add apps where holding ⌥ already means something, like Figma's measurements.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.excludedApps, id: \.self) { bid in
                    HStack(spacing: 8) {
                        Image(nsImage: AppInfo.icon(bid))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(AppInfo.name(bid))
                        Spacer()
                        Button {
                            settings.excludedApps.removeAll { $0 == bid }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Menu("Add App…") {
                    ForEach(AppInfo.runningApps().filter { !settings.excludedApps.contains($0.id) }) { app in
                        Button {
                            settings.excludedApps.append(app.id)
                        } label: {
                            Label {
                                Text(app.name)
                            } icon: {
                                Image(nsImage: app.icon)
                            }
                        }
                    }
                }
                .fixedSize()
            } header: {
                Text("Disabled in")
            }

            Section {
                LabeledContent {
                    HStack(spacing: 4) { KeyView(key: "⌥", size: 10); KeyView(key: "⇥", size: 10) }
                } label: {
                    Text("Switch format")
                    Text("Code · Markdown · file:line · GitHub link. Dates as ISO/Unix/calendar events, prices converted, JSON pretty, tables as CSV/JSON, images as subject or palette… Grab remembers your choice per kind.")
                }
                LabeledContent {
                    HStack(spacing: 4) { KeyView(key: "⌥", size: 10); KeyView(key: "⇧", size: 10); KeyView(key: "C", size: 10) }
                } label: {
                    Text("Collect on the shelf")
                    Text("Adds to a floating shelf you can reorder; the clipboard always holds the whole shelf.")
                }
                Toggle(isOn: $settings.adaptivePaste) {
                    Text("Adapt code to where you paste")
                    Text("Pasting into a terminal drops the $ prompts; Slack, Discord, Notion and Obsidian get a code block.")
                }
                Toggle(isOn: $spotlightFiles) {
                    Text("Find open files with Spotlight")
                    Text("For editors that don't say which file is open (like Cursor's agent window), Grab looks up the file name shown in the tab so it can copy the exact code.")
                }
                .onChange(of: spotlightFiles) { _, on in UserDefaults.standard.set(on, forKey: "spotlightFiles") }
            } header: {
                Text("Code & formats")
            }

            Section {
                Picker("Search with", selection: $settings.searchEngine) {
                    Text("Google").tag("google")
                    Text("DuckDuckGo").tag("duckduckgo")
                    Text("Bing").tag("bing")
                    Text("Kagi").tag("kagi")
                    Text("Perplexity").tag("perplexity")
                    Text("Ecosia").tag("ecosia")
                }
                Toggle(isOn: $settings.currencyConversion) {
                    Text("Convert prices to \(Locale.current.currency?.identifier ?? "your currency")")
                    Text("Uses the European Central Bank's daily rates. Only currency codes are fetched; nothing you grab leaves your Mac.")
                }
                ActionKeysGrid()
                LabeledContent {
                    if let why = Assistant.unavailableReason {
                        Text(why).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    } else {
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                    }
                } label: {
                    Text("On-device AI")
                    Text("⌥E explains, summarizes, fixes OCR text or turns it into JSON with Apple Intelligence, on your Mac.")
                }
            } header: {
                Text("Actions")
            }

            Section {
                if settings.appRules.isEmpty {
                    Text("Grab picks the type for you. Set a favorite per app, like Color in Figma or Link in Safari, here or from the menu bar.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.appRules.keys.sorted(), id: \.self) { bid in
                    HStack(spacing: 8) {
                        Image(nsImage: AppInfo.icon(bid)).resizable().frame(width: 18, height: 18)
                        Text(AppInfo.name(bid))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.appRules[bid] ?? 0 },
                            set: { settings.appRules[bid] = $0 }
                        )) {
                            ForEach(GrabMode.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            settings.appRules[bid] = nil
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Menu("Add App…") {
                    ForEach(AppInfo.runningApps().filter { settings.appRules[$0.id] == nil }) { app in
                        Button {
                            settings.appRules[app.id] = GrabMode.text.rawValue
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        }
                    }
                }
                .fixedSize()
            } header: {
                Text("Preferred type per app")
            }

            Section {
                Toggle(isOn: $settings.protectSecrets) {
                    Text("Protect secrets")
                    Text("API keys, tokens, private keys and Wi-Fi passwords are hidden from clipboard managers, kept out of history and cleared after a minute.")
                }
            } header: {
                Text("Privacy")
            }

            Section {
                Picker("Copy colors as", selection: $settings.colorFormat) {
                    ForEach(ColorFormat.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Example") {
                    HStack(spacing: 8) {
                        Text(sample.formatted(settings.colorFormat))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: sample.nsColor)).frame(width: 18, height: 18)
                    }
                }
            } header: {
                Text("Colors")
            }

            Section {
                Stepper("Keep the last \(settings.historyLimit) grabs", value: $settings.historyLimit, in: 1...200)
                Button("Search History…") { Panels.shared.showHistory() }
                HStack {
                    Text("History lives in memory only and is never written to disk.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { history.clear() }
                        .disabled(history.items.isEmpty)
                }
            } header: {
                Text("History")
            }

            Section {
                PermissionRow(
                    reason: .accessibility,
                    granted: permissions.accessibility,
                    action: { permissions.requestAccessibility() }
                )
                PermissionRow(
                    reason: .screenRecording,
                    granted: permissions.screenRecording,
                    actionTitle: permissions.screenRecordingNeedsRelaunch ? "Relaunch" : "Grant",
                    action: {
                        if permissions.screenRecordingNeedsRelaunch { Permissions.relaunch() } else { permissions.requestScreenRecording() }
                    }
                )
                OtherAccessNote().padding(.vertical, 2)
            } header: {
                Text("Permissions")
            } footer: {
                Text("You can change these any time in System Settings → Privacy & Security.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
                HStack {
                    Button("Welcome & Playground…", action: openOnboarding)
                    Spacer()
                    Button("Quit Grab") { NSApp.terminate(nil) }
                }
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 700)
    }
}

private struct PermissionRow: View {
    let reason: PermissionReason
    let granted: Bool
    var actionTitle = "Grant"
    let action: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Button(actionTitle, action: action)
                }
            } label: {
                Text(reason.title)
                Text(reason.summary)
            }
            DisclosureGroup(isExpanded: $expanded) {
                PermissionExplainer(reason: reason).padding(.top, 6).padding(.leading, 2)
            } label: {
                Text("What it's for and what Grab never does").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

enum AppInfo {
    struct App: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
    }

    static func runningApps() -> [App] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> App? in
                guard let id = app.bundleIdentifier, id != me, seen.insert(id).inserted else { return nil }
                let icon = (app.icon?.copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 16, height: 16)
                return App(id: id, name: app.localizedName ?? id, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func name(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

/// The keys that act on what's under the cursor while ⌥ is held.
private struct ActionKeysGrid: View {
    private let rows: [(String, String)] = [
        ("⏎", "Open: links, files, maps for addresses, calendar for dates, search for text"),
        ("␣", "Quick Look the file, image or text"),
        ("P", "Pin it on screen in a floating window"),
        ("S", "Speak it aloud (S again stops)"),
        ("T", "Translate it"),
        ("E", "Ask on-device AI about it"),
        ("Z", "Undo the last grab and restore the clipboard"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("While holding ⌥").font(.system(size: 12, weight: .medium))
            ForEach(rows, id: \.0) { key, text in
                HStack(spacing: 8) {
                    KeyView(key: key, size: 10).frame(width: 24)
                    Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Who carries each grab to the menu bar. Picking one makes it show off.
private struct MascotPicker: View {
    @Binding var selection: String

    var body: some View {
        let current = MascotKind(rawValue: selection) ?? .snap
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mascot")
                Text("Who carries each grab up to the menu bar. Click one to see it in action.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(MascotKind.allCases) { kind in
                    let on = kind == current
                    Button {
                        selection = kind.rawValue
                        if kind != .off { NotificationCenter.default.post(name: .grabMascotPreview, object: nil) }
                    } label: {
                        VStack(spacing: 6) {
                            MascotIdle(kind: kind).frame(height: 58)
                            Text(kind.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(on ? 0.07 : 0.025)))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(on ? AnyShapeStyle(LinearGradient(colors: Theme.brand, startPoint: .topLeading, endPoint: .bottomTrailing))
                                                 : AnyShapeStyle(Color.primary.opacity(0.08)), lineWidth: on ? 2 : 1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(kind.blurb)
                }
            }
            Text(current.blurb).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
