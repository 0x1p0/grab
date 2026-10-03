import AVFoundation
import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the on-device model can do with a grab.
enum AssistTask: String, CaseIterable, Identifiable {
    case explain, summarize, fix, extract, translate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .explain: "Explain"
        case .summarize: "Summary"
        case .fix: "Fix"
        case .extract: "JSON"
        case .translate: "Translate"
        }
    }

    var symbol: String {
        switch self {
        case .explain: "lightbulb"
        case .summarize: "text.badge.star"
        case .fix: "wand.and.stars"
        case .extract: "curlybraces"
        case .translate: "translate"
        }
    }

    var instructions: String {
        switch self {
        case .explain:
            "Explain the user's text clearly and concisely for someone who just came across it. If it is code, say what it does and point out anything notable. If it is an error message, say what it means and the most likely fix. Use short paragraphs or a few bullets. No preamble."
        case .summarize:
            "Summarize the user's text in two to four short bullet points that capture the key facts. No preamble."
        case .fix:
            "The user's text was captured from the screen with OCR and may contain recognition errors: broken hyphenation, merged or split words, wrong characters, stray line breaks. Return only the corrected text. Preserve the original wording, meaning, language and paragraph structure. Do not add commentary."
        case .extract:
            "Extract the structured information from the user's text (names, dates, times, prices, quantities, addresses, identifiers, contact details) as one JSON object with concise camelCase keys. Return only the JSON, without code fences."
        case .translate:
            "Translate the user's text into English. Return only the translation."
        }
    }
}

/// Apple's on-device language model: nothing leaves the Mac.
enum Assistant {
    /// Nil when available, otherwise why not.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to use this."
                case .modelNotReady: return "Apple Intelligence is still getting ready. Try again in a bit."
                @unknown default: return "Apple Intelligence isn't available right now."
                }
            }
        }
        #endif
        return "Needs macOS 26 with Apple Intelligence."
    }

    static func run(_ task: AssistTask, text: String, question: String? = nil) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let why = unavailableReason { throw GrabError.failed(why) }
            // The on-device model has a small context window.
            let input = text.count > 6_000 ? String(text.prefix(6_000)) + "\n…" : text
            let instructions = question.map { _ in
                "Answer the user's question about the text they provide. Be concise and specific. No preamble."
            } ?? task.instructions
            let session = LanguageModelSession(instructions: instructions)
            let prompt = question.map { "Question: \($0)\n\nText:\n\(input)" } ?? input
            let response = try await session.respond(to: prompt)
            var out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if task == .extract && question == nil {
                out = out.replacingOccurrences(of: #"^```(?:json)?\s*|\s*```$"#, with: "", options: .regularExpression)
                if let pretty = SmartTypes.prettyJSON(out) { out = pretty }
            }
            return out
        }
        #endif
        throw GrabError.failed(unavailableReason ?? "Not available")
    }
}

/// Reads grabs aloud with the system voice.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    var onChange: ((Bool) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }

    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: String(text.prefix(20_000)))
        if let lang = NLLanguage.detect(text) { u.voice = AVSpeechSynthesisVoice(language: lang) }
        synth.speak(u)
        onChange?(true)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        onChange?(false)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onChange?(false) }
    }
}

enum NLLanguage {
    /// BCP-47 code of the text's dominant language, when it's clear.
    static func detect(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(2_000)))
        guard let lang = r.dominantLanguage, let p = r.languageHypotheses(withMaximum: 1)[lang], p > 0.6 else { return nil }
        return lang.rawValue
    }
}
