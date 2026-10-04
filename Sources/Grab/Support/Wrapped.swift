import AppKit
import SwiftUI

/// One month of grabbing, for Grab Wrapped: counts, which apps, which hours, the colors
/// you picked. Never what you grabbed (no text, no images).
struct MonthLog: Codable, Equatable {
    var counts: [String: Int] = [:]
    /// Bundle identifiers → grabs.
    var apps: [String: Int] = [:]
    /// Days of the month with at least one grab.
    var days: [Int] = []
    var hours: [Int] = Array(repeating: 0, count: 24)
    var biggestText = 0
    var biggestImage = 0
    /// Colors picked with Grab (hex), oldest first.
    var colors: [String] = []
    var bestCombo = 0
    var badges: [String] = []
    var seconds: Double = 0

    var total: Int { counts.values.reduce(0, +) }

    var topKind: Stats.Kind? {
        counts.max { $0.value < $1.value }.flatMap { Stats.Kind(rawValue: $0.key) }
    }

    var topApp: (bundleID: String, count: Int)? {
        apps.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    /// The longest run of consecutive days with grabs.
    var longestStreak: Int {
        var best = 0, run = 0, prev = -10
        for d in days.sorted() {
            run = d == prev + 1 ? run + 1 : 1
            best = max(best, run)
            prev = d
        }
        return best
    }

    var busiestHour: Int? {
        guard let m = hours.max(), m > 0 else { return nil }
        return hours.firstIndex(of: m)
    }

    static let maxColors = 120
}

@Observable
final class Journal {
    static let shared = Journal()

    @ObservationIgnored private let d: UserDefaults
    private(set) var months: [String: MonthLog]

    init(defaults: UserDefaults = .standard) {
        d = defaults
        months = d.data(forKey: "journal").flatMap { try? JSONDecoder().decode([String: MonthLog].self, from: $0) } ?? [:]
    }

    static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func title(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return key }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// Months with grabs, newest first.
    var keys: [String] { months.filter { $0.value.total > 0 }.keys.sorted(by: >) }

    func record(_ e: GrabEvent, combo: Int, at now: Date = Date()) {
        let key = Self.key(now)
        var m = months[key] ?? MonthLog()
        let kind = Stats.kind(of: e)
        m.counts[kind.rawValue, default: 0] += 1
        m.seconds += kind.secondsSaved
        if let b = e.bundleID { m.apps[b, default: 0] += 1 }
        let cal = Calendar.current
        let day = cal.component(.day, from: now)
        if !m.days.contains(day) { m.days.append(day) }
        m.hours[cal.component(.hour, from: now)] += 1
        if let t = e.text, e.mode == .text { m.biggestText = max(m.biggestText, t.count) }
        m.biggestImage = max(m.biggestImage, e.pixels)
        if e.mode == .color, let c = e.color {
            m.colors.append(c.hex)
            if m.colors.count > MonthLog.maxColors { m.colors.removeFirst(m.colors.count - MonthLog.maxColors) }
        }
        m.bestCombo = max(m.bestCombo, combo)
        months[key] = m
        save()
    }

    func noteBadges(_ badges: [Badge], at now: Date = Date()) {
        guard !badges.isEmpty else { return }
        let key = Self.key(now)
        var m = months[key] ?? MonthLog()
        m.badges += badges.map(\.rawValue).filter { !m.badges.contains($0) }
        months[key] = m
        save()
    }

    /// Last month's Wrapped, the first time we're into a new month (once).
    func takeReadyMonth(at now: Date = Date()) -> String? {
        guard let last = Calendar.current.date(byAdding: .month, value: -1, to: now) else { return nil }
        let key = Self.key(last)
        guard (months[key]?.total ?? 0) >= 10, d.string(forKey: "journalAnnounced") != key else { return nil }
        d.set(key, forKey: "journalAnnounced")
        return key
    }

    func reset() {
        months = [:]
        d.removeObject(forKey: "journal")
    }

    private func save() {
        // Two years is plenty.
        if months.count > 24, let oldest = months.keys.sorted().first { months[oldest] = nil }
        if let data = try? JSONEncoder().encode(months) { d.set(data, forKey: "journal") }
    }
}

// MARK: - The card

/// A month of grabbing as a tall, shareable card.
struct WrappedCard: View {
    let key: String
    let log: MonthLog
    let mascot: MascotKind
    /// Looked up before drawing.
    private let appName: String?
    private let appIcon: CGImage?

    init(key: String, log: MonthLog, mascot: MascotKind = MascotKind(rawValue: Settings.shared.mascot) ?? .snap) {
        self.key = key
        self.log = log
        self.mascot = mascot
        if let id = log.topApp?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            // Plain 8-bit sRGB: a deeper icon would wash the whole card out when it's rendered.
            let side = 64
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
                NSGraphicsContext.restoreGraphicsState()
                appIcon = ctx.makeImage()
            } else {
                appIcon = nil
            }
        } else {
            appName = nil
            appIcon = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GRAB WRAPPED").font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(2.5).foregroundStyle(.white.opacity(0.75))
                    Text(Journal.title(key)).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                }
                Spacer()
                if mascot != .off, mascot != .classic {
                    MascotIdle(kind: mascot, animated: false).frame(width: 64, height: 56)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(log.total.formatted()).font(.system(size: 72, weight: .black, design: .rounded)).foregroundStyle(.white)
                    .minimumScaleFactor(0.5).lineLimit(1)
                Text("things grabbed · \(Stats.savedPhrase(log.seconds))").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }

            VStack(spacing: 10) {
                if let n = appName, let count = log.topApp?.count {
                    tile(icon: appIcon.map { AnyView(Image(decorative: $0, scale: 2).resizable().frame(width: 30, height: 30)) },
                         symbol: "app.fill", label: "Grabbed most from", value: n, note: "\(count.formatted()) grabs")
                }
                if let k = log.topKind {
                    tile(symbol: k.symbol, label: "You're a", value: personality(k), note: "\((log.counts[k.rawValue] ?? 0).formatted()) \(k.title.lowercased())")
                }
                HStack(spacing: 10) {
                    small(symbol: "flame.fill", value: "\(max(1, log.longestStreak))", label: log.longestStreak == 1 ? "day streak" : "days in a row")
                    small(symbol: "bolt.fill", value: "×\(max(1, log.bestCombo))", label: "best combo")
                    if let h = log.busiestHour { small(symbol: "clock.fill", value: hourName(h), label: "peak hour") }
                }
                if let biggest = biggestLine {
                    tile(symbol: "scalemass.fill", label: "Biggest grab", value: biggest, note: nil)
                }
            }

            palette
            if !log.badges.isEmpty {
                HStack(spacing: 8) {
                    ForEach(log.badges.compactMap(Badge.init(rawValue:)).prefix(7)) { b in BadgeMedal(badge: b, earned: true, size: 30) }
                    Spacer(minLength: 0)
                    Text(log.badges.count == 1 ? "1 badge" : "\(log.badges.count) badges")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }
            Text("Hold \(Trigger.current.symbol), point, press C.").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(28)
        .frame(width: 420, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1B1036), Color(hex: 0x3B1250), Color(hex: 0x7A1F4F)], startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(hex: 0xFF8A3D).opacity(0.55)).frame(width: 300).blur(radius: 70).offset(x: 150, y: -260)
            Circle().fill(Color(hex: 0x7C5CFF).opacity(0.6)).frame(width: 320).blur(radius: 80).offset(x: -170, y: 120)
            Circle().fill(Color(hex: 0xEC4F7C).opacity(0.45)).frame(width: 260).blur(radius: 70).offset(x: 160, y: 330)
        }
    }

    /// Every color picked this month as a poster, or a nudge to pick some.
    @ViewBuilder private var palette: some View {
        let colors = log.colors.compactMap(RGBAColor.init(hex:))
        if colors.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "eyedropper.halffull")
                Text("Pick colors with \(Trigger.current.symbol) and next month's card gets a poster of them.")
            }
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your colors").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                let cols = min(12, max(4, Int(Double(colors.count).squareRoot().rounded(.up))))
                let rows = Int((Double(min(colors.count, cols * 4)) / Double(cols)).rounded(.up))
                VStack(spacing: 3) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 3) {
                            ForEach(0..<cols, id: \.self) { c in
                                let i = (r * cols + c) % colors.count
                                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(nsColor: colors[colors.count - 1 - i].nsColor))
                            }
                        }
                        .frame(height: 22)
                    }
                }
            }
        }
    }

    private func tile(icon: AnyView? = nil, symbol: String, label: String, value: String, note: String?) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon { icon } else { Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white) }
            }
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(icon == nil ? 0.16 : 0)))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let note { Text(note).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.7)) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.09)))
    }

    private func small(symbol: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            Text(value).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.09)))
    }

    private func personality(_ k: Stats.Kind) -> String {
        switch k {
        case .text: "Wordsmith"
        case .code: "Code Collector"
        case .ocr: "Picture Reader"
        case .link: "Link Hoarder"
        case .qr: "QR Hunter"
        case .image: "Image Snatcher"
        case .color: "Color Thief"
        case .file: "File Wrangler"
        case .box: "Box Drawer"
        }
    }

    private func hourName(_ h: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: h)) ?? Date()
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }

    private var biggestLine: String? {
        if log.biggestImage >= 1_000_000 {
            return String(format: "a %.1f-megapixel image", Double(log.biggestImage) / 1_000_000)
        }
        if log.biggestText >= 200 { return "\(log.biggestText.formatted()) characters of text" }
        return nil
    }

    /// The card as a picture, at 2×.
    @MainActor static func render(_ key: String, _ log: MonthLog) -> CGImage? {
        let r = ImageRenderer(content: WrappedCard(key: key, log: log))
        r.scale = 2
        return r.cgImage
    }
}

// MARK: - The window

/// Grab Wrapped: pick a month, copy or save the card.
struct WrappedPanelView: View {
    var close: () -> Void
    @State private var journal = Journal.shared
    @State private var key = Journal.key(Date())
    @State private var copied = false

    var body: some View {
        let keys = journal.keys
        VStack(spacing: 14) {
            if let log = journal.months[key], log.total > 0 {
                ScrollView(.vertical, showsIndicators: false) {
                    WrappedCard(key: key, log: log)
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                        .padding(.vertical, 6)
                }
                HStack(spacing: 8) {
                    if keys.count > 1 {
                        Picker("Month", selection: $key) {
                            ForEach(keys, id: \.self) { Text(Journal.title($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Spacer()
                    Button {
                        guard let img = WrappedCard.render(key, log) else { return }
                        Clipboard.write(.image(img, pointSize: CGSize(width: img.width / 2, height: img.height / 2)))
                        Sound.shared.play(.copy)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Button {
                        save(log)
                    } label: {
                        Label("Save…", systemImage: "square.and.arrow.down")
                    }
                }
                .controlSize(.regular)
            } else {
                VStack(spacing: 10) {
                    MascotIdle(kind: MascotKind(rawValue: Settings.shared.mascot) ?? .snap).frame(height: 64)
                    Text("Nothing wrapped yet").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Grab Wrapped sums up each month: your top app, streaks, combos and every color you picked. Start grabbing and check back.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 320)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(18)
        .padding(.top, 14)
        .frame(width: 476)
        .frame(maxHeight: .infinity)
        .background(HUDBackground(cornerRadius: 22))
        .onAppear { if journal.months[key] == nil, let first = keys.first { key = first } }
    }

    private func save(_ log: MonthLog) {
        guard let img = WrappedCard.render(key, log), let png = ImageTools.pngData(img) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Grab Wrapped \(Journal.title(key)).png"
        panel.allowedContentTypes = [.png]
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}
