import AppKit
import AVFoundation

/// Grab's sounds are synthesised at launch: no audio files, no licensing, and they
/// can be tuned like an instrument.
final class Sound {
    static let shared = Sound()

    enum Effect: CaseIterable {
        case copy, tick, scope, bump, error
    }

    private var pools: [Effect: [AVAudioPlayer]] = [:]
    private var cursor: [Effect: Int] = [:]

    func prepare() {
        guard pools.isEmpty else { return }
        for effect in Effect.allCases {
            let data = Synth.wav(Synth.render(effect))
            pools[effect] = (0..<3).compactMap { _ in
                let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                p?.prepareToPlay()
                return p
            }
        }
    }

    func play(_ effect: Effect) {
        let s = Settings.shared
        guard s.soundEnabled, let pool = pools[effect], !pool.isEmpty else { return }
        let i = (cursor[effect] ?? 0) % pool.count
        cursor[effect] = i + 1
        let p = pool[i]
        p.volume = Float(s.soundVolume) * Self.gain(effect)
        p.currentTime = 0
        p.play()
    }

    private static func gain(_ e: Effect) -> Float {
        switch e {
        case .copy: 0.9
        case .tick: 0.45
        case .scope: 0.45
        case .bump: 0.5
        case .error: 0.7
        }
    }
}

enum Haptics {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard Settings.shared.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// A tiny additive synthesiser.
enum Synth {
    static let rate = 44_100.0

    private struct Note {
        var freq: Double
        var start: Double
        var amp: Double
        var decay: Double
        var attack = 0.0025
        var harmonics: [(Double, Double)] = [(2, 0.28), (3.01, 0.06)]
        var glide = 0.0
    }

    static func render(_ e: Sound.Effect) -> [Float] {
        switch e {
        case .copy:
            // A bright two-note "ti-ding": E6 then B6, glassy and quick.
            return mix(duration: 0.45, notes: [
                Note(freq: 1318.51, start: 0, amp: 0.42, decay: 0.07),
                Note(freq: 1975.53, start: 0.052, amp: 0.4, decay: 0.15),
                Note(freq: 2637.02, start: 0.052, amp: 0.05, decay: 0.05, harmonics: []),
            ], click: 0.12, peak: 0.6)
        case .tick:
            return mix(duration: 0.05, notes: [
                Note(freq: 2637.02, start: 0, amp: 0.35, decay: 0.010, attack: 0.0006, harmonics: []),
                Note(freq: 1318.51, start: 0, amp: 0.12, decay: 0.016, attack: 0.0006, harmonics: []),
            ], click: 0.05, peak: 0.35)
        case .scope:
            return mix(duration: 0.07, notes: [
                Note(freq: 1760, start: 0, amp: 0.32, decay: 0.016, attack: 0.0008, harmonics: [(2, 0.1)], glide: -0.08),
                Note(freq: 880, start: 0, amp: 0.1, decay: 0.022, attack: 0.0008, harmonics: []),
            ], click: 0.04, peak: 0.34)
        case .bump:
            return mix(duration: 0.08, notes: [
                Note(freq: 330, start: 0, amp: 0.4, decay: 0.03, attack: 0.001, harmonics: [(2, 0.2)]),
            ], click: 0.0, peak: 0.35)
        case .error:
            return mix(duration: 0.32, notes: [
                Note(freq: 392.0, start: 0, amp: 0.38, decay: 0.06, harmonics: [(2, 0.25), (3, 0.1)]),
                Note(freq: 311.13, start: 0.075, amp: 0.38, decay: 0.09, harmonics: [(2, 0.25), (3, 0.1)]),
            ], click: 0.0, peak: 0.45)
        }
    }

    private static func mix(duration: Double, notes: [Note], click: Double, peak: Double) -> [Float] {
        let n = Int(duration * rate)
        var out = [Double](repeating: 0, count: n)
        for note in notes {
            let first = Int(note.start * rate)
            var phase = 0.0
            for i in first..<n {
                let t = Double(i - first) / rate
                let env = (1 - exp(-t / note.attack)) * exp(-t / note.decay)
                if env < 0.0001 && t > note.attack * 4 { break }
                let f = note.freq * (1 + note.glide * min(1, t / 0.04))
                phase += 2 * .pi * f / rate
                var v = sin(phase)
                for (mult, a) in note.harmonics { v += a * sin(phase * mult + 0.3) }
                out[i] += note.amp * env * v
            }
        }
        if click > 0 {
            // Deterministic noise burst for a crisp transient.
            var seed: UInt32 = 0x9E3779B9
            for i in 0..<min(n, Int(0.004 * rate)) {
                seed = seed &* 1664525 &+ 1013904223
                let noise = Double(seed) / Double(UInt32.max) * 2 - 1
                out[i] += noise * click * exp(-(Double(i) / rate) / 0.0007)
            }
        }
        // Fade the tail and normalise.
        let fade = min(n, Int(0.01 * rate))
        for i in 0..<fade { out[n - 1 - i] *= Double(i) / Double(fade) }
        let maxV = out.map(abs).max() ?? 1
        let k = maxV > 0 ? peak / maxV : 1
        return out.map { Float($0 * k) }
    }

    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}
