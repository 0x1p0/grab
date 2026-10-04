import AppKit
import SwiftUI

/// Code as a picture for sharing: syntax colors on a dark card, in a Grab-gradient frame.
enum CodeImage {
    enum Token: Equatable { case plain, keyword, string, number, comment, type, function }

    struct Piece: Equatable {
        var token: Token
        var text: String
    }

    private static let keywords: Set<String> = [
        // C family, Swift, Kotlin, Java, C#, Go, Rust, JS/TS
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "func", "function",
        "fn", "fun", "def", "class", "struct", "enum", "protocol", "interface", "trait", "impl", "extension", "let", "var",
        "const", "static", "final", "public", "private", "protected", "internal", "fileprivate", "open", "import", "from",
        "export", "package", "module", "use", "using", "namespace", "new", "delete", "try", "catch", "throw", "throws",
        "finally", "guard", "in", "of", "is", "as", "async", "await", "yield", "self", "Self", "this", "super", "nil", "null",
        "undefined", "true", "false", "void", "where", "typealias", "type", "override", "mutating", "lazy", "weak", "inout",
        "init", "deinit", "some", "any", "mut", "match", "loop", "pub", "crate", "go", "defer", "chan", "select", "map",
        "lambda", "pass", "raise", "with", "and", "or", "not", "None", "True", "False", "elif", "except", "global",
        "end", "then", "begin", "rescue", "unless", "until", "local", "nonlocal", "extends", "implements", "abstract",
        "sealed", "data", "object", "val", "when", "typeof", "instanceof",
    ]

    /// Splits code into colored pieces. Approximate on purpose: it only has to look right.
    static func highlight(_ code: String, language: String) -> [Piece] {
        let lang = language.lowercased()
        let hashComments = ["python", "ruby", "shell", "bash", "zsh", "sh", "console", "yaml", "toml", "perl", "r", "elixir", "make", "dockerfile"].contains(lang)
        let dashComments = ["sql", "lua", "haskell"].contains(lang)
        let chars = Array(code)
        var out: [Piece] = []
        func push(_ t: Token, _ s: String) {
            if let last = out.last, last.token == t { out[out.count - 1].text += s } else { out.append(Piece(token: t, text: s)) }
        }
        var i = 0
        let n = chars.count
        func peek(_ k: Int) -> Character? { i + k < n ? chars[i + k] : nil }
        while i < n {
            let c = chars[i]
            // Comments
            if (c == "/" && peek(1) == "/") || (hashComments && c == "#") || (dashComments && c == "-" && peek(1) == "-") {
                var j = i
                while j < n && chars[j] != "\n" { j += 1 }
                push(.comment, String(chars[i..<j])); i = j; continue
            }
            if c == "/" && peek(1) == "*" {
                var j = i + 2
                while j < n - 1 && !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                j = min(n, j + 2)
                push(.comment, String(chars[i..<j])); i = j; continue
            }
            // Strings
            if c == "\"" || c == "'" || c == "`" {
                let triple = peek(1) == c && peek(2) == c
                var j = i + (triple ? 3 : 1)
                while j < n {
                    if chars[j] == "\\" { j += 2; continue }
                    if triple {
                        if chars[j] == c && j + 2 < n && chars[j + 1] == c && chars[j + 2] == c { j += 3; break }
                    } else if chars[j] == c { j += 1; break }
                    if !triple && chars[j] == "\n" && c != "`" { break }
                    j += 1
                }
                j = min(j, n)
                push(.string, String(chars[i..<j])); i = j; continue
            }
            // Numbers
            if c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < n && (chars[j].isHexDigit || chars[j] == "." || chars[j] == "_" || chars[j] == "x" || chars[j] == "X") { j += 1 }
                push(.number, String(chars[i..<j])); i = j; continue
            }
            // Words
            if c.isLetter || c == "_" || c == "@" || (c == "$" && lang != "php") {
                var j = i + 1
                while j < n && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let word = String(chars[i..<j])
                var k = j
                while k < n && chars[k] == " " { k += 1 }
                let token: Token
                if keywords.contains(word) { token = .keyword }
                else if k < n && chars[k] == "(" { token = .function }
                else if word.first?.isUppercase == true || word.hasPrefix("@") { token = .type }
                else { token = .plain }
                push(token, word); i = j; continue
            }
            push(.plain, String(c)); i += 1
        }
        return out
    }

    private static func color(_ t: Token) -> Color {
        switch t {
        case .plain: Color(hex: 0xE8E6F0)
        case .keyword: Color(hex: 0xFF7AB2)
        case .string: Color(hex: 0xFFB86C)
        case .number: Color(hex: 0xC4A7FF)
        case .comment: Color(hex: 0x7F8399)
        case .type: Color(hex: 0x6FD6FF)
        case .function: Color(hex: 0x8EE59B)
        }
    }

    /// The card, rendered at 2× for crisp sharing.
    @MainActor static func render(_ code: String, language: String, title: String?, firstLine: Int?) -> CGImage? {
        var lines = code.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        if lines.count > 120 { lines = Array(lines.prefix(120)) + ["…"] }
        lines = lines.map { $0.count > 110 ? String($0.prefix(109)) + "…" : $0 }
        let text = lines.joined(separator: "\n")
        var attributed = AttributedString()
        for p in highlight(text, language: language) {
            var a = AttributedString(p.text)
            a.foregroundColor = color(p.token)
            if p.token == .comment { a.font = .system(size: 13, design: .monospaced).italic() }
            attributed += a
        }
        let card = CodeCard(code: attributed, lines: lines.count, firstLine: firstLine, title: title ?? language.capitalizedFirst)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.cgImage
    }
}

private struct CodeCard: View {
    let code: AttributedString
    let lines: Int
    let firstLine: Int?
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack(spacing: 7) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 11, height: 11) }
                    Spacer()
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            HStack(alignment: .top, spacing: 14) {
                if let first = firstLine {
                    Text((0..<lines).map { String(first + $0) }.joined(separator: "\n"))
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundStyle(Color.white.opacity(0.22))
                        .multilineTextAlignment(.trailing)
                        .fixedSize()
                }
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x17161F)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .padding(34)
        .background(LinearGradient(colors: [Color(hex: 0xFF8A3D), Color(hex: 0xEC4F7C), Color(hex: 0x7C5CFF)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
