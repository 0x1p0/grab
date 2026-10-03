import AppKit
import ApplicationServices

/// Code awareness for the inspector: knowing when the cursor is over code, and
/// turning it into symbol / line / block / function / file scopes.
extension Inspector {
    struct CodeHint {
        var isCodeApp = false
        var isTerminal = false
        var isElectronEditor = false
        var language: CodeLanguage?
        var fileURL: URL?
        var workingDirectory: URL?
    }

    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty", "co.zeit.hyper", "com.raphaelamorim.rio",
        "app.tabby", "dev.commandline.waveterm",
    ]

    static let nativeEditorApps: Set<String> = [
        "com.apple.dt.Xcode", "com.panic.Nova", "com.barebones.bbedit", "com.coteditor.CotEditor", "com.macromates.TextMate",
        "com.sublimetext.4", "com.sublimetext.3", "com.apple.ScriptEditor2", "dev.zed.Zed", "dev.zed.Zed-Preview",
        "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.jetbrains.goland",
        "com.jetbrains.CLion", "com.jetbrains.rider", "com.jetbrains.rubymine", "com.jetbrains.PhpStorm",
        "com.google.android.studio", "com.jetbrains.fleet", "com.chimehq.Edit",
    ]

    static let electronEditorApps: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "com.vscodium", "com.trae.app", "ai.codestory.AideInsiders", "com.kiro.desktop",
    ]

    private static let monospaceHints = ["mono", "menlo", "monaco", "courier", "consol", "code", "fira", "jetbrains",
                                         "hack", "inconsolata", "iosevka", "cascadia", "andale", "pt mono", "sf mono"]

    func codeHint(bundleID: String?, chain: [Node], leaf: AXUIElement) -> CodeHint {
        var hint = CodeHint()
        let bid = bundleID ?? ""
        hint.isTerminal = Self.terminalApps.contains(bid)
        hint.isElectronEditor = Self.electronEditorApps.contains(bid)
        hint.isCodeApp = hint.isTerminal || hint.isElectronEditor || Self.nativeEditorApps.contains(bid) || bid.hasPrefix("com.jetbrains.")

        // The window's document: the open file in editors, the working directory in terminals.
        var doc = chain.last(where: { $0.role == "AXWindow" })?.document
        if doc == nil, hint.isCodeApp || chain.count >= 18,
           let w = leaf.attribute("AXWindow"), CFGetTypeID(w) == AXUIElementGetTypeID() {
            doc = AXBox.url((w as! AXUIElement).attribute(AXAttr.document))
        }
        if let d = doc, d.isFileURL {
            if d.hasDirectoryPath || d.pathExtension.isEmpty && hint.isTerminal {
                hint.workingDirectory = d
            } else {
                hint.fileURL = d
                hint.workingDirectory = d.deletingLastPathComponent()
                hint.language = CodeLanguage.forFile(d)
            }
        }
        if hint.isTerminal { hint.language = .shell }
        return hint
    }

    func isMonospaced(_ e: AXUIElement, at index: Int) -> Bool {
        guard let attr = e.parameterized("AXAttributedStringForRange", AXBox.range(CFRange(location: index, length: 1))) as? NSAttributedString,
              attr.length > 0 else { return false }
        let font = attr.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any]
        let name = ((font?["AXFontFamily"] as? String ?? "") + " " + (font?["AXFontName"] as? String ?? "")).lowercased()
        return Self.monospaceHints.contains { name.contains($0) }
    }

    // MARK: Building scopes

    /// Converts code scopes into Grab scopes using `rect` to place them on screen.
    static func makeCodeScopes(analysis a: CodeAnalysis, cursor: Int, title: String, fileURL: URL?, cwd: URL? = nil,
                        rect: (NSRange) -> CGRect?) -> [Scope] {
        let (codeScopes, def) = a.scopes(at: cursor)
        // Colors and paths written right under the cursor.
        let lr = a.lineRange(a.line(of: cursor))
        let lineText = a.text.substring(with: lr)
        let col = cursor - lr.location
        let literal = SmartData.color(in: lineText, at: col)
        let path = SmartData.path(in: lineText, at: col, cwd: cwd ?? fileURL?.deletingLastPathComponent())
        var out: [Scope] = []
        for (i, c) in codeScopes.enumerated() {
            guard var frame = rect(c.range) else { continue }
            if c.firstLine != c.lastLine {
                // Start the box at the block's own indentation, not the text view's edge.
                let firstContent = a.contentRange(c.firstLine)
                if firstContent.length > 0, let ch = rect(NSRange(location: firstContent.location, length: 1)), ch.width > 0 {
                    var minIndent = Int.max
                    for l in c.firstLine...c.lastLine where !a.isBlank(l) { minIndent = min(minIndent, a.indent(l)) }
                    let x0 = ch.minX - CGFloat(max(0, a.indent(c.firstLine) - minIndent)) * ch.width
                    if x0 > frame.minX + 1 {
                        frame = CGRect(x: x0, y: frame.minY, width: frame.maxX - x0, height: frame.height)
                    }
                }
            }
            var label = c.label
            if c.kind == .file { label = title }
            var s = Scope(kind: .code, frame: frame, label: label, text: a.copyText(c))
            s.code = CodeInfo(kind: c.kind, language: a.language.name, fileURL: fileURL,
                              lines: (c.firstLine + 1)...(c.lastLine + 1), isTerminal: a.isTerminal)
            s.isPreferred = i == def
            if c.kind == .file, let fileURL { s.fileURL = fileURL }
            if [.symbol, .expression, .string, .line, .command, .comment].contains(c.kind) {
                s.colorLiteral = literal
                s.pathURL = path
            }
            out.append(s)
        }
        return out
    }

    // MARK: Native text views (Xcode, Terminal, Nova, TextEdit with code…)

    func cocoaCodeScopes(_ e: AXUIElement, index idx: Int, total: Int?, at p: CGPoint, clip: CGRect, hint: CodeHint) -> [Scope]? {
        let count = total ?? (idx + 40_000)
        let lo = count <= 400_000 ? 0 : max(0, idx - 40_000)
        let hi = count <= 400_000 ? count : min(count, idx + 40_000)
        guard hi > lo else { return nil }

        let key = "\(CFHash(e))|\(lo)|\(hi)|\(count)"
        let analysis: CodeAnalysis
        if let cached = cocoaCodeCache, cached.key == key {
            analysis = cached.analysis
        } else {
            var chunk: String?
            if let s = e.parameterized(AXAttr.stringForRange, AXBox.range(CFRange(location: lo, length: hi - lo))) as? String {
                chunk = s
            } else if let v = e.attribute(AXAttr.value) as? String {
                let ns = v as NSString
                if lo < ns.length { chunk = ns.substring(with: NSRange(location: lo, length: min(hi, ns.length) - lo)) }
            }
            guard let text = chunk, !text.isEmpty else { return nil }
            // Not a code app and not monospaced code: leave it to the prose scopes.
            if !hint.isCodeApp && hint.fileURL == nil {
                guard isMonospaced(e, at: idx), CodeAnalysis.looksLikeCode(text) else { return nil }
            }
            let lang = hint.language ?? (hint.isTerminal ? .shell : CodeLanguage.guess(text))
            analysis = CodeAnalysis(text: text, language: lang, terminal: hint.isTerminal)
            cocoaCodeCache = (key, analysis)
        }

        func bounds(_ r: NSRange) -> CGRect? {
            guard r.length > 0 else { return nil }
            let g = CFRange(location: lo + r.location, length: r.length)
            var rect = AXBox.rect(e.parameterized(AXAttr.boundsForRange, AXBox.range(g)))
            if r.length > 1 {
                for c in [CFRange(location: g.location, length: 1), CFRange(location: g.location + g.length - 1, length: 1)] {
                    if let b = AXBox.rect(e.parameterized(AXAttr.boundsForRange, AXBox.range(c))), b.width > 0 || b.height > 0 {
                        rect = rect.map { $0.union(b) } ?? b
                    }
                }
            }
            guard let out = rect?.intersection(clip), !out.isNull, out.width >= 1, out.height >= 2 else { return nil }
            return out
        }

        // The cursor has to be over a line of text, not past its end.
        let cursor = idx - lo
        let line = analysis.line(of: min(cursor, analysis.text.length - 1))
        let content = analysis.contentRange(line)
        guard content.length > 0, let lineRect = bounds(content), lineRect.insetBy(dx: -24, dy: -3).contains(p) else { return [] }

        let title = hint.isTerminal ? "Everything" : (hint.fileURL.map { "File · \($0.lastPathComponent)" } ?? "All")
        return Self.makeCodeScopes(analysis: analysis, cursor: min(cursor, NSMaxRange(content) - 1), title: title,
                              fileURL: hint.isTerminal ? nil : hint.fileURL, cwd: hint.workingDirectory, rect: bounds)
    }

    // MARK: Web code blocks

    static let codeClassHints = ["language-", "lang-", "highlight", "hljs", "prism", "shiki", "sourcecode", "source-code",
                                 "codeblock", "code-block", "cm-content", "cm-editor", "codemirror", "blob-code", "torchlight"]

    /// The element holding a code block (or inline code) under the cursor, with any language hint.
    func codeElement(in chain: [Node]) -> (element: AXUIElement, index: Int, language: CodeLanguage?)? {
        for (i, n) in chain.prefix(6).enumerated() {
            let classes = (n.element.attribute("AXDOMClassList") as? [String]) ?? []
            let isCode = n.subrole == "AXCodeStyleGroup" || n.subrole == "AXPreformattedStyleGroup"
                || n.roleDescription == "code"
                || classes.contains { c in Self.codeClassHints.contains { c.lowercased().hasPrefix($0) || c.lowercased() == $0 } }
            guard isCode else { continue }
            // Prefer the outer <pre> when the <code> sits inside one.
            var index = i
            if i + 1 < chain.count, chain[i + 1].subrole == "AXPreformattedStyleGroup" { index = i + 1 }
            // Inline `code` in a sentence is part of the prose around it.
            if chain[index].subrole != "AXPreformattedStyleGroup", (chain[index].frame?.height ?? 0) < 30 { return nil }
            var lang: CodeLanguage?
            for j in i..<min(chain.count, i + 4) {
                let cls = (chain[j].element.attribute("AXDOMClassList") as? [String]) ?? []
                for c in cls {
                    if let l = CodeLanguage.named(c) { lang = l; break }
                }
                if lang != nil { break }
            }
            return (chain[index].element, index, lang)
        }
        return nil
    }

    /// Safari: exact positions from text markers and element-relative bounds.
    func webCodeScopes(host: AXUIElement, code: AXUIElement, language: CodeLanguage?, at p: CGPoint, clip: CGRect) -> [Scope]? {
        guard let r = host.parameterized(AXAttr.markerRangeForElement, code), CFGetTypeID(r) == AXTextMarkerRangeGetTypeID(),
              let text = host.parameterized(AXAttr.stringForMarkerRange, r) as? String, !text.isEmpty,
              let m = host.parameterized(AXAttr.textMarkerForPosition, AXBox.point(p)),
              let cur = host.parameterized("AXIndexForTextMarker", m) as? NSNumber else { return nil }
        let start = AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
        guard let base = host.parameterized("AXIndexForTextMarker", start) as? NSNumber else { return nil }
        let cursor = cur.intValue - base.intValue
        let length = (text as NSString).length
        guard cursor >= 0, cursor < length else { return nil }

        func bounds(_ range: NSRange) -> CGRect? {
            guard range.length > 0 else { return nil }
            var rect = AXBox.rect(code.parameterized(AXAttr.boundsForRange, AXBox.range(CFRange(location: range.location, length: range.length))))
            for c in [CFRange(location: range.location, length: 1), CFRange(location: NSMaxRange(range) - 1, length: 1)] where range.length > 1 {
                if let b = AXBox.rect(code.parameterized(AXAttr.boundsForRange, AXBox.range(c))), b.width > 0 {
                    rect = rect.map { $0.union(b) } ?? b
                }
            }
            guard let out = rect?.intersection(clip), !out.isNull, out.width >= 1, out.height >= 2 else { return nil }
            return out
        }
        // Make sure the element-relative bounds really work here before trusting them.
        guard bounds(NSRange(location: cursor, length: 1)) != nil else { return nil }

        let key = "web|\(CFHash(code))|\(length)|\(text.hashValue)"
        let analysis: CodeAnalysis
        if let cached = webCodeCache, cached.key == key {
            analysis = cached.analysis
        } else {
            analysis = CodeAnalysis(text: text, language: language ?? CodeLanguage.guess(text))
            webCodeCache = (key, analysis)
        }
        let line = analysis.line(of: cursor)
        guard let lineRect = bounds(analysis.contentRange(line)), lineRect.insetBy(dx: -24, dy: -3).contains(p) else { return [] }
        return Self.makeCodeScopes(analysis: analysis, cursor: cursor, title: "Code block", fileURL: nil, rect: bounds)
    }

    /// Chrome & friends: we can read the code block's text but not where each
    /// character is, so the layout is learned from pixels later.
    func webCodeRegion(host: AXUIElement, code: AXUIElement, frame: CGRect?, language: CodeLanguage?, clip: CGRect) -> CodeRegion? {
        guard let f = frame?.intersection(clip), f.isUsable,
              let r = host.parameterized(AXAttr.markerRangeForElement, code),
              let text = host.parameterized(AXAttr.stringForMarkerRange, r) as? String,
              text.contains("\n") || text.count > 3 else { return nil }
        return CodeRegion(rect: f, source: .text(text), language: language ?? CodeLanguage.guess(text), title: "Code block")
    }

    /// Editors that draw their own text (VS Code, Cursor, Zed…): read the file, find the lines by pixels.
    func editorRegion(chain: [Node], hint: CodeHint, windowFrame: CGRect?, clip: CGRect) -> CodeRegion? {
        guard hint.isCodeApp, !hint.isTerminal else { return nil }
        var rect: CGRect?
        var terminalPanel = false
        for n in chain.prefix(8) {
            let classes = ((n.element.attribute("AXDOMClassList") as? [String]) ?? []).map { $0.lowercased() }
            if classes.contains("monaco-editor") { rect = n.frame; break }
            if classes.contains(where: { $0 == "xterm" || $0 == "xterm-screen" || $0 == "terminal-wrapper" }) {
                rect = n.frame
                terminalPanel = true
                break
            }
            if rect == nil, classes.contains(where: { $0.contains("lines-content") || $0.contains("view-lines") }), let f = n.frame {
                // Include the gutter so line numbers can anchor the layout.
                rect = CGRect(x: f.minX - 90, y: f.minY, width: f.width + 90, height: f.height)
            }
        }
        if rect == nil, !hint.isElectronEditor, let leafFrame = chain.first?.frame, leafFrame.width > 300, leafFrame.height > 150 {
            rect = leafFrame
        }
        // Without an accessibility tree, take the window's content; the line-number
        // gutter found in the pixels narrows it down to the editor itself.
        if rect == nil, hint.isElectronEditor, let w = windowFrame ?? chain.last?.frame {
            rect = CGRect(x: w.minX, y: w.minY + 28, width: w.width, height: w.height - 28)
        }
        guard let r = rect?.intersection(clip), r.isUsable else { return nil }
        if terminalPanel {
            return CodeRegion(rect: r, source: .ocr, language: .shell, title: "Everything", isTerminal: true)
        }
        if let file = hint.fileURL {
            return CodeRegion(rect: r, source: .file(file), language: hint.language, title: "File · \(file.lastPathComponent)")
        }
        return CodeRegion(rect: r, source: .ocr, language: hint.language, title: "All")
    }
}
