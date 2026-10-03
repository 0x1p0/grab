import Foundation

/// Recognises useful things written in text right under the cursor: colors
/// (`#ED6E2A`, `rgb(237, 110, 42)`, `0xED6E2A`) and file paths (`~/Projects/a.swift:12`).
enum SmartData {
    private static let colorPatterns: [NSRegularExpression] = [
        #"#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![0-9a-zA-Z])"#,
        #"0x[0-9a-fA-F]{6}(?![0-9a-zA-Z])"#,
        #"rgba?\(\s*\d{1,3}%?\s*[, ]\s*\d{1,3}%?\s*[, ]\s*\d{1,3}%?\s*(?:[,/]\s*[\d.]+%?\s*)?\)"#,
        #"hsla?\(\s*[\d.]+(?:deg)?\s*[, ]\s*[\d.]+%\s*[, ]\s*[\d.]+%\s*(?:[,/]\s*[\d.]+%?\s*)?\)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let pathPatterns: [NSRegularExpression] = [
        #"(?<![A-Za-z0-9_.~@-])(?:~|\.{1,2})?/[^\s'"`<>|*?,;()\[\]{}]+"#,
        #"[A-Za-z0-9_.@-]+(?:/[A-Za-z0-9_.@-]+)+"#,
        #"[A-Za-z0-9_@-][A-Za-z0-9_.@-]*\.(?:swift|py|js|mjs|cjs|ts|tsx|jsx|json|md|txt|html|css|scss|rb|go|rs|java|kt|kts|c|h|cc|cpp|hpp|m|mm|yml|yaml|toml|sh|zsh|bash|plist|xml|csv|png|jpe?g|gif|svg|webp|pdf|zip|log|lock|env|sql|vue|svelte|lua|ex|exs|php|cs|dart|ini|conf|gradle|xcconfig|storyboard|xib|entitlements|strings)(?![A-Za-z0-9])(?::\d+(?::\d+)?)?"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// The match in `line` covering UTF-16 column `col`, if any.
    private static func match(_ patterns: [NSRegularExpression], in line: String, at col: Int) -> String? {
        let ns = line as NSString
        for re in patterns {
            for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            where m.range.location <= col && col < NSMaxRange(m.range) + 1 {
                return ns.substring(with: m.range)
            }
        }
        return nil
    }

    static func color(in line: String, at col: Int) -> RGBAColor? {
        guard let s = match(colorPatterns, in: line, at: col) else { return nil }
        return parseColor(s)
    }

    static func parseColor(_ raw: String) -> RGBAColor? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") || s.hasPrefix("0x") {
            var hex = String(s.dropFirst(s.hasPrefix("#") ? 1 : 2))
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 8 {
                return RGBAColor(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                                 b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
            }
            return RGBAColor(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
        }
        let nums = s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap(Double.init)
        guard nums.count >= 3 else { return nil }
        let alpha = nums.count >= 4 ? (s.contains("%") && nums[3] > 1 ? nums[3] / 100 : nums[3]) : 1
        if s.hasPrefix("rgb") {
            func ch(_ v: Double) -> Double { s.contains("%") && v <= 100 && nums[0...2].allSatisfy({ $0 <= 100 }) ? v / 100 : v / 255 }
            return RGBAColor(r: ch(nums[0]), g: ch(nums[1]), b: ch(nums[2]), a: alpha)
        }
        if s.hasPrefix("hsl") {
            let h = nums[0].truncatingRemainder(dividingBy: 360) / 360, sat = nums[1] / 100, l = nums[2] / 100
            func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
                var t = t0
                if t < 0 { t += 1 }
                if t > 1 { t -= 1 }
                if t < 1 / 6 { return p + (q - p) * 6 * t }
                if t < 1 / 2 { return q }
                if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
                return p
            }
            if sat == 0 { return RGBAColor(r: l, g: l, b: l, a: alpha) }
            let q = l < 0.5 ? l * (1 + sat) : l + sat - l * sat
            let p = 2 * l - q
            return RGBAColor(r: hue(p, q, h + 1 / 3), g: hue(p, q, h), b: hue(p, q, h - 1 / 3), a: alpha)
        }
        return nil
    }

    /// A path-looking token at `col`, resolved against `cwd`. Existence is checked
    /// only when the user actually copies it.
    static func path(in line: String, at col: Int, cwd: URL?) -> URL? {
        guard var token = match(pathPatterns, in: line, at: col), !token.contains("://") else { return nil }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;"))
        // Compiler-style locations: Sources/A.swift:12:4
        if let r = token.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { token.removeSubrange(r) }
        guard token.count >= 2 else { return nil }
        if token.hasPrefix("~") { return URL(fileURLWithPath: (token as NSString).expandingTildeInPath) }
        if token.hasPrefix("/") {
            // Bare "/" fragments (fractions, dates) aren't paths.
            return token.filter({ $0 == "/" }).count >= 2 || token.count > 4 ? URL(fileURLWithPath: token) : nil
        }
        guard let cwd else { return nil }
        // Relative paths need a slash, or a file extension we know (main.swift, README.md).
        if !token.contains("/") {
            guard let re = pathPatterns.last,
                  re.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length))?.range.length == (token as NSString).length
            else { return nil }
        }
        // a.b/c.d style member chains in code aren't paths unless they look like one.
        if token.contains("/") && !token.contains(".") && token.filter({ $0 == "/" }).count < 2 { return nil }
        return cwd.appendingPathComponent(token).standardizedFileURL
    }
}
