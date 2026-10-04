import AppKit

/// The mascot's life between trips: whether it's awake, how fired up it is, what it's
/// wearing, and whether it has had enough of being poked.
@Observable
final class Buddy {
    static let shared = Buddy()

    enum Mood: Equatable {
        case normal
        /// No grabs for a while: it nods off, and wakes with a start when you hold ⌥.
        case sleepy
        /// 20 or more grabs today.
        case pumped
        /// Poked one time too many: gone for a minute.
        case away
    }

    /// What it's wearing right now.
    struct Outfit: Equatable {
        var shades = false
        var crown = false
        var nightcap = false
    }

    enum PetReaction: Equatable {
        case giggle(Int)
        case annoyed
    }

    static let sleepAfter: TimeInterval = 30 * 60
    static let comboWindow: TimeInterval = 5
    static let pumpedAt = 20
    static let petsUntilAnnoyed = 5
    static let awayFor: TimeInterval = 60
    static let shadesAt = 100
    static let crownAt = 1_000

    @ObservationIgnored private let d: UserDefaults
    /// The last grab or hold of ⌥: sleepiness is measured from here.
    private(set) var lastActive: Date?
    private(set) var awayUntil: Date?
    private(set) var combo = 0
    private(set) var petsTotal: Int
    @ObservationIgnored private var lastGrab: Date?
    @ObservationIgnored private var recentPets: [Date] = []
    @ObservationIgnored private var day: String
    @ObservationIgnored private var dayCount: Int

    init(defaults: UserDefaults = .standard) {
        d = defaults
        let last = d.double(forKey: "buddyLastActive")
        lastActive = last > 0 ? Date(timeIntervalSince1970: last) : nil
        petsTotal = d.integer(forKey: "buddyPets")
        day = d.string(forKey: "buddyDay") ?? ""
        dayCount = d.integer(forKey: "buddyDayCount")
    }

    #if DEBUG
    /// For pictures of every mood and outfit.
    nonisolated(unsafe) static var debugMood: Mood?
    nonisolated(unsafe) static var debugOutfit: Outfit?
    #endif

    func mood(at now: Date = Date()) -> Mood {
        #if DEBUG
        if let m = Self.debugMood { return m }
        #endif
        if let a = awayUntil, now < a { return .away }
        if let last = lastActive, now.timeIntervalSince(last) > Self.sleepAfter { return .sleepy }
        if grabsToday(at: now) >= Self.pumpedAt { return .pumped }
        return .normal
    }

    var isAway: Bool { mood() == .away }

    func grabsToday(at now: Date = Date()) -> Int { Self.dayKey(now) == day ? dayCount : 0 }

    static func isNight(_ now: Date = Date()) -> Bool { (0..<5).contains(Calendar.current.component(.hour, from: now)) }

    func outfit(at now: Date = Date(), total: Int = Stats.shared.total, wear: Bool = Settings.shared.wearOutfits) -> Outfit {
        #if DEBUG
        if let o = Self.debugOutfit { return o }
        #endif
        let night = Self.isNight(now)
        return Outfit(shades: wear && total >= Self.shadesAt && !night, crown: wear && total >= Self.crownAt, nightcap: night)
    }

    /// Holding ⌥ wakes it. Returns whether it had been asleep.
    @discardableResult
    func wake(at now: Date = Date()) -> Bool {
        let wasAsleep = mood(at: now) == .sleepy
        touch(now)
        return wasAsleep
    }

    /// Counts a grab. Returns the combo it makes: 1 alone, 2+ when grabs come within a few seconds of each other.
    @discardableResult
    func grabbed(at now: Date = Date()) -> Int {
        if let last = lastGrab, now.timeIntervalSince(last) <= Self.comboWindow { combo += 1 } else { combo = 1 }
        lastGrab = now
        let key = Self.dayKey(now)
        if key != day { day = key; dayCount = 0 }
        dayCount += 1
        d.set(day, forKey: "buddyDay")
        d.set(dayCount, forKey: "buddyDayCount")
        touch(now)
        return combo
    }

    /// Poked while peeking. Five pokes in a minute and it storms off.
    func pet(at now: Date = Date()) -> PetReaction {
        recentPets = recentPets.filter { now.timeIntervalSince($0) < 60 } + [now]
        petsTotal += 1
        d.set(petsTotal, forKey: "buddyPets")
        touch(now)
        if recentPets.count >= Self.petsUntilAnnoyed {
            recentPets = []
            awayUntil = now.addingTimeInterval(Self.awayFor)
            return .annoyed
        }
        return .giggle(recentPets.count)
    }

    private func touch(_ now: Date) {
        lastActive = now
        d.set(now.timeIntervalSince1970, forKey: "buddyLastActive")
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
