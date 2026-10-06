import AppKit
import Observation

extension Notification.Name {
    static let grabSettingsChanged = Notification.Name("GrabSettingsChanged")
    /// Settings asks the current mascot to show off.
    static let grabMascotPreview = Notification.Name("GrabMascotPreview")
    /// After every successful grab; the object is a `GrabEvent`.
    static let grabDidCopy = Notification.Name("GrabDidCopy")
}

/// What was just grabbed, for the practice checklist and stats.
struct GrabEvent {
    var mode: GrabMode
    var text: String?
    var color: RGBAColor?
    var bundleID: String?
    var codeKind: String?
    var ocr: Bool
    var box: Bool
    var appended: Bool
    var format: String?
    var pixels: Int
}

/// Light, dark, or whatever macOS is set to.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// What you hold to grab.
enum Trigger: String, CaseIterable, Identifiable {
    case option, rightOption, controlOption, hyper
    var id: String { rawValue }

    var title: String {
        switch self {
        case .option: "Option"
        case .rightOption: "Right Option only"
        case .controlOption: "Control-Option"
        case .hyper: "Hyper"
        }
    }

    var detail: String {
        switch self {
        case .option: "Either ⌥ key."
        case .rightOption: "Left ⌥ stays free for typing characters like @ [ ] { } on many keyboards."
        case .controlOption: "⌃ and ⌥ together. VoiceOver uses this pair too."
        case .hyper: "⌃⌥⇧⌘ together, for a Hyper key set up with Karabiner or similar. ⇧-shortcuts aren't available."
        }
    }

    /// Key caps, for drawing.
    var keys: [String] {
        switch self {
        case .option: ["⌥"]
        case .rightOption: ["right ⌥"]
        case .controlOption: ["⌃", "⌥"]
        case .hyper: ["⌃", "⌥", "⇧", "⌘"]
        }
    }

    /// For running text: "Hold ⌥", "Hold right ⌥".
    var symbol: String {
        switch self {
        case .option: "⌥"
        case .rightOption: "right ⌥"
        case .controlOption: "⌃⌥"
        case .hyper: "⌃⌥⇧⌘"
        }
    }

    /// The trigger plus a key, as running text: "⌥C", "right ⌥C".
    func chord(_ key: String) -> String { symbol + key }

    /// ⌥⇧C and friends need ⇧ to be free.
    var allowsShift: Bool { self != .hyper }

    static var current: Trigger { Settings.shared.trigger }
}

/// User preferences, persisted to UserDefaults.
@Observable
final class Settings {
    static let shared = Settings()

    @ObservationIgnored private let d = UserDefaults.standard

    var soundEnabled: Bool { didSet { save("soundEnabled", soundEnabled) } }
    var soundVolume: Double { didSet { save("soundVolume", soundVolume) } }
    var hapticsEnabled: Bool { didSet { save("hapticsEnabled", hapticsEnabled) } }
    var spotlight: Bool { didSet { save("spotlight", spotlight) } }
    var showHints: Bool { didSet { save("showHints", showHints) } }
    var armDelay: Double { didSet { save("armDelay", armDelay) } }
    var trigger: Trigger { didSet { save("trigger", trigger.rawValue) } }
    var quickCopy: Bool { didSet { save("quickCopy", quickCopy) } }
    var paused: Bool { didSet { save("paused", paused) } }
    var colorFormat: ColorFormat { didSet { save("colorFormat", colorFormat.rawValue) } }
    /// Copied images get softly rounded corners.
    var roundImageCorners: Bool { didSet { save("roundImageCorners", roundImageCorners) } }
    var historyLimit: Int { didSet { save("historyLimit", historyLimit) } }
    /// Save history between launches, encrypted (off: memory only).
    var keepHistory: Bool { didSet { save("keepHistory", keepHistory) } }
    var keepHistoryDays: Int { didSet { save("keepHistoryDays", keepHistoryDays) } }
    /// The border, HUD and mascot show up in screen sharing and recordings (Grab's own
    /// captures leave them out either way).
    var overlayInRecordings: Bool { didSet { save("overlayInRecordings", overlayInRecordings) } }
    /// Bundle identifiers where holding ⌥ should be left alone.
    var excludedApps: [String] { didSet { save("excludedApps", excludedApps) } }
    /// Last-used format per family ("code" → "markdown"…).
    var formatChoices: [String: String] { didSet { save("formatChoices", formatChoices) } }
    /// Search engine for "search this" (⌥⏎ on text, error searches).
    var searchEngine: String { didSet { save("searchEngine", searchEngine) } }
    /// Offer prices in your currency (fetches daily ECB rates; only currency codes are sent).
    var currencyConversion: Bool { didSet { save("currencyConversion", currencyConversion) } }
    /// Code pasted into a terminal loses its prompts; into chat apps it gets a code fence.
    var adaptivePaste: Bool { didSet { save("adaptivePaste", adaptivePaste) } }
    /// Secrets (API keys, tokens, passwords) are hidden from clipboard managers and cleared after a minute.
    var protectSecrets: Bool { didSet { save("protectSecrets", protectSecrets) } }
    /// A light tick on the trackpad when the border snaps to something new.
    var snapHaptics: Bool { didSet { save("snapHaptics", snapHaptics) } }
    /// Preferred grab type per app (bundle identifier → GrabMode raw value).
    var appRules: [String: Int] { didSet { save("appRules", appRules) } }
    /// Who carries each grab to the menu bar (`MascotKind` raw value).
    var mascot: String { didSet { save("mascot", mascot) } }
    /// Mascots dress up for Halloween and the holidays.
    var seasonal: Bool { didSet { save("seasonal", seasonal) } }
    /// Grab's own look: follow the system, or always light or dark.
    var appearance: AppAppearance { didSet { save("appearance", appearance.rawValue) } }
    /// On Macs with a notch, grabs are carried into it instead of to the menu bar icon.
    var notchCatch: Bool { didSet { save("notchCatch", notchCatch) } }
    /// The mascot peeks out from under the menu bar while ⌥ is held.
    var mascotPeek: Bool { didSet { save("mascotPeek", mascotPeek) } }
    /// Sunglasses at 100 grabs, a crown at 1,000.
    var wearOutfits: Bool { didSet { save("wearOutfits", wearOutfits) } }
    /// Quick grabs in a row make a combo: rising sounds, a burst every fifth.
    var combos: Bool { didSet { save("combos", combos) } }
    /// Your own ⇥ formats: templates and Shortcuts.
    var customFormats: [CustomFormat] {
        didSet { save("customFormats", (try? JSONEncoder().encode(customFormats)) ?? Data()) }
    }
    /// Look for a new version on GitHub about once a day.
    var checkForUpdates: Bool { didSet { save("checkForUpdates", checkForUpdates) } }
    var skippedVersion: String { didSet { d.set(skippedVersion, forKey: "skippedVersion") } }
    var grabCount: Int { didSet { d.set(grabCount, forKey: "grabCount") } }
    var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }

    private init() {
        d.register(defaults: [
            "soundEnabled": true,
            "soundVolume": 0.7,
            "hapticsEnabled": true,
            "spotlight": true,
            "showHints": true,
            "armDelay": 0.18,
            "trigger": Trigger.option.rawValue,
            "quickCopy": true,
            "paused": false,
            "colorFormat": ColorFormat.hex.rawValue,
            "roundImageCorners": true,
            "historyLimit": 12,
            "keepHistory": false,
            "keepHistoryDays": 7,
            "overlayInRecordings": true,
            "excludedApps": [String](),
            "formatChoices": [String: String](),
            "searchEngine": "google",
            "currencyConversion": true,
            "adaptivePaste": true,
            "protectSecrets": true,
            "snapHaptics": true,
            "appRules": [String: Int](),
            "mascot": "snap",
            "seasonal": true,
            "appearance": AppAppearance.system.rawValue,
            "notchCatch": true,
            "mascotPeek": true,
            "wearOutfits": true,
            "combos": true,
            "checkForUpdates": true,
            "skippedVersion": "",
            "grabCount": 0,
            "hasOnboarded": false,
        ])
        soundEnabled = d.bool(forKey: "soundEnabled")
        soundVolume = d.double(forKey: "soundVolume")
        hapticsEnabled = d.bool(forKey: "hapticsEnabled")
        spotlight = d.bool(forKey: "spotlight")
        showHints = d.bool(forKey: "showHints")
        armDelay = d.double(forKey: "armDelay")
        trigger = Trigger(rawValue: d.string(forKey: "trigger") ?? "") ?? .option
        quickCopy = d.bool(forKey: "quickCopy")
        paused = d.bool(forKey: "paused")
        colorFormat = ColorFormat(rawValue: d.string(forKey: "colorFormat") ?? "") ?? .hex
        roundImageCorners = d.bool(forKey: "roundImageCorners")
        historyLimit = d.integer(forKey: "historyLimit")
        keepHistory = d.bool(forKey: "keepHistory")
        keepHistoryDays = d.integer(forKey: "keepHistoryDays")
        overlayInRecordings = d.bool(forKey: "overlayInRecordings")
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        formatChoices = d.dictionary(forKey: "formatChoices") as? [String: String] ?? [:]
        searchEngine = d.string(forKey: "searchEngine") ?? "google"
        currencyConversion = d.bool(forKey: "currencyConversion")
        adaptivePaste = d.bool(forKey: "adaptivePaste")
        protectSecrets = d.bool(forKey: "protectSecrets")
        snapHaptics = d.bool(forKey: "snapHaptics")
        appRules = d.dictionary(forKey: "appRules") as? [String: Int] ?? [:]
        mascot = d.string(forKey: "mascot") ?? "snap"
        seasonal = d.bool(forKey: "seasonal")
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        notchCatch = d.bool(forKey: "notchCatch")
        mascotPeek = d.bool(forKey: "mascotPeek")
        wearOutfits = d.bool(forKey: "wearOutfits")
        combos = d.bool(forKey: "combos")
        customFormats = d.data(forKey: "customFormats").flatMap { try? JSONDecoder().decode([CustomFormat].self, from: $0) } ?? []
        checkForUpdates = d.bool(forKey: "checkForUpdates")
        skippedVersion = d.string(forKey: "skippedVersion") ?? ""
        grabCount = d.integer(forKey: "grabCount")
        hasOnboarded = d.bool(forKey: "hasOnboarded")
    }

    private func save(_ key: String, _ value: Any) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: .grabSettingsChanged, object: nil)
    }
}
