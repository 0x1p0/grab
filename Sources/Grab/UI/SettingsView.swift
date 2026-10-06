import AppKit
import SwiftUI

/// Grab's settings: a sidebar of panes, each with a few cards of settings.
struct SettingsView: View {
    var openOnboarding: () -> Void
    @State private var nav = SettingsNav.shared

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $nav.pane)
                .background(SidebarMaterial().ignoresSafeArea())
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PaneHeader(pane: nav.pane)
                    pane
                }
                .padding(.horizontal, 30)
                .padding(.top, 40)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(nav.pane)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Theme.accent)
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    @ViewBuilder private var pane: some View {
        switch nav.pane {
        case .general: GeneralPane(openOnboarding: openOnboarding)
        case .feel: FeelPane()
        case .mascot: MascotPane()
        case .formats: FormatsPane()
        case .actions: ActionsPane()
        case .apps: AppsPane()
        case .history: HistoryPane()
        case .privacy: PrivacyPane()
        case .achievements: AchievementsPane()
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    var openOnboarding: () -> Void
    @Bindable private var settings = Settings.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Who we are, and the one thing to remember.
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grab").font(.system(size: 20, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Text("Hold").foregroundStyle(.secondary)
                        TriggerKeys(size: 10)
                        Text("point, press").foregroundStyle(.secondary)
                        KeyView(key: "C", size: 10)
                    }
                    .font(.system(size: 12))
                }
                Spacer()
                Button("Welcome & Playground…", action: openOnboarding)
                    .controlSize(.regular)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))

            SettingsCard(title: "Appearance") {
                HStack(spacing: 14) {
                    ForEach(AppAppearance.allCases) { a in
                        AppearanceTile(appearance: a, selected: settings.appearance == a) { settings.appearance = a }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }

            SettingsCard(title: "Grabbing") {
                TriggerPicker(selection: $settings.trigger)
                RowDivider()
                SettingRow(title: "Overlay delay", detail: "How long to hold \(settings.trigger.symbol) before the border appears.") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.armDelay, in: 0.05...0.6).frame(width: 150).controlSize(.small)
                        Text("\(Int(settings.armDelay * 1000)) ms")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                RowDivider()
                ToggleRow(title: "Instant \(settings.trigger.chord("C"))",
                          detail: "Grabs even before the border shows. Turn off if you type ç with ⌥C.", isOn: $settings.quickCopy)
                RowDivider()
                ToggleRow(title: "Pause Grab", detail: "Holding \(settings.trigger.symbol) does nothing until you turn this off.", isOn: $settings.paused)
            }

            SettingsCard(title: "Startup & updates") {
                ToggleRow(title: "Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
                RowDivider()
                ToggleRow(title: "Check for updates automatically",
                          detail: "About once a day Grab asks GitHub for the latest release. Nothing about you is sent, and nothing installs without your OK.",
                          isOn: $settings.checkForUpdates)
                RowDivider()
                SettingRow(title: updater.available.map { "Grab \($0.version) is available" } ?? "Updates") {
                    Button(updater.available == nil ? "Check Now" : "Update…") {
                        if updater.available != nil { Panels.shared.showUpdate() } else { Task { await Updater.shared.check(userInitiated: true) } }
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("Quit Grab") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
    }
}

/// A little window in each look, like the Appearance choice in System Settings.
private struct AppearanceTile: View {
    let appearance: AppAppearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview
                    .frame(width: 92, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2.5))
                Text(appearance.title).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var preview: some View {
        switch appearance {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true).mask(HalfMask())
            }
        }
    }

    /// The right half, cut on a slant.
    struct HalfMask: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX + 10, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.midX - 10, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }

    struct MiniWindow: View {
        let dark: Bool
        var body: some View {
            let bg = dark ? Color(hex: 0x1E1E22) : Color(hex: 0xF4F4F7)
            let side = dark ? Color(hex: 0x2B2B31) : Color(hex: 0xE4E4EA)
            let card = dark ? Color(hex: 0x34343B) : Color.white
            let line = dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2.5) {
                        ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { c in Circle().fill(Color(hex: UInt32(c))).frame(width: 4, height: 4) }
                    }
                    .padding(.bottom, 3)
                    ForEach(0..<4, id: \.self) { i in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 1.5).fill(i == 0 ? Theme.accent : line).frame(width: 6, height: 6)
                            Capsule().fill(line).frame(width: 12, height: 3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(width: 34, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(side)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(line).frame(width: 26, height: 4).padding(.bottom, 2)
                    RoundedRectangle(cornerRadius: 3).fill(card).frame(height: 14)
                        .overlay(alignment: .trailing) { Capsule().fill(Theme.accent).frame(width: 9, height: 5).padding(.trailing, 4) }
                    RoundedRectangle(cornerRadius: 3).fill(card).frame(height: 14)
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(bg)
            }
        }
    }
}

/// "Hold to grab": which modifier starts a grab, with a nudge for keyboards that type
/// everyday characters with ⌥.
private struct TriggerPicker: View {
    @Binding var selection: Trigger
    @State private var optionChars = KeyLayout.optionOnlyCharacters()

    var body: some View {
        SettingRow(title: "Hold to grab", detail: selection.detail) {
            Picker("", selection: $selection) {
                ForEach(Trigger.allCases) { t in Text("\(t.title)   \(t.symbol)").tag(t) }
            }
            .labelsHidden()
            .fixedSize()
        }
        if selection == .option, !optionChars.isEmpty {
            LayoutTip(characters: optionChars) { selection = .rightOption }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
    }
}

/// Shown when the keyboard layout types @ [ ] { } with ⌥.
struct LayoutTip: View {
    let characters: [Character]
    let useRightOption: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your keyboard types \(characters.map(String.init).joined(separator: " ")) with ⌥")
                    .font(.system(size: 12, weight: .semibold))
                Text("Grab with right ⌥ and keep left ⌥ for typing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Use Right ⌥", action: useRightOption)
                .controlSize(.small)
        }
    }
}

// MARK: - Feel

private struct FeelPane: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "Sound") {
                ToggleRow(title: "Sounds", detail: "A bright little chime when something's copied, and a few more for the mascot.", isOn: $settings.soundEnabled)
                if settings.soundEnabled {
                    RowDivider()
                    SettingRow(title: "Volume") {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Slider(value: $settings.soundVolume, in: 0...1) { editing in
                                if !editing { Sound.shared.play(.copy) }
                            }
                            .frame(width: 150)
                            .controlSize(.small)
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                RowDivider()
                ToggleRow(title: "Combos", detail: "Grabs within 5 seconds of each other ring a step higher; every fifth gets confetti.", isOn: $settings.combos)
            }

            SettingsCard(title: "Touch") {
                ToggleRow(title: "Haptic feedback", detail: "A tap on Force Touch trackpads as you switch, copy and as each grab lands.", isOn: $settings.hapticsEnabled)
                if settings.hapticsEnabled {
                    RowDivider()
                    ToggleRow(title: "Tick when the border snaps", detail: "A light tap each time Grab lands on something new.", isOn: $settings.snapHaptics)
                }
            }

            SettingsCard(title: "On screen") {
                ToggleRow(title: "Spotlight", detail: "Gently dims everything except what you're about to grab.", isOn: $settings.spotlight)
                RowDivider()
                ToggleRow(title: "Keyboard hints", detail: "Shows the keys you can press next to the border.", isOn: $settings.showHints)
                RowDivider()
                ToggleRow(title: "Show when sharing your screen",
                          detail: "People watching a screen share or recording see the border, the HUD and the mascot. Grab's own captures leave them out either way.",
                          isOn: $settings.overlayInRecordings)
            }
        }
    }
}

// MARK: - Mascot

private struct MascotPane: View {
    @Bindable private var settings = Settings.shared
    @State private var stats = Stats.shared

    private var current: MascotKind { MascotKind(rawValue: settings.mascot) ?? .snap }
    private var hasMascot: Bool { current != .off && current != .classic }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // The stage: the chosen one, big, and the others to pick from.
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0x231A3A), Color(hex: 0x3A1F4D), Color(hex: 0x5A2448)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    RadialGradient(colors: [Color(hex: 0xFF8A3D).opacity(0.45), .clear], center: UnitPoint(x: 0.18, y: 0.3), startRadius: 0, endRadius: 170)
                    RadialGradient(colors: [Color(hex: 0x7C5CFF).opacity(0.5), .clear], center: UnitPoint(x: 0.85, y: 0.8), startRadius: 0, endRadius: 200)
                    HStack(spacing: 22) {
                        MascotIdle(kind: current, mood: Buddy.shared.mood() == .away ? .normal : Buddy.shared.mood())
                            .frame(width: 110, height: 100)
                            .scaleEffect(1.7)
                            .environment(\.colorScheme, .dark)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(current.title).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            Text(current.blurb).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                            if current != .off {
                                Button {
                                    NotificationCenter.default.post(name: .grabMascotPreview, object: nil)
                                } label: {
                                    Label("Show me", systemImage: "play.fill").font(.system(size: 11.5, weight: .semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 5)
                                        .background(Capsule().fill(.white.opacity(0.16)))
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 4)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 26)
                }
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 8) {
                    ForEach(MascotKind.allCases) { kind in
                        let on = kind == current
                        Button {
                            settings.mascot = kind.rawValue
                            if kind != .off { NotificationCenter.default.post(name: .grabMascotPreview, object: nil) }
                        } label: {
                            VStack(spacing: 4) {
                                MascotIdle(kind: kind, animated: on).frame(width: 56, height: 46).scaleEffect(0.8)
                                Text(kind.title).font(.system(size: 11, weight: on ? .semibold : .medium))
                                    .foregroundStyle(on ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(on ? 0.07 : 0.03)))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(on ? AnyShapeStyle(LinearGradient(colors: Theme.brand, startPoint: .topLeading, endPoint: .bottomTrailing))
                                                     : AnyShapeStyle(Color.primary.opacity(0.06)), lineWidth: on ? 1.5 : 0.5)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(kind.blurb)
                    }
                }
            }

            if hasMascot {
                SettingsCard(title: "Where it lives") {
                    if NSScreen.screens.contains(where: { Notch.rect(on: $0) != nil }) {
                        ToggleRow(title: "Catch grabs in the notch",
                                  detail: "The notch opens up, \(current.title) pops out, and your grab disappears inside.", isOn: $settings.notchCatch)
                        RowDivider()
                    }
                    ToggleRow(title: "Peek while you hold \(settings.trigger.symbol)",
                              detail: "Looks out from under the menu bar for a few seconds. Point at it and press C to pet it, gently.", isOn: $settings.mascotPeek)
                }

                SettingsCard(title: "Wardrobe", footer: "A nightcap goes on by itself after midnight.") {
                    SettingRow(title: "Sunglasses", detail: stats.total >= Buddy.shadesAt ? "Earned" : "At \(Buddy.shadesAt) grabs · \(Buddy.shadesAt - stats.total) to go") {
                        unlock(stats.total >= Buddy.shadesAt)
                    }
                    RowDivider()
                    SettingRow(title: "Crown", detail: stats.total >= Buddy.crownAt ? "Earned" : "At \(Buddy.crownAt.formatted()) grabs · \((Buddy.crownAt - stats.total).formatted()) to go") {
                        unlock(stats.total >= Buddy.crownAt)
                    }
                    RowDivider()
                    ToggleRow(title: "Wear what's earned", isOn: $settings.wearOutfits)
                    RowDivider()
                    ToggleRow(title: "Seasonal outfits", detail: "Dressed up for Halloween and the winter holidays.", isOn: $settings.seasonal)
                }
            }
        }
    }

    private func unlock(_ yes: Bool) -> some View {
        Image(systemName: yes ? "checkmark.seal.fill" : "lock.fill")
            .font(.system(size: 14))
            .foregroundStyle(yes ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFFC53D), Color(hex: 0xFF7A1A)], startPoint: .top, endPoint: .bottom))
                                 : AnyShapeStyle(Color.secondary.opacity(0.6)))
    }
}

// MARK: - Formats

private struct FormatsPane: View {
    @Bindable private var settings = Settings.shared
    @State private var spotlightFiles = UserDefaults.standard.object(forKey: "spotlightFiles") as? Bool ?? true
    private let sample = RGBAColor(r: 237 / 255, g: 110 / 255, b: 42 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "Shortcuts") {
                SettingRow(title: "Switch format",
                           detail: "Code, Markdown, a link, a sticker, a receipt… Grab remembers your choice for each kind of thing.") {
                    KeyCombo(keys: Settings.shared.trigger.keys + ["⇥"])
                }
                RowDivider()
                SettingRow(title: "Collect on the shelf", detail: "Adds to a floating shelf; the clipboard holds the whole shelf.") {
                    KeyCombo(keys: Settings.shared.trigger.keys + ["⇧", "C"])
                }
            }

            SettingsCard(title: "Copies") {
                ToggleRow(title: "Polish copied images",
                          detail: "Soft rounded corners, and pictures of text framed with the same room on every side.", isOn: $settings.roundImageCorners)
                RowDivider()
                ToggleRow(title: "Adapt code to where you paste",
                          detail: "Terminals lose the $ prompts; Slack, Discord, Notion and Obsidian get a code block.", isOn: $settings.adaptivePaste)
                RowDivider()
                ToggleRow(title: "Find open files with Spotlight",
                          detail: "For editors that don't say which file is open, Grab looks up the file named in the tab.", isOn: $spotlightFiles)
                    .onChange(of: spotlightFiles) { _, on in UserDefaults.standard.set(on, forKey: "spotlightFiles") }
            }

            SettingsCard(title: "Colors") {
                SettingRow(title: "Copy colors as") {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(nsColor: sample.nsColor)).frame(width: 14, height: 14)
                            Text(sample.formatted(settings.colorFormat))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        Picker("", selection: $settings.colorFormat) {
                            ForEach(ColorFormat.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            CustomFormatsCard()
        }
    }
}

// MARK: - Actions

private struct ActionsPane: View {
    @Bindable private var settings = Settings.shared

    private let keys: [(String, String, String)] = [
        ("⏎", "Open", "Links, files, maps for addresses, calendar for dates, a search for text"),
        ("space", "Quick Look", "The file, image or text"),
        ("P", "Pin", "Keeps it on screen in a floating window"),
        ("S", "Speak", "Reads it aloud; S again stops"),
        ("T", "Translate", "Into your language, on your Mac"),
        ("E", "Ask AI", "Explain, summarize or fix it with Apple Intelligence"),
        ("R", "Box", "Draw a box; C copies what's inside"),
        ("D", "Compare", "With what's on the clipboard"),
        ("F", "Fill", "The form under the pointer, from the clipboard"),
        ("V", "Paste next", "The next item on the shelf"),
        ("Z", "Undo", "The last grab, restoring the clipboard"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "While holding \(settings.trigger.symbol)") {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                    if i > 0 { RowDivider() }
                    HStack(spacing: 12) {
                        KeyView(key: k.0, wide: k.0.count > 1, size: 10).frame(width: 44)
                        Text(k.1).font(.system(size: 13)).frame(width: 84, alignment: .leading)
                        Text(k.2).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }

            SettingsCard(title: "Search & AI") {
                SettingRow(title: "Search with", detail: "For \(settings.trigger.chord("⏎")) on text and for error messages.") {
                    Picker("", selection: $settings.searchEngine) {
                        Text("Google").tag("google")
                        Text("DuckDuckGo").tag("duckduckgo")
                        Text("Bing").tag("bing")
                        Text("Kagi").tag("kagi")
                        Text("Perplexity").tag("perplexity")
                        Text("Ecosia").tag("ecosia")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                RowDivider()
                ToggleRow(title: "Convert prices to \(Locale.current.currency?.identifier ?? "your currency")",
                          detail: "Daily European Central Bank rates. Only currency codes are fetched.", isOn: $settings.currencyConversion)
                RowDivider()
                SettingRow(title: "On-device AI", detail: Assistant.unavailableReason ?? "Apple Intelligence is ready for \(settings.trigger.chord("E")).") {
                    if Assistant.unavailableReason == nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Apps

private struct AppsPane: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "Turned off in",
                         footer: "Holding \(settings.trigger.symbol) is left alone in these apps, for when it already means something, like Figma's measurements.") {
                ForEach(Array(settings.excludedApps.enumerated()), id: \.element) { i, bid in
                    if i > 0 { RowDivider() }
                    appRow(bid) {
                        removeButton { settings.excludedApps.removeAll { $0 == bid } }
                    }
                }
                if !settings.excludedApps.isEmpty { RowDivider() }
                addMenu(AppInfo.runningApps().filter { !settings.excludedApps.contains($0.id) }) { settings.excludedApps.append($0) }
            }

            SettingsCard(title: "Favorite type per app",
                         footer: "Grab picks the type for you. Set a favorite where you always want the same thing, like Color in Figma. Also in the menu bar's ⋯ menu.") {
                ForEach(Array(settings.appRules.keys.sorted().enumerated()), id: \.element) { i, bid in
                    if i > 0 { RowDivider() }
                    appRow(bid) {
                        HStack(spacing: 10) {
                            Picker("", selection: Binding(get: { settings.appRules[bid] ?? 0 }, set: { settings.appRules[bid] = $0 })) {
                                ForEach(GrabMode.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            removeButton { settings.appRules[bid] = nil }
                        }
                    }
                }
                if !settings.appRules.isEmpty { RowDivider() }
                addMenu(AppInfo.runningApps().filter { settings.appRules[$0.id] == nil }) { settings.appRules[$0] = GrabMode.text.rawValue }
            }
        }
    }

    private func appRow<T: View>(_ bid: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: AppInfo.icon(bid)).resizable().frame(width: 22, height: 22)
            Text(AppInfo.name(bid)).font(.system(size: 13))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle.fill").font(.system(size: 14)) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove")
    }

    private func addMenu(_ apps: [AppInfo.App], add: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(apps) { app in
                Button { add(app.id) } label: { Label { Text(app.name) } icon: { Image(nsImage: app.icon) } }
            }
        } label: {
            Label("Add App", systemImage: "plus").font(.system(size: 12.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - History

private struct HistoryPane: View {
    @Bindable private var settings = Settings.shared
    @State private var history = History.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "Recent grabs") {
                SettingRow(title: "Keep the last \(settings.historyLimit) grabs") {
                    Stepper("", value: $settings.historyLimit, in: 1...200).labelsHidden()
                }
                RowDivider()
                ButtonRow(title: "Search History", detail: "Every recent grab, grouped by app, with search. Also ⌘F in the menu bar menu.") {
                    Panels.shared.showHistory()
                }
                RowDivider()
                SettingRow(title: "Clear History", detail: history.items.isEmpty ? "Nothing to clear." : "\(history.items.count) grabs, and any saved copy.") {
                    Button("Clear") { history.clear() }.controlSize(.small).disabled(history.items.isEmpty)
                }
            }

            SettingsCard(title: "After quitting",
                         footer: "Saved encrypted on this Mac, with the key in your keychain. Secrets are never saved.") {
                ToggleRow(title: "Keep history after quitting", detail: "Off: history lives in memory and is gone when Grab quits.", isOn: $settings.keepHistory)
                    .onChange(of: settings.keepHistory) { _, on in History.shared.setKeepHistory(on) }
                if settings.keepHistory {
                    RowDivider()
                    SettingRow(title: "Forget grabs after") {
                        Picker("", selection: $settings.keepHistoryDays) {
                            Text("1 day").tag(1)
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @Bindable private var settings = Settings.shared
    @State private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "Permissions", footer: "You can change these any time in System Settings → Privacy & Security.") {
                PermissionRow(reason: .accessibility, granted: permissions.accessibility) { permissions.requestAccessibility() }
                RowDivider()
                PermissionRow(reason: .screenRecording, granted: permissions.screenRecording,
                              actionTitle: permissions.screenRecordingNeedsRelaunch ? "Relaunch" : "Grant") {
                    if permissions.screenRecordingNeedsRelaunch { Permissions.relaunch() } else { permissions.requestScreenRecording() }
                }
            }

            SettingsCard(title: "Secrets") {
                ToggleRow(title: "Protect secrets",
                          detail: "API keys, tokens, private keys and Wi-Fi passwords are hidden from clipboard managers, kept out of history and cleared after a minute.",
                          isOn: $settings.protectSecrets)
            }

            SettingsCard(title: "Everything else") {
                OtherAccessNote().padding(14)
                RowDivider()
                SettingRow(title: "Stats are counts",
                           detail: "Achievements and Grab Wrapped keep numbers, the apps you grab in and the colors you pick, on this Mac. Never what you grab.")
            }
        }
    }
}

private struct PermissionRow: View {
    let reason: PermissionReason
    let granted: Bool
    var actionTitle = "Grant"
    let action: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: reason.title, detail: reason.summary) {
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                } else {
                    Button(actionTitle, action: action).controlSize(.small)
                }
            }
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(expanded ? "Less" : "What it's for, and what Grab never does")
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, expanded ? 6 : 12)
            if expanded {
                PermissionExplainer(reason: reason).padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
    }
}

// MARK: - Achievements

private struct AchievementsPane: View {
    @State private var stats = Stats.shared
    @State private var badges = Badges.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // The numbers, big.
            ZStack(alignment: .leading) {
                LinearGradient(colors: [Color(hex: 0xFF8A3D), Color(hex: 0xEC4F7C), Color(hex: 0x7C5CFF)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.12)).frame(width: 220).offset(x: 400, y: -70)
                Circle().fill(.white.opacity(0.08)).frame(width: 140).offset(x: 470, y: 60)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(stats.total.formatted()).font(.system(size: 46, weight: .heavy, design: .rounded))
                        Text(stats.total == 1 ? "grab" : "grabs").font(.system(size: 17, weight: .semibold)).opacity(0.85)
                    }
                    Text(stats.total == 0 ? "Your grabs get counted here." : Stats.savedPhrase(stats.seconds).capitalizedFirst + " so far")
                        .font(.system(size: 13, weight: .medium)).opacity(0.85)
                    HStack(spacing: 6) {
                        ForEach(stats.top.prefix(4), id: \.0) { k, n in
                            HStack(spacing: 5) {
                                Image(systemName: k.symbol)
                                Text("\(n.formatted()) \(k.title.lowercased())").monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.2)))
                        }
                    }
                    HStack(spacing: 8) {
                        heroButton(copied ? "Copied" : "Share Card", symbol: copied ? "checkmark" : "square.and.arrow.up") {
                            guard let img = stats.shareCard() else { return }
                            Clipboard.write(.image(img, pointSize: CGSize(width: img.width / 2, height: img.height / 2)))
                            Sound.shared.play(.copy)
                            withAnimation { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                        }
                        heroButton("Grab Wrapped", symbol: "sparkles") { Panels.shared.showWrapped() }
                    }
                    .padding(.top, 2)
                }
                .foregroundStyle(.white)
                .padding(22)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Badges").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(badges.earnedCount) of \(Badge.allCases.count) earned").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                BadgesGrid()
                Text("Earned by using Grab. Counts include every grab since you installed it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    private func heroButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.22)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// Every badge with what it takes: earned ones in color with the date, the rest with how far along you are.
struct BadgesGrid: View {
    @State private var badges: Badges
    @State private var stats = Stats.shared
    @State private var buddy = Buddy.shared

    init(badges: Badges = .shared) {
        _badges = State(initialValue: badges)
    }

    var body: some View {
        // Earned first; otherwise always the same order, so nothing jumps around as you grab.
        let all = Badge.allCases.filter { badges.has($0) } + Badge.allCases.filter { !badges.has($0) }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)], spacing: 8) {
            ForEach(all) { b in card(b) }
        }
        .padding(.vertical, 4)
        .onAppear { badges.catchUp() }
    }

    private func progress(_ b: Badge) -> (Int, Int)? { badges.progress(b, stats: stats, pets: buddy.petsTotal) }

    private func card(_ b: Badge) -> some View {
        let earned = badges.has(b)
        return HStack(alignment: .top, spacing: 10) {
            BadgeMedal(badge: b, earned: earned, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(b.title).font(.system(size: 12.5, weight: .semibold))
                Text(b.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if earned, let d = badges.earned[b.rawValue] {
                    Label("Earned \(d.formatted(.dateTime.month(.abbreviated).day()))", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(b.colors.first ?? .green)
                } else if let (now, target) = progress(b) {
                    VStack(alignment: .leading, spacing: 3) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(LinearGradient(colors: b.colors, startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(now > 0 ? 4 : 0, g.size.width * CGFloat(now) / CGFloat(max(1, target))))
                            }
                        }
                        .frame(height: 4)
                        Text(b == .comboKing ? "Best ×\(now) of ×\(target)" : "\(now.formatted()) of \(target.formatted()) \(b.unit)")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 1)
                } else {
                    Text("Not yet").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(earned ? 0.05 : 0.025)))
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

/// Your own ⇥ formats: templates and Shortcuts.
private struct CustomFormatsCard: View {
    @Bindable private var settings = Settings.shared
    @State private var expanded: UUID?
    @State private var shortcuts: [String] = []

    var body: some View {
        SettingsCard(title: "Your formats",
                     footer: settings.customFormats.isEmpty ? "Add your own to the \(settings.trigger.chord("⇥")) list: a template like [{title}]({url}), or any Shortcut that takes text or an image." : nil) {
            ForEach(Array($settings.customFormats.enumerated()), id: \.element.id) { i, $format in
                if i > 0 { RowDivider() }
                CustomFormatRow(format: $format, expanded: expanded == format.id) {
                    withAnimation(.easeOut(duration: 0.18)) { expanded = expanded == format.id ? nil : format.id }
                } delete: {
                    settings.customFormats.removeAll { $0.id == format.id }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            if !settings.customFormats.isEmpty { RowDivider() }
            Menu {
                Button("Template") { add(CustomFormat(name: "My format", template: "{text}", targets: [.text])) }
                Menu("Example") {
                    ForEach(CustomFormat.examples) { ex in
                        Button("\(ex.name)   \(ex.template.replacingOccurrences(of: "\n", with: " ⏎ "))") { add(ex) }
                    }
                }
                Menu("Run a Shortcut") {
                    if shortcuts.isEmpty { Text("No shortcuts found") }
                    ForEach(shortcuts, id: \.self) { name in
                        Button(name) { add(CustomFormat(name: name, template: "", shortcut: name, targets: [.text])) }
                    }
                }
            } label: {
                Label("Add Format", systemImage: "plus").font(.system(size: 12.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .task { shortcuts = await ShortcutRunner.list() }
    }

    private func add(_ f: CustomFormat) {
        var copy = f
        copy.id = UUID()
        settings.customFormats.append(copy)
        expanded = copy.id
    }
}

private struct CustomFormatRow: View {
    @Binding var format: CustomFormat
    let expanded: Bool
    let toggle: () -> Void
    let delete: () -> Void

    private static let sample = Template.values(
        text: "Grab copies anything on your Mac", url: URL(string: "https://example.com/grab"),
        title: "Grab — point and copy", app: "Safari", language: "swift", file: URL(fileURLWithPath: "/tmp/App.swift"), line: 12
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: format.shortcut != nil ? "square.2.layers.3d.fill" : "curlybraces")
                    .foregroundStyle(LinearGradient(colors: Theme.brand, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 18)
                TextField("Name", text: $format.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(format.targets.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button(action: toggle) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button(action: delete) { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if expanded {
                if let name = format.shortcut {
                    Text("Runs “\(name)” with the grab as its input (text, or a PNG for images) and copies what it returns.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top) {
                        TextField("Template", text: $format.template, axis: .vertical)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1...5)
                        Menu {
                            Section("Values") {
                                ForEach(CustomFormat.tokens, id: \.0) { t in
                                    Button("\(t.0)   \(t.1)") { format.template += t.0 }
                                }
                            }
                            Section("Filters, like {text|upper}") {
                                ForEach(CustomFormat.filters, id: \.0) { f in Text("\(f.0)   \(f.1)") }
                            }
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    Text(Template.render(format.template, values: Self.sample))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Text("Offer on").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    ForEach(CustomFormat.Target.allCases.filter { $0 != .image || format.shortcut != nil }) { t in
                        Toggle(t.title, isOn: Binding(
                            get: { format.targets.contains(t) },
                            set: { on in if on { format.targets.insert(t) } else if format.targets.count > 1 { format.targets.remove(t) } }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
