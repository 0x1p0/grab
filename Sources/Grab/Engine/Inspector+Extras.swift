import AppKit
import ApplicationServices

/// Lists, forms, fonts, CSS selectors and video timestamps: things read from the
/// accessibility tree only when they're asked for.
extension Inspector {
    // MARK: Lists

    static let listRoles: Set<String> = ["AXList", "AXMenu"]

    /// Turns the nearest list or menu around the cursor into a "List · 12 items" scope.
    func addListScopes(chain: [Node], scopes: inout [Scope]) {
        guard let li = chain.prefix(8).firstIndex(where: { Self.listRoles.contains($0.role) }) else { return }
        let list = chain[li]
        guard let si = scopes.firstIndex(where: { $0.kind == .element && ($0.element.map { CFEqual($0, list.element) } ?? false) }),
              scopes[si].fileURL == nil else { return }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(list.element, AXAttr.children as CFString, &count) == .success, count >= 2 else { return }
        scopes[si].kind = .list
        scopes[si].label = "\(list.role == "AXMenu" ? "Menu" : "List") · \(count) items"
        scopes[si].tableRef = TableRef(table: list.element, row: nil, column: nil, part: .list)
        scopes[si].text = nil
        scopes[si].textPending = true
    }

    /// One line per item.
    func listText(_ list: AXUIElement) -> String? {
        let deadline = CFAbsoluteTimeGetCurrent() + 0.6
        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(list, AXAttr.children as CFString, &count)
        var raw: CFArray?
        guard AXUIElementCopyAttributeValues(list, AXAttr.children as CFString, 0, min(count, 1000), &raw) == .success else { return nil }
        var items: [String] = []
        for k in (raw as? [AXUIElement] ?? []) where CFAbsoluteTimeGetCurrent() < deadline {
            if let t = itemText(k, depth: 0) { items.append(t) }
        }
        return Self.strippingMarkers(items).joined(separator: "\n").nonBlank
    }

    /// "• Apples" → "Apples"; "1. One", "2. Two" → "One", "Two" (only when every item is numbered in order).
    static func strippingMarkers(_ items: [String]) -> [String] {
        var out = items.map { $0.replacingOccurrences(of: #"^[•◦▪▫‣⁃●○■□–—\-*·]\s+"#, with: "", options: .regularExpression) }
        let numbered = out.enumerated().allSatisfy { i, t in t.hasPrefix("\(i + 1). ") || t.hasPrefix("\(i + 1)) ") }
        if numbered, out.count >= 2 {
            out = out.map { $0.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression) }
        }
        return out
    }

    private func itemText(_ e: AXUIElement, depth: Int) -> String? {
        let v = e.attributes([AXAttr.role, AXAttr.value, AXAttr.title, AXAttr.description, AXAttr.children])
        let role = v[AXAttr.role] as? String ?? ""
        if role == "AXListMarker" || role == "AXSeparator" || role == "AXImage" && depth > 0 { return nil }
        let kids = v[AXAttr.children] as? [AXUIElement] ?? []
        let own = (v[AXAttr.title] as? String)?.nonBlank ?? (v[AXAttr.value] as? String)?.nonBlank
        let leafRoles: Set<String> = ["AXStaticText", "AXMenuItem", "AXTextField", "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuBarItem"]
        if let own, leafRoles.contains(role) || kids.isEmpty { return Formats.oneLine(own) }
        guard depth < 4 else { return nil }
        let parts = kids.prefix(16).compactMap { itemText($0, depth: depth + 1) }
        if parts.isEmpty { return (v[AXAttr.description] as? String)?.nonBlank.map(Formats.oneLine) }
        return Formats.oneLine(parts.joined(separator: " ")).nonBlank
    }

    // MARK: Forms

    static let formContainerRoles: Set<String> = ["AXGroup", "AXSheet", "AXWindow", "AXTabGroup", "AXScrollArea", "AXForm", "AXSplitGroup", "AXLayoutArea"]
    static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXSearchField", "AXDateField", "AXColorWell", "AXStepper"]

    /// Two or more controls inside, found within a small budget. Cached per session.
    func hasFormControls(_ e: AXUIElement) -> Bool {
        let key = ElementKey(element: e)
        if let known = formCache[key] { return known }
        let deadline = CFAbsoluteTimeGetCurrent() + 0.025
        var queue: [(AXUIElement, Int)] = [(e, 0)]
        var seen = 0, found = 0
        while !queue.isEmpty, seen < 50, found < 2, CFAbsoluteTimeGetCurrent() < deadline {
            let (n, d) = queue.removeFirst()
            seen += 1
            let v = n.attributes([AXAttr.role, AXAttr.children])
            if Self.inputRoles.contains(v[AXAttr.role] as? String ?? "") { found += 1; continue }
            if d < 6 { queue += (v[AXAttr.children] as? [AXUIElement] ?? []).prefix(30).map { ($0, d + 1) } }
        }
        formCache[key] = found >= 2
        return found >= 2
    }

    struct FormControl {
        var name: String
        var value: String
        var role: String
        var element: AXUIElement
    }

    /// Label → value for every control in a container, in reading order. Password fields are skipped.
    func formFields(_ root: AXUIElement) -> [(String, String)] {
        formControls(root).map { ($0.name, $0.value) }
    }

    /// Every control in a container with its label, in reading order. Password fields are skipped.
    func formControls(_ root: AXUIElement) -> [FormControl] {
        let deadline = CFAbsoluteTimeGetCurrent() + 0.8
        var out: [FormControl] = []
        var used: [String: Int] = [:]
        var lastText: String?
        var stack: [AXUIElement] = [root]
        var visited = 0
        let names = [AXAttr.role, AXAttr.subrole, AXAttr.title, AXAttr.value, AXAttr.description, AXAttr.children,
                     "AXPlaceholderValue", "AXTitleUIElement", "AXHelp"]
        while let e = stack.popLast(), visited < 800, CFAbsoluteTimeGetCurrent() < deadline {
            visited += 1
            let v = e.attributes(names)
            let role = v[AXAttr.role] as? String ?? ""
            // Browsers report password inputs as text fields with a "secure" subrole.
            if role == "AXSecureTextField" || (v[AXAttr.subrole] as? String) == "AXSecureTextField" { lastText = nil; continue }
            if role == "AXStaticText" {
                lastText = (v[AXAttr.value] as? String)?.nonBlank.map(Formats.oneLine)
                continue
            }
            if Self.inputRoles.contains(role) {
                var label = (v[AXAttr.title] as? String)?.nonBlank
                if label == nil, let ref = v["AXTitleUIElement"], CFGetTypeID(ref) == AXUIElementGetTypeID() {
                    let t = ref as! AXUIElement
                    label = (t.attribute(AXAttr.value) as? String)?.nonBlank ?? t.string(AXAttr.title)
                }
                label = label ?? (v[AXAttr.description] as? String)?.nonBlank ?? (v["AXPlaceholderValue"] as? String)?.nonBlank
                    ?? lastText ?? (v["AXHelp"] as? String)?.nonBlank
                var name = Formats.oneLine(label ?? String(role.dropFirst(2))).trimmingCharacters(in: CharacterSet(charactersIn: ":* "))
                if name.count > 60 { name = name.truncated(60) }
                let value: String
                switch role {
                case "AXCheckBox", "AXRadioButton":
                    value = ((v[AXAttr.value] as? NSNumber)?.intValue ?? 0) == 1 ? "true" : "false"
                    if role == "AXRadioButton" && value == "false" { lastText = nil; continue }
                case "AXPopUpButton":
                    value = (v[AXAttr.value] as? String) ?? (v[AXAttr.title] as? String) ?? ""
                default:
                    if let n = v[AXAttr.value] as? NSNumber { value = n.stringValue }
                    else { value = (v[AXAttr.value] as? String) ?? "" }
                }
                used[name, default: 0] += 1
                if let n = used[name], n > 1 { name += " \(n)" }
                out.append(FormControl(name: name, value: value, role: role, element: e))
                lastText = nil
                continue
            }
            stack.append(contentsOf: (v[AXAttr.children] as? [AXUIElement] ?? []).reversed())
        }
        return out
    }

    #if DEBUG
    nonisolated(unsafe) static var fillNote = ""
    #endif

    /// Fields ⌥F can type into.
    private static let fillableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// ⌥F: writes `values` into the text fields of the form at `root`, matched by label.
    /// Returns how many were filled, out of how many text fields there are.
    func fillForm(_ root: AXUIElement, with values: [(String, String)]) -> (filled: Int, fields: Int) {
        let controls = formControls(root).filter { Self.fillableRoles.contains($0.role) }
        let matches = FormFill.match(fields: controls.map(\.name), values: values)
        #if DEBUG
        Self.fillNote = "fill root=\(root.string(AXAttr.role) ?? "?") fields=\(controls.map { "\($0.role):\($0.name)" })\n"
        #endif
        let pairs = zip(controls, matches).compactMap { c, m in m.map { (c.element, values[$0].1) } }
        // Focus each field and set its value, the way typing would: web views only take
        // a new value for the focused field.
        for (e, text) in pairs {
            _ = e.set("AXFocused", kCFBooleanTrue)
            _ = e.set(AXAttr.value, text as CFString)
        }
        // Browsers update values a moment later; anything that didn't take gets its
        // whole text replaced as a selection instead.
        usleep(150_000)
        for (e, text) in pairs where (e.attribute(AXAttr.value) as? String) != text {
            _ = e.set("AXFocused", kCFBooleanTrue)
            var range = CFRange(location: 0, length: ((e.attribute(AXAttr.value) as? String) ?? "").utf16.count)
            if let all = AXValueCreate(.cfRange, &range) { _ = e.set(kAXSelectedTextRangeAttribute, all) }
            _ = e.set(kAXSelectedTextAttribute, text as CFString)
        }
        usleep(100_000)
        let filled = pairs.filter { (e, text) in (e.attribute(AXAttr.value) as? String) == text }.count
        return (filled, controls.count)
    }

    /// The form around `element`: the nearest ancestor holding two or more controls.
    func formRoot(around element: AXUIElement) -> AXUIElement? {
        var e: AXUIElement? = element
        for _ in 0..<12 {
            guard let cur = e else { return nil }
            let role = cur.string(AXAttr.role) ?? ""
            // Never the whole page or window: only a form-sized container counts.
            if ["AXWebArea", "AXApplication", "AXWindow", "AXScrollArea", "AXSplitGroup"].contains(role) { return nil }
            if (Self.formContainerRoles.contains(role) || role == "AXForm") && hasFormControls(cur) { return cur }
            e = cur.attribute(AXAttr.parent).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        return nil
    }

    // MARK: Video pages

    /// The canonical URL of a page whose links can start at a timestamp.
    static func timestampablePage(_ u: URL) -> URL? {
        guard let host = u.host?.lowercased() else { return nil }
        if host.hasSuffix("youtube.com"), u.path == "/watch",
           let id = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            return URL(string: "https://youtu.be/\(id)")
        }
        if host == "youtu.be" { return URL(string: "https://youtu.be" + u.path) }
        return nil
    }

    /// The player's current time in seconds, read from its controls.
    func videoTime(near element: AXUIElement) -> Int? {
        var root = element
        for _ in 0..<5 {
            guard let p = root.attribute(AXAttr.parent), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            root = p as! AXUIElement
        }
        let deadline = CFAbsoluteTimeGetCurrent() + 0.6
        var queue = [root]
        var seen = 0
        while !queue.isEmpty, seen < 900, CFAbsoluteTimeGetCurrent() < deadline {
            let e = queue.removeFirst()
            seen += 1
            let v = e.attributes(["AXDOMClassList", AXAttr.children, AXAttr.value])
            if let classes = v["AXDOMClassList"] as? [String], classes.contains("ytp-time-current") {
                var text = (v[AXAttr.value] as? String)?.nonBlank
                if text == nil {
                    text = (v[AXAttr.children] as? [AXUIElement])?.compactMap { ($0.attribute(AXAttr.value) as? String)?.nonBlank }.first
                }
                return text.flatMap(Self.seconds)
            }
            queue += v[AXAttr.children] as? [AXUIElement] ?? []
        }
        return nil
    }

    /// "1:02:03" → 3723.
    static func seconds(_ clock: String) -> Int? {
        let parts = clock.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    // MARK: CSS selectors

    /// An approximate CSS selector for a web element: stops at the nearest id.
    func cssSelector(_ element: AXUIElement) -> String? {
        var parts: [String] = []
        var cursor: AXUIElement? = element
        var depth = 0
        while let e = cursor, depth < 9 {
            depth += 1
            let v = e.attributes([AXAttr.role, AXAttr.subrole, AXAttr.roleDescription, "AXDOMIdentifier", "AXDOMClassList", AXAttr.parent, AXAttr.value])
            let role = v[AXAttr.role] as? String ?? ""
            if role == "AXWebArea" || role.isEmpty { break }
            let next: AXUIElement? = v[AXAttr.parent].flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            if role == "AXStaticText" { cursor = next; continue }
            let tag = Self.tag(role: role, subrole: v[AXAttr.subrole] as? String, description: v[AXAttr.roleDescription] as? String,
                               level: (v[AXAttr.value] as? NSNumber)?.intValue)
            if let id = (v["AXDOMIdentifier"] as? String)?.nonBlank {
                parts.append(Self.cssIdent(id, prefix: "#"))
                break
            }
            let classes = (v["AXDOMClassList"] as? [String] ?? []).filter(Self.isMeaningfulClass).prefix(2)
            parts.append(tag + classes.map { Self.cssIdent($0, prefix: ".") }.joined())
            cursor = next
        }
        guard !parts.isEmpty else { return nil }
        return parts.reversed().joined(separator: " > ")
    }

    private static func tag(role: String, subrole: String?, description: String?, level: Int?) -> String {
        let d = description?.lowercased() ?? ""
        switch role {
        case "AXLink": return "a"
        case "AXImage": return "img"
        case "AXButton": return "button"
        case "AXHeading": return "h\(min(6, max(1, level ?? 2)))"
        case "AXList": return d.contains("ordered") || d.contains("numbered") ? "ol" : "ul"
        case "AXListItem": return "li"
        case "AXParagraph": return "p"
        case "AXTextField", "AXCheckBox", "AXRadioButton", "AXSearchField": return "input"
        case "AXTextArea": return "textarea"
        case "AXPopUpButton": return "select"
        case "AXTable": return "table"
        case "AXRow": return "tr"
        case "AXCell": return "td"
        case "AXBlockquote": return "blockquote"
        case "AXForm": return "form"
        case "AXFigure": return "figure"
        default: break
        }
        switch subrole {
        case "AXLandmarkNavigation": return "nav"
        case "AXLandmarkMain": return "main"
        case "AXLandmarkBanner": return "header"
        case "AXLandmarkContentInfo": return "footer"
        case "AXLandmarkComplementary": return "aside"
        case "AXLandmarkForm": return "form"
        case "AXLandmarkRegion": return "section"
        case "AXDocumentArticle": return "article"
        default: break
        }
        if d == "article" { return "article" }
        if d == "section" || d == "region" { return "section" }
        if d == "video" { return "video" }
        if d == "code" { return "code" }
        if d == "paragraph" { return "p" }
        return "div"
    }

    /// Generated class names (css-1x2y3z, sc-AbCdE) change between builds; leave them out.
    private static func isMeaningfulClass(_ c: String) -> Bool {
        guard !c.isEmpty, c.count <= 40 else { return false }
        if c.range(of: #"^(?:css|sc|jsx|emotion|svelte|styled)-"#, options: .regularExpression) != nil { return false }
        let digits = c.filter(\.isNumber).count
        return digits <= 2 || Double(digits) / Double(c.count) < 0.25
    }

    private static func cssIdent(_ s: String, prefix: String) -> String {
        var out = prefix
        for (i, ch) in s.enumerated() {
            if ch.isLetter || ch == "-" || ch == "_" || (ch.isNumber && i > 0) { out.append(ch) }
            else { out += "\\" + String(ch) }
        }
        return out
    }

    // MARK: Fonts

    /// "Inter SemiBold, 15 pt · #1F2937" (native) or CSS (web) for the text under `p`.
    func fontDescription(at p: CGPoint, leaf: AXUIElement?, webArea: AXUIElement?) -> String? {
        var attributed: NSAttributedString?
        if let web = webArea, let marker = web.parameterized(AXAttr.textMarkerForPosition, AXBox.point(p)),
           let range = web.parameterized(AXAttr.rightWord, marker) ?? web.parameterized(AXAttr.leftWord, marker) {
            attributed = web.parameterized("AXAttributedStringForTextMarkerRange", range) as? NSAttributedString
        }
        if attributed == nil, let e = leaf, let r = AXBox.cfRange(e.parameterized(AXAttr.rangeForPosition, AXBox.point(p))) {
            attributed = e.parameterized("AXAttributedStringForRange", AXBox.range(CFRange(location: r.location, length: max(1, r.length)))) as? NSAttributedString
        }
        guard let a = attributed, a.length > 0 else { return nil }
        let attrs = a.attributes(at: 0, effectiveRange: nil)
        guard let font = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] else { return nil }
        let name = font["AXFontName"] as? String ?? ""
        let family = (font["AXFontFamily"] as? String)?.nonBlank ?? name.components(separatedBy: "-").first ?? name
        let size = (font["AXFontSize"] as? NSNumber)?.doubleValue ?? 0
        let visible = (font["AXVisibleName"] as? String)?.nonBlank ?? name
        var color: String?
        if let c = attrs[NSAttributedString.Key("AXForegroundColor")], CFGetTypeID(c as CFTypeRef) == CGColor.typeID {
            let cg = c as! CGColor
            // Browsers report CSS colors' own sRGB values; converting them would shift the hex.
            if let comps = cg.components, comps.count >= 3, cg.colorSpace?.model == .rgb {
                color = RGBAColor(r: Double(comps[0]), g: Double(comps[1]), b: Double(comps[2])).hex
            } else if let ns = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) {
                color = RGBAColor(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent).hex
            }
        }
        let sizeText = size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
        if webArea != nil {
            var css = "font-family: \"\(family)\"; font-size: \(sizeText)px; font-weight: \(Self.weight(of: name));"
            if let color { css += " color: \(color.lowercased());" }
            return css
        }
        return "\(visible), \(sizeText) pt" + (color.map { " · \($0)" } ?? "")
    }

    static func weight(of fontName: String) -> Int {
        let n = fontName.lowercased().replacingOccurrences(of: " ", with: "")
        let table: [(String, Int)] = [
            ("thin", 100), ("hairline", 100), ("extralight", 200), ("ultralight", 200), ("semibold", 600), ("demibold", 600),
            ("extrabold", 800), ("ultrabold", 800), ("heavy", 800), ("black", 900), ("light", 300), ("medium", 500), ("bold", 700),
        ]
        for (k, w) in table where n.contains(k) { return w }
        return 400
    }
}
