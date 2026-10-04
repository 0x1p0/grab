import AppKit
import SwiftUI

/// How much you've grabbed, and a rough idea of the time it saved. Counts only:
/// nothing about what was grabbed is kept.
@Observable
final class Stats {
    static let shared = Stats()

    enum Kind: String, CaseIterable {
        case text, code, ocr, link, qr, image, color, file, box

        var title: String {
            switch self {
            case .text: "Text"
            case .code: "Code"
            case .ocr: "Text in pictures"
            case .link: "Links"
            case .qr: "QR codes"
            case .image: "Images"
            case .color: "Colors"
            case .file: "Files"
            case .box: "Boxes"
            }
        }

        var symbol: String {
            switch self {
            case .text: "text.quote"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .ocr: "text.viewfinder"
            case .link: "link"
            case .qr: "qrcode"
            case .image: "photo"
            case .color: "eyedropper.halffull"
            case .file: "doc.fill"
            case .box: "rectangle.dashed"
            }
        }

        /// Roughly how long the same thing takes by hand: selecting precisely,
        /// retyping text from a picture, finding a phone for a QR code…
        var secondsSaved: Double {
            switch self {
            case .text: 4
            case .code: 8
            case .ocr: 30
            case .link: 5
            case .qr: 20
            case .image: 10
            case .color: 12
            case .file: 6
            case .box: 25
            }
        }
    }

    static let milestones = [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000]

    @ObservationIgnored private let d = UserDefaults.standard
    private(set) var counts: [String: Int]
    private(set) var seconds: Double
    @ObservationIgnored private var pendingMilestone: Int?
    @ObservationIgnored private var observer: NSObjectProtocol?

    var total: Int { counts.values.reduce(0, +) }

    private init() {
        counts = d.dictionary(forKey: "stats") as? [String: Int] ?? [:]
        seconds = d.double(forKey: "statsSeconds")
        observer = NotificationCenter.default.addObserver(forName: .grabDidCopy, object: nil, queue: nil) { [weak self] note in
            guard let e = note.object as? GrabEvent else { return }
            self?.record(e)
        }
    }

    static func kind(of e: GrabEvent) -> Kind {
        if e.box { return .box }
        switch e.mode {
        case .text: return e.codeKind != nil ? .code : (e.ocr ? .ocr : .text)
        case .link: return .link
        case .qr: return .qr
        case .file: return .file
        case .image: return .image
        case .color: return .color
        }
    }

    func record(_ e: GrabEvent) {
        let k = Self.kind(of: e)
        let before = total
        counts[k.rawValue, default: 0] += 1
        seconds += k.secondsSaved
        d.set(counts, forKey: "stats")
        d.set(seconds, forKey: "statsSeconds")
        if let m = Self.milestones.first(where: { before < $0 && total >= $0 }) { pendingMilestone = m }
    }

    /// A milestone the last grab reached, once.
    func takeMilestone() -> Int? {
        defer { pendingMilestone = nil }
        return pendingMilestone
    }

    func count(_ k: Kind) -> Int { counts[k.rawValue] ?? 0 }

    /// The kinds you grab most, biggest first.
    var top: [(Kind, Int)] {
        Kind.allCases.map { ($0, count($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    /// "about 10 min saved", "a few seconds saved".
    static func savedPhrase(_ seconds: Double) -> String {
        seconds < 60 ? "a few seconds saved" : "about \(saved(seconds)) saved"
    }

    static func saved(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "a few seconds" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        if hours < 48 { return hours < 10 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h" }
        return "\(Int((hours / 24).rounded())) days"
    }

    func reset() {
        counts = [:]
        seconds = 0
        d.removeObject(forKey: "stats")
        d.removeObject(forKey: "statsSeconds")
    }

    /// A card to share, rendered at 2×.
    @MainActor func shareCard() -> CGImage? {
        let renderer = ImageRenderer(content: StatsShareCard(total: total, saved: Self.savedPhrase(seconds), top: Array(top.prefix(4)),
                                                             mascot: MascotKind(rawValue: Settings.shared.mascot) ?? .snap))
        renderer.scale = 2
        return renderer.cgImage
    }
}

private struct StatsShareCard: View {
    let total: Int
    let saved: String
    let top: [(Stats.Kind, Int)]
    let mascot: MascotKind

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                Text("Grab").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Spacer()
                if mascot != .off { MascotIdle(kind: mascot).frame(width: 64, height: 48) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(total.formatted()).font(.system(size: 56, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                Text("things grabbed · \(saved)").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: 10) {
                ForEach(top, id: \.0) { k, n in
                    HStack(spacing: 6) {
                        Image(systemName: k.symbol)
                        Text("\(n.formatted()) \(k.title.lowercased())")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.18)))
                }
            }
            Text("Hold \(Trigger.current.symbol), point, press C.").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        }
        .padding(30)
        .frame(width: 560, alignment: .leading)
        .background(LinearGradient(colors: [Color(hex: 0xFF8A3D), Color(hex: 0xEC4F7C), Color(hex: 0x7C5CFF)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
