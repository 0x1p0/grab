import Foundation

/// Something with a well-known shape found in grabbed text: a date, a phone number,
/// an address, a price, a tracking number, JSON, a stack trace… Each one adds
/// formats to ⌥ Tab on top of the plain text ("ISO 8601", "Apple Maps", "= 148.8").
struct SmartValue: Equatable {
    enum Kind: String, CaseIterable {
        case date, address, phone, email, money, measure, tracking, flight, isbn, doi
        case math, json, base64, jwt, timestamp, error

        var title: String {
            switch self {
            case .date: "Date"
            case .address: "Address"
            case .phone: "Phone"
            case .email: "Email"
            case .money: "Price"
            case .measure: "Measurement"
            case .tracking: "Tracking number"
            case .flight: "Flight"
            case .isbn: "ISBN"
            case .doi: "DOI"
            case .math: "Math"
            case .json: "JSON"
            case .base64: "Base64"
            case .jwt: "JWT"
            case .timestamp: "Timestamp"
            case .error: "Error"
            }
        }
    }

    var kind: Kind
    /// The matched text, as written.
    var raw: String
    var date: Date?
    var duration: TimeInterval = 0
    var timeZone: TimeZone?
    var hasTime = true
    var fields: [String: String] = [:]
    var number: Double?
    var currency: String?
    var unit: String?
    var link: URL?
    /// The normalized value (E.164 phone, decoded text, the error line…).
    var value: String?
    /// Whatever surrounds the match, for event titles.
    var context: String?
}

/// What a smart format turns into.
enum SmartOutput: Equatable {
    case text(String)
    case link(URL)
    /// An .ics calendar file, written only when copied.
    case event(ics: String, name: String)
}

enum SmartTypes {
    // MARK: Detection

    /// What a text contains, before knowing which word the cursor is on. This is the
    /// expensive part (data detectors, regexes), so callers cache it per text.
    struct Analysis {
        var whole: SmartValue?
        var candidates: [(value: SmartValue, range: NSRange)] = []
        var text: String = ""
    }

    static func analyze(_ text: String) -> Analysis {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 200_000 else { return Analysis() }
        if let v = json(t) { return Analysis(whole: v) }
        if t.count <= 20_000, let v = stackTrace(t) { return Analysis(whole: v) }
        guard t.count <= 4_000 else { return Analysis() }
        if let v = jwt(t) ?? timestamp(t) ?? math(t) ?? base64(t) ?? errorLine(t) { return Analysis(whole: v) }
        return Analysis(whole: nil, candidates: detectorMatches(t) + regexMatches(t), text: t)
    }

    /// The smart value in `text`: the whole text when it has a recognizable shape
    /// (JSON, a timestamp, a sum, a stack trace…), otherwise the entity under the
    /// hovered word, or the dominant one in a short text.
    static func detect(_ text: String, near word: String?) -> SmartValue? {
        choose(analyze(text), near: word)
    }

    static func choose(_ a: Analysis, near word: String?) -> SmartValue? {
        if let w = a.whole { return w }
        let candidates = a.candidates
        guard !candidates.isEmpty else { return nil }
        let t = a.text
        let ns = t as NSString

        // The entity under the cursor wins.
        if let w = word?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty, w.count < 80 {
            var hits: [NSRange] = []
            var search = NSRange(location: 0, length: ns.length)
            while hits.count < 20 {
                let r = ns.range(of: w, options: [], range: search)
                guard r.location != NSNotFound else { break }
                hits.append(r)
                search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
            }
            let under = candidates.filter { c in hits.contains { NSIntersectionRange($0, c.range).length > 0 } }
            if let best = under.max(by: { $0.range.length < $1.range.length }) {
                return withContext(best.value, range: best.range, in: ns)
            }
            if t.count > 140 { return nil }
        }
        guard t.count <= 140, let best = candidates.max(by: { $0.range.length < $1.range.length }),
              Double(best.range.length) / Double(max(ns.length, 1)) >= 0.2 else { return nil }
        return withContext(best.value, range: best.range, in: ns)
    }

    private static func withContext(_ v: SmartValue, range: NSRange, in ns: NSString) -> SmartValue {
        var v = v
        let rest = ns.replacingCharacters(in: range, with: " ")
        var words = rest.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        // "Team sync on" → "Team sync".
        let dangling: Set<String> = ["on", "at", "by", "for", "from", "until", "till", "due", "starting", "is", "the", "in", "@", "-", "–", "—", "|", "·", ":"]
        while let last = words.last, dangling.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))) { words.removeLast() }
        v.context = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—·|@"))
        return v
    }

    private static let detector = try? NSDataDetector(types:
        NSTextCheckingResult.CheckingType.date.rawValue | NSTextCheckingResult.CheckingType.address.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.transitInformation.rawValue)

    private static let timeHint = try! NSRegularExpression(
        pattern: #"\d{1,2}[:.]\d{2}|\b\d{1,2}\s?(?:am|pm|a\.m\.|p\.m\.)|\bnoon\b|\bmidnight\b|o'clock|\btonight\b|\bnow\b"#,
        options: [.caseInsensitive])

    private static func detectorMatches(_ t: String) -> [(value: SmartValue, range: NSRange)] {
        guard let detector else { return [] }
        let ns = t as NSString
        var out: [(SmartValue, NSRange)] = []
        for m in detector.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range)
            switch m.resultType {
            case .date:
                guard let d = m.date else { continue }
                // A bare number or year isn't a date worth converting.
                guard raw.rangeOfCharacter(from: .letters) != nil || raw.contains("/") || raw.contains("-") || raw.contains(".") || raw.contains(":")
                else { continue }
                var v = SmartValue(kind: .date, raw: raw, date: d, duration: m.duration, timeZone: m.timeZone)
                // "Due March 3", "until Friday": the detector returns a range from now; the date that matters is its end.
                if m.duration > 0, raw.range(of: #"^(?:due|by|until|till|before|deadline|expires?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    v.date = d.addingTimeInterval(m.duration)
                    v.duration = 0
                }
                v.hasTime = timeHint.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) != nil
                out.append((v, m.range))
            case .address:
                var v = SmartValue(kind: .address, raw: raw)
                for (k, val) in m.addressComponents ?? [:] { v.fields[k.rawValue] = val }
                out.append((v, m.range))
            case .phoneNumber:
                guard let p = m.phoneNumber, p.filter(\.isNumber).count >= 7 else { continue }
                var v = SmartValue(kind: .phone, raw: raw)
                v.value = e164(p)
                out.append((v, m.range))
            case .link:
                guard let u = m.url, u.scheme?.lowercased() == "mailto" else { continue }
                var v = SmartValue(kind: .email, raw: raw)
                let address = u.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? raw
                v.value = address.removingPercentEncoding ?? address
                v.link = u
                out.append((v, m.range))
            case .transitInformation:
                guard let flight = m.components?[.flight] else { continue }
                var v = SmartValue(kind: .flight, raw: raw)
                let airline = m.components?[.airline] ?? ""
                v.value = raw.trimmingCharacters(in: .whitespaces)
                v.fields = ["airline": airline, "flight": flight]
                v.link = WebSearch.url(for: "\(raw) flight status")
                out.append((v, m.range))
            default:
                continue
            }
        }
        return out
    }

    // MARK: Regex entities

    private struct Carrier {
        let name: String
        let pattern: NSRegularExpression
        let context: String?
        let url: (String) -> String
    }

    private static let carriers: [Carrier] = [
        Carrier(name: "UPS", pattern: try! NSRegularExpression(pattern: #"\b1Z[0-9A-Z]{16}\b"#), context: nil,
                url: { "https://www.ups.com/track?tracknum=\($0)" }),
        Carrier(name: "USPS", pattern: try! NSRegularExpression(pattern: #"\b(?:9[2-5]\d{20}|9[2-5]\d{24}|[A-Z]{2}\d{9}US)\b"#), context: nil,
                url: { "https://tools.usps.com/go/TrackConfirmAction?tLabels=\($0)" }),
        Carrier(name: "Amazon", pattern: try! NSRegularExpression(pattern: #"\bTBA\d{12}\b"#), context: nil,
                url: { "https://track.amazon.com/tracking/\($0)" }),
        Carrier(name: "FedEx", pattern: try! NSRegularExpression(pattern: #"\b(?:\d{12}|\d{15}|\d{20})\b"#), context: "fedex",
                url: { "https://www.fedex.com/fedextrack/?trknbr=\($0)" }),
        Carrier(name: "DHL", pattern: try! NSRegularExpression(pattern: #"\b\d{10}\b"#), context: "dhl",
                url: { "https://www.dhl.com/global-en/home/tracking/tracking-express.html?tracking-id=\($0)" }),
    ]

    private static let isbnPattern = try! NSRegularExpression(
        pattern: #"(?:ISBN(?:-1[03])?:?\s*)?\b((?:97[89][\s-]?)?\d{1,5}[\s-]?\d{1,7}[\s-]?\d{1,7}[\s-]?[\dX])\b"#)
    private static let doiPattern = try! NSRegularExpression(pattern: #"\b(10\.\d{4,9}/[-._;()/:A-Za-z0-9]*[A-Za-z0-9])"#)

    static let currencySymbols: [String: String] = [
        "US$": "USD", "A$": "AUD", "C$": "CAD", "NZ$": "NZD", "HK$": "HKD", "R$": "BRL", "S$": "SGD",
        "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₽": "RUB", "₺": "TRY",
        "₪": "ILS", "฿": "THB", "₫": "VND", "₴": "UAH", "₦": "NGN", "zł": "PLN", "Kč": "CZK", "kr": "SEK", "Fr": "CHF",
    ]
    private static let currencyCodes = "USD|EUR|GBP|JPY|INR|CAD|AUD|CHF|CNY|SEK|NOK|DKK|PLN|BRL|MXN|KRW|SGD|HKD|NZD|ZAR|TRY|RUB|CZK|HUF|ILS|THB|IDR|PHP|MYR|AED|SAR"
    private static let moneyPattern = try! NSRegularExpression(pattern:
        #"(?<![\w$])(US\$|A\$|C\$|NZ\$|HK\$|R\$|S\$|[$€£¥₹₩₽₺₪฿₫₴₦]|(?:"# + currencyCodes + #")\s?)\s?(-?\d[\d,.\x{00A0}\x{202F} ]*\d|\d)(\s?(?:k|K|m|M|bn|B)\b)?"#
        + #"|(-?\d[\d,.\x{00A0}\x{202F}]*\d|\d)\s?(€|£|¥|₹|zł|Kč|kr|(?:"# + currencyCodes + #"))(?![\w])"#)

    private static let measurePattern = try! NSRegularExpression(pattern:
        #"(?<![\w.])(-?\d+(?:[.,]\d+)?)\s?(°F|℉|°C|℃|fl\.? ?oz|ft|feet|foot|inches|inch|in|mi|miles|mile|yds|yd|yards|yard|lbs|lb|pounds|pound|oz|ounces|ounce|kms|km|kilometers|kilometres|kilometer|kilometre|cm|mm|meters|metres|meter|metre|m|kgs|kg|grams|gram|g|liters|litres|liter|litre|ml|mL|l|L|gallons|gallon|gal|cups|cup|mph|km/h|kph)(?![\w/])"#)

    private static func regexMatches(_ t: String) -> [(value: SmartValue, range: NSRange)] {
        let ns = t as NSString
        let all = NSRange(location: 0, length: ns.length)
        let lower = t.lowercased()
        var out: [(SmartValue, NSRange)] = []

        for c in carriers {
            if let ctx = c.context, !lower.contains(ctx) { continue }
            for m in c.pattern.matches(in: t, range: all) {
                let raw = ns.substring(with: m.range)
                var v = SmartValue(kind: .tracking, raw: raw)
                v.value = raw
                v.fields["carrier"] = c.name
                v.link = URL(string: c.url(raw))
                out.append((v, m.range))
            }
        }

        for m in isbnPattern.matches(in: t, range: all) {
            let whole = ns.substring(with: m.range)
            let digits = ns.substring(with: m.range(at: 1)).filter { $0.isNumber || $0 == "X" }
            let prefixed = whole.uppercased().hasPrefix("ISBN")
            guard validISBN(digits), prefixed || (digits.count == 13 && (digits.hasPrefix("978") || digits.hasPrefix("979"))) else { continue }
            var v = SmartValue(kind: .isbn, raw: whole)
            v.value = digits
            v.link = URL(string: "https://openlibrary.org/isbn/\(digits)")
            out.append((v, m.range))
        }

        for m in doiPattern.matches(in: t, range: all) {
            let doi = ns.substring(with: m.range(at: 1))
            var v = SmartValue(kind: .doi, raw: doi)
            v.value = doi
            v.link = URL(string: "https://doi.org/" + (doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi))
            out.append((v, m.range))
        }

        for m in moneyPattern.matches(in: t, range: all) {
            let raw = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            let prefix = m.range(at: 1).location != NSNotFound
            let symbol = (prefix ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range(at: 5))).trimmingCharacters(in: .whitespaces)
            let amount = prefix ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 4))
            guard let n = Formats.number(in: amount).flatMap(Double.init) else { continue }
            var mult = 1.0
            if prefix, m.range(at: 3).location != NSNotFound {
                switch ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces).lowercased() {
                case "k": mult = 1_000
                case "m": mult = 1_000_000
                default: mult = 1_000_000_000
                }
            }
            var v = SmartValue(kind: .money, raw: raw)
            v.number = n * mult
            v.currency = currencySymbols[symbol] ?? symbol.uppercased()
            out.append((v, m.range))
        }

        for m in measurePattern.matches(in: t, range: all) {
            let unit = ns.substring(with: m.range(at: 2))
            // "5 in the box", "3 m ago"? Only when nothing word-like follows.
            if ["in", "m", "g", "l", "L", "mi"].contains(unit) {
                let after = NSMaxRange(m.range)
                if after < ns.length, let next = ns.substring(from: after).trimmingCharacters(in: .whitespaces).first, next.isLetter { continue }
            }
            guard let n = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")),
                  Measures.convert(n, unit: unit) != nil else { continue }
            var v = SmartValue(kind: .measure, raw: ns.substring(with: m.range))
            v.number = n
            v.unit = unit
            out.append((v, m.range))
        }
        return out
    }

    static func validISBN(_ d: String) -> Bool {
        let chars = Array(d)
        if chars.count == 10 {
            var sum = 0
            for (i, c) in chars.enumerated() {
                let v = c == "X" ? (i == 9 ? 10 : -1000) : (c.wholeNumberValue ?? -1000)
                sum += v * (10 - i)
            }
            return sum >= 0 && sum % 11 == 0
        }
        if chars.count == 13 {
            var sum = 0
            for (i, c) in chars.enumerated() {
                guard let v = c.wholeNumberValue else { return false }
                sum += v * (i % 2 == 0 ? 1 : 3)
            }
            return sum % 10 == 0
        }
        return false
    }

    // MARK: Whole-text shapes

    private static func json(_ t: String) -> SmartValue? {
        guard let f = t.first, let l = t.last, (f == "{" && l == "}") || (f == "[" && l == "]"), t.count >= 2,
              let data = t.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        var v = SmartValue(kind: .json, raw: t)
        v.value = t
        return v
    }

    private static let jwtPattern = try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#)

    private static func jwt(_ t: String) -> SmartValue? {
        let ns = t as NSString
        guard let m = jwtPattern.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
              Double(m.range.length) / Double(ns.length) > 0.6 else { return nil }
        let token = ns.substring(with: m.range)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let header = decodeBase64(String(parts[0])), let payload = decodeBase64(String(parts[1])),
              let h = prettyJSON(header), let p = prettyJSON(payload) else { return nil }
        var v = SmartValue(kind: .jwt, raw: token)
        v.fields = ["header": h, "payload": p]
        return v
    }

    private static func timestamp(_ t: String) -> SmartValue? {
        guard t.range(of: #"^\d{10}(?:\d{3})?(?:\.\d+)?$"#, options: .regularExpression) != nil, let n = Double(t) else { return nil }
        let seconds = t.split(separator: ".")[0].count == 13 ? n / 1000 : n
        guard seconds > 946_684_800, seconds < 4_102_444_800 else { return nil }
        var v = SmartValue(kind: .timestamp, raw: t)
        v.date = Date(timeIntervalSince1970: seconds)
        return v
    }

    private static func math(_ t: String) -> SmartValue? {
        guard t.count <= 200, t.range(of: #"^[\d\s.,+\-*/×÷^()%xX−·]+$"#, options: .regularExpression) != nil,
              t.contains(where: \.isNumber) else { return nil }
        // Dates, phone numbers, ranges and IDs use the same characters.
        if t.range(of: #"^\d{1,4}[/.\-]\d{1,2}[/.\-]\d{1,4}$"#, options: .regularExpression) != nil { return nil }
        let ops = t.filter { "+*/×÷^%xX·".contains($0) }
        let hasSpacedMinus = t.range(of: #"\d\s+[-−]\s+[\d(]"#, options: .regularExpression) != nil
        guard !ops.isEmpty || hasSpacedMinus else { return nil }
        // "1920x1080" is a size and "3x" is a multiplier, but "4 x 12" is a product.
        if ops.allSatisfy({ $0 == "x" || $0 == "X" }), t.range(of: #"\d\s+[xX]\s+\d"#, options: .regularExpression) == nil { return nil }
        if ops == "%" && !hasSpacedMinus && t.range(of: #"[+*/×÷]"#, options: .regularExpression) == nil { return nil }
        guard let result = MathParser.evaluate(t), result.isFinite else { return nil }
        var v = SmartValue(kind: .math, raw: t)
        v.number = result
        v.value = MathParser.format(result)
        return v
    }

    private static func base64(_ t: String) -> SmartValue? {
        guard t.count >= 16, t.count <= 4000, t.range(of: #"^[A-Za-z0-9+/_-]+={0,2}$"#, options: .regularExpression) != nil,
              t.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) == nil,
              t.contains(where: \.isNumber) || t.contains("+") || t.contains("/") || t.contains("="),
              t.contains(where: \.isUppercase), t.contains(where: \.isLowercase),
              let decoded = decodeBase64(t), decoded.count >= 4 else { return nil }
        let printable = decoded.unicodeScalars.filter { !$0.properties.isWhitespace && $0.value < 32 }.count
        guard Double(printable) / Double(decoded.unicodeScalars.count) < 0.02,
              decoded.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        var v = SmartValue(kind: .base64, raw: t)
        v.value = decoded
        return v
    }

    static func decodeBase64(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b = b.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let str = String(data: d, encoding: .utf8) else { return nil }
        return str
    }

    /// Re-indents JSON text without parsing it into dictionaries, so key order and
    /// number spelling stay exactly as written.
    static func prettyJSON(_ s: String) -> String? {
        guard let d = s.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)) != nil else { return nil }
        return reformatJSON(s, pretty: true)
    }

    static func minifiedJSON(_ s: String) -> String? {
        guard let d = s.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)) != nil else { return nil }
        return reformatJSON(s, pretty: false)
    }

    private static func reformatJSON(_ s: String, pretty: Bool) -> String {
        let chars = Array(s)
        var out = ""
        out.reserveCapacity(chars.count + chars.count / 4)
        var depth = 0
        var i = 0
        func newline() {
            out += "\n" + String(repeating: "  ", count: depth)
        }
        func nextSignificant(_ from: Int) -> Character? {
            var j = from
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            return j < chars.count ? chars[j] : nil
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"":
                // Copy the string verbatim, escapes included.
                out.append(c)
                i += 1
                while i < chars.count {
                    out.append(chars[i])
                    if chars[i] == "\\", i + 1 < chars.count { i += 1; out.append(chars[i]) }
                    else if chars[i] == "\"" { break }
                    i += 1
                }
            case "{", "[":
                out.append(c)
                if let n = nextSignificant(i + 1), n == (c == "{" ? "}" : "]") {
                    var j = i + 1
                    while chars[j].isWhitespace { j += 1 }
                    out.append(chars[j])
                    i = j
                } else {
                    depth += 1
                    if pretty { newline() }
                }
            case "}", "]":
                depth = max(0, depth - 1)
                if pretty { newline() }
                out.append(c)
            case ",":
                out.append(c)
                if pretty { newline() }
            case ":":
                out.append(pretty ? ": " : ":")
            default:
                if !c.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return out
    }

    // MARK: Errors and stack traces

    private static let errorLinePatterns: [NSRegularExpression] = [
        #"^(?:Uncaught |Unhandled )?(?:[A-Z]\w*(?:\.\w+)*(?:Error|Exception|Warning|Exit|Interrupt|Fault)\b)(?::.*)?$"#,
        #"^(?:Fatal error|fatal error|panic|thread '.*' panicked at|error\[E\d+\]|error|ERROR|FATAL|Segmentation fault|Exception in thread)\b.*$"#,
        #"^\S+:\d+(?::\d+)?: (?:fatal )?error: .+$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }

    private static let framePattern = try! NSRegularExpression(pattern:
        #"^\s+at .+|^\s+File ".+", line \d+|^\s*\d+\s+\S+\s+0x[0-9a-f]+ |^\s+\S+\.go:\d+|^\s+[\w.$<>]+\(.*:\d+\)$|^\tat "#,
        options: [.anchorsMatchLines])

    /// The line that says what went wrong.
    private static func keyErrorLine(_ t: String) -> String? {
        let lines = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Python puts it last; most others put it first.
        let python = t.contains("Traceback (most recent call last)")
        let ordered = python ? lines.reversed() : lines
        for l in ordered where l.count < 600 {
            let ns = l as NSString
            if errorLinePatterns.contains(where: { $0.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) != nil }) {
                return l
            }
        }
        return nil
    }

    private static func stackTrace(_ t: String) -> SmartValue? {
        let ns = t as NSString
        let frames = framePattern.numberOfMatches(in: t, range: NSRange(location: 0, length: ns.length))
        guard frames >= 2 || t.contains("Traceback (most recent call last)"), let line = keyErrorLine(t) else { return nil }
        // A trace inside a bigger text (a whole page, a chat) isn't the thing itself.
        let lines = t.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard Double(frames + 1) >= Double(lines.count) * 0.4 || t.contains("Traceback (most recent call last)") && lines.count <= frames * 3 + 4
        else { return nil }
        var v = SmartValue(kind: .error, raw: t)
        v.value = line
        v.fields["frames"] = "\(frames)"
        return v
    }

    private static func errorLine(_ t: String) -> SmartValue? {
        guard !t.contains("\n") || t.components(separatedBy: "\n").count <= 6, let line = keyErrorLine(t),
              line.count >= 8, line.contains(":") else { return nil }
        var v = SmartValue(kind: .error, raw: t)
        v.value = line
        return v
    }

    /// A stack trace with library and runtime frames folded away.
    static func cleanTrace(_ t: String) -> String {
        let noise = try! NSRegularExpression(pattern:
            #"node_modules|node:internal|internal/(?:modules|process)|site-packages|dist-packages|<frozen |/lib/python\d|java\.base/|\bat (?:java|javax|sun|jdk|kotlin|kotlinx|scala)\.|/usr/lib/|libdispatch|libswift|libsystem|CoreFoundation|/rustc/|/src/runtime/|\(native\)|<anonymous>"#)
        var out: [String] = []
        var folded = 0
        for line in t.components(separatedBy: "\n") {
            let ns = line as NSString
            let isFrame = framePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
            if isFrame, noise.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                folded += 1
                continue
            }
            if folded > 0 {
                out.append("    … \(folded) library frame\(folded == 1 ? "" : "s")")
                folded = 0
            }
            out.append(line)
        }
        if folded > 0 { out.append("    … \(folded) library frame\(folded == 1 ? "" : "s")") }
        return out.joined(separator: "\n")
    }

    /// What to type into a search box for an error: no paths, addresses or line numbers.
    static func searchQuery(forError line: String) -> String {
        var q = line
        let cleanups = [
            #"(?:/[\w.@+-]+)+/?"#, #"[A-Za-z]:\\[^\s]+"#, #"0x[0-9a-fA-F]+"#, #":\d+(?::\d+)?"#,
            #"\bline \d+\b"#, #"\b[0-9a-f]{12,}\b"#, #"\s{2,}"#,
        ]
        for p in cleanups { q = q.replacingOccurrences(of: p, with: " ", options: .regularExpression) }
        return String(q.trimmingCharacters(in: .whitespaces).prefix(200))
    }

    // MARK: Phone numbers

    private static let callingCodes: [String: String] = [
        "US": "1", "CA": "1", "GB": "44", "IN": "91", "DE": "49", "FR": "33", "ES": "34", "IT": "39", "NL": "31", "BE": "32",
        "CH": "41", "AT": "43", "SE": "46", "NO": "47", "DK": "45", "FI": "358", "IE": "353", "PT": "351", "PL": "48",
        "BR": "55", "MX": "52", "AR": "54", "AU": "61", "NZ": "64", "JP": "81", "KR": "82", "CN": "86", "HK": "852",
        "SG": "65", "AE": "971", "SA": "966", "ZA": "27", "NG": "234", "IL": "972", "TR": "90", "RU": "7", "UA": "380",
        "ID": "62", "PH": "63", "TH": "66", "VN": "84", "MY": "60", "PK": "92", "BD": "880", "EG": "20", "CZ": "420",
        "GR": "30", "HU": "36", "RO": "40", "CL": "56", "CO": "57", "PE": "51", "TW": "886",
    ]

    /// "(555) 123-4567" → "+15551234567", using your region for numbers without a country code.
    static func e164(_ raw: String, region: String? = Locale.current.region?.identifier) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: #"\s*(?:x|ext\.?|extension|#)\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        let digits = s.filter(\.isNumber)
        if s.hasPrefix("+") { return "+" + digits }
        if digits.hasPrefix("00") { return "+" + digits.dropFirst(2) }
        // "(555) 123-4567" and "555-123-4567" are written the North American way.
        if digits.count == 10, s.range(of: #"^\(?\d{3}\)?[\s.-]?\d{3}[\s.-]\d{4}$"#, options: .regularExpression) != nil,
           s.contains("(") || s.filter({ $0 == "-" }).count == 2 {
            return "+1" + digits
        }
        let cc = region.flatMap { callingCodes[$0] } ?? "1"
        if cc == "1" {
            if digits.count == 11 && digits.hasPrefix("1") { return "+" + digits }
            return "+1" + digits
        }
        if digits.hasPrefix("0") { return "+" + cc + digits.dropFirst() }
        return "+" + cc + digits
    }

    // MARK: Formats

    static func options(for v: SmartValue) -> [FormatOption] {
        var out: [FormatOption] = [.init(id: "plain", title: "Text")]
        switch v.kind {
        case .date:
            out += [.init(id: "iso", title: v.hasTime ? "ISO 8601" : "YYYY-MM-DD"), .init(id: "local", title: "Local"),
                    .init(id: "unix", title: "Unix"), .init(id: "ics", title: "Event")]
        case .address:
            out += [.init(id: "oneline", title: "One line"), .init(id: "apple", title: "Apple Maps"), .init(id: "google", title: "Google Maps")]
        case .phone:
            out += [.init(id: "e164", title: v.value ?? "E.164"), .init(id: "digits", title: "Digits"), .init(id: "tel", title: "Call link")]
        case .email:
            out += [.init(id: "address", title: "Address"), .init(id: "mailto", title: "mailto:")]
        case .money:
            out.append(.init(id: "number", title: "Number"))
            if let c = convertedMoney(v) { out.append(.init(id: "convert", title: "≈ " + c)) }
        case .measure:
            out.append(.init(id: "number", title: "Number"))
            if let n = v.number, let unit = v.unit, let c = Measures.convert(n, unit: unit) { out.append(.init(id: "convert", title: "≈ " + c)) }
        case .tracking:
            out += [.init(id: "value", title: "Number"), .init(id: "link", title: "Track on \(v.fields["carrier"] ?? "web")")]
        case .flight:
            out += [.init(id: "value", title: v.value ?? "Flight"), .init(id: "link", title: "Status")]
        case .isbn:
            out += [.init(id: "value", title: "ISBN"), .init(id: "link", title: "Open Library")]
        case .doi:
            out += [.init(id: "value", title: "DOI"), .init(id: "link", title: "doi.org link")]
        case .math:
            out.append(.init(id: "result", title: "= " + (v.value ?? "?")))
        case .json:
            out += [.init(id: "pretty", title: "Pretty"), .init(id: "min", title: "Minified")]
        case .jwt:
            out += [.init(id: "payload", title: "Payload"), .init(id: "header", title: "Header")]
        case .base64:
            out.append(.init(id: "decoded", title: "Decoded"))
        case .timestamp:
            out += [.init(id: "local", title: "Local"), .init(id: "iso", title: "ISO 8601"), .init(id: "relative", title: "Relative")]
        case .error:
            out += [.init(id: "line", title: "Error"), .init(id: "search", title: "Search")]
            if Int(v.fields["frames"] ?? "0") ?? 0 >= 2 { out.append(.init(id: "clean", title: "Clean trace")) }
        }
        return out
    }

    /// Renders a smart format. Nil means "use the plain text".
    static func render(_ v: SmartValue, as id: String) -> SmartOutput? {
        switch (v.kind, id) {
        case (.date, "iso"), (.timestamp, "iso"):
            guard let d = v.date else { return nil }
            if !v.hasTime {
                let f = DateFormatter()
                f.calendar = Calendar(identifier: .iso8601)
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = v.timeZone ?? .current
                return .text(f.string(from: d))
            }
            let f = ISO8601DateFormatter()
            f.timeZone = v.timeZone ?? .current
            return .text(f.string(from: d))
        case (.date, "local"), (.timestamp, "local"):
            guard let d = v.date else { return nil }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = v.hasTime ? .short : .none
            if v.kind == .timestamp { f.timeStyle = .medium }
            return .text(f.string(from: d))
        case (.date, "unix"):
            guard let d = v.date else { return nil }
            return .text(String(Int(d.timeIntervalSince1970)))
        case (.date, "ics"):
            guard let d = v.date else { return nil }
            let title = (v.context?.nonBlank ?? "Event").truncated(80)
            return .event(ics: ics(title: title, start: d, duration: v.duration, allDay: !v.hasTime, notes: v.raw), name: title)
        case (.timestamp, "relative"):
            guard let d = v.date else { return nil }
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return .text(f.localizedString(for: d, relativeTo: Date()))

        case (.address, "oneline"):
            return .text(oneLineAddress(v))
        case (.address, "apple"):
            var c = URLComponents(string: "https://maps.apple.com/")!
            c.queryItems = [URLQueryItem(name: "address", value: oneLineAddress(v))]
            return c.url.map(SmartOutput.link)
        case (.address, "google"):
            var c = URLComponents(string: "https://www.google.com/maps/search/")!
            c.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: oneLineAddress(v))]
            return c.url.map(SmartOutput.link)

        case (.phone, "e164"):
            return v.value.map(SmartOutput.text)
        case (.phone, "digits"):
            return .text(v.raw.filter(\.isNumber))
        case (.phone, "tel"):
            return v.value.flatMap { URL(string: "tel:" + $0) }.map(SmartOutput.link)

        case (.email, "address"):
            return v.value.map(SmartOutput.text)
        case (.email, "mailto"):
            return v.value.flatMap { URL(string: "mailto:" + $0) }.map(SmartOutput.link)

        case (.money, "number"), (.measure, "number"):
            return v.number.map { .text(MathParser.format($0)) }
        case (.money, "convert"):
            return convertedMoney(v).map(SmartOutput.text)
        case (.measure, "convert"):
            guard let n = v.number, let u = v.unit else { return nil }
            return Measures.convert(n, unit: u).map(SmartOutput.text)

        case (.tracking, "value"), (.flight, "value"), (.isbn, "value"), (.doi, "value"):
            return v.value.map(SmartOutput.text)
        case (.tracking, "link"), (.flight, "link"), (.isbn, "link"), (.doi, "link"):
            return v.link.map(SmartOutput.link)

        case (.math, "result"):
            return v.value.map(SmartOutput.text)
        case (.json, "pretty"):
            return prettyJSON(v.raw).map(SmartOutput.text)
        case (.json, "min"):
            return minifiedJSON(v.raw).map(SmartOutput.text)
        case (.jwt, "payload"):
            return v.fields["payload"].map(SmartOutput.text)
        case (.jwt, "header"):
            return v.fields["header"].map(SmartOutput.text)
        case (.base64, "decoded"):
            return v.value.map(SmartOutput.text)

        case (.error, "line"):
            return v.value.map(SmartOutput.text)
        case (.error, "search"):
            return WebSearch.url(for: searchQuery(forError: v.value ?? v.raw)).map(SmartOutput.link)
        case (.error, "clean"):
            return .text(cleanTrace(v.raw))
        default:
            return nil
        }
    }

    private static func oneLineAddress(_ v: SmartValue) -> String {
        let keys: [NSTextCheckingKey] = [.street, .city, .state, .zip, .country]
        let parts = keys.compactMap { v.fields[$0.rawValue]?.replacingOccurrences(of: "\n", with: ", ").nonBlank }
        if parts.count >= 2 {
            // "Cupertino, CA 95014": state and zip share a comma.
            var out: [String] = []
            for k in keys {
                guard let p = v.fields[k.rawValue]?.replacingOccurrences(of: "\n", with: ", ").nonBlank else { continue }
                if k == .zip, let last = out.last, v.fields[NSTextCheckingKey.state.rawValue] != nil { out[out.count - 1] = last + " " + p }
                else { out.append(p) }
            }
            return out.joined(separator: ", ")
        }
        return Formats.oneLine(v.raw.replacingOccurrences(of: "\n", with: ", "))
    }

    private static func convertedMoney(_ v: SmartValue) -> String? {
        guard Settings.shared.currencyConversion, let n = v.number, let from = v.currency else { return nil }
        let to = Locale.current.currency?.identifier ?? "USD"
        guard from != to else { return nil }
        guard let rate = Rates.shared.rate(from: from, to: to) else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = to
        f.maximumFractionDigits = n * rate >= 100 ? 0 : 2
        return f.string(from: NSNumber(value: n * rate))
    }

    static func ics(title: String, start: Date, duration: TimeInterval, allDay: Bool, notes: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyyMMdd"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Grab//Grab//EN", "BEGIN:VEVENT",
                     "UID:\(UUID().uuidString)@grab", "DTSTAMP:\(utc.string(from: Date()))"]
        if allDay {
            lines.append("DTSTART;VALUE=DATE:\(day.string(from: start))")
            let end = Calendar.current.date(byAdding: .day, value: max(1, Int((duration / 86_400).rounded(.up))), to: start) ?? start
            lines.append("DTEND;VALUE=DATE:\(day.string(from: end))")
        } else {
            lines.append("DTSTART:\(utc.string(from: start))")
            lines.append("DTEND:\(utc.string(from: start.addingTimeInterval(duration > 0 ? duration : 3600)))")
        }
        lines += ["SUMMARY:\(esc(title))", "DESCRIPTION:\(esc(notes))", "END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Math

/// A small, safe arithmetic evaluator: + − × ÷ ^ %, parentheses, unary minus,
/// thousands separators. (NSExpression raises on bad input; this just returns nil.)
enum MathParser {
    private enum Token: Equatable { case num(Double), op(Character), lparen, rparen }

    static func evaluate(_ input: String) -> Double? {
        var s = input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "·", with: "*")
        s = s.replacingOccurrences(of: #"(\d)\s*[xX]\s*(\d)"#, with: "$1*$2", options: .regularExpression)
        // 1,240 → 1240 (a comma followed by exactly three digits is a separator).
        s = s.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: ",", with: ".")
        guard let tokens = tokenize(s), !tokens.isEmpty else { return nil }
        var i = 0
        guard let v = expr(tokens, &i, 0), i == tokens.count else { return nil }
        return v
    }

    private static func tokenize(_ s: String) -> [Token]? {
        var out: [Token] = []
        var num = ""
        func flush() -> Bool {
            guard !num.isEmpty else { return true }
            guard let d = Double(num) else { return false }
            out.append(.num(d))
            num = ""
            return true
        }
        for ch in s {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            guard flush() else { return nil }
            switch ch {
            case " ", "\u{00A0}": continue
            case "+", "-", "*", "/", "^", "%": out.append(.op(ch))
            case "(": out.append(.lparen)
            case ")": out.append(.rparen)
            default: return nil
            }
        }
        guard flush() else { return nil }
        return out
    }

    private static func precedence(_ op: Character) -> Int {
        switch op {
        case "+", "-": 1
        case "*", "/": 2
        case "^": 3
        default: 0
        }
    }

    private static func expr(_ t: [Token], _ i: inout Int, _ minPrec: Int) -> Double? {
        guard var lhs = unary(t, &i) else { return nil }
        while i < t.count, case .op(let op) = t[i], op != "%", precedence(op) >= minPrec, precedence(op) > 0 {
            i += 1
            let next = op == "^" ? precedence(op) : precedence(op) + 1
            guard let rhs = expr(t, &i, next) else { return nil }
            switch op {
            case "+": lhs += rhs
            case "-": lhs -= rhs
            case "*": lhs *= rhs
            case "/": guard rhs != 0 else { return nil }; lhs /= rhs
            case "^": lhs = pow(lhs, rhs)
            default: return nil
            }
        }
        return lhs
    }

    private static func unary(_ t: [Token], _ i: inout Int) -> Double? {
        guard i < t.count else { return nil }
        if case .op(let op) = t[i], op == "-" || op == "+" {
            i += 1
            guard let v = unary(t, &i) else { return nil }
            return op == "-" ? -v : v
        }
        guard var v = primary(t, &i) else { return nil }
        while i < t.count, case .op("%") = t[i] {
            i += 1
            v /= 100
        }
        return v
    }

    private static func primary(_ t: [Token], _ i: inout Int) -> Double? {
        guard i < t.count else { return nil }
        switch t[i] {
        case .num(let d):
            i += 1
            return d
        case .lparen:
            i += 1
            guard let v = expr(t, &i, 1), i < t.count, t[i] == .rparen else { return nil }
            i += 1
            return v
        default:
            return nil
        }
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumSignificantDigits = 12
        f.usesSignificantDigits = true
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

// MARK: - Units

enum Measures {
    private static let table: [String: (Dimension, Dimension)] = {
        var t: [String: (Dimension, Dimension)] = [:]
        func add(_ keys: [String], _ from: Dimension, _ to: Dimension) { for k in keys { t[k] = (from, to) } }
        add(["°F", "℉"], UnitTemperature.fahrenheit, UnitTemperature.celsius)
        add(["°C", "℃"], UnitTemperature.celsius, UnitTemperature.fahrenheit)
        add(["ft", "feet", "foot"], UnitLength.feet, UnitLength.meters)
        add(["in", "inch", "inches"], UnitLength.inches, UnitLength.centimeters)
        add(["mi", "mile", "miles"], UnitLength.miles, UnitLength.kilometers)
        add(["yd", "yds", "yard", "yards"], UnitLength.yards, UnitLength.meters)
        add(["m", "meter", "meters", "metre", "metres"], UnitLength.meters, UnitLength.feet)
        add(["cm"], UnitLength.centimeters, UnitLength.inches)
        add(["mm"], UnitLength.millimeters, UnitLength.inches)
        add(["km", "kms", "kilometer", "kilometers", "kilometre", "kilometres"], UnitLength.kilometers, UnitLength.miles)
        add(["lb", "lbs", "pound", "pounds"], UnitMass.pounds, UnitMass.kilograms)
        add(["oz", "ounce", "ounces"], UnitMass.ounces, UnitMass.grams)
        add(["kg", "kgs"], UnitMass.kilograms, UnitMass.pounds)
        add(["g", "gram", "grams"], UnitMass.grams, UnitMass.ounces)
        add(["l", "L", "liter", "liters", "litre", "litres"], UnitVolume.liters, UnitVolume.gallons)
        add(["ml", "mL"], UnitVolume.milliliters, UnitVolume.fluidOunces)
        add(["gal", "gallon", "gallons"], UnitVolume.gallons, UnitVolume.liters)
        add(["fl oz", "fl.oz", "fl. oz", "floz"], UnitVolume.fluidOunces, UnitVolume.milliliters)
        add(["cup", "cups"], UnitVolume.cups, UnitVolume.milliliters)
        add(["mph"], UnitSpeed.milesPerHour, UnitSpeed.kilometersPerHour)
        add(["km/h", "kph"], UnitSpeed.kilometersPerHour, UnitSpeed.milesPerHour)
        return t
    }()

    /// "12 ft" → "3.66 m".
    static func convert(_ value: Double, unit: String) -> String? {
        guard let (from, to) = table[unit] ?? table[unit.lowercased()] else { return nil }
        let out = Measurement(value: value, unit: from).converted(to: to)
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.unitStyle = .medium
        f.numberFormatter.maximumFractionDigits = abs(out.value) >= 100 ? 0 : (abs(out.value) >= 10 ? 1 : 2)
        return f.string(from: out)
    }
}

// MARK: - Web search

enum WebSearch {
    static func url(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? query
        let base: String
        switch Settings.shared.searchEngine {
        case "duckduckgo": base = "https://duckduckgo.com/?q="
        case "bing": base = "https://www.bing.com/search?q="
        case "kagi": base = "https://kagi.com/search?q="
        case "perplexity": base = "https://www.perplexity.ai/search?q="
        case "ecosia": base = "https://www.ecosia.org/search?q="
        default: base = "https://www.google.com/search?q="
        }
        return URL(string: base + q)
    }
}

// MARK: - Exchange rates

/// Daily reference rates from the European Central Bank (via frankfurter.dev), cached
/// for 12 hours. Only currency codes are sent; nothing you grab leaves the Mac.
final class Rates: @unchecked Sendable {
    static let shared = Rates()
    private let lock = NSLock()
    private var eur: [String: Double] = [:]
    private var fetched: Date?
    private var loading = false

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: "rates.eur") as? [String: Double],
           let date = UserDefaults.standard.object(forKey: "rates.date") as? Date {
            eur = saved
            fetched = date
        }
    }

    /// Nil until rates are loaded; asking starts a load.
    func rate(from: String, to: String) -> Double? {
        lock.lock()
        let stale = fetched.map { Date().timeIntervalSince($0) > 43_200 } ?? true
        let table = eur
        lock.unlock()
        if stale { load() }
        func perEUR(_ c: String) -> Double? { c == "EUR" ? 1 : table[c] }
        guard let a = perEUR(from), let b = perEUR(to), a > 0 else { return nil }
        return b / a
    }

    private func load() {
        lock.lock()
        guard !loading else { lock.unlock(); return }
        loading = true
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            var table: [String: Double]?
            for endpoint in ["https://api.frankfurter.dev/v1/latest?base=EUR", "https://api.frankfurter.app/latest?from=EUR"] {
                guard let url = URL(string: endpoint),
                      let (data, _) = try? await URLSession.shared.data(from: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rates = json["rates"] as? [String: Double], !rates.isEmpty else { continue }
                table = rates
                break
            }
            store(table)
        }
    }

    private func store(_ table: [String: Double]?) {
        lock.lock()
        defer { lock.unlock() }
        loading = false
        if let table {
            eur = table
            fetched = Date()
            UserDefaults.standard.set(table, forKey: "rates.eur")
            UserDefaults.standard.set(Date(), forKey: "rates.date")
        } else {
            // Try again in a while rather than on every hover.
            fetched = Date().addingTimeInterval(-43_200 + 600)
        }
    }
}
