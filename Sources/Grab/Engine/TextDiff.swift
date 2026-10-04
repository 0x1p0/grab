import Foundation

/// ⌥D: what changed between the clipboard and the thing under the pointer.
enum TextDiff {
    enum Kind: Equatable { case same, removed, added }

    struct Piece: Equatable {
        var kind: Kind
        var text: String
    }

    struct Result {
        var pieces: [Piece]
        /// Compared line by line (long texts) rather than word by word.
        var byLine: Bool
        var added: Int
        var removed: Int
        var identical: Bool { added == 0 && removed == 0 }
    }

    /// Word-level for prose and short snippets, line-level for anything long.
    static func compare(_ old: String, _ new: String) -> Result {
        let lineCount = max(old.components(separatedBy: "\n").count, new.components(separatedBy: "\n").count)
        let byLine = lineCount > 12 || old.count + new.count > 6000
        let a = byLine ? lines(old) : words(old)
        let b = byLine ? lines(new) : words(new)
        var pieces: [Piece] = []
        var added = 0, removed = 0
        func push(_ kind: Kind, _ text: String) {
            if let last = pieces.last, last.kind == kind { pieces[pieces.count - 1].text += text }
            else { pieces.append(Piece(kind: kind, text: text)) }
        }
        // Myers via the standard library; it tops out on huge inputs, so cap them.
        guard a.count < 20_000, b.count < 20_000 else {
            return Result(pieces: [Piece(kind: .removed, text: old), Piece(kind: .added, text: new)], byLine: true, added: 1, removed: 1)
        }
        let diff = b.difference(from: a)
        var removals = Set<Int>(), insertions = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removals.contains(i) {
                push(.removed, a[i]); i += 1
                if !isSpace(a[i - 1]) { removed += 1 }
            } else if j < b.count, insertions.contains(j) {
                push(.added, b[j]); j += 1
                if !isSpace(b[j - 1]) { added += 1 }
            } else if i < a.count, j < b.count {
                push(.same, b[j]); i += 1; j += 1
            } else {
                break
            }
        }
        return Result(pieces: pieces, byLine: byLine, added: added, removed: removed)
    }

    /// The difference as a unified patch, for pasting into a review or a chat.
    static func patch(_ old: String, _ new: String) -> String {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let diff = b.difference(from: a)
        var removals = Set<Int>(), insertions = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removals.insert(o)
            case .insert(let o, _, _): insertions.insert(o)
            }
        }
        var out = ["--- clipboard", "+++ grabbed"]
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removals.contains(i) { out.append("-" + a[i]); i += 1 }
            else if j < b.count, insertions.contains(j) { out.append("+" + b[j]); j += 1 }
            else if i < a.count, j < b.count { out.append(" " + b[j]); i += 1; j += 1 }
            else { break }
        }
        return out.joined(separator: "\n")
    }

    private static func isSpace(_ s: String) -> Bool { s.allSatisfy(\.isWhitespace) }

    /// Words and the whitespace between them, so joining the pieces gives the text back.
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace: Bool?
        for ch in s {
            let space = ch.isWhitespace
            let punct = ch.isPunctuation || ch.isSymbol
            if punct {
                if !current.isEmpty { out.append(current); current = "" }
                out.append(String(ch))
                inSpace = nil
                continue
            }
            if let was = inSpace, was != space, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current.append(ch)
            inSpace = space
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func lines(_ s: String) -> [String] {
        var parts = s.components(separatedBy: "\n")
        for k in parts.indices.dropLast() { parts[k] += "\n" }
        return parts
    }
}
