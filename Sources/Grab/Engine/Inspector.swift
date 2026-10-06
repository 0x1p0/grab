import AppKit
import ApplicationServices

/// Turns "the point under the cursor" into an ordered list of grabbable scopes,
/// using the accessibility tree. Everything here runs on a single background queue.
final class Inspector {
    private let systemWide = AXUIElementCreateSystemWide()
    private let myPID = getpid()
    private var prepared = Set<pid_t>()
    private var textCache: [ElementKey: String] = [:]
    /// Containers already checked for form controls this session.
    var formCache: [ElementKey: Bool] = [:]
    #if DEBUG
    var debugNote = ""
    #endif
    private var windowTitles: [ElementKey: String] = [:]
    private var appWindowTitles: [pid_t: String] = [:]
    /// Lexing a big file is the expensive part of code awareness; do it once per text.
    var cocoaCodeCache: (key: String, analysis: CodeAnalysis)?
    var webCodeCache: (key: String, analysis: CodeAnalysis)?

    init() {
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    /// Forget per-session caches. Call on the inspector's queue.
    func reset() {
        textCache.removeAll()
        cocoaCodeCache = nil
        webCodeCache = nil
        formCache.removeAll()
        windowTitles.removeAll()
        appWindowTitles.removeAll()
    }

    // MARK: Nodes

    struct Node {
        let element: AXUIElement
        let role: String
        let subrole: String?
        let roleDescription: String?
        let frame: CGRect?
        let title: String?
        let desc: String?
        let url: URL?
        let document: URL?
        let parent: AXUIElement?
    }

    private static let snapshotAttributes = [
        AXAttr.role, AXAttr.subrole, AXAttr.roleDescription, AXAttr.position, AXAttr.size,
        AXAttr.title, AXAttr.description, AXAttr.url, AXAttr.document, AXAttr.parent,
    ]

    func node(_ e: AXUIElement) -> Node {
        let v = e.attributes(Self.snapshotAttributes)
        var frame: CGRect?
        if let p = AXBox.cgPoint(v[AXAttr.position]), let s = AXBox.cgSize(v[AXAttr.size]) {
            frame = CGRect(origin: p, size: s)
        }
        var parent: AXUIElement?
        if let ref = v[AXAttr.parent], CFGetTypeID(ref) == AXUIElementGetTypeID() {
            parent = (ref as! AXUIElement)
        }
        return Node(
            element: e,
            role: v[AXAttr.role] as? String ?? "",
            subrole: v[AXAttr.subrole] as? String,
            roleDescription: v[AXAttr.roleDescription] as? String,
            frame: frame,
            title: (v[AXAttr.title] as? String)?.nonBlank,
            desc: (v[AXAttr.description] as? String)?.nonBlank,
            url: AXBox.url(v[AXAttr.url]),
            document: AXBox.url(v[AXAttr.document]),
            parent: parent
        )
    }

    // MARK: Hit testing

    private func hit(_ p: CGPoint) -> AXUIElement? {
        var found: AXUIElement?
        if AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &found) == .success, let e = found {
            if e.pid != myPID { return e }
            // We hit ourselves. That's right if the cursor is over one of our real
            // windows (onboarding playground, settings), wrong if it's the overlay. Our own
            // elements are only ever read on the main thread (see Session.onAXQueue): off it,
            // look past ourselves.
            if Thread.isMainThread, let top = WindowList.top(at: p, accept: { $0.layer < WindowList.overlayLayer }), top.pid == myPID {
                return e
            }
        }
        guard let top = WindowList.top(at: p, accept: { $0.pid != self.myPID && $0.layer < WindowList.overlayLayer }) else {
            return nil
        }
        let app = AXUIElementCreateApplication(top.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var e: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &e) == .success else { return nil }
        return e
    }

    private static let wakeWithEnhancedUI: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "app.zen-browser.zen", "net.imput.helium",
        "ai.perplexity.comet", "com.openai.atlas",
    ]

    /// Chromium, Electron and Firefox only build their accessibility tree when
    /// asked. Ask once per process.
    private func prepare(_ pid: pid_t) {
        guard pid != myPID, prepared.insert(pid).inserted else { return }
        let app = AXUIElementCreateApplication(pid)
        // VS Code and its forks switch into "Screen Reader Optimized" mode when an
        // accessibility client turns their tree on. Grab reads their code from the
        // file and the screen instead, so leave them alone (and undo older builds).
        if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, Self.electronEditorApps.contains(bid) {
            app.set("AXManualAccessibility", kCFBooleanFalse)
            return
        }
        let manual = app.set("AXManualAccessibility", kCFBooleanTrue)
        if manual != .success,
           let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           Self.wakeWithEnhancedUI.contains(bid) || bid.hasPrefix("org.mozilla.") {
            app.set("AXEnhancedUserInterface", kCFBooleanTrue)
        }
    }

    // MARK: Overlays

    private static let pierceable: Set<String> = ["AXLink", "AXGroup", "AXButton", "AXUnknown", "AXLayoutArea"]

    /// Web pages often lay an invisible link or click-catcher over content (Reddit's
    /// post cards, news teasers, product tiles). When what we hit has no text of its
    /// own under the cursor, look underneath it for the text or image really there.
    private func pierce(_ hit: Node, at p: CGPoint) -> AXUIElement? {
        guard Self.pierceable.contains(hit.role), let f = hit.frame, f.height > 24 || f.width > 260 else { return nil }
        if findUnder(hit.element, at: p, skipping: nil, budget: 80) != nil { return nil }
        var container = hit.parent
        for _ in 0..<3 {
            guard let c = container else { break }
            if let found = findUnder(c, at: p, skipping: hit.element, budget: 500) { return found }
            container = c.attribute(AXAttr.parent).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        return nil
    }

    /// The smallest text or image under `p` within `root`, ignoring `skip`'s subtree.
    private func findUnder(_ root: AXUIElement, at p: CGPoint, skipping skip: AXUIElement?, budget: Int) -> AXUIElement? {
        var stack: [AXUIElement] = [root]
        var best: (AXUIElement, CGFloat)?
        var visited = 0
        let names = [AXAttr.role, AXAttr.position, AXAttr.size, AXAttr.children]
        while let e = stack.popLast(), visited < budget {
            visited += 1
            if let skip, CFEqual(e, skip) { continue }
            let v = e.attributes(names)
            guard let pos = AXBox.cgPoint(v[AXAttr.position]), let size = AXBox.cgSize(v[AXAttr.size]) else { continue }
            let f = CGRect(origin: pos, size: size)
            let role = v[AXAttr.role] as? String ?? ""
            // Text runs report their bounding box; children of containers may overflow, so don't prune those.
            if role == "AXStaticText" || role == "AXImage" {
                if f.insetBy(dx: -1, dy: -1).contains(p), best == nil || f.width * f.height < best!.1 { best = (e, f.width * f.height) }
                continue
            }
            guard f.insetBy(dx: -2, dy: -2).contains(p) || f.width < 1 else { continue }
            if let kids = v[AXAttr.children] as? [AXUIElement] { stack.append(contentsOf: kids) }
        }
        return best?.0
    }

    // MARK: Inspection

    func inspect(at p: CGPoint) -> Inspection {
        guard let hitElement = hit(p) else { return fallback(at: p) }
        var leaf = hitElement
        var overlay: Node?
        let pid = leaf.pid
        prepare(pid)
        let app = NSRunningApplication(processIdentifier: pid)

        func buildChain(from start: AXUIElement) -> [Node] {
            var chain: [Node] = []
            var cursor: AXUIElement? = start
            while let e = cursor, chain.count < 18 {
                let n = node(e)
                if n.role == "AXApplication" || (n.role.isEmpty && !chain.isEmpty) { break }
                chain.append(n)
                if n.role == "AXWindow" { break }
                cursor = n.parent
            }
            return chain
        }
        var chain = buildChain(from: leaf)
        guard !chain.isEmpty else { return fallback(at: p) }
        if chain.contains(where: { $0.role == "AXWebArea" }), let under = pierce(chain[0], at: p) {
            overlay = chain[0]
            leaf = under
            chain = buildChain(from: under)
            guard !chain.isEmpty else { return fallback(at: p) }
        }

        // A cursor on the far edge of the last display isn't "contained" by any of
        // them; use the nearest so every frame below stays finite.
        let displays = ScreenSpace.displayBounds()
        let screen = displays.first { $0.contains(p) }
            ?? displays.min { hypot($0.midX - p.x, $0.midY - p.y) < hypot($1.midX - p.x, $1.midY - p.y) }
            ?? .infinite
        let windowFrame = chain.last { $0.role == "AXWindow" }?.frame
        let webIndex = chain.firstIndex { $0.role == "AXWebArea" }

        // What's actually visible from a given depth: the screen, the window and
        // every scroll view above it.
        func clip(from index: Int) -> CGRect {
            var c = screen
            if let w = windowFrame { c = c.intersection(w) }
            if index + 1 < chain.count {
                for j in (index + 1)..<chain.count where chain[j].role == "AXScrollArea" {
                    if let f = chain[j].frame, f.isUsable { c = c.intersection(f) }
                }
            }
            return c
        }

        let hint = codeHint(bundleID: app?.bundleIdentifier, chain: chain, leaf: leaf)
        var scopes: [Scope] = []
        var codeRegion: CodeRegion?
        var codeHandled = false

        // Code blocks on web pages: exact in Safari, learned from pixels elsewhere.
        if let wi = webIndex, let ce = codeElement(in: chain) {
            let host = chain[wi].element
            if let exact = webCodeScopes(host: host, code: ce.element, language: ce.language, at: p, clip: clip(from: ce.index)) {
                scopes += exact
                codeHandled = true
            } else if let region = webCodeRegion(host: host, code: ce.element, frame: chain[ce.index].frame,
                                                 language: ce.language, clip: clip(from: ce.index)) {
                codeRegion = region
                codeHandled = true
            }
        }
        if !codeHandled {
            scopes += textRangeScopes(chain: chain, webIndex: webIndex, at: p, clip: clip(from: 0), hint: hint)
            codeHandled = scopes.contains { $0.kind == .code }
        }
        // Chromium's "paragraph" stops at inline links and bold text; the paragraph you
        // see is the enclosing block, so widen it when the block's text contains it.
        if let wi = webIndex, let pi = scopes.firstIndex(where: { $0.kind == .paragraph }), let fragment = scopes[pi].text {
            let blockRoles: Set<String> = ["AXGroup", "AXHeading", "AXListItem", "AXCell", "AXBlockquote", "AXParagraph"]
            for j in 1..<min(6, chain.count) where blockRoles.contains(chain[j].role) {
                guard let f = chain[j].frame, f.height <= 600, f.insetBy(dx: -3, dy: -3).contains(scopes[pi].frame) else { continue }
                if let r = chain[wi].element.parameterized(AXAttr.markerRangeForElement, chain[j].element),
                   let block = (chain[wi].element.parameterized(AXAttr.stringForMarkerRange, r) as? String)?.cleanedForClipboard,
                   block.count > fragment.count, block.contains(fragment), block.count < 20_000 {
                    let isWebKit = (app?.bundleIdentifier ?? "").hasPrefix("com.apple.Safari") || (app?.bundleIdentifier ?? "").hasPrefix("com.apple.WebKit")
                    let text = isWebKit ? block : spacedBlockText(host: chain[wi].element, element: chain[j].element, raw: block)
                    scopes[pi].text = fullerText(text, block: chain[j].element)
                    scopes[pi].frame = f.intersection(clip(from: j))
                }
                break
            }
        }
        // Editors that draw their own text.
        if !codeHandled, let region = editorRegion(chain: chain, hint: hint, windowFrame: windowFrame, clip: clip(from: 0)) {
            codeRegion = region
            scopes.removeAll { $0.kind.isTextRange }
        }
        // Any other text that's clearly code but can't tell us where its characters are
        // (SwiftUI labels, plain <pre> blocks…): exact text, layout from pixels.
        if !codeHandled, codeRegion == nil, !scopes.contains(where: { $0.kind.isTextRange }),
           ["AXStaticText", "AXTextArea", "AXTextField", "AXGroup"].contains(chain[0].role),
           let f = chain[0].frame?.intersection(clip(from: 0)), f.isUsable,
           let value = (chain[0].element.attribute(AXAttr.value) as? String) ?? quickText(chain[0], inWeb: webIndex != nil),
           value.contains("\n"), value.count < 20_000, CodeAnalysis.looksLikeCode(value) {
            codeRegion = CodeRegion(rect: f, source: .text(value), language: CodeLanguage.guess(value), title: "Code")
        }

        // Engines that can't map a point to a text position (Chrome, Electron) still
        // group text into blocks: treat the block around a text run as its paragraph.
        var paragraphDepth: Int?
        if webIndex != nil, codeRegion == nil, scopes.isEmpty, chain[0].role == "AXStaticText" {
            paragraphDepth = (1..<min(3, chain.count)).first { j in
                ["AXGroup", "AXHeading", "AXListItem", "AXCell", "AXParagraph", "AXBlockquote"].contains(chain[j].role)
                    && (chain[j].frame?.height ?? .infinity) <= 480
            }
        }
        // A text run that's only part of its paragraph (the text before some inline code
        // or a bold word) isn't worth offering on its own: copying it cuts the sentence off.
        var partialRun = false
        if webIndex != nil, chain.count > 1, chain[0].role == "AXStaticText", Self.textBlockRoles.contains(chain[1].role),
           (chain[1].frame?.height ?? .infinity) <= 600,
           ((chain[1].element.attribute(AXAttr.children) as? [AXUIElement])?.count ?? 0) > 1 {
            partialRun = true
        }

        let isFinder = app?.bundleIdentifier == "com.apple.finder"
        var formChecks = 0
        // Forms are only looked for around a control you're pointing at: "Fields" is one ↑ away.
        let pointingAtControl = chain.prefix(3).contains { Self.inputRoles.contains($0.role) || $0.role == "AXSecureTextField" }
        // Secure fields: no text ranges (a browser would otherwise hand us the bullets).
        if chain.prefix(2).contains(where: { $0.subrole == "AXSecureTextField" || $0.role == "AXSecureTextField" }) {
            scopes.removeAll { $0.kind.isTextRange }
        }
        let pageURL = webIndex.flatMap { chain[$0].url }
        let videoPage = pageURL.flatMap(Self.timestampablePage)
        for (i, n) in chain.enumerated() {
            if i == 0, partialRun { continue }
            guard var f = n.frame, f.isUsable else { continue }
            f = f.intersection(clip(from: i))
            guard f.isUsable else { continue }

            var s = Scope(kind: n.role == "AXWindow" ? .window : .element, frame: f, label: label(for: n), element: n.element, role: n.role)
            s.depth = i
            if let wi = webIndex, i < wi { s.inWeb = true }
            if i >= 1, pointingAtControl, formChecks < 3, Self.formContainerRoles.contains(n.role) {
                formChecks += 1
                s.hasFields = hasFormControls(n.element)
            }
            if i == paragraphDepth {
                s.kind = .paragraph
                if n.role == "AXGroup" { s.label = "Paragraph" }
            }
            s.isVisual = isVisual(n)
            if s.isVisual, let vp = videoPage, n.subrole == "AXVideo" || n.roleDescription?.lowercased() == "video" || i <= 2 {
                s.videoPage = vp
            }

            if let u = n.url {
                if u.isFileURL {
                    // Trust the app: touching the disk here could trigger privacy
                    // prompts (Desktop, Documents…) just from hovering.
                    if webIndex == nil { s.fileURL = u }
                } else if n.role == "AXImage" {
                    s.imageURL = u
                } else if Self.isLinkScheme(u) {
                    s.linkURL = u
                    s.linkIsSelf = n.role == "AXLink"
                }
            }
            if s.linkURL == nil, i + 1 < chain.count {
                for j in (i + 1)...min(i + 3, chain.count - 1) where chain[j].role == "AXLink" {
                    if let u = chain[j].url, !u.isFileURL { s.linkURL = u; break }
                }
            }
            // Finder puts the URL on the name field; hovering elsewhere in the row
            // (size, kind, icon) should still find it.
            if s.fileURL == nil, isFinder, i <= 3, ["AXRow", "AXCell", "AXGroup", "AXImage"].contains(n.role) {
                s.fileURL = childFileURL(of: n.element, depth: n.role == "AXRow" ? 2 : 1)
            }
            if s.fileURL == nil, n.role == "AXWindow", let d = n.document, d.isFileURL {
                s.fileURL = d
            }
            if let f = s.fileURL, n.role != "AXWindow", n.role != "AXDockItem" {
                s.label = f.hasDirectoryPath && f.pathExtension.isEmpty ? "Folder" : "File"
            }

            if n.subrole == "AXSecureTextField" { s.role = "AXSecureTextField" }
            if n.role == "AXSecureTextField" || n.subrole == "AXSecureTextField" {
                s.label = "Password"
            } else if !s.isVisual {
                s.text = quickText(n, inWeb: webIndex != nil)
                s.textPending = s.text == nil && mightHaveText(n)
            }
            scopes.append(s)
        }

        addTableScopes(chain: chain, scopes: &scopes, clip: clip)
        addListScopes(chain: chain, scopes: &scopes)
        for i in scopes.indices where scopes[i].videoPage != nil && scopes[i].linkURL == nil {
            scopes[i].linkURL = scopes[i].videoPage
        }

        // The overlay we looked under is still useful: it's usually the card's link.
        if let o = overlay, let of = o.frame?.intersection(clip(from: 0)), of.isUsable {
            var s = Scope(kind: .element, frame: of, label: label(for: o), element: o.element, role: o.role)
            // Reachable with ↑ and ← →, but never the default: the text under it is.
            s.depth = 50
            if let u = o.url, !u.isFileURL, Self.isLinkScheme(u) {
                s.linkURL = u
                s.linkIsSelf = o.role == "AXLink"
                for i in scopes.indices where scopes[i].linkURL == nil && of.insetBy(dx: -2, dy: -2).contains(scopes[i].frame.center) {
                    scopes[i].linkURL = u
                }
            }
            s.textPending = true
            scopes.append(s)
        }

        // Nothing specific under the cursor, just a big surface: likely a colour pick.
        if !scopes.contains(where: { $0.kind.isTextRange }), codeRegion == nil,
           let i = scopes.firstIndex(where: { $0.depth == 0 }),
           Self.backdropRoles.contains(scopes[i].role ?? ""),
           scopes[i].linkURL == nil || !scopes[i].linkIsSelf, scopes[i].fileURL == nil, !scopes[i].isVisual {
            let f = scopes[i].frame
            let big = f.width * f.height >= max(160_000, 0.25 * (windowFrame.map { $0.width * $0.height } ?? 0))
            if scopes[i].role != "AXGroup" || big { scopes[i].isBackdrop = true }
        }

        var ins = Inspection(
            point: p,
            pid: pid,
            appName: app?.localizedName,
            bundleID: app?.bundleIdentifier,
            leaf: leaf,
            webArea: webIndex.map { chain[$0].element },
            scopes: scopes,
            defaultID: nil
        )
        #if DEBUG
        ins.debugChain = chain.map { "\($0.role)|\($0.subrole ?? "")|\($0.title ?? "")" } + [debugNote]
        debugNote = ""
        #endif
        ins.codeRegion = codeRegion
        ins.workingDirectory = hint.workingDirectory
        if let wi = webIndex {
            ins.sourceURL = chain[wi].url
            ins.sourceTitle = chain[wi].title ?? chain.last { $0.role == "AXWindow" }?.title
                ?? windowTitle(of: chain[wi].element) ?? windowTitle(pid: pid, at: p)
        } else if let w = chain.last(where: { $0.role == "AXWindow" }) {
            ins.sourceTitle = w.title.map { t in app?.localizedName.map { $0 == t ? t : "\(t) — \($0)" } ?? t }
            if let d = w.document, !d.isFileURL { ins.sourceURL = d }
        }
        ins.sortScopes()
        ins.defaultID = Self.chooseDefault(ins.scopes)
        return ins
    }

    static func chooseDefault(_ scopes: [Scope]) -> UUID? {
        if let s = scopes.first(where: { $0.kind == .barcode }) { return s.id }
        if let s = scopes.first(where: { $0.isPreferred }) { return s.id }
        if let s = scopes.first(where: { $0.fileURL != nil && $0.kind == .element && $0.depth <= 3 }) { return s.id }
        // An image wins over the link wrapped around it; Link stays one ← → away.
        if let s = scopes.first(where: { $0.isVisual && $0.kind == .element && $0.depth <= 1 }) { return s.id }
        if let s = scopes.first(where: { $0.linkIsSelf && $0.kind == .element && $0.depth <= 3 }) { return s.id }
        if let s = scopes.first(where: { $0.isVisual && $0.kind == .element && $0.depth <= 2 }) { return s.id }
        if let s = scopes.first(where: { $0.kind == .paragraph }) ?? scopes.first(where: { $0.kind == .line }) {
            return s.id
        }
        return scopes.first(where: { $0.kind == .element })?.id ?? scopes.first?.id
    }

    /// When accessibility has nothing for us (games, remote desktops, apps that
    /// don't implement it), fall back to the window under the cursor and let OCR do the work.
    private func fallback(at p: CGPoint) -> Inspection {
        var scopes: [Scope] = []
        var pid: pid_t = 0
        var name: String?
        if let w = WindowList.top(at: p, accept: { $0.pid != self.myPID && $0.layer < WindowList.overlayLayer }) {
            pid = w.pid
            name = w.owner
            var s = Scope(kind: .window, frame: w.bounds, label: w.owner ?? "Window")
            s.isVisual = true
            s.isBackdrop = true
            scopes.append(s)
        } else if let screen = ScreenSpace.displayBounds().first(where: { $0.contains(p) }) {
            var s = Scope(kind: .window, frame: screen, label: "Screen")
            s.isVisual = true
            s.isBackdrop = true
            scopes.append(s)
        }
        return Inspection(point: p, pid: pid, appName: name, bundleID: nil, leaf: nil, webArea: nil, scopes: scopes, defaultID: scopes.first?.id)
    }

    /// The title of the window holding `e` (browsers name it after the page), cached per window.
    private func windowTitle(of e: AXUIElement) -> String? {
        guard let w = e.attribute("AXWindow"), CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        let window = w as! AXUIElement
        let key = ElementKey(element: window)
        if let t = windowTitles[key] { return t.nonBlank }
        let t = window.string(AXAttr.title) ?? ""
        windowTitles[key] = t
        return t.nonBlank
    }

    /// The title of the app's window under `p` (Safari's web content doesn't lead up to its window).
    private func windowTitle(pid: pid_t, at p: CGPoint) -> String? {
        if let t = appWindowTitles[pid] { return t.nonBlank }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var title = ""
        for w in (app.attribute("AXWindows") as? [AXUIElement] ?? []).prefix(12) {
            let v = w.attributes([AXAttr.position, AXAttr.size, AXAttr.title])
            if let o = AXBox.cgPoint(v[AXAttr.position]), let sz = AXBox.cgSize(v[AXAttr.size]),
               CGRect(origin: o, size: sz).contains(p) {
                title = (v[AXAttr.title] as? String) ?? ""
                break
            }
        }
        appWindowTitles[pid] = title
        return title.nonBlank
    }

    // MARK: Element details

    private static let backdropRoles: Set<String> = [
        "AXWebArea", "AXScrollArea", "AXWindow", "AXSplitGroup", "AXLayoutArea", "AXUnknown", "AXGroup", "AXSheet",
    ]

    private static let valueTextRoles: Set<String> = ["AXStaticText", "AXTextField", "AXComboBox"]
    private static let titleTextRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXDockItem", "AXDisclosureTriangle", "AXTab", "AXCell",
    ]
    private static let silentRoles: Set<String> = [
        "AXImage", "AXScrollBar", "AXSplitter", "AXValueIndicator", "AXSlider", "AXGrowArea",
        "AXSecureTextField", "AXProgressIndicator", "AXBusyIndicator", "AXIncrementor",
    ]

    private func quickText(_ n: Node, inWeb: Bool) -> String? {
        if Self.valueTextRoles.contains(n.role) {
            return (n.element.attribute(AXAttr.value) as? String)?.cleanedForClipboard.nonBlank ?? n.title
        }
        if Self.titleTextRoles.contains(n.role) && !inWeb {
            return n.title ?? (n.element.attribute(AXAttr.value) as? String)?.cleanedForClipboard.nonBlank ?? n.desc
        }
        return nil
    }

    private func mightHaveText(_ n: Node) -> Bool {
        !Self.silentRoles.contains(n.role)
    }

    private func isVisual(_ n: Node) -> Bool {
        if n.role == "AXImage" { return true }
        let rd = n.roleDescription?.lowercased() ?? ""
        return n.subrole == "AXVideo" || rd == "video" || rd == "canvas" || rd == "image"
    }

    /// Full text of a container, fetched lazily because it can be expensive.
    func resolveText(for s: Scope, webArea: AXUIElement?) -> String? {
        guard let e = s.element else { return nil }
        let key = ElementKey(element: e)
        if let cached = textCache[key] { return cached.isEmpty ? nil : cached }

        var result: String?
        if s.role != "AXSecureTextField" {
            if let web = webArea {
                for host in [e, web] {
                    if let r = host.parameterized(AXAttr.markerRangeForElement, e),
                       let str = host.parameterized(AXAttr.stringForMarkerRange, r) as? String,
                       let t = str.cleanedForClipboard.nonBlank {
                        result = t
                        break
                    }
                }
                // Chromium joins block elements without line breaks ("Title.Body…");
                // rebuild multi-block text from the layout instead.
                if let r = result, !r.contains("\n"), s.frame.height > 40, let laidOut = collectText(under: e), laidOut.contains("\n") {
                    result = laidOut
                }
                // …and stops a paragraph's text at its first inline element.
                if let r = result, Self.textBlockRoles.contains(s.role ?? ""), s.frame.height <= 600 {
                    result = fullerText(r, block: e)
                }
            }
            if result == nil, ["AXTextArea", "AXTextField", "AXStaticText", "AXComboBox"].contains(s.role ?? "") {
                result = (e.attribute(AXAttr.value) as? String)?.cleanedForClipboard.nonBlank
            }
            if result == nil {
                result = collectText(under: e)
            }
        }
        textCache[key] = result ?? ""
        return result
    }

    /// A paragraph's text exactly as written, from its text runs in order. Chromium's text
    /// markers stop at the first inline element (code, bold, a link), and laying the runs
    /// out by position adds spaces that aren't there ("( excludetest )"). Nil when the
    /// block holds other blocks (lists, tables), whose line breaks this would lose.
    func inlineText(of root: AXUIElement) -> String? {
        var out = ""
        var stack: [AXUIElement] = [root]
        var visited = 0
        let names = [AXAttr.role, AXAttr.value, AXAttr.children]
        let blocks: Set<String> = ["AXList", "AXListItem", "AXTable", "AXOutline", "AXHeading", "AXTextArea", "AXBlockquote", "AXParagraph"]
        while let e = stack.popLast() {
            visited += 1
            guard visited < 400 else { return nil }
            let v = e.attributes(names)
            let role = v[AXAttr.role] as? String ?? ""
            if visited > 1, blocks.contains(role) { return nil }
            if Self.silentRoles.contains(role) { continue }
            if role == "AXStaticText" {
                out += v[AXAttr.value] as? String ?? ""
                continue
            }
            stack.append(contentsOf: (v[AXAttr.children] as? [AXUIElement] ?? []).reversed())
        }
        return out.cleanedForClipboard.nonBlank
    }

    /// Prefers the paragraph rebuilt from its runs when the engine's own text for it
    /// stopped short (same text so far, just cut off).
    private func fullerText(_ text: String, block: AXUIElement) -> String {
        guard let inline = inlineText(of: block) else { return text }
        let a = text.filter { !$0.isWhitespace }, b = inline.filter { !$0.isWhitespace }
        return b.count > a.count && b.contains(a) ? inline : text
    }

    /// Walks the subtree gathering visible text in reading order, within a time budget.
    func collectText(under root: AXUIElement) -> String? {
        let deadline = CFAbsoluteTimeGetCurrent() + 0.12
        var pieces: [(String, CGRect?)] = []
        var stack: [AXUIElement] = [root]
        var visited = 0
        var total = 0
        let names = [AXAttr.role, AXAttr.subrole, AXAttr.value, AXAttr.title, AXAttr.position, AXAttr.size, AXAttr.children]

        while let e = stack.popLast(), visited < 1200, total < 60_000, CFAbsoluteTimeGetCurrent() < deadline {
            visited += 1
            let v = e.attributes(names)
            let role = v[AXAttr.role] as? String ?? ""
            var frame: CGRect?
            if let p = AXBox.cgPoint(v[AXAttr.position]), let s = AXBox.cgSize(v[AXAttr.size]) {
                frame = CGRect(origin: p, size: s)
            }
            let kids = v[AXAttr.children] as? [AXUIElement] ?? []

            if Self.silentRoles.contains(role) || (v[AXAttr.subrole] as? String) == "AXSecureTextField" { continue }
            if ["AXStaticText", "AXTextField", "AXTextArea", "AXComboBox"].contains(role),
               let s = (v[AXAttr.value] as? String)?.nonBlank {
                pieces.append((s, frame))
                total += s.count
                continue
            }
            if Self.titleTextRoles.contains(role) || role == "AXLink", kids.isEmpty,
               let s = (v[AXAttr.title] as? String)?.nonBlank {
                pieces.append((s, frame))
                total += s.count
                continue
            }
            stack.append(contentsOf: kids.reversed())
        }

        var out = ""
        var prev: CGRect?
        for (s, f) in pieces {
            let piece = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if out.isEmpty {
                out = piece
            } else if let f, let pf = prev,
                      abs(f.midY - pf.midY) < max(4, min(f.height, pf.height) * 0.5),
                      f.minX >= pf.minX - 1 {
                out += (f.minX - pf.maxX > 28 ? "\t" : " ") + piece
            } else {
                out += "\n" + piece
            }
            if let f { prev = f }
        }
        return out.cleanedForClipboard.nonBlank
    }

    // MARK: Text ranges

    private static let cocoaTextRoles: Set<String> = ["AXTextArea", "AXTextField", "AXStaticText", "AXComboBox"]
    private static let webTextLeafRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXComboBox", "AXLink", "AXHeading", "AXListMarker"]

    private func textRangeScopes(chain: [Node], webIndex: Int?, at p: CGPoint, clip: CGRect, hint: CodeHint) -> [Scope] {
        guard !isVisual(chain[0]) else { return [] }
        if let wi = webIndex {
            // Only trust ranges that start from real text. (Safari also reports
            // Live Text fragments from inside images; our own OCR reads those better.)
            if Self.webTextLeafRoles.contains(chain[0].role) {
                return webScopes(hosts: [chain[wi].element, chain[0].element], at: p, clip: clip)
            }
            // Between two lines of a paragraph there's no text at the exact point;
            // snap to the nearest line so the selection doesn't drop to "Group".
            if Self.textBlockRoles.contains(chain[0].role), let f = chain[0].frame, f.height <= 600, f.contains(p),
               let (q, leaf) = snapToLine(block: chain[0].element, blockFrame: f, at: p) {
                return webScopes(hosts: [chain[wi].element, leaf], at: q, clip: clip)
            }
            return []
        }
        for n in chain.prefix(2) where Self.cocoaTextRoles.contains(n.role) {
            let r = cocoaScopes(n.element, at: p, clip: clip, hint: hint)
            if !r.isEmpty { return r }
        }
        return []
    }

    /// Word / line / sentence / paragraph for native (AppKit-style) text.
    /// For text views that can say where a character is but not which character is
    /// at a point (Xcode's editor): binary-search the visible characters by their rectangles.
    private func indexByBounds(_ e: AXUIElement, at p: CGPoint) -> Int? {
        guard let total = (e.attribute(AXAttr.numberOfCharacters) as? NSNumber)?.intValue, total > 0 else { return nil }
        let visible = AXBox.cfRange(e.attribute("AXVisibleCharacterRange")) ?? CFRange(location: 0, length: total)
        var lo = max(0, visible.location)
        var hi = min(total, visible.location + visible.length) - 1
        guard hi >= lo else { return nil }
        func rect(_ i: Int) -> CGRect? { AXBox.rect(e.parameterized(AXAttr.boundsForRange, AXBox.range(CFRange(location: i, length: 1)))) }
        var steps = 0
        while lo < hi, steps < 40 {
            steps += 1
            let mid = (lo + hi) / 2
            guard let r = rect(mid) else { return nil }
            let before = r.maxY <= p.y || (r.minY <= p.y && p.y < r.maxY && r.maxX <= p.x && r.width > 0)
            if before { lo = mid + 1 } else { hi = mid }
        }
        guard let r = rect(lo), r.minY - 3 <= p.y, p.y <= r.maxY + 3 else { return nil }
        return lo
    }

    private func cocoaScopes(_ e: AXUIElement, at p: CGPoint, clip: CGRect, hint: CodeHint) -> [Scope] {
        let idx: Int
        if let hitRange = AXBox.cfRange(e.parameterized(AXAttr.rangeForPosition, AXBox.point(p))),
           hitRange.location >= 0, hitRange.location != kCFNotFound {
            idx = hitRange.location
        } else if hint.isCodeApp, let i = indexByBounds(e, at: p) {
            idx = i
        } else {
            return []
        }
        let total = (e.attribute(AXAttr.numberOfCharacters) as? NSNumber)?.intValue
        if let code = cocoaCodeScopes(e, index: idx, total: total, at: p, clip: clip, hint: hint) {
            return code
        }
        let lo = max(0, idx - 3000)
        let hi = min(total ?? (idx + 3000), idx + 3000)
        guard hi > lo else { return [] }

        let chunk: String
        if let s = e.parameterized(AXAttr.stringForRange, AXBox.range(CFRange(location: lo, length: hi - lo))) as? String {
            chunk = s
        } else if let v = e.attribute(AXAttr.value) as? String {
            let full = v as NSString
            guard lo < full.length else { return [] }
            chunk = full.substring(with: NSRange(location: lo, length: min(hi, full.length) - lo))
        } else {
            return []
        }
        let ns = chunk as NSString
        let li = idx - lo
        guard ns.length > 0, li >= 0, li < ns.length else { return [] }

        func bounds(_ r: NSRange) -> CGRect? {
            let t = TextRanges.trim(r, in: ns)
            guard t.length > 0 else { return nil }
            let g = CFRange(location: lo + t.location, length: t.length)
            var rect = AXBox.rect(e.parameterized(AXAttr.boundsForRange, AXBox.range(g)))
            if t.length > 1 {
                for c in [CFRange(location: g.location, length: 1), CFRange(location: g.location + g.length - 1, length: 1)] {
                    if let b = AXBox.rect(e.parameterized(AXAttr.boundsForRange, AXBox.range(c))), b.width > 0 || b.height > 0 {
                        rect = rect.map { $0.union(b) } ?? b
                    }
                }
            }
            guard let r = rect?.intersection(clip), !r.isNull, r.width >= 1, r.height >= 2 else { return nil }
            return r
        }
        func text(_ r: NSRange) -> String? {
            ns.substring(with: TextRanges.trim(r, in: ns)).cleanedForClipboard.nonBlank
        }

        let para = ns.paragraphRange(for: NSRange(location: li, length: 0))
        var lineRange: NSRange?
        if let ln = e.parameterized(AXAttr.lineForIndex, idx as CFNumber) as? NSNumber,
           let lr = AXBox.cfRange(e.parameterized(AXAttr.rangeForLine, ln as CFNumber)) {
            let l = NSRange(location: lr.location - lo, length: lr.length)
                .intersection(NSRange(location: 0, length: ns.length))
            if let l, l.length > 0 { lineRange = l }
        }

        // The cursor has to be over text, not in the margin past the end of a line.
        guard let probe = bounds(lineRange ?? para), probe.insetBy(dx: -8, dy: -3).contains(p) else { return [] }

        var out: [Scope] = []
        if let w = TextRanges.word(in: ns, at: li, within: para), let b = bounds(w),
           b.insetBy(dx: -3, dy: -3).contains(p), let t = text(w) {
            out.append(Scope(kind: .word, frame: b, label: "Word", text: t))
        }
        if let l = lineRange, let b = bounds(l), let t = text(l) {
            out.append(Scope(kind: .line, frame: b, label: "Line", text: t))
        }
        if let s = TextRanges.sentence(in: ns, at: li, within: para), let b = bounds(s), let t = text(s) {
            out.append(Scope(kind: .sentence, frame: b, label: "Sentence", text: t))
        }
        if let b = bounds(para), let t = text(para) {
            out.append(Scope(kind: .paragraph, frame: b, label: "Paragraph", text: t))
        }
        let lineR = ns.lineRange(for: NSRange(location: li, length: 0))
        let lineText = ns.substring(with: lineR)
        let literal = SmartData.color(in: lineText, at: li - lineR.location)
        let path = SmartData.path(in: lineText, at: li - lineR.location, cwd: hint.workingDirectory)
        for i in out.indices where out[i].kind == .word || out[i].kind == .line {
            out[i].colorLiteral = literal
            out[i].pathURL = path
        }
        return TextRanges.dedupe(out)
    }

    /// The same, for web content (Safari, Chrome, Electron, Firefox) via text markers.
    private func webScopes(hosts: [AXUIElement], at p: CGPoint, clip: CGRect) -> [Scope] {
        let point = AXBox.point(p)
        guard let web = hosts.first else { return [] }
        var host = web
        var marker: CFTypeRef?
        for e in hosts {
            if let m = e.parameterized(AXAttr.textMarkerForPosition, point) {
                host = e
                marker = m
                break
            }
        }

        func make(_ range: CFTypeRef?, _ kind: ScopeKind, _ label: String) -> Scope? {
            guard let range,
                  let raw = host.parameterized(AXAttr.stringForMarkerRange, range) as? String,
                  let text = raw.cleanedForClipboard.nonBlank,
                  let b = AXBox.rect(host.parameterized(AXAttr.boundsForMarkerRange, range))?.intersection(clip),
                  b.isUsable || (b.width >= 1 && b.height >= 2) else { return nil }
            return Scope(kind: kind, frame: b, label: label, text: text)
        }
        func covers(_ s: Scope?, slack: CGFloat = 0) -> Bool {
            s?.frame.insetBy(dx: -8 - slack, dy: -3 - slack).contains(p) ?? false
        }
        func line(at m: CFTypeRef) -> Scope? {
            var l = make(host.parameterized(AXAttr.lineRange, m), .line, "Line")
            if !covers(l) {
                l = [make(host.parameterized(AXAttr.rightLine, m), .line, "Line"), make(host.parameterized(AXAttr.leftLine, m), .line, "Line")]
                    .compactMap { $0 }.first { covers($0) }
            }
            return l
        }

        var lineScope: Scope?
        var word: Scope?
        if let m = marker { lineScope = line(at: m) }
        // Chrome can't map a point to text (and overlays fool Safari): walk the text
        // under the cursor instead, line by line, then word by word.
        if lineScope == nil, hosts.count > 1, let walked = walkToWord(host: web, leaf: hosts[1], at: p, clip: clip) {
            host = web
            marker = walked.marker
            lineScope = walked.line
            word = walked.word
        }
        guard let lineScope, let marker else { return [] }

        var marker2 = marker
        if word == nil {
            let words = [make(host.parameterized(AXAttr.rightWord, marker), .word, "Word"),
                         make(host.parameterized(AXAttr.leftWord, marker), .word, "Word")].compactMap { $0 }
            word = words.first { $0.frame.insetBy(dx: -2, dy: -2).contains(p) && ($0.text?.count ?? 0) < 80 }
        }
        // A position marker that landed in an overlay finds the line but not the word.
        if word == nil, hosts.count > 1, let walked = walkToWord(host: web, leaf: hosts[1], at: p, clip: clip), walked.word != nil {
            host = web
            word = walked.word
            marker2 = walked.marker
        }
        // A lone "." just past the end of a line: the word before it is what you mean.
        if let w = word, !(w.text ?? "").contains(where: { $0.isLetter || $0.isNumber }) {
            let prev = make(host.parameterized(AXAttr.leftWord, marker2), .word, "Word")
            let near = prev.map { abs($0.frame.midY - w.frame.midY) < max(4, w.frame.height / 2) && w.frame.minX - $0.frame.maxX < 30 } ?? false
            word = near && (prev?.text ?? "").contains(where: { $0.isLetter || $0.isNumber }) ? prev : nil
        }
        var out = [lineScope]
        if let w = word { out.append(w) }
        if let s = make(host.parameterized(AXAttr.sentenceRange, marker2), .sentence, "Sentence"), covers(s, slack: 4) { out.append(s) }
        if let pa = make(host.parameterized(AXAttr.paragraphRange, marker2), .paragraph, "Paragraph"), covers(pa, slack: 4) { out.append(pa) }
        return TextRanges.dedupe(out)
    }

    /// Chromium drops the space where a paragraph soft-wraps ("matrix barcode⏎invented"
    /// comes out as "barcodeinvented"). Rebuild the text from its visual lines, and only
    /// use that when it holds exactly the same characters.
    private func spacedBlockText(host: AXUIElement, element: AXUIElement, raw: String) -> String {
        guard let r = host.parameterized(AXAttr.markerRangeForElement, element), CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return raw }
        let target = raw.filter { !$0.isWhitespace }
        var m: CFTypeRef = AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
        var lines: [String] = []
        var got = 0
        for _ in 0..<400 {
            guard let lr = host.parameterized(AXAttr.lineRange, m),
                  let s = host.parameterized(AXAttr.stringForMarkerRange, lr) as? String else { break }
            let t = s.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, lines.last != t {
                lines.append(t)
                got += t.filter { !$0.isWhitespace }.count
            }
            if got >= target.count { break }
            let end = AXTextMarkerRangeCopyEndMarker(lr as! AXTextMarkerRange)
            guard let next = host.parameterized("AXNextTextMarkerForTextMarker", end), !CFEqual(next, m) else { break }
            m = next
        }
        let rebuilt = lines.joined(separator: " ")
        return rebuilt.filter { !$0.isWhitespace } == target ? rebuilt : raw
    }

    /// Steps through a text element with markers: find the visual line under the
    /// cursor, then the word. A few dozen cheap calls, and the only way to get
    /// word-level precision out of Chrome and Electron.
    static let textBlockRoles: Set<String> = ["AXGroup", "AXParagraph", "AXListItem", "AXHeading", "AXCell", "AXBlockquote"]

    /// The nearest text above or below `p` inside `block` (the gap between two lines,
    /// or a paragraph's padding): the point to use and the text element found there.
    private func snapToLine(block: AXUIElement, blockFrame: CGRect, at p: CGPoint, tolerance: CGFloat = 16) -> (CGPoint, AXUIElement)? {
        func text(at q: CGPoint) -> (CGPoint, AXUIElement)? {
            guard blockFrame.contains(q), let e = hit(q) else { return nil }
            let n = node(e)
            return Self.webTextLeafRoles.contains(n.role) && (n.frame?.insetBy(dx: -2, dy: -2).contains(q) ?? false) ? (q, e) : nil
        }
        // Above and below first (between lines), then sideways (past a line's end, or
        // in front of an indented line).
        var d: CGFloat = 3
        while d <= tolerance {
            if let f = text(at: CGPoint(x: p.x, y: p.y - d)) ?? text(at: CGPoint(x: p.x, y: p.y + d)) { return f }
            d += 3
        }
        d = 10
        while d <= 120 {
            if let f = text(at: CGPoint(x: p.x - d, y: p.y)) ?? text(at: CGPoint(x: p.x + d, y: p.y)) { return f }
            d += 10
        }
        return nil
    }

    private func walkToWord(host: AXUIElement, leaf: AXUIElement, at p: CGPoint, clip: CGRect)
        -> (marker: CFTypeRef, line: Scope, word: Scope?)? {
        guard let r = host.parameterized(AXAttr.markerRangeForElement, leaf), CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        func bounds(_ range: CFTypeRef?) -> CGRect? { AXBox.rect(range.flatMap { host.parameterized(AXAttr.boundsForMarkerRange, $0) }) }
        func string(_ range: CFTypeRef?) -> String? { range.flatMap { host.parameterized(AXAttr.stringForMarkerRange, $0) as? String } }

        var m: CFTypeRef = AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
        var lineRange: CFTypeRef?
        var lineRect: CGRect?
        for _ in 0..<60 {
            guard let lr = host.parameterized(AXAttr.lineRange, m), let lb = bounds(lr), lb.height > 0 else { return nil }
            if lb.minY - 2 <= p.y && p.y <= lb.maxY + 2 {
                lineRange = lr
                lineRect = lb
                break
            }
            if lb.minY > p.y + 2 { return nil }
            let end = AXTextMarkerRangeCopyEndMarker(lr as! AXTextMarkerRange)
            guard let next = host.parameterized("AXNextTextMarkerForTextMarker", end), !CFEqual(next, m) else { return nil }
            m = next
        }
        guard let lineRange, let lineRect, lineRect.insetBy(dx: -8, dy: -3).contains(p),
              let lineText = string(lineRange)?.cleanedForClipboard.nonBlank else { return nil }
        let line = Scope(kind: .line, frame: lineRect.intersection(clip), label: "Line", text: lineText)

        var w: CFTypeRef = AXTextMarkerRangeCopyStartMarker(lineRange as! AXTextMarkerRange)
        var inside: CFTypeRef = w
        for _ in 0..<120 {
            guard let wEnd = host.parameterized("AXNextWordEndTextMarkerForTextMarker", w), !CFEqual(wEnd, w),
                  let wr = host.parameterized(AXAttr.leftWord, wEnd), let wb = bounds(wr) else { break }
            if wb.minY > lineRect.maxY + 2 { break }
            inside = wEnd
            if wb.insetBy(dx: -1, dy: -3).contains(p) {
                let text = string(wr)?.cleanedForClipboard.nonBlank
                return (wEnd, line, text.map { Scope(kind: .word, frame: wb.intersection(clip), label: "Word", text: $0) })
            }
            if wb.minX > p.x { break }
            w = wEnd
        }
        return (inside, line, nil)
    }

    // MARK: Tables

    private static let tableRoles: Set<String> = ["AXTable", "AXOutline", "AXGrid"]

    /// Row, column and whole-table scopes for anything that looks like a table.
    private func addTableScopes(chain: [Node], scopes: inout [Scope], clip: (Int) -> CGRect) {
        guard let ti = chain.prefix(7).firstIndex(where: { Self.tableRoles.contains($0.role) }) else { return }
        let table = chain[ti]
        let rowIndex = chain[..<ti].firstIndex { $0.role == "AXRow" }
        let cellIndex = chain[..<ti].firstIndex { $0.role == "AXCell" }

        if let ri = rowIndex, let si = scopes.firstIndex(where: { $0.element.map { CFEqual($0, chain[ri].element) } ?? false }),
           scopes[si].fileURL == nil {
            scopes[si].kind = .table
            scopes[si].tableRef = TableRef(table: table.element, row: chain[ri].element, column: nil, part: .row)
            if let n = (chain[ri].element.attribute("AXIndex") as? NSNumber)?.intValue { scopes[si].label = "Row \(n + 1)" }
            scopes[si].text = nil
            scopes[si].textPending = true
        }
        if let ci = cellIndex, let cellFrame = chain[ci].frame {
            var column = AXBox.cfRange(chain[ci].element.attribute("AXColumnIndexRange"))?.location
            if column == nil, let ri = rowIndex, let kids = chain[ri].element.attribute(AXAttr.children) as? [AXUIElement] {
                column = kids.firstIndex { CFEqual($0, chain[ci].element) }
            }
            let visible = (table.frame ?? cellFrame).intersection(clip(ti))
            if let column, visible.isUsable {
                var label = "Column"
                if let headers = table.element.attribute("AXColumnHeaderUIElements") as? [AXUIElement], column < headers.count {
                    let h = headers[column]
                    if let t = h.string(AXAttr.title) ?? h.string(AXAttr.value) ?? h.string(AXAttr.description) { label += " · \(t)" }
                } else {
                    // No declared headers: the first row usually is one. Fetch just that row.
                    var first: CFArray?
                    if AXUIElementCopyAttributeValues(table.element, "AXRows" as CFString, 0, 1, &first) == .success,
                       let row = (first as? [AXUIElement])?.first, let cell = cells(of: row)[safe: column] {
                        let t = cellText(cell)
                        if !t.isEmpty, t.count < 40 { label += " · \(t)" }
                    }
                }
                var col = Scope(kind: .table, frame: CGRect(x: cellFrame.minX, y: visible.minY, width: cellFrame.width, height: visible.height),
                                label: label, element: table.element, role: "AXColumn")
                col.depth = ci
                col.tableRef = TableRef(table: table.element, row: nil, column: column, part: .column)
                col.textPending = true
                scopes.append(col)
            }
        }
        if let si = scopes.firstIndex(where: { s in s.role != "AXColumn" && (s.element.map { CFEqual($0, table.element) } ?? false) }) {
            scopes[si].kind = .table
            scopes[si].label = "Table"
            scopes[si].tableRef = TableRef(table: table.element, row: nil, column: nil, part: .table)
            scopes[si].text = nil
            scopes[si].textPending = true
        }
    }

    private func cells(of row: AXUIElement) -> [AXUIElement] {
        let kids = row.attribute(AXAttr.children) as? [AXUIElement] ?? []
        let cells = kids.filter { $0.string(AXAttr.role) == "AXCell" }
        return cells.isEmpty ? kids : cells
    }

    private func cellText(_ cell: AXUIElement) -> String {
        let v = cell.attributes([AXAttr.role, AXAttr.value, AXAttr.title, AXAttr.children])
        var t = (v[AXAttr.value] as? String)?.nonBlank ?? (v[AXAttr.title] as? String)?.nonBlank
        if t == nil, let kids = v[AXAttr.children] as? [AXUIElement] {
            t = kids.prefix(6).compactMap { k -> String? in
                let kv = k.attributes([AXAttr.value, AXAttr.title, AXAttr.children])
                if let s = (kv[AXAttr.value] as? String)?.nonBlank ?? (kv[AXAttr.title] as? String)?.nonBlank { return s }
                // One level deeper (web cells wrap text in groups/links).
                return (kv[AXAttr.children] as? [AXUIElement])?.prefix(4).compactMap {
                    ($0.attribute(AXAttr.value) as? String)?.nonBlank ?? $0.string(AXAttr.title)
                }.joined(separator: " ").nonBlank
            }.joined(separator: " ")
        }
        return (t ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Tab-separated text for a row, a column or a whole table.
    func tableText(_ ref: TableRef) -> String? {
        let rows = Array((ref.table.attribute("AXRows") as? [AXUIElement] ?? []).prefix(2000))
        let headers = (ref.table.attribute("AXColumnHeaderUIElements") as? [AXUIElement] ?? []).map {
            ($0.string(AXAttr.title) ?? ($0.attribute(AXAttr.value) as? String) ?? $0.string(AXAttr.description) ?? "")
        }
        switch ref.part {
        case .list:
            return listText(ref.table)
        case .row:
            guard let row = ref.row else { return nil }
            return cells(of: row).map(cellText).joined(separator: "\t").nonBlank
        case .column:
            guard let c = ref.column else { return nil }
            var out: [String] = []
            if c < headers.count, !headers[c].isEmpty { out.append(headers[c]) }
            for r in rows { out.append(cells(of: r)[safe: c].map(cellText) ?? "") }
            while out.last == "" { out.removeLast() }
            return out.joined(separator: "\n").nonBlank
        case .table:
            var out: [String] = []
            if headers.contains(where: { !$0.isEmpty }) { out.append(headers.joined(separator: "\t")) }
            for r in rows { out.append(cells(of: r).map(cellText).joined(separator: "\t")) }
            return out.joined(separator: "\n").nonBlank
        }
    }

    // MARK: Files

    private func childFileURL(of e: AXUIElement, depth: Int) -> URL? {
        guard depth > 0, let kids = e.attribute(AXAttr.children) as? [AXUIElement] else { return nil }
        for k in kids.prefix(8) {
            if let u = AXBox.url(k.attribute(AXAttr.url)), u.isFileURL { return u }
        }
        for k in kids.prefix(8) {
            if let u = childFileURL(of: k, depth: depth - 1) { return u }
        }
        return nil
    }

    // MARK: Labels

    private func label(for n: Node) -> String {
        switch n.role {
        case "AXStaticText": return "Text"
        case "AXLink": return "Link"
        case "AXImage": return "Image"
        case "AXButton": return "Button"
        case "AXWindow": return "Window"
        case "AXWebArea": return "Page"
        case "AXTextArea": return "Text area"
        case "AXTextField": return n.subrole == "AXSearchField" ? "Search field" : "Text field"
        case "AXRow": return "Row"
        case "AXCell": return "Cell"
        case "AXTable", "AXOutline", "AXList": return "List"
        case "AXHeading": return "Heading"
        case "AXDockItem": return "Dock item"
        case "AXMenuItem": return "Menu item"
        case "AXMenuBarItem": return "Menu"
        case "AXScrollArea": return "Scroll area"
        case "AXToolbar": return "Toolbar"
        case "AXGroup":
            if let rd = n.roleDescription, rd.lowercased() != "group" { return rd.capitalizedFirst }
            return "Group"
        default:
            if let rd = n.roleDescription?.nonBlank { return rd.capitalizedFirst }
            return String(n.role.dropFirst(2))
        }
    }

    static func isLinkScheme(_ u: URL) -> Bool {
        guard let s = u.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "ftp", "tel", "sms"].contains(s) || (s.count > 2 && !["file", "about", "data", "javascript", "blob"].contains(s))
    }
}

// MARK: - Text range helpers

enum TextRanges {
    static func trim(_ r: NSRange, in ns: NSString) -> NSRange {
        var start = r.location
        var end = r.location + r.length
        let ws = CharacterSet.whitespacesAndNewlines
        while start < end, let u = UnicodeScalar(ns.character(at: start)), ws.contains(u) { start += 1 }
        while end > start, let u = UnicodeScalar(ns.character(at: end - 1)), ws.contains(u) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    static func word(in ns: NSString, at i: Int, within limit: NSRange) -> NSRange? {
        let lo = max(limit.location, i - 200)
        let hi = min(limit.location + limit.length, i + 200)
        guard hi > lo else { return nil }
        var found: NSRange?
        ns.enumerateSubstrings(in: NSRange(location: lo, length: hi - lo), options: [.byWords, .substringNotRequired]) { _, r, _, stop in
            if NSLocationInRange(i, r) {
                found = r
                stop.pointee = true
            }
        }
        return found
    }

    static func sentence(in ns: NSString, at i: Int, within para: NSRange) -> NSRange? {
        guard para.length < 6000 else { return nil }
        var found: NSRange?
        ns.enumerateSubstrings(in: para, options: [.bySentences, .substringNotRequired]) { _, r, _, stop in
            if NSLocationInRange(i, r) {
                found = r
                stop.pointee = true
            }
        }
        return found
    }

    /// Ordered smallest → largest. When two granularities produce the same text,
    /// keep the larger one so ↑ / ↓ never feel like they did nothing.
    static func dedupe(_ input: [Scope]) -> [Scope] {
        let order: [ScopeKind] = [.word, .line, .sentence, .paragraph]
        let sorted = input.sorted { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
        var out: [Scope] = []
        for s in sorted.reversed() {
            if let bigger = out.last, bigger.text == s.text {
                if s.kind == .line && bigger.kind == .paragraph { out[out.count - 1].label = "Line" }
                continue
            }
            out.append(s)
        }
        return out.reversed()
    }
}

extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}

// MARK: - Window list

enum WindowList {
    /// Our overlay windows live at the screen-saver level and above.
    static let overlayLayer = Int(CGWindowLevelForKey(.screenSaverWindow))

    struct Info {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let layer: Int
        let owner: String?
        let alpha: Double
    }

    static func onScreen() -> [Info] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { d in
            guard let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { return nil }
            return Info(
                id: (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0,
                pid: pid,
                bounds: b,
                layer: layer,
                owner: d[kCGWindowOwnerName as String] as? String,
                alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            )
        }
    }

    static func top(at p: CGPoint, accept: (Info) -> Bool) -> Info? {
        onScreen().first { $0.bounds.contains(p) && $0.alpha > 0.01 && accept($0) }
    }
}
