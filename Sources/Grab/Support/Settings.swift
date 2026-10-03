import Foundation
import Observation

extension Notification.Name {
    static let grabSettingsChanged = Notification.Name("GrabSettingsChanged")
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
    var quickCopy: Bool { didSet { save("quickCopy", quickCopy) } }
    var paused: Bool { didSet { save("paused", paused) } }
    var colorFormat: ColorFormat { didSet { save("colorFormat", colorFormat.rawValue) } }
    var historyLimit: Int { didSet { save("historyLimit", historyLimit) } }
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
            "quickCopy": true,
            "paused": false,
            "colorFormat": ColorFormat.hex.rawValue,
            "historyLimit": 12,
            "overlayInRecordings": false,
            "excludedApps": [String](),
            "formatChoices": [String: String](),
            "searchEngine": "google",
            "currencyConversion": true,
            "adaptivePaste": true,
            "protectSecrets": true,
            "snapHaptics": true,
            "appRules": [String: Int](),
            "grabCount": 0,
            "hasOnboarded": false,
        ])
        soundEnabled = d.bool(forKey: "soundEnabled")
        soundVolume = d.double(forKey: "soundVolume")
        hapticsEnabled = d.bool(forKey: "hapticsEnabled")
        spotlight = d.bool(forKey: "spotlight")
        showHints = d.bool(forKey: "showHints")
        armDelay = d.double(forKey: "armDelay")
        quickCopy = d.bool(forKey: "quickCopy")
        paused = d.bool(forKey: "paused")
        colorFormat = ColorFormat(rawValue: d.string(forKey: "colorFormat") ?? "") ?? .hex
        historyLimit = d.integer(forKey: "historyLimit")
        overlayInRecordings = d.bool(forKey: "overlayInRecordings")
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        formatChoices = d.dictionary(forKey: "formatChoices") as? [String: String] ?? [:]
        searchEngine = d.string(forKey: "searchEngine") ?? "google"
        currencyConversion = d.bool(forKey: "currencyConversion")
        adaptivePaste = d.bool(forKey: "adaptivePaste")
        protectSecrets = d.bool(forKey: "protectSecrets")
        snapHaptics = d.bool(forKey: "snapHaptics")
        appRules = d.dictionary(forKey: "appRules") as? [String: Int] ?? [:]
        grabCount = d.integer(forKey: "grabCount")
        hasOnboarded = d.bool(forKey: "hasOnboarded")
    }

    private func save(_ key: String, _ value: Any) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: .grabSettingsChanged, object: nil)
    }
}
