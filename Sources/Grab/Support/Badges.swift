import AppKit
import NaturalLanguage
import SwiftUI

/// Little achievements, earned by grabbing. Kept on this Mac as names and dates only.
enum Badge: String, CaseIterable, Identifiable {
    case firstGrab, century, royalty, nightOwl, earlyBird, chromatic, polyglot, comboKing
    case detective, codeMonkey, boxer, onARoll, bestFriends, testingPatience

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstGrab: "Hello, World"
        case .century: "Century"
        case .royalty: "Royalty"
        case .nightOwl: "Night Owl"
        case .earlyBird: "Early Bird"
        case .chromatic: "Chromatic"
        case .polyglot: "Polyglot"
        case .comboKing: "Combo King"
        case .detective: "Detective"
        case .codeMonkey: "Code Monkey"
        case .boxer: "Boxer"
        case .onARoll: "On a Roll"
        case .bestFriends: "Best Friends"
        case .testingPatience: "Testing Patience"
        }
    }

    /// How it's earned.
    var detail: String {
        switch self {
        case .firstGrab: "Your first grab"
        case .century: "100 grabs. Comes with sunglasses"
        case .royalty: "1,000 grabs. Comes with a crown"
        case .nightOwl: "A grab between 2 and 5 a.m."
        case .earlyBird: "A grab between 5 and 7 a.m."
        case .chromatic: "50 colors picked"
        case .polyglot: "Text grabbed in 5 languages"
        case .comboKing: "A ×10 combo"
        case .detective: "25 grabs of text inside pictures"
        case .codeMonkey: "100 grabs of code"
        case .boxer: "25 boxes drawn"
        case .onARoll: "Grabs 7 days in a row"
        case .bestFriends: "Pet your mascot 25 times"
        case .testingPatience: "Poke your mascot until it walks off"
        }
    }

    var symbol: String {
        switch self {
        case .firstGrab: "hand.wave.fill"
        case .century: "sunglasses.fill"
        case .royalty: "crown.fill"
        case .nightOwl: "moon.stars.fill"
        case .earlyBird: "sunrise.fill"
        case .chromatic: "paintpalette.fill"
        case .polyglot: "globe"
        case .comboKing: "flame.fill"
        case .detective: "text.viewfinder"
        case .codeMonkey: "chevron.left.forwardslash.chevron.right"
        case .boxer: "rectangle.dashed"
        case .onARoll: "calendar"
        case .bestFriends: "heart.fill"
        case .testingPatience: "exclamationmark.bubble.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .firstGrab, .century, .royalty: [Color(hex: 0xFFC53D), Color(hex: 0xFF7A1A)]
        case .nightOwl: [Color(hex: 0x5B5BF7), Color(hex: 0x1E1B4B)]
        case .earlyBird: [Color(hex: 0xFFB347), Color(hex: 0xFF5E62)]
        case .chromatic: [Color(hex: 0x22C3EE), Color(hex: 0xD946EF)]
        case .polyglot: [Color(hex: 0x10B981), Color(hex: 0x0EA5E9)]
        case .comboKing: [Color(hex: 0xFF8A3D), Color(hex: 0xEF4444)]
        case .detective: [Color(hex: 0x2F7BFF), Color(hex: 0x22C3EE)]
        case .codeMonkey: [Color(hex: 0x84CC16), Color(hex: 0x10B981)]
        case .boxer: [Color(hex: 0xF43F5E), Color(hex: 0x7C5CFF)]
        case .onARoll: [Color(hex: 0xEC4F7C), Color(hex: 0x7C5CFF)]
        case .bestFriends: [Color(hex: 0xFF6FA5), Color(hex: 0xEC4F7C)]
        case .testingPatience: [Color(hex: 0x94A3B8), Color(hex: 0x475569)]
        }
    }

    /// Badges you can see coming show how far along you are.
    var target: Int? {
        switch self {
        case .century: 100
        case .royalty: 1_000
        case .chromatic: 50
        case .polyglot: 5
        case .comboKing: 10
        case .detective: 25
        case .codeMonkey: 100
        case .boxer: 25
        case .onARoll: 7
        case .bestFriends: 25
        default: nil
        }
    }
}

@Observable
final class Badges {
    static let shared = Badges()

    @ObservationIgnored private let d: UserDefaults
    private(set) var earned: [String: Date]
    /// Languages seen in text grabs, as codes ("en", "fr"): never the text.
    private(set) var languages: Set<String>
    private(set) var bestCombo: Int
    private(set) var bestStreak: Int
    @ObservationIgnored private var streakDay: Date?
    @ObservationIgnored private var streak: Int

    init(defaults: UserDefaults = .standard) {
        d = defaults
        earned = (d.dictionary(forKey: "badges") as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
        languages = Set(d.stringArray(forKey: "badgeLanguages") ?? [])
        bestCombo = d.integer(forKey: "badgeBestCombo")
        bestStreak = d.integer(forKey: "badgeBestStreak")
        streak = d.integer(forKey: "badgeStreak")
        let day = d.double(forKey: "badgeStreakDay")
        streakDay = day > 0 ? Date(timeIntervalSince1970: day) : nil
    }

    func has(_ b: Badge) -> Bool { earned[b.rawValue] != nil }

    var earnedCount: Int { Badge.allCases.filter(has).count }

    /// (so far, needed) for badges with a target.
    func progress(_ b: Badge, stats: Stats = .shared, pets: Int = Buddy.shared.petsTotal) -> (Int, Int)? {
        guard let target = b.target else { return nil }
        let now: Int
        switch b {
        case .century, .royalty: now = stats.total
        case .chromatic: now = stats.count(.color)
        case .polyglot: now = languages.count
        case .comboKing: now = bestCombo
        case .detective: now = stats.count(.ocr)
        case .codeMonkey: now = stats.count(.code)
        case .boxer: now = stats.count(.box)
        case .onARoll: now = bestStreak
        case .bestFriends: now = pets
        default: now = 0
        }
        return (min(now, target), target)
    }

    /// After a grab is counted: anything newly earned.
    @discardableResult
    func check(_ e: GrabEvent, combo: Int, at now: Date = Date(), stats: Stats = .shared) -> [Badge] {
        var new: [Badge] = []
        func award(_ b: Badge, _ cond: Bool) { if cond, unlock(b, at: now) { new.append(b) } }

        if combo > bestCombo {
            bestCombo = combo
            d.set(bestCombo, forKey: "badgeBestCombo")
        }
        updateStreak(now)
        if e.mode == .text, let t = e.text, let lang = Self.language(of: t), !languages.contains(lang) {
            languages.insert(lang)
            d.set(languages.sorted(), forKey: "badgeLanguages")
        }

        let hour = Calendar.current.component(.hour, from: now)
        award(.firstGrab, stats.total >= 1)
        award(.century, stats.total >= 100)
        award(.royalty, stats.total >= 1_000)
        award(.nightOwl, (2..<5).contains(hour))
        award(.earlyBird, (5..<7).contains(hour))
        award(.chromatic, stats.count(.color) >= 50)
        award(.polyglot, languages.count >= 5)
        award(.comboKing, bestCombo >= 10)
        award(.detective, stats.count(.ocr) >= 25)
        award(.codeMonkey, stats.count(.code) >= 100)
        award(.boxer, stats.count(.box) >= 25)
        award(.onARoll, bestStreak >= 7)
        return new
    }

    /// After a pet: friendship, or patience tested.
    @discardableResult
    func checkPet(_ reaction: Buddy.PetReaction, total: Int, at now: Date = Date()) -> [Badge] {
        var new: [Badge] = []
        if total >= 25, unlock(.bestFriends, at: now) { new.append(.bestFriends) }
        if reaction == .annoyed, unlock(.testingPatience, at: now) { new.append(.testingPatience) }
        return new
    }

    private func unlock(_ b: Badge, at now: Date) -> Bool {
        guard earned[b.rawValue] == nil else { return false }
        earned[b.rawValue] = now
        d.set(earned.mapValues { $0.timeIntervalSince1970 }, forKey: "badges")
        return true
    }

    private func updateStreak(_ now: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        if let last = streakDay {
            let gap = cal.dateComponents([.day], from: last, to: today).day ?? 0
            if gap == 0 { return }
            streak = gap == 1 ? streak + 1 : 1
        } else {
            streak = 1
        }
        streakDay = today
        bestStreak = max(bestStreak, streak)
        d.set(streak, forKey: "badgeStreak")
        d.set(today.timeIntervalSince1970, forKey: "badgeStreakDay")
        d.set(bestStreak, forKey: "badgeBestStreak")
    }

    /// The language of a piece of text, when it's long enough to tell and clear-cut.
    static func language(of text: String) -> String? {
        let sample = String(text.prefix(600))
        guard sample.filter(\.isLetter).count >= 16 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(sample)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.85 else { return nil }
        return lang.rawValue
    }

    func reset() {
        earned = [:]
        languages = []
        bestCombo = 0
        bestStreak = 0
        streak = 0
        streakDay = nil
        for k in ["badges", "badgeLanguages", "badgeBestCombo", "badgeBestStreak", "badgeStreak", "badgeStreakDay"] { d.removeObject(forKey: k) }
    }
}

/// A badge as a round medal: colored when earned, a grey outline with progress when not.
struct BadgeMedal: View {
    let badge: Badge
    var earned: Bool
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle()
                .fill(earned ? AnyShapeStyle(LinearGradient(colors: badge.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                             : AnyShapeStyle(Color.primary.opacity(0.06)))
            Circle().strokeBorder(earned ? Color.white.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: earned ? 1.5 : 1)
            Image(systemName: badge.symbol)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(earned ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary.opacity(0.28)))
        }
        .frame(width: size, height: size)
        .shadow(color: earned ? (badge.colors.last ?? .clear).opacity(0.35) : .clear, radius: 4, y: 2)
    }
}
