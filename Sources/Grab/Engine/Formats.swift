import Foundation

/// Ways to put the same grab on the clipboard; ⌥ + Tab cycles through them.
/// The last choice per family is remembered across sessions.
struct FormatOption: Equatable, Identifiable {
    let id: String
    let title: String
}

/// A kind of grab with its own set of formats. Each family remembers its last choice.
struct FormatFamily: Hashable {
    let rawValue: String

    static let text = FormatFamily(rawValue: "text")
    static let code = FormatFamily(rawValue: "code")
    static let terminal = FormatFamily(rawValue: "terminal")
    static let link = FormatFamily(rawValue: "link")
    static let color = FormatFamily(rawValue: "color")
    static let file = FormatFamily(rawValue: "file")
    static let table = FormatFamily(rawValue: "table")
    static let list = FormatFamily(rawValue: "list")
    static let image = FormatFamily(rawValue: "image")
    static let wifi = FormatFamily(rawValue: "wifi")
    static let none = FormatFamily(rawValue: "none")
    static func smart(_ k: SmartValue.Kind) -> FormatFamily { FormatFamily(rawValue: "smart." + k.rawValue) }

    var smartKind: SmartValue.Kind? {
        rawValue.hasPrefix("smart.") ? SmartValue.Kind(rawValue: String(rawValue.dropFirst(6))) : nil
    }
}

enum Formats {
    static func family(for s: Scope, mode: GrabMode) -> FormatFamily {
        switch mode {
        case .text:
            if s.kind == .table { return .table }
            if s.kind == .list { return .list }
            if let c = s.code { return c.isTerminal ? .terminal : .code }
            if let v = s.smart { return .smart(v.kind) }
            return .text
        case .link: return .link
        case .color: return .color
        case .file: return .file
        case .qr: return s.barcode?.uppercased().hasPrefix("WIFI:") == true ? .wifi : .none
        case .image: return .image
        }
    }

    /// Smart formats that also make sense on code and terminal text.
    private static func codeExtras(_ s: Scope) -> [FormatOption] {
        guard let v = s.smart, v.kind == .error || v.kind == .json || v.kind == .jwt || v.kind == .base64 else { return [] }
        return SmartTypes.options(for: v).filter { $0.id != "plain" }
    }

    static func options(_ family: FormatFamily, scope s: Scope, source: (title: String?, url: URL?) = (nil, nil)) -> [FormatOption] {
        builtIn(family, scope: s, source: source) + custom(for: family)
    }

    /// Your own formats that apply to this kind of grab.
    static func custom(for family: FormatFamily) -> [FormatOption] {
        let formats = Settings.shared.customFormats
        guard !formats.isEmpty else { return [] }
        let target: CustomFormat.Target?
        switch family {
        case .code, .terminal: target = .code
        case .link: target = .link
        case .image: target = .image
        case .text, .table, .list: target = .text
        default: target = family.smartKind != nil ? .text : nil
        }
        guard let target else { return [] }
        return formats.filter { $0.targets.contains(target) && (target != .image || $0.shortcut != nil) }
            .map { FormatOption(id: $0.formatID, title: $0.name) }
    }

    static func customFormat(_ id: String) -> CustomFormat? {
        guard id.hasPrefix("custom.") else { return nil }
        return Settings.shared.customFormats.first { $0.formatID == id }
    }

    private static func builtIn(_ family: FormatFamily, scope s: Scope, source: (title: String?, url: URL?)) -> [FormatOption] {
        if family.smartKind != nil, let v = s.smart { return SmartTypes.options(for: v) }
        switch family {
        case .text:
            var out: [FormatOption] = [.init(id: "plain", title: "Plain"), .init(id: "oneline", title: "One line"), .init(id: "quote", title: "Quote")]
            if let t = s.bestText, number(in: t) != nil { out.insert(.init(id: "number", title: "Number"), at: 1) }
            if source.url != nil || source.title != nil { out.append(.init(id: "cite", title: "Cite")) }
            if s.hasFields { out.append(.init(id: "fields", title: "Fields")) }
            if s.kind.isTextRange && !s.textIsOCR { out.append(.init(id: "font", title: "Font")) }
            if s.inWeb && s.element != nil && !s.kind.isTextRange { out.append(.init(id: "selector", title: "Selector")) }
            out.append(.init(id: "receipt", title: "Receipt"))
            return out
        case .wifi:
            return [.init(id: "password", title: "Password"), .init(id: "network", title: "Network"), .init(id: "raw", title: "Raw")]
        case .code:
            var out = [FormatOption(id: "code", title: "Code"), .init(id: "markdown", title: "Markdown")]
            if s.code?.fileURL != nil, s.code?.lines != nil { out.append(.init(id: "reference", title: "Reference")) }
            if let f = s.code?.fileURL, let l = s.code?.lines, let host = Git.remoteHost(for: f, lines: l) {
                out.append(.init(id: "permalink", title: host))
            }
            out.append(.init(id: "picture", title: "Picture"))
            return out + codeExtras(s)
        case .terminal:
            return [.init(id: "code", title: "Text"), .init(id: "markdown", title: "Markdown"), .init(id: "picture", title: "Picture")] + codeExtras(s)
        case .link:
            var out: [FormatOption] = [.init(id: "url", title: "URL"), .init(id: "markdown", title: "Markdown"), .init(id: "title", title: "Title")]
            if s.videoPage != nil { out.append(.init(id: "attime", title: "At current time")) }
            return out
        case .color:
            return ColorFormat.allCases.map { .init(id: $0.rawValue, title: $0.title) }
        case .file:
            return [.init(id: "file", title: "File"), .init(id: "path", title: "Path"), .init(id: "name", title: "Name"), .init(id: "icon", title: "Icon")]
        case .table:
            return [.init(id: "tsv", title: "Cells"), .init(id: "markdown", title: "Markdown"), .init(id: "csv", title: "CSV"), .init(id: "json", title: "JSON")]
        case .list:
            return [.init(id: "lines", title: "Lines"), .init(id: "bullets", title: "Bullets"), .init(id: "numbered", title: "Numbered"),
                    .init(id: "comma", title: "Comma"), .init(id: "json", title: "JSON"), .init(id: "receipt", title: "Receipt")]
        case .image:
            return [.init(id: "image", title: "Image"), .init(id: "subject", title: "Subject"), .init(id: "sticker", title: "Sticker"),
                    .init(id: "polaroid", title: "Polaroid"), .init(id: "palette", title: "Palette"), .init(id: "datauri", title: "Data URI")]
        default:
            return []
        }
    }

    /// The current choice for a family.
    static func selected(_ family: FormatFamily, in options: [FormatOption]) -> FormatOption? {
        guard !options.isEmpty else { return nil }
        if family == .color {
            return options.first { $0.id == Settings.shared.colorFormat.rawValue } ?? options.first
        }
        let saved = Settings.shared.formatChoices[family.rawValue]
        return options.first { $0.id == saved } ?? options.first
    }

    static func select(_ option: FormatOption, for family: FormatFamily) {
        if family == .color, let f = ColorFormat(rawValue: option.id) {
            Settings.shared.colorFormat = f
            return
        }
        var choices = Settings.shared.formatChoices
        choices[family.rawValue] = option.id
        Settings.shared.formatChoices = choices
    }

    // MARK: Rendering

    static func markdownFence(_ code: String, language: String) -> String {
        let fence = code.contains("```") ? "~~~" : "```"
        return "\(fence)\(language)\n\(code)\n\(fence)"
    }

    /// `Sources/App/Main.swift:12-30`, relative to the repository when there is one.
    static func reference(file: URL, lines: ClosedRange<Int>) -> String {
        var path = (file.path as NSString).abbreviatingWithTildeInPath
        var dir = file.deletingLastPathComponent()
        let fm = FileManager.default
        while dir.path != "/" && !dir.path.isEmpty {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                path = String(file.path.dropFirst(dir.path.count + 1))
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let span = lines.lowerBound == lines.upperBound ? "\(lines.lowerBound)" : "\(lines.lowerBound)-\(lines.upperBound)"
        return "\(path):\(span)"
    }

    static func table(_ tsv: String, as format: String) -> String {
        let rows = tsv.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        switch format {
        case "markdown":
            let width = rows.map(\.count).max() ?? 0
            func line(_ r: [String]) -> String {
                "| " + (0..<width).map { (r[safe: $0] ?? "").replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
            }
            guard let head = rows.first else { return tsv }
            return ([line(head), "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"] + rows.dropFirst().map(line))
                .joined(separator: "\n")
        case "json":
            guard let head = rows.first, rows.count > 1 else { return jsonString(rows) }
            let keys = head.enumerated().map { $1.nonBlank ?? "column\($0 + 1)" }
            let objects = rows.dropFirst().map { r in
                "  {" + keys.enumerated().map { i, k in jsonString(k) + ": " + jsonString(r[safe: i] ?? "") }.joined(separator: ", ") + "}"
            }
            return "[\n" + objects.joined(separator: ",\n") + "\n]"
        case "csv":
            return rows.map { r in
                r.map { f in f.contains(",") || f.contains("\"") || f.contains("\n") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f }
                    .joined(separator: ",")
            }.joined(separator: "\n")
        default:
            return tsv
        }
    }

    /// One item per line → bullets, numbers, a comma list or a JSON array.
    static func list(_ lines: String, as format: String) -> String {
        let items = lines.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch format {
        case "bullets": return items.map { "- " + $0 }.joined(separator: "\n")
        case "numbered": return items.enumerated().map { "\($0 + 1). " + $1 }.joined(separator: "\n")
        case "comma": return items.joined(separator: ", ")
        case "json": return jsonString(items)
        default: return items.joined(separator: "\n")
        }
    }

    /// JSON text for strings and nested arrays of strings, keeping order.
    static func jsonString(_ value: Any) -> String {
        if let s = value as? String {
            var out = "\""
            for u in s.unicodeScalars {
                switch u {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
                }
            }
            return out + "\""
        }
        if let a = value as? [String] { return "[" + a.map { jsonString($0) }.joined(separator: ", ") + "]" }
        if let a = value as? [[String]] { return "[\n" + a.map { "  " + jsonString($0) }.joined(separator: ",\n") + "\n]" }
        if let pairs = value as? [(String, String)] {
            return "{\n" + pairs.map { "  " + jsonString($0.0) + ": " + jsonString($0.1) }.joined(separator: ",\n") + "\n}"
        }
        return "null"
    }

    /// "“text” — Title (URL)", for quoting with attribution.
    static func cite(_ text: String, title: String?, url: URL?) -> String {
        var source = title?.nonBlank ?? ""
        if let u = url {
            source += source.isEmpty ? u.absoluteString : " (\(u.absoluteString))"
        }
        let body = text.contains("\n") ? quote(text) : "“" + text + "”"
        return source.isEmpty ? body : body + "\n— " + source
    }

    /// "$12,480.50" → "12480.50", "−3.5 %" → "-3.5". Nil unless the text is basically one number.
    static func number(in raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
        guard t.count <= 40, t.range(of: #"^[^\d\-+.]{0,4}[-+]?[\d][\d,. \x{00A0}\x{202F}']*[^\d]{0,6}$"#, options: .regularExpression) != nil else { return nil }
        var digits = t.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        // 1.234,56 (European) vs 1,234.56: the last separator is the decimal point.
        if let lastComma = digits.lastIndex(of: ","), let lastDot = digits.lastIndex(of: ".") {
            if lastComma > lastDot { digits = digits.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { digits = digits.replacingOccurrences(of: ",", with: "") }
        } else if digits.filter({ $0 == "," }).count == 1, let c = digits.firstIndex(of: ","), digits.distance(from: c, to: digits.endIndex) != 4 {
            digits = digits.replacingOccurrences(of: ",", with: ".")
        } else {
            digits = digits.replacingOccurrences(of: ",", with: "")
        }
        return Double(digits) == nil ? nil : digits
    }

    /// Fields of a `WIFI:T:WPA;S:name;P:secret;;` payload.
    static func wifi(_ payload: String) -> (network: String?, password: String?) {
        var network: String?, password: String?
        var field = "", value = "", escaping = false, inValue = false
        for ch in payload.dropFirst(5) {
            if escaping { value.append(ch); escaping = false; continue }
            if ch == "\\" { escaping = true; continue }
            if !inValue { if ch == ":" { inValue = true } else { field.append(ch) }; continue }
            if ch == ";" {
                if field == "S" { network = value }
                if field == "P" { password = value }
                field = ""; value = ""; inValue = false
                continue
            }
            value.append(ch)
        }
        return (network, password)
    }

    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func quote(_ s: String) -> String {
        s.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }
}
