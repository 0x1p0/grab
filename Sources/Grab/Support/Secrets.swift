import Foundation

/// Recognizes API keys, tokens, private keys and passwords so they can be hidden
/// from clipboard managers and cleared from the clipboard after a minute.
enum Secrets {
    private static let patterns: [NSRegularExpression] = [
        #"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----"#,
        #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#,
        #"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{40,}"#,
        #"\bglpat-[A-Za-z0-9_-]{20,}"#,
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_-]{35}\b"#,
        #"\bnpm_[A-Za-z0-9]{36}\b"#,
        #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\."#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func looksSecret(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 8_000 else { return false }
        let ns = t as NSString
        if t.count <= 600, patterns.contains(where: { $0.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil }) {
            return true
        }
        if t.contains("PRIVATE KEY-----") { return true }
        return isRandomToken(t)
    }

    /// One long, high-entropy token mixing cases and digits (not a URL, path or hash).
    static func isRandomToken(_ t: String) -> Bool {
        guard (24...200).contains(t.count), !t.contains(where: \.isWhitespace), !t.contains("://"), !t.hasPrefix("/"),
              t.range(of: #"^[0-9a-fA-F-]+$"#, options: .regularExpression) == nil,
              t.contains(where: \.isUppercase), t.contains(where: \.isLowercase), t.filter(\.isNumber).count >= 2 else { return false }
        // Identifiers read like words: few switches between letters and digits.
        let chars = Array(t)
        let switches = zip(chars, chars.dropFirst()).filter { $0.isNumber != $1.isNumber }.count
        guard switches >= 3 else { return false }
        var counts: [Character: Int] = [:]
        for c in t { counts[c, default: 0] += 1 }
        let n = Double(t.count)
        let entropy = counts.values.reduce(0.0) { e, c in let p = Double(c) / n; return e - p * log2(p) }
        return entropy >= 4.3
    }
}
