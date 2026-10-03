import Foundation

// MARK: - Languages

/// Just enough about a language to find its strings, comments, blocks and functions.
struct CodeLanguage: Equatable {
    enum Blocks: Equatable { case braces, indentation, endKeyword, lines }

    var name: String
    var blocks: Blocks
    var lineComments: [String]
    var blockOpen: String?
    var blockClose: String?
    var tripleQuotes = false
    var backtickStrings = false
    var singleQuoteStrings = true

    static let swift = CodeLanguage(name: "swift", blocks: .braces, lineComments: ["//"], blockOpen: "/*", blockClose: "*/", tripleQuotes: true, singleQuoteStrings: false)
    static let javascript = CodeLanguage(name: "javascript", blocks: .braces, lineComments: ["//"], blockOpen: "/*", blockClose: "*/", backtickStrings: true)
    static let typescript = CodeLanguage(name: "typescript", blocks: .braces, lineComments: ["//"], blockOpen: "/*", blockClose: "*/", backtickStrings: true)
    static let cLike = CodeLanguage(name: "c", blocks: .braces, lineComments: ["//"], blockOpen: "/*", blockClose: "*/")
    static let go = CodeLanguage(name: "go", blocks: .braces, lineComments: ["//"], blockOpen: "/*", blockClose: "*/", backtickStrings: true)
    static let rust = CodeLanguage(name: "rust", blocks: .braces, lineComments: ["//"], blockOpen: "/*", blockClose: "*/")
    static let kotlin = CodeLanguage(name: "kotlin", blocks: .braces, lineComments: ["//"], blockOpen: "/*", blockClose: "*/", tripleQuotes: true)
    static let css = CodeLanguage(name: "css", blocks: .braces, lineComments: [], blockOpen: "/*", blockClose: "*/")
    static let python = CodeLanguage(name: "python", blocks: .indentation, lineComments: ["#"], tripleQuotes: true)
    static let yaml = CodeLanguage(name: "yaml", blocks: .indentation, lineComments: ["#"])
    static let ruby = CodeLanguage(name: "ruby", blocks: .endKeyword, lineComments: ["#"])
    static let lua = CodeLanguage(name: "lua", blocks: .endKeyword, lineComments: ["--"], blockOpen: "--[[", blockClose: "]]")
    static let elixir = CodeLanguage(name: "elixir", blocks: .endKeyword, lineComments: ["#"], tripleQuotes: true)
    static let shell = CodeLanguage(name: "bash", blocks: .braces, lineComments: ["#"])
    static let sql = CodeLanguage(name: "sql", blocks: .lines, lineComments: ["--"], blockOpen: "/*", blockClose: "*/")
    static let markup = CodeLanguage(name: "html", blocks: .lines, lineComments: [], blockOpen: "<!--", blockClose: "-->")
    static let generic = CodeLanguage(name: "", blocks: .braces, lineComments: ["//"], blockOpen: "/*", blockClose: "*/")

    /// From a file extension or a highlighter class name ("language-swift", "lang-py", "highlight-source-ts"…).
    static func named(_ raw: String) -> CodeLanguage? {
        var n = raw.lowercased()
        for prefix in ["language-", "lang-", "highlight-source-", "source-", "hljs-"] where n.hasPrefix(prefix) {
            n = String(n.dropFirst(prefix.count))
        }
        switch n {
        case "swift": return .swift
        case "js", "javascript", "jsx", "mjs", "cjs", "node": return .javascript
        case "ts", "typescript", "tsx", "mts", "cts": return .typescript
        case "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "c++", "objc", "objective-c", "m", "mm", "java", "cs", "csharp",
             "scala", "dart", "groovy", "zig", "php", "sol", "solidity", "proto", "glsl", "metal", "hlsl", "json", "jsonc":
            var l = CodeLanguage.cLike
            l.name = ["h": "c", "hpp": "cpp", "hh": "cpp", "cc": "cpp", "cxx": "cpp", "c++": "cpp", "m": "objc", "mm": "objc", "cs": "csharp", "jsonc": "json"][n] ?? n
            if n == "php" { l.lineComments = ["//", "#"] }
            if n.hasPrefix("json") { l.lineComments = n == "jsonc" ? ["//"] : [] }
            return l
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "kt", "kts", "kotlin": return .kotlin
        case "css", "scss", "sass", "less":
            var l = CodeLanguage.css
            l.name = n
            if n != "css" { l.lineComments = ["//"] }
            return l
        case "py", "pyi", "python", "py3": return .python
        case "yaml", "yml": return .yaml
        case "rb", "ruby", "rake", "gemspec": return .ruby
        case "lua": return .lua
        case "ex", "exs", "elixir": return .elixir
        case "sh", "bash", "zsh", "fish", "shell", "console", "shellsession", "terminal", "ksh": return .shell
        case "sql", "psql", "mysql", "sqlite": return .sql
        case "html", "htm", "xml", "svg", "plist", "vue", "svelte", "xhtml": return .markup
        case "toml", "ini", "conf", "dockerfile", "makefile", "mk":
            var l = CodeLanguage.yaml
            l.name = n
            l.blocks = .lines
            return l
        default: return nil
        }
    }

    static func forFile(_ url: URL) -> CodeLanguage? {
        let base = url.lastPathComponent.lowercased()
        if base == "dockerfile" || base == "makefile" || base == "gemfile" || base == "podfile" || base == "rakefile" {
            return named(base == "gemfile" || base == "podfile" || base == "rakefile" ? "ruby" : base)
        }
        return named(url.pathExtension)
    }

    /// Best guess from the code itself.
    static func guess(_ text: String) -> CodeLanguage {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(400)
        var colonHeaders = 0, braces = 0, ends = 0, swiftish = 0, jsish = 0
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("{") || t == "}" { braces += 1 }
            if t.hasSuffix(":"), t.hasPrefix("def ") || t.hasPrefix("class ") || t.hasPrefix("if ") || t.hasPrefix("for ") || t.hasPrefix("elif ") || t == "else:" || t.hasPrefix("with ") || t.hasPrefix("async def ") {
                colonHeaders += 1
            }
            if t == "end" { ends += 1 }
            if t.hasPrefix("func ") || t.hasPrefix("guard ") || t.contains(" -> ") && !t.contains("=>") { swiftish += 1 }
            if t.contains("=> ") || t.hasPrefix("const ") || t.hasPrefix("function ") || t.hasPrefix("export ") { jsish += 1 }
        }
        if colonHeaders > braces { return .python }
        if ends > braces && ends > 0 { return .ruby }
        if swiftish > jsish { return .swift }
        if jsish > 0 { return .javascript }
        return .generic
    }
}

// MARK: - Scopes

struct CodeScope: Equatable {
    enum Kind: String, Equatable {
        case symbol, expression, string, comment, line, statement, block, function, type, command, output, file
    }

    var kind: Kind
    /// What gets highlighted.
    var range: NSRange
    /// What gets copied (may be narrower, e.g. a string's contents).
    var copyRange: NSRange
    var label: String
    var firstLine: Int
    var lastLine: Int
}

/// A lexed piece of code, ready to answer "what's around this character?" quickly.
/// Build once per text; ask many times as the cursor moves.
final class CodeAnalysis {
    let text: NSString
    let language: CodeLanguage
    let isTerminal: Bool

    private let u: [unichar]
    /// 0 = code, 1 = string, 2 = comment, per UTF-16 unit.
    private var mask: [UInt8]
    private(set) var lineStarts: [Int] = [0]
    /// Matched bracket pairs (open, close) for each bracket kind.
    private var braces: [(Int, Int)] = []
    private var parens: [(Int, Int)] = []
    private var closeOfOpen: [Int: Int] = [:]
    private var openOfClose: [Int: Int] = [:]

    init(text: String, language: CodeLanguage, terminal: Bool = false) {
        self.text = text as NSString
        self.language = language
        self.isTerminal = terminal
        self.u = Array(text.utf16)
        self.mask = [UInt8](repeating: 0, count: u.count)
        for (i, c) in u.enumerated() where c == 10 { lineStarts.append(i + 1) }
        if !terminal { lex() }
    }

    var lineCount: Int { lineStarts.count }

    // MARK: Lexing

    private func matches(_ s: String, at i: Int) -> Bool {
        var j = i
        for c in s.utf16 {
            guard j < u.count, u[j] == c else { return false }
            j += 1
        }
        return true
    }

    private func lex() {
        let n = u.count
        let quote: unichar = 34, apostrophe: unichar = 39, backtick: unichar = 96, backslash: unichar = 92, newline: unichar = 10
        var stack: [(Int, unichar)] = []
        var i = 0
        func mark(_ from: Int, _ to: Int, _ v: UInt8) {
            let end = min(to, n)
            if from < end { for k in from..<end { mask[k] = v } }
        }
        func isWordChar(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }

        scan: while i < n {
            let c = u[i]
            for lc in language.lineComments where matches(lc, at: i) {
                // "#" only starts a comment at a word boundary (not `$#`, `${#a}`, `a#b`).
                if lc == "#", i > 0, isWordChar(u[i - 1]) || u[i - 1] == 36 || u[i - 1] == 123 { continue }
                var j = i
                while j < n && u[j] != newline { j += 1 }
                mark(i, j, 2)
                i = j
                continue scan
            }
            if let open = language.blockOpen, let close = language.blockClose, matches(open, at: i) {
                var j = i + open.utf16.count
                while j < n && !matches(close, at: j) { j += 1 }
                j = min(n, j + close.utf16.count)
                mark(i, j, 2)
                i = j
                continue
            }
            if language.tripleQuotes, c == quote || c == apostrophe, i + 2 < n, u[i + 1] == c, u[i + 2] == c {
                var j = i + 3
                while j + 2 < n && !(u[j] == c && u[j + 1] == c && u[j + 2] == c) {
                    j += u[j] == backslash ? 2 : 1
                }
                j = min(n, j + 3)
                mark(i, j, 1)
                i = j
                continue
            }
            if c == quote || (c == apostrophe && language.singleQuoteStrings) || (c == backtick && language.backtickStrings) {
                var j = i + 1
                var closed = false
                while j < n {
                    if u[j] == backslash { j += 2; continue }
                    if u[j] == c { closed = true; break }
                    if u[j] == newline && c != backtick { break }
                    j += 1
                }
                if closed {
                    mark(i, j + 1, 1)
                    i = j + 1
                    continue
                }
                if c == apostrophe {
                    // A lone apostrophe (Rust lifetime, prose): not a string.
                    i += 1
                    continue
                }
                mark(i, min(j, n), 1)
                i = j
                continue
            }
            switch c {
            case 40, 91, 123: // ( [ {
                stack.append((i, c))
            case 41, 93, 125: // ) ] }
                let want: unichar = c == 41 ? 40 : (c == 93 ? 91 : 123)
                if let k = stack.lastIndex(where: { $0.1 == want }) {
                    let o = stack[k].0
                    stack.removeSubrange(k...)
                    closeOfOpen[o] = i
                    openOfClose[i] = o
                    if want == 123 { braces.append((o, i)) } else { parens.append((o, i)) }
                }
            default:
                break
            }
            i += 1
        }
    }

    // MARK: Lines

    func line(of offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Full line range without the trailing newline.
    func lineRange(_ l: Int) -> NSRange {
        let start = lineStarts[l]
        var end = l + 1 < lineStarts.count ? lineStarts[l + 1] - 1 : u.count
        if end > start, end - 1 < u.count, u[end - 1] == 13 { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Line range without leading/trailing whitespace.
    func contentRange(_ l: Int) -> NSRange {
        let r = lineRange(l)
        var s = r.location, e = r.location + r.length
        while s < e, u[s] == 32 || u[s] == 9 { s += 1 }
        while e > s, u[e - 1] == 32 || u[e - 1] == 9 { e -= 1 }
        return NSRange(location: s, length: e - s)
    }

    func isBlank(_ l: Int) -> Bool { contentRange(l).length == 0 }

    func indent(_ l: Int) -> Int {
        let r = lineRange(l)
        var col = 0
        for k in r.location..<(r.location + r.length) {
            if u[k] == 32 { col += 1 } else if u[k] == 9 { col += 4 } else { break }
        }
        return col
    }

    func content(_ l: Int) -> String { text.substring(with: contentRange(l)) }

    private func isComment(_ l: Int) -> Bool {
        let r = contentRange(l)
        return r.length > 0 && mask[r.location] == 2
    }

    // MARK: Scopes

    /// Every meaningful scope around `cursor`, smallest first, and which one to pick by default.
    func scopes(at rawCursor: Int) -> (scopes: [CodeScope], defaultIndex: Int) {
        guard !u.isEmpty else { return ([], 0) }
        let cursor = max(0, min(rawCursor, u.count - 1))
        let cl = line(of: cursor)
        var out: [CodeScope] = []

        if isTerminal {
            out += terminalScopes(cursor: cursor, line: cl)
        } else {
            out += tokenScopes(cursor: cursor)
        }

        // The line itself.
        let lr = contentRange(cl)
        if lr.length > 0 {
            out.append(CodeScope(kind: .line, range: lr, copyRange: lr, label: isTerminal ? "Line" : "Line \(cl + 1)", firstLine: cl, lastLine: cl))
        }

        var defaultIndexHint: CodeScope?
        if !isTerminal {
            if let st = statementScope(line: cl) { out.append(st) }
            let blocks: [CodeScope]
            switch language.blocks {
            case .braces: blocks = braceBlocks(cursor: cursor, line: cl)
            case .indentation, .endKeyword: blocks = indentBlocks(line: cl)
            case .lines: blocks = []
            }
            out += blocks.filter { $0.firstLine != $0.lastLine }
            // Pointing at a block's header (or its closing line) means "this block".
            let multi = blocks.filter { $0.firstLine != $0.lastLine }
            defaultIndexHint = multi.first { $0.firstLine == cl || headerLines(of: $0).contains(cl) }
                ?? multi.first { $0.lastLine == cl && isClosingLine(cl) }
        }

        let all = NSRange(location: 0, length: u.count)
        let trimmedAll = trimmed(all)
        if trimmedAll.length > 0 {
            out.append(CodeScope(kind: .file, range: trimmedAll, copyRange: trimmedAll, label: isTerminal ? "Everything" : "All",
                                 firstLine: line(of: trimmedAll.location), lastLine: line(of: max(trimmedAll.location, NSMaxRange(trimmedAll) - 1))))
        }

        // Smallest first; identical ranges keep the most meaningful one.
        // When two scopes cover exactly the same text, the higher number wins ("Function · add" beats "All").
        let priority: [CodeScope.Kind: Int] = [.symbol: 0, .expression: 1, .string: 2, .comment: 3, .line: 4, .command: 5,
                                               .statement: 6, .output: 7, .file: 8, .block: 9, .function: 10, .type: 11]
        var unique: [CodeScope] = []
        for s in out.sorted(by: { $0.range.length != $1.range.length ? $0.range.length < $1.range.length : priority[$0.kind]! < priority[$1.kind]! }) {
            if let i = unique.firstIndex(where: { NSEqualRanges($0.range, s.range) }) {
                if priority[s.kind]! > priority[unique[i].kind]! { unique[i] = s }
                continue
            }
            unique.append(s)
        }

        var def = unique.firstIndex { $0.kind == .line } ?? 0
        if isTerminal, let i = unique.firstIndex(where: { $0.kind == .command }) { def = i }
        if let hint = defaultIndexHint, let i = unique.firstIndex(where: { NSEqualRanges($0.range, hint.range) }) { def = i }
        return (unique, def)
    }

    private func trimmed(_ r: NSRange) -> NSRange {
        var s = r.location, e = NSMaxRange(r)
        while s < e, isSpace(u[s]) { s += 1 }
        while e > s, isSpace(u[e - 1]) { e -= 1 }
        return NSRange(location: s, length: e - s)
    }

    private func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    private func isIdent(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127
    }

    private func isClosingLine(_ l: Int) -> Bool {
        let t = content(l)
        guard let f = t.first else { return false }
        if t == "end" || t.hasPrefix("end ") || t == "fi" || t == "done" || t == "esac" { return true }
        return "})]".contains(f) && t.allSatisfy { "})];,.? ".contains($0) }
    }

    // Symbol, member chain / call, string, comment.
    private func tokenScopes(cursor: Int) -> [CodeScope] {
        var out: [CodeScope] = []
        let l = line(of: cursor)
        switch mask[cursor] {
        case 1:
            var s = cursor, e = cursor + 1
            while s > 0, mask[s - 1] == 1 { s -= 1 }
            while e < u.count, mask[e] == 1 { e += 1 }
            let r = NSRange(location: s, length: e - s)
            var inner = r
            // Strip the quotes (and triple quotes / prefixes like r" f" b").
            let q = u[s]
            var openLen = 1
            if s + 2 < e, u[s + 1] == q, u[s + 2] == q { openLen = 3 }
            if e - s >= openLen * 2 { inner = NSRange(location: s + openLen, length: e - s - openLen * 2) }
            out.append(CodeScope(kind: .string, range: r, copyRange: inner, label: "String", firstLine: line(of: s), lastLine: line(of: e - 1)))
        case 2:
            // Consecutive comment lines read as one comment.
            var first = l, last = l
            while first > 0, isComment(first - 1) { first -= 1 }
            while last + 1 < lineCount, isComment(last + 1) { last += 1 }
            var s = cursor, e = cursor + 1
            while s > 0, mask[s - 1] == 2 { s -= 1 }
            while e < u.count, mask[e] == 2 { e += 1 }
            if first != last {
                s = min(s, contentRange(first).location)
                e = max(e, NSMaxRange(contentRange(last)))
            }
            let r = trimmed(NSRange(location: s, length: e - s))
            let doc = text.substring(with: r).hasPrefix("///") || text.substring(with: r).hasPrefix("/**")
            out.append(CodeScope(kind: .comment, range: r, copyRange: r, label: doc ? "Doc comment" : "Comment", firstLine: line(of: r.location), lastLine: line(of: NSMaxRange(r) - 1)))
        default:
            guard isIdent(u[cursor]) else { break }
            var s = cursor, e = cursor + 1
            while s > 0, isIdent(u[s - 1]) { s -= 1 }
            while e < u.count, isIdent(u[e]) { e += 1 }
            let sym = NSRange(location: s, length: e - s)
            let name = text.substring(with: sym)
            out.append(CodeScope(kind: .symbol, range: sym, copyRange: sym, label: "Symbol · \(name)", firstLine: l, lastLine: l))

            // Member chain to the left: a.b?.c::d->e
            var cs = s
            while cs > 0 {
                var k = cs
                if k >= 1, u[k - 1] == 46 { k -= 1 }                                // .
                else if k >= 2, u[k - 2] == 63, u[k - 1] == 46 { k -= 2 }           // ?.
                else if k >= 2, u[k - 2] == 58, u[k - 1] == 58 { k -= 2 }           // ::
                else if k >= 2, u[k - 2] == 45, u[k - 1] == 62 { k -= 2 }           // ->
                else { break }
                // Allow calls/subscripts/optional marks right before the dot: foo().bar, a[0].b, x!.y
                var j = k
                while j > 0, u[j - 1] == 33 || u[j - 1] == 63 { j -= 1 }
                if j > 0, u[j - 1] == 41 || u[j - 1] == 93, let o = openOfClose[j - 1] { j = o }
                guard j > 0, isIdent(u[j - 1]) else { break }
                var w = j
                while w > 0, isIdent(u[w - 1]) { w -= 1 }
                cs = w
            }
            // …and to the right: calls, subscripts and further members.
            var ce = e
            while ce < u.count {
                if u[ce] == 40 || u[ce] == 91, let c = closeOfOpen[ce] { ce = c + 1; continue }
                if u[ce] == 33 || u[ce] == 63, ce + 1 < u.count, u[ce + 1] == 46 { ce += 1 }
                if ce < u.count, u[ce] == 46, ce + 1 < u.count, isIdent(u[ce + 1]) {
                    ce += 1
                    while ce < u.count, isIdent(u[ce]) { ce += 1 }
                    continue
                }
                break
            }
            if cs < s || ce > e {
                let r = NSRange(location: cs, length: ce - cs)
                out.append(CodeScope(kind: .expression, range: r, copyRange: r, label: "Expression", firstLine: line(of: cs), lastLine: line(of: ce - 1)))
            }
        }
        return out
    }

    /// The whole lines needed to balance ( and [ around the cursor's line: multi-line calls, arrays, argument lists.
    private func statementScope(line l: Int) -> CodeScope? {
        var first = l, last = l
        var changed = true
        while changed {
            changed = false
            let lo = lineStarts[first]
            let hi = NSMaxRange(lineRange(last))
            for (o, c) in parens where (o < lo && c >= lo) || (o < hi && c >= hi) || (o >= lo && o < hi && c >= hi) {
                let ol = line(of: o), clL = line(of: c)
                if ol < first { first = ol; changed = true }
                if clL > last { last = clL; changed = true }
            }
        }
        guard first != last else { return nil }
        let r = NSRange(location: contentRange(first).location, length: NSMaxRange(contentRange(last)) - contentRange(first).location)
        return CodeScope(kind: .statement, range: r, copyRange: r, label: "Statement", firstLine: first, lastLine: last)
    }

    private struct Header {
        var firstLine: Int
        var kind: CodeScope.Kind
        var label: String
    }

    private var headerCache: [Int: Header] = [:]

    private func headerLines(of s: CodeScope) -> ClosedRange<Int> {
        // The block's own header lines: from its first line to the line holding its opening brace.
        guard s.kind == .function || s.kind == .type || s.kind == .block else { return s.firstLine...s.firstLine }
        for (o, c) in braces where line(of: c) == s.lastLine {
            let ol = line(of: o)
            if ol >= s.firstLine { return s.firstLine...ol }
        }
        return s.firstLine...s.firstLine
    }

    private func braceBlocks(cursor: Int, line cl: Int) -> [CodeScope] {
        // Blocks containing the cursor, plus a block whose header is the cursor's line.
        var picked: [(Int, Int)] = []
        for (o, c) in braces {
            let containing = o < cursor && cursor <= c
            let ol = line(of: o)
            let headerHere: Bool = {
                guard !containing, ol >= cl else { return false }
                let h = header(forBraceAt: o)
                return h.firstLine <= cl && cl <= ol
            }()
            if containing || headerHere { picked.append((o, c)) }
        }
        var out: [CodeScope] = []
        for (o, c) in picked {
            let h = header(forBraceAt: o)
            var first = h.firstLine
            if h.kind == .function || h.kind == .type { first = attachedDecorations(above: first) }
            var endLine = line(of: c)
            // Pull in `} else {…}` / `} catch {…}` continuations for the whole statement.
            var chainEnd = endLine
            var next = c
            while true {
                let rest = text.substring(with: NSRange(location: next + 1, length: NSMaxRange(lineRange(line(of: next))) - next - 1))
                    .trimmingCharacters(in: .whitespaces)
                guard ["else", "catch", "finally", "except", "elif", "rescue", "ensure"].contains(where: { rest.hasPrefix($0) }),
                      let nb = braces.first(where: { $0.0 > next && line(of: $0.0) == line(of: next) }) else { break }
                next = nb.1
                chainEnd = line(of: next)
            }
            let startLoc = contentRange(first).location
            func scope(_ endL: Int, _ kind: CodeScope.Kind, _ label: String) -> CodeScope {
                let r = NSRange(location: startLoc, length: NSMaxRange(contentRange(endL)) - startLoc)
                return CodeScope(kind: kind, range: r, copyRange: r, label: label, firstLine: first, lastLine: endL)
            }
            // A continuation block (`} else {`) belongs to the statement that started it.
            if content(h.firstLine).hasPrefix("}") {
                if let headPair = braces.first(where: { line(of: $0.1) == h.firstLine && $0.1 < o }) {
                    let head = header(forBraceAt: headPair.0)
                    let headStart = contentRange(head.firstLine).location
                    var e = c
                    while true {
                        let rest = text.substring(with: NSRange(location: e + 1, length: NSMaxRange(lineRange(line(of: e))) - e - 1))
                            .trimmingCharacters(in: .whitespaces)
                        guard ["else", "catch", "finally", "except", "elif", "rescue", "ensure"].contains(where: { rest.hasPrefix($0) }),
                              let nb = braces.first(where: { $0.0 > e && line(of: $0.0) == line(of: e) }) else { break }
                        e = nb.1
                    }
                    let r = NSRange(location: headStart, length: NSMaxRange(contentRange(line(of: e))) - headStart)
                    out.append(CodeScope(kind: .block, range: r, copyRange: r, label: head.label.replacingOccurrences(of: " block", with: " statement"),
                                         firstLine: head.firstLine, lastLine: line(of: e)))
                }
                // The else-part on its own, starting at "else".
                let elseStart = contentRange(h.firstLine).location + 1
                var s = elseStart
                while s < o, u[s] == 32 { s += 1 }
                let r = NSRange(location: s, length: NSMaxRange(contentRange(endLine)) - s)
                out.append(CodeScope(kind: .block, range: r, copyRange: r, label: h.label, firstLine: h.firstLine, lastLine: endLine))
                continue
            }
            out.append(scope(endLine, h.kind, h.label))
            if chainEnd != endLine {
                out.append(scope(chainEnd, .block, h.label.replacingOccurrences(of: " block", with: " statement")))
                endLine = chainEnd
            }
        }
        return out
    }

    private func header(forBraceAt o: Int) -> Header {
        if let h = headerCache[o] { return h }
        var hl = line(of: o)
        // Allman style: the brace sits alone under its header.
        if contentRange(hl).location == o {
            var p = hl - 1
            while p >= 0, isBlank(p) { p -= 1 }
            if p >= 0 { hl = p }
        }
        // Multi-line signatures: start where the parameter list opened.
        let lo = lineStarts[hl]
        var first = hl
        for (po, pc) in parens where pc >= lo && pc < o && po < lo {
            first = min(first, line(of: po))
        }
        let headerText = text.substring(with: NSRange(location: contentRange(first).location, length: o - contentRange(first).location))
        let after = text.substring(with: NSRange(location: o + 1, length: max(0, NSMaxRange(lineRange(line(of: o))) - o - 1)))
        let (kind, label) = CodeAnalysis.classify(header: headerText, afterBrace: after)
        let h = Header(firstLine: first, kind: kind, label: label)
        headerCache[o] = h
        return h
    }

    /// Doc comments, attributes and decorators directly above a declaration belong to it.
    private func attachedDecorations(above l: Int) -> Int {
        var first = l
        var p = l - 1
        while p >= 0, !isBlank(p) {
            let t = content(p)
            let decoration = t.hasPrefix("@") || t.hasPrefix("#[") || t.hasPrefix("///") || t.hasPrefix("//") || t.hasPrefix("/**")
                || t.hasPrefix("*") || t.hasPrefix("*/") || (t.hasPrefix("#") && language.lineComments.contains("#"))
                || t.hasPrefix("[") && t.hasSuffix("]") && language.name == "csharp"
            guard decoration else { break }
            first = p
            p -= 1
        }
        return first
    }

    private func indentBlocks(line cl: Int) -> [CodeScope] {
        var anchor = cl
        while anchor > 0, isBlank(anchor) { anchor -= 1 }
        var out: [CodeScope] = []
        var level = indent(anchor)

        // The cursor's own line may be a header.
        var headers: [Int] = []
        if let next = nextNonBlank(after: anchor), indent(next) > indent(anchor), !isComment(anchor) {
            headers.append(anchor)
        }
        var p = anchor - 1
        while p >= 0 && level > 0 {
            if !isBlank(p), !isComment(p), indent(p) < level {
                headers.append(p)
                level = indent(p)
            }
            p -= 1
        }
        for h in headers {
            let hi = indent(h)
            var last = h
            var k = h + 1
            while k < lineCount {
                if isBlank(k) { k += 1; continue }
                if indent(k) <= hi {
                    if language.blocks == .endKeyword, indent(k) == hi, content(k) == "end" || content(k).hasPrefix("end ") || content(k).hasPrefix("end.") {
                        last = k
                    }
                    break
                }
                last = k
                k += 1
            }
            guard last > h else { continue }
            let (kind, label) = CodeAnalysis.classify(header: content(h), afterBrace: "", indentation: true)
            let first = (kind == .function || kind == .type) ? attachedDecorations(above: h) : h
            let start = contentRange(first).location
            let r = NSRange(location: start, length: NSMaxRange(contentRange(last)) - start)
            out.append(CodeScope(kind: kind, range: r, copyRange: r, label: label, firstLine: first, lastLine: last))
        }
        return out
    }

    private func nextNonBlank(after l: Int) -> Int? {
        var k = l + 1
        while k < lineCount {
            if !isBlank(k) { return k }
            k += 1
        }
        return nil
    }

    // MARK: Terminal

    private static let promptPatterns: [NSRegularExpression] = [
        #"^\S+@\S+[^\n]*?[%$#] "#,
        #"^(?:\([^)\n]+\)\s+)?[^\s]*\s?[❯➜›»λ$%#>] "#,
        #"^PS [^>\n]*> "#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Length of the prompt at the start of a line, if it looks like one.
    func promptLength(_ l: Int) -> Int? {
        let r = lineRange(l)
        let s = text.substring(with: r)
        for re in Self.promptPatterns {
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)), m.range.location == 0 {
                return m.range.length
            }
        }
        return nil
    }

    private func terminalScopes(cursor: Int, line cl: Int) -> [CodeScope] {
        var out: [CodeScope] = []
        // Words in terminals include paths and flags.
        if !isSpace(u[cursor]) {
            var s = cursor, e = cursor + 1
            while s > 0, !isSpace(u[s - 1]) { s -= 1 }
            while e < u.count, !isSpace(u[e]) { e += 1 }
            var r = NSRange(location: s, length: e - s)
            // Shed surrounding quotes/punctuation.
            while r.length > 1, "\"'`,;:()[]".utf16.contains(u[r.location]) { r.location += 1; r.length -= 1 }
            while r.length > 1, "\"'`,;:()[].".utf16.contains(u[NSMaxRange(r) - 1]) { r.length -= 1 }
            out.append(CodeScope(kind: .symbol, range: r, copyRange: r, label: "Word", firstLine: cl, lastLine: cl))
        }
        if let p = promptLength(cl) {
            let lr = lineRange(cl)
            let cmd = trimmed(NSRange(location: lr.location + p, length: max(0, lr.length - p)))
            if cmd.length > 0 {
                out.append(CodeScope(kind: .command, range: cmd, copyRange: cmd, label: "Command", firstLine: cl, lastLine: cl))
            }
            // The command together with its output.
            var last = cl
            var k = cl + 1
            while k < lineCount, promptLength(k) == nil { k += 1 }
            last = k - 1
            while last > cl, isBlank(last) { last -= 1 }
            if last > cl {
                let start = contentRange(cl).location
                let r = NSRange(location: start, length: NSMaxRange(contentRange(last)) - start)
                out.append(CodeScope(kind: .output, range: r, copyRange: r, label: "Command + output", firstLine: cl, lastLine: last))
            }
        } else {
            // Output: everything between the previous prompt and the next one.
            var first = cl, last = cl
            while first > 0, promptLength(first - 1) == nil { first -= 1 }
            while last + 1 < lineCount, promptLength(last + 1) == nil { last += 1 }
            while first < cl, isBlank(first) { first += 1 }
            while last > cl, isBlank(last) { last -= 1 }
            if last > first || first != cl {
                let start = contentRange(first).location
                let r = NSRange(location: start, length: NSMaxRange(contentRange(last)) - start)
                out.append(CodeScope(kind: .output, range: r, copyRange: r, label: "Output", firstLine: first, lastLine: last))
            }
        }
        return out
    }

    // MARK: Text

    /// What to put on the clipboard for a scope: single lines trimmed, blocks dedented.
    func copyText(_ s: CodeScope) -> String {
        if s.kind == .command || s.kind == .symbol || s.kind == .expression || s.kind == .string || s.firstLine == s.lastLine {
            return text.substring(with: s.copyRange)
        }
        // Use whole lines so indentation can be measured, then strip the common indent.
        let start = lineStarts[s.firstLine]
        let end = NSMaxRange(s.copyRange)
        let block = text.substring(with: NSRange(location: start, length: end - start))
        return CodeAnalysis.dedent(block)
    }

    static func dedent(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let cut = indents.min() ?? 0
        return lines.map { line in
            let lead = line.prefix { $0 == " " || $0 == "\t" }.count
            return String(line.dropFirst(min(cut, lead)))
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .newlines)
    }

    // MARK: Classification

    private static let modifiers: Set<String> = [
        "public", "private", "internal", "fileprivate", "open", "static", "final", "override", "class", "mutating",
        "nonmutating", "async", "export", "default", "abstract", "protected", "virtual", "inline", "extern", "pub",
        "unsafe", "const", "readonly", "sealed", "partial", "suspend", "inner", "data", "lazy", "weak", "dynamic",
        "convenience", "required", "nonisolated", "consuming", "borrowing", "declare", "synchronized", "native",
    ]

    private static let controlNames: [String: String] = [
        "if": "if block", "else": "else block", "for": "for loop", "foreach": "for loop", "while": "while loop",
        "repeat": "repeat loop", "do": "do block", "switch": "switch", "match": "match", "guard": "guard",
        "try": "try block", "catch": "catch block", "finally": "finally block", "when": "when", "with": "with block",
        "loop": "loop", "unless": "unless block", "until": "until loop", "select": "select", "defer": "defer block",
        "case": "case", "default": "default case", "elif": "elif block", "except": "except block",
    ]

    private static func firstMatch(_ pattern: String, _ s: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
              m.numberOfRanges > group, m.range(at: group).location != NSNotFound else { return nil }
        return (s as NSString).substring(with: m.range(at: group))
    }

    static func classify(header raw: String, afterBrace: String, indentation: Bool = false) -> (CodeScope.Kind, String) {
        var h = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        while h.hasPrefix("}") { h = String(h.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if h.hasSuffix(":") && indentation { h = String(h.dropLast()) }
        // Drop attributes/decorators and modifiers.
        var words = h.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let w = words.first, w.hasPrefix("@") || w.hasPrefix("#[") || modifiers.contains(w) {
            // `class func` / `class var` in Swift: "class" is a modifier only when followed by func/var.
            if w == "class", words.count > 1, !["func", "var", "let", "subscript"].contains(words[1]) { break }
            words.removeFirst()
        }
        let s = words.joined(separator: " ")
        let first = words.first ?? ""
        let lowerFirst = first.lowercased()

        // Types.
        let typeKinds = ["class", "struct", "enum", "protocol", "interface", "extension", "impl", "trait", "object",
                         "record", "namespace", "module", "actor", "union", "type"]
        if typeKinds.contains(first), words.count > 1 {
            var name = words[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "<" || $0 == ">" }
            if first == "impl", let forIndex = words.firstIndex(of: "for"), forIndex + 1 < words.count {
                name = Substring("\(words[1]) for \(words[forIndex + 1].prefix { $0.isLetter || $0.isNumber || $0 == "_" })")
            }
            let kind = first == "impl" ? "Impl" : first.capitalizedFirst
            return (.type, name.isEmpty ? kind : "\(kind) · \(name)")
        }

        // Functions by keyword.
        if ["func", "function", "def", "fn", "fun", "sub", "proc"].contains(first) || s.hasPrefix("function*") {
            if first == "func", let recv = firstMatch(#"^func\s*\([^)]*\)\s*([A-Za-z_]\w*)"#, s) { return (.function, "Function · \(recv)") }
            let name = words.count > 1 ? String(words[1].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "?" || $0 == "!" }) : ""
            return (.function, name.isEmpty ? "Function" : "Function · \(name)")
        }
        if first == "init" || first.hasPrefix("init(") || first.hasPrefix("init?(") { return (.function, "Initializer") }
        if first == "deinit" { return (.function, "Deinitializer") }
        if first == "subscript" || first.hasPrefix("subscript(") { return (.function, "Subscript") }
        if first == "constructor" || first.hasPrefix("constructor(") { return (.function, "Constructor") }

        // Control flow.
        if lowerFirst == "else", words.count > 1, words[1] == "if" { return (.block, "else if block") }
        let ctl = String(lowerFirst.prefix { $0.isLetter })
        if let name = controlNames[ctl], first.lowercased().hasPrefix(ctl), ctl.count == first.prefix(while: { $0.isLetter }).count {
            return (.block, name)
        }

        // Swift computed properties and accessors.
        if first == "var" || first == "let", let name = firstMatch(#"^(?:var|let)\s+([A-Za-z_]\w*)\s*:"#, s), !s.contains("=") {
            return (.function, "Property · \(name)")
        }
        if ["get", "set", "willSet", "didSet", "_read", "_modify"].contains(first) { return (.block, first) }

        // Closures and lambdas.
        let afterTrim = afterBrace.trimmingCharacters(in: .whitespaces)
        if firstMatch(#"^((?:\[[^\]]*\]\s*)?[\w\s,()_:<>?.]*)\s+in(\s|$)"#, afterTrim) != nil {
            if let call = firstMatch(#"([A-Za-z_]\w*)\s*(?:\([^)]*\))?\s*$"#, s) { return (.block, "Closure · \(call)") }
            return (.block, "Closure")
        }
        if s.hasSuffix("=>") || s.contains("=> ") || s.hasSuffix(") =>") {
            if let name = firstMatch(#"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?"#, raw) { return (.function, "Function · \(name)") }
            return (.function, "Arrow function")
        }

        // Methods/functions in C-like languages: `name(args) … {`.
        if let name = firstMatch(#"([A-Za-z_$][\w$]*)\s*(?:<[^<>]*>)?\s*\([^;{}]*\)\s*(?:const|noexcept|override|throws|rethrows|async|->\s*[^{=]+|:\s*[\w<>\[\]?.,| ]+|\s)*$"#, s),
           controlNames[name.lowercased()] == nil, !["return", "new", "await", "typeof", "sizeof"].contains(name),
           !s.contains(" = ") || s.contains("function") {
            return (.function, "Function · \(name)")
        }

        // Objects and maps: `const config = {`, `"key": {`, `key:` in YAML.
        if let name = firstMatch(#"([A-Za-z_$][\w$-]*)["']?\s*[:=]\s*(?:new\s+\w+\s*\(?\)?)?\s*$"#, s) {
            return (.block, indentation ? "Key · \(name)" : "Object · \(name)")
        }
        if indentation, !s.isEmpty, s.count < 60 {
            return (.block, "\(s.prefix(40)) block")
        }
        // CSS rules.
        if !s.isEmpty, s.count < 80, !s.contains("("), !s.contains("=") {
            return (.block, "Rule · \(s.prefix(40))")
        }
        return (.block, "Block")
    }

    // MARK: Heuristics

    /// Conservative: true only for text that is clearly code.
    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            guard let only = lines.first else { return false }
            return only.range(of: #"^(?:let|var|const|func|def|return|import|from|#include|class|struct|if|for)\b.*[=({;:]"#, options: .regularExpression) != nil
        }
        var signals = 0
        var symbols = 0, chars = 0
        let keywords = #"^(?:func|def|fn|fun|function|let|var|const|return|import|from|package|class|struct|enum|interface|public|private|protected|static|if|else|for|while|switch|case|try|catch|guard|#include|#import|using|namespace|async|await|export|type|impl|use|mod|pub|elif|except|with|lambda|print\(|console\.)\b"#
        for l in lines {
            chars += l.count
            symbols += l.filter { "{}()[];=<>:".contains($0) }.count
            if l.hasSuffix("{") || l.hasSuffix("}") || l.hasSuffix(";") || l.hasSuffix(")") || l.hasSuffix("):") || l.hasSuffix(",")
                || l.range(of: keywords, options: .regularExpression) != nil || l.contains(" = ") || l.contains("->") || l.contains("=>") {
                signals += 1
            }
        }
        let density = Double(symbols) / Double(max(chars, 1))
        return Double(signals) / Double(lines.count) >= 0.45 && density >= 0.035
    }
}
