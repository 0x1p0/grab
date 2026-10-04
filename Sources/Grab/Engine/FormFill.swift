import Foundation

/// ⌥F: values copied from one form (Grab's "Fields" JSON, or "Label: value" lines)
/// matched to the fields of another by their labels.
enum FormFill {
    /// Label → value pairs from the clipboard, in order. Empty if it isn't form data.
    static func parse(_ text: String) -> [(String, String)] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 200_000 else { return [] }
        if t.hasPrefix("{"), let data = t.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Keep the order the keys appear in the text.
            let ordered = obj.keys.sorted { (t.range(of: "\"\($0)\"")?.lowerBound ?? t.endIndex) < (t.range(of: "\"\($1)\"")?.lowerBound ?? t.endIndex) }
            return ordered.compactMap { k in
                switch obj[k] {
                case let s as String: return (k, s)
                case let n as NSNumber: return (k, CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue)
                default: return nil
                }
            }
        }
        // "Label: value" or "Label<tab>value", one per line, at least two.
        var out: [(String, String)] = []
        for line in t.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let sep: Range<String.Index>? = line.range(of: "\t") ?? line.range(of: ": ")
            guard let r = sep else { return [] }
            let key = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count <= 60 else { return [] }
            out.append((key, value))
        }
        return out.count >= 2 ? out : []
    }

    /// Words that mean the same thing on different forms.
    private static let synonyms: [String: String] = [
        "e mail": "email", "mail": "email", "email address": "email",
        "telephone": "phone", "tel": "phone", "mobile": "phone", "cell": "phone", "phone number": "phone",
        "given name": "first name", "forename": "first name", "first": "first name",
        "surname": "last name", "family name": "last name", "last": "last name",
        "full name": "name", "your name": "name",
        "street": "address", "street address": "address", "address line 1": "address", "address 1": "address",
        "town": "city", "locality": "city",
        "province": "state", "region": "state", "county": "state",
        "zip": "postal code", "zip code": "postal code", "postcode": "postal code", "post code": "postal code",
        "organization": "company", "organisation": "company", "business": "company",
        "site": "website", "url": "website", "homepage": "website",
        "username": "user name", "login": "user name",
    ]

    static func normalize(_ label: String) -> String {
        let lowered = label.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // "Name 2" (a second field with the same label) still means "name".
        let base = lowered.replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
        let stripped = base.replacingOccurrences(of: #"^(your|enter|enter your)\s+"#, with: "", options: .regularExpression)
        return synonyms[stripped] ?? stripped
    }

    /// For each field label, the index of the value that fits it best, using each value once.
    static func match(fields: [String], values: [(String, String)]) -> [Int?] {
        let keys = values.map { normalize($0.0) }
        var used = Set<Int>()
        var result = [Int?](repeating: nil, count: fields.count)
        func score(_ a: String, _ b: String) -> Double {
            if a.isEmpty || b.isEmpty { return 0 }
            if a == b { return 1 }
            let wa = Set(a.split(separator: " ")), wb = Set(b.split(separator: " "))
            let overlap = Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
            if a.contains(b) || b.contains(a) { return max(0.75, overlap) }
            return overlap
        }
        // Best pairs first, so "Email" doesn't steal a value "Email address" fits better.
        var pairs: [(Int, Int, Double)] = []
        for (fi, f) in fields.enumerated() {
            let nf = normalize(f)
            for (vi, k) in keys.enumerated() {
                let s = score(nf, k)
                if s >= 0.5 { pairs.append((fi, vi, s)) }
            }
        }
        for (fi, vi, _) in pairs.sorted(by: { $0.2 > $1.2 }) where result[fi] == nil && !used.contains(vi) {
            result[fi] = vi
            used.insert(vi)
        }
        return result
    }
}
