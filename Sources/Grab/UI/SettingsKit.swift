import AppKit
import SwiftUI

// The pieces Settings is built from: a sidebar of panes, a header per pane, and
// cards of rows. One look everywhere, so every pane feels like the same app.

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, feel, mascot, formats, actions, apps, history, privacy, achievements
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .feel: "Feel"
        case .mascot: "Mascot"
        case .formats: "Formats"
        case .actions: "Actions"
        case .apps: "Apps"
        case .history: "History"
        case .privacy: "Privacy"
        case .achievements: "Achievements"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "How you start a grab, and how Grab starts up."
        case .feel: "Sounds, taps and the little touches while you grab."
        case .mascot: "Who carries each grab to the menu bar."
        case .formats: "What lands on your clipboard, and in which shape."
        case .actions: "Keys that do more than copy while you hold \(Trigger.current.symbol)."
        case .apps: "Where Grab steps aside, and what it prefers where."
        case .history: "Your recent grabs, and how long they're kept."
        case .privacy: "What Grab can see, and what it never does."
        case .achievements: "Your grabs in numbers, badges and Grab Wrapped."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .feel: "hand.tap.fill"
        case .mascot: "face.smiling.inverse"
        case .formats: "wand.and.stars"
        case .actions: "bolt.fill"
        case .apps: "square.grid.2x2.fill"
        case .history: "clock.arrow.circlepath"
        case .privacy: "hand.raised.fill"
        case .achievements: "trophy.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .general: [Color(hex: 0x9A9AA2), Color(hex: 0x5E5E66)]
        case .feel: [Color(hex: 0xFF7EB0), Color(hex: 0xE3437A)]
        case .mascot: [Color(hex: 0xFFB648), Color(hex: 0xFF6A1A)]
        case .formats: [Color(hex: 0xA98DFF), Color(hex: 0x6E4BF5)]
        case .actions: [Color(hex: 0xFFD45E), Color(hex: 0xF29A0E)]
        case .apps: [Color(hex: 0x5CB8FF), Color(hex: 0x2A6FF0)]
        case .history: [Color(hex: 0x3EDBB0), Color(hex: 0x0E9F7A)]
        case .privacy: [Color(hex: 0x8B93FF), Color(hex: 0x4A43D9)]
        case .achievements: [Color(hex: 0xFFE07A), Color(hex: 0xF2A10F)]
        }
    }

    /// Sidebar groups, separated by a little space.
    static let groups: [[SettingsPane]] = [[.general, .feel, .mascot], [.formats, .actions, .apps], [.history, .privacy], [.achievements]]
}

/// Which pane is showing (the debug hook can switch it for screenshots).
@Observable
final class SettingsNav {
    static let shared = SettingsNav()
    var pane: SettingsPane = .general
}

extension Theme {
    /// Switches, sliders and highlights.
    static let accent = Color(hex: 0xEC4F7C)
}

/// A rounded square with a gradient and a white symbol, like System Settings.
struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            .frame(width: size, height: size)
            .background(shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
    }
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group) { pane in item(pane) }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Grab").font(.system(size: 11.5, weight: .semibold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(.top, 52)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func item(_ pane: SettingsPane) -> some View {
        let on = pane == selection
        return Button {
            selection = pane
        } label: {
            HStack(spacing: 9) {
                IconTile(symbol: pane.symbol, colors: pane.colors, size: 22)
                Text(pane.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(on ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The big title at the top of a pane.
struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: pane.symbol, colors: pane.colors, size: 42)
                .shadow(color: (pane.colors.last ?? .clear).opacity(0.35), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title).font(.system(size: 22, weight: .bold))
                Text(pane.subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }
}

/// A group of rows on a soft card, with an optional title above and note below.
struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A hairline between rows in a card.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5).padding(.leading, 14) }
}

/// One setting: a title, an optional explanation, and its control on the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, detail == nil ? 9 : 11)
        .frame(minHeight: 38)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

/// A row that opens something (a list, a window) or does something.
struct ButtonRow: View {
    let title: String
    var detail: String?
    var symbol = "chevron.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingRow(title: title, detail: detail) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Keys as key caps, for rows that explain a shortcut.
struct KeyCombo: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in KeyView(key: k, wide: k.count > 1, size: 10) }
        }
    }
}

/// The window's background behind the sidebar: translucent, like Finder's.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
