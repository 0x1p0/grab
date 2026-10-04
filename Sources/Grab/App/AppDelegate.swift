import AppKit
import CryptoKit
import Quartz
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let permissions = Permissions.shared
    private let keyTap = KeyTap()
    private var copyKeyCodes = KeyLayout.keyCodes(typing: "c")
    private var actionKeyCodes = AppDelegate.actionKeys()
    private var overlay: OverlayController!
    private var session: Session!
    private var status: StatusItemController!
    let windows = WindowCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Sound.shared.prepare()
        TempFiles.clear()
        _ = Stats.shared

        overlay = OverlayController()
        session = Session(overlay: overlay)
        status = StatusItemController(app: self)

        session.statusItemFrame = { [weak self] in self?.status.buttonFrame() }
        session.onCopied = { [weak self] landing in self?.status.celebrate(at: landing) }
        NotificationCenter.default.addObserver(forName: .grabMascotPreview, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.previewMascot(at: ScreenSpace.mouseLocation()) }
        }
        session.onLostOption = { [weak self] in self?.keyTap.resetHold() }
        session.onEndHold = { [weak self] in self?.keyTap.suppressCurrentHold() }
        keyTap.onAction = { [weak self] action in self?.session.handle(action) }

        applySettings()
        NotificationCenter.default.addObserver(forName: .grabSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }

        // Re-map ⌥C whenever the keyboard layout changes.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.copyKeyCodes = KeyLayout.keyCodes(typing: "c")
                self.actionKeyCodes = AppDelegate.actionKeys()
                self.applySettings()
            }
        }

        // Apps where ⌥ means something else (Figma's measurements, games…) can opt out.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }

        permissions.onChange = { [weak self] in self?.permissionsChanged() }
        permissions.startMonitoring()
        startTapIfPossible()
        // Nothing heavy at launch: capture and Vision start when you first hold ⌥.

        if !settings.hasOnboarded || !permissions.accessibility {
            windows.showOnboarding()
        }

        #if DEBUG
        installDebugHooks()
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if permissions.accessibility { windows.showSettings() } else { windows.showOnboarding() }
        return false
    }

    /// `grab://copy?mode=text`, `grab://history`, `grab://shelf`, `grab://pause`… for Shortcuts and scripts.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "grab" {
            let command = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch command {
            case "copy", "grab":
                let mode = query.first { $0.name == "mode" }?.value.flatMap { name in
                    GrabMode.allCases.first { $0.title.lowercased() == name.lowercased() }
                }
                session.grabNow(mode: mode)
            case "history": Panels.shared.showHistory()
            case "shelf": Panels.shared.showShelf()
            case "pause": settings.paused = true
            case "resume": settings.paused = false
            case "toggle": settings.paused.toggle()
            case "settings": windows.showSettings()
            default: break
            }
        }
    }

    // Quick Look asks the responder chain for a controller; with no windows of our own, that's us.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.begin(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.end(panel)
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyTap.stop()
    }

    private func applySettings() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let excluded = settings.excludedApps.contains(frontmost)
        keyTap.config = KeyTap.Config(
            armDelay: settings.armDelay,
            quickCopy: settings.quickCopy,
            enabled: !settings.paused && !excluded,
            copyKeyCodes: copyKeyCodes,
            actionKeyCodes: actionKeyCodes,
            trigger: settings.trigger
        )
        overlay?.applySharing()
        Updater.shared.applySettings()
        if settings.paused, session?.armed == true {
            keyTap.suppressCurrentHold()
            session.disarm(cancelled: true)
        }
        status?.refresh()
    }

    /// ⏎ and space are fixed; letters follow the keyboard layout like ⌥C does.
    private static func actionKeys() -> [Int64: GrabAction] {
        var keys: [Int64: GrabAction] = [36: .open, 76: .open, 49: .look]
        let letters: [(String, Int64, GrabAction)] = [
            ("p", 35, .pin), ("s", 1, .speak), ("t", 17, .translate), ("e", 14, .ask), ("z", 6, .undo),
            ("r", 15, .box), ("v", 9, .pasteNext), ("d", 2, .compare), ("f", 3, .fill),
        ]
        for (letter, ansi, action) in letters {
            for code in KeyLayout.keyCodes(typing: letter, fallback: ansi) { keys[code] = action }
        }
        return keys
    }

    private func startTapIfPossible() {
        guard permissions.accessibility, !keyTap.isRunning else { return }
        keyTap.start()
        status?.refresh()
    }

    private func permissionsChanged() {
        startTapIfPossible()
        if permissions.screenRecording {
            Task {
                await ScreenGrabber.shared.invalidate()
                await ScreenGrabber.shared.warmUp()
            }
        }
        status.refresh()
    }

    // MARK: Menu actions

    @objc func togglePause() {
        settings.paused.toggle()
    }

    @objc func openSettings() {
        windows.showSettings()
    }

    @objc func openOnboarding() {
        windows.showOnboarding()
    }

    @objc func checkForUpdates() {
        Task { await Updater.shared.check(userInitiated: true) }
    }

    // MARK: Debug hooks

    #if DEBUG
    /// Lets a development build be driven from the command line:
    /// `post app.grab.debug arm|disarm|copy|mode:1|scope:-1|dump:/path|onboarding|settings`
    private func installDebugHooks() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.grab.debug"), object: nil, queue: .main
        ) { [weak self] note in
            let cmd = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let cmd else { return }
                self.debug(cmd)
            }
        }
    }

    private func debug(_ cmd: String) {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "arm": session.arm(debug: true)
        case "disarm": session.disarm()
        case "copy": session.copy()
        case "mode": session.cycleMode(Int(arg) ?? 1)
        case "scope": session.changeScope(Int(arg) ?? 1)
        case "format": session.cycleFormat(Int(arg) ?? 1)
        case "codedebug": session.debugCode(to: arg)
        case "append": session.copy(append: true)
        case "action": session.debugAction(arg)
        case "mascotstills": MascotDebug.renderStills(to: arg)
        case "seasonstills": MascotDebug.renderSeasons(to: arg)
        case "codepic":
            let sample = "/// Greets someone by name.\nfunc greet(_ name: String) -> String {\n    // Empty names get a plain hello.\n    if name.isEmpty { return \"Hello!\" }\n    let count = 42\n    return \"Hi, \\(name) #\\(count)\"\n}"
            if let img = CodeImage.render(sample, language: "swift", title: "Greeter.swift", firstLine: 12) {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            }
        case "windows":
            let list = NSApp.windows.filter(\.isVisible).map { w -> [String: Any] in
                let r = ScreenSpace.toAX(w.frame)
                return ["title": w.title, "frame": [r.minX, r.minY, r.width, r.height].map { Double($0) }, "level": w.level.rawValue]
            }
            if let d = try? JSONSerialization.data(withJSONObject: list, options: .prettyPrinted) { try? d.write(to: URL(fileURLWithPath: arg)) }
        case "pins":
            let list = Panels.shared.pins.map { p -> [String: Any] in
                var o: [String: Any] = ["live": p.live, "interval": p.interval, "changed": p.changedAt.map { $0.timeIntervalSince1970 } ?? 0]
                switch p.content {
                case .text(let t, _): o["text"] = t
                case .image(let i, _): o["image"] = [i.width, i.height]; o["print"] = ImageFingerprint.of(i).prefix(16).map { Int($0) }
                }
                if let r = p.source?.rect { o["source"] = [r.minX, r.minY, r.width, r.height].map { Double($0) } }
                return o
            }
            if let d = try? JSONSerialization.data(withJSONObject: list, options: .prettyPrinted) { try? d.write(to: URL(fileURLWithPath: arg)) }
        case "livepins":
            for p in Panels.shared.pins { p.interval = 2; p.live = arg != "off" }
        case "customformat":
            // name|template|text,link
            let f = arg.components(separatedBy: "|")
            if f.count >= 3 {
                let targets = Set(f[f.count - 1].split(separator: ",").compactMap { CustomFormat.Target(rawValue: String($0)) })
                settings.customFormats.append(CustomFormat(name: f[0], template: f[1..<(f.count - 1)].joined(separator: "|"), targets: targets))
            } else if arg == "clear" {
                settings.customFormats = []
            }
        case "vaulttest":
            // A throwaway file and key; the keychain is never touched.
            History.shared.debugUseVault(HistoryVault(url: URL(fileURLWithPath: arg).appendingPathComponent("History.grabvault"), key: .init(size: .bits256)))
            settings.keepHistory = true
            History.shared.setKeepHistory(true)
        case "historyreload":
            History.shared.debugReload()
        case "historydump":
            let rows = History.shared.items.map { "\($0.mode.title)|\($0.appName ?? "")|\($0.title)" }
            try? rows.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        case "sim":
            // Real key events through the system, as if typed: "opt-down,sleep:0.4,key:9,opt-up".
            let steps = arg.split(separator: ",").map(String.init)
            Thread.detachNewThread {
                let src = CGEventSource(stateID: .hidSystemState)
                var flags: CGEventFlags = []
                for step in steps {
                    if step.hasPrefix("sleep:") { Thread.sleep(forTimeInterval: Double(step.dropFirst(6)) ?? 0.2); continue }
                    if step.hasPrefix("key:"), let code = CGKeyCode(step.dropFirst(4)) {
                        for down in [true, false] {
                            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
                            e?.flags = flags
                            e?.post(tap: .cghidEventTap)
                            Thread.sleep(forTimeInterval: 0.03)
                        }
                        continue
                    }
                    let (code, bits): (CGKeyCode, UInt64) = step.hasPrefix("ropt") ? (61, 0x40) : (58, 0x20)
                    if step.hasSuffix("-down") { flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | bits) } else { flags = [] }
                    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: step.hasSuffix("-down"))
                    e?.type = .flagsChanged
                    e?.flags = flags
                    e?.post(tap: .cghidEventTap)
                }
            }
        case "focus":
            let v = arg.split(separator: ",").compactMap { Float(String($0)) }
            var found: AXUIElement?
            if v.count == 2, AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), v[0], v[1], &found) == .success, let e = found {
                AXUIElementSetAttributeValue(e, "AXFocused" as CFString, kCFBooleanTrue)
            }
        case "settingsscroll":
            // Scrolls the settings form to a y offset, for screenshots.
            func scrollView(in v: NSView) -> NSScrollView? {
                if let s = v as? NSScrollView { return s }
                for sub in v.subviews { if let s = scrollView(in: sub) { return s } }
                return nil
            }
            if let w = NSApp.windows.first(where: { $0.title == "Grab Settings" }), let root = w.contentView, let sv = scrollView(in: root) {
                sv.contentView.scroll(to: NSPoint(x: 0, y: Double(arg) ?? 0))
                sv.reflectScrolledClipView(sv.contentView)
            }
        case "updateinstall":
            if let r = Updater.shared.available { Task { await Updater.shared.install(r) } }
        case "updatestate":
            try? "\(Updater.shared.state) available=\(Updater.shared.available?.version ?? "none")".write(toFile: arg, atomically: true, encoding: .utf8)
        case "updatefeed":
            Updater.shared.debugFeed = URL(string: arg)
            Task { await Updater.shared.check(userInitiated: true) }
        case "statscard":
            if let img = Stats.shared.shareCard() {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            }
        case "historystill": HistoryDebug.snapshot(to: arg)
        case "permstill":
            let view = VStack(alignment: .leading, spacing: 18) {
                ForEach(PermissionReason.allCases) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(r.title).font(.system(size: 14, weight: .bold))
                        Text(r.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        PermissionExplainer(reason: r)
                    }
                }
                OtherAccessNote()
            }
            .padding(20)
            .frame(width: 480)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.cgImage {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            }
        case "mascot":
            settings.mascot = arg
            session.previewMascot(at: session.debugPoint ?? ScreenSpace.mouseLocation())
        case "at":
            let v = arg.split(separator: ",").compactMap { Double(String($0)) }
            session.debugPoint = v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
        case "history": Panels.shared.showHistory()
        case "shelf": Panels.shared.showShelf()
        case "onboarding": windows.showOnboarding()
        case "settings": windows.showSettings()
        case "sck":
            Task {
                var line = "preflight=\(CGPreflightScreenCaptureAccess())"
                do {
                    let cap = try await ScreenGrabber.shared.capture(CGRect(x: 0, y: 0, width: 200, height: 100))
                    line += " capture=ok \(cap.image.width)x\(cap.image.height)"
                } catch {
                    line += " capture=error \(error)"
                }
                try? line.write(toFile: arg.isEmpty ? "/tmp/grab-sck.txt" : arg, atomically: true, encoding: .utf8)
            }
        case "params":
            let p = ScreenSpace.mouseLocation()
            DispatchQueue.global().async {
                var el: AXUIElement?
                AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el)
                var out = ""
                if let w = el?.attribute("AXWindow").map({ $0 as! AXUIElement }) {
                    out += "WINDOW title=\(w.string("AXTitle") ?? "-") doc=\(w.string("AXDocument") ?? "-")\n"
                }
                var cur = el
                for _ in 0..<7 {
                    guard let e = cur else { break }
                    var names: CFArray?
                    AXUIElementCopyParameterizedAttributeNames(e, &names)
                    var attrs: CFArray?
                    AXUIElementCopyAttributeNames(e, &attrs)
                    let cls = (e.attribute("AXDOMClassList") as? [String])?.joined(separator: " ") ?? ""
                    out += "[sub=\(e.string("AXSubrole") ?? "-") desc=\(e.string("AXRoleDescription") ?? "-") class=\(cls) doc=\(e.string("AXDocument") ?? "-")]\n"
                    out += "\(e.string("AXRole") ?? "?"): params=\((names as? [String]) ?? []) attrs=\((attrs as? [String]) ?? [])\n\n"
                    cur = e.attribute("AXParent").map { $0 as! AXUIElement }
                }
                try? out.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "webcode":
            let p = ScreenSpace.mouseLocation()
            DispatchQueue.global().async {
                var el: AXUIElement?
                AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el)
                var web: AXUIElement? = el
                while let w = web, w.string("AXRole") != "AXWebArea" { web = w.attribute("AXParent").map { $0 as! AXUIElement } }
                var out = "leaf=\(el?.string("AXRole") ?? "-") web=\(web != nil)\n"
                if let host = web {
                    let m = host.parameterized("AXTextMarkerForPosition", AXBox.point(p))
                    out += "marker=\(m != nil)\n"
                    if let m {
                        let idx = host.parameterized("AXIndexForTextMarker", m)
                        out += "indexForMarker=\(String(describing: idx))\n"
                        if let n = idx as? NSNumber {
                            let m2 = host.parameterized("AXTextMarkerForIndex", NSNumber(value: n.intValue + 6))
                            out += "markerForIndex=\(m2 != nil)\n"
                            if let m2 {
                                let r = AXTextMarkerRangeCreate(nil, m as! AXTextMarker, m2 as! AXTextMarker)
                                out += "str=\(String(describing: host.parameterized("AXStringForTextMarkerRange", r)))\n"
                                out += "bounds=\(String(describing: AXBox.rect(host.parameterized("AXBoundsForTextMarkerRange", r))))\n"
                            }
                        }
                    }
                    // Walk up to the code element and try index-based APIs on it.
                    var code: AXUIElement? = el
                    while let c = code, c.string("AXSubrole") != "AXCodeStyleGroup" { code = c.attribute("AXParent").map { $0 as! AXUIElement } }
                    if let code {
                        let txt = code.attribute("AXValue") as? String
                        out += "codeValue=\(txt.map { String($0.prefix(40)) } ?? "nil") nchars=\(String(describing: code.attribute("AXNumberOfCharacters")))\n"
                        for (loc, len) in [(0, 6), (120, 10)] {
                            out += "codeBounds(\(loc),\(len))=\(String(describing: AXBox.rect(code.parameterized("AXBoundsForRange", AXBox.range(CFRange(location: loc, length: len))))))"
                            out += " str=\(String(describing: code.parameterized("AXStringForRange", AXBox.range(CFRange(location: loc, length: len)))))\n"
                        }
                        if let r = host.parameterized("AXTextMarkerRangeForUIElement", code) {
                            let s = host.parameterized("AXStringForTextMarkerRange", r) as? String
                            out += "codeMarkerText=\(s.map { String($0.prefix(60)).replacingOccurrences(of: "\n", with: "⏎") } ?? "nil")\n"
                        }
                        out += "rangeForPosition=\(String(describing: code.parameterized("AXRangeForPosition", AXBox.point(p))))\n"
                    }
                    if let leaf = el, let r = host.parameterized("AXTextMarkerRangeForUIElement", leaf) {
                        let start = AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
                        out += "leafStartIndex=\(String(describing: host.parameterized("AXIndexForTextMarker", start)))\n"
                    }
                }
                try? out.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "chromemarkers":
            let p = ScreenSpace.mouseLocation()
            DispatchQueue.global().async {
                var out = ""
                var el: AXUIElement?
                AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el)
                var web: AXUIElement? = el
                while let w = web, w.string("AXRole") != "AXWebArea" { web = w.attribute("AXParent").map { $0 as! AXUIElement } }
                // Find a static text under the point by walking down from the hit element's parent.
                var leaf = el
                if el?.string("AXRole") != "AXStaticText", let parent = el?.attribute("AXParent").map({ $0 as! AXUIElement }) {
                    var stack = [parent]
                    var best: AXUIElement?
                    var n = 0
                    while let e = stack.popLast(), n < 300 {
                        n += 1
                        guard let f = AXBox.rect(e.attribute("AXFrame")), f.contains(p) else { continue }
                        if e.string("AXRole") == "AXStaticText" { best = e }
                        stack += (e.attribute("AXChildren") as? [AXUIElement]) ?? []
                    }
                    if let best { leaf = best }
                }
                guard let host = web, let leaf else { try? "no web".write(toFile: arg, atomically: true, encoding: .utf8); return }
                out += "leaf=\(leaf.string("AXRole") ?? "") value=\((leaf.attribute("AXValue") as? String)?.prefix(50) ?? "")\n"
                guard let r = host.parameterized("AXTextMarkerRangeForUIElement", leaf) else { try? (out + "no range").write(toFile: arg, atomically: true, encoding: .utf8); return }
                let start = AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
                let end = AXTextMarkerRangeCopyEndMarker(r as! AXTextMarkerRange)
                for (name, h) in [("host", host), ("leaf", leaf)] {
                    out += "\(name) idx(start)=\(String(describing: h.parameterized("AXIndexForTextMarker", start))) idx(end)=\(String(describing: h.parameterized("AXIndexForTextMarker", end)))\n"
                }
                if let s0 = host.parameterized("AXIndexForTextMarker", start) as? NSNumber {
                    for (name, h) in [("host", host), ("leaf", leaf)] {
                        if let m = h.parameterized("AXTextMarkerForIndex", NSNumber(value: s0.intValue + 4)) {
                            let rr = AXTextMarkerRangeCreate(nil, start, m as! AXTextMarker)
                            out += "\(name) markerForIndex+4 str=\(String(describing: host.parameterized("AXStringForTextMarkerRange", rr))) bounds=\(String(describing: AXBox.rect(host.parameterized("AXBoundsForTextMarkerRange", rr))))\n"
                        } else { out += "\(name) markerForIndex nil\n" }
                    }
                }
                if let n1 = host.parameterized("AXNextTextMarkerForTextMarker", start) {
                    let rr = AXTextMarkerRangeCreate(nil, start, n1 as! AXTextMarker)
                    out += "next: str=\(String(describing: host.parameterized("AXStringForTextMarkerRange", rr))) bounds=\(String(describing: AXBox.rect(host.parameterized("AXBoundsForTextMarkerRange", rr))))\n"
                    if let w = host.parameterized("AXRightWordTextMarkerRangeForTextMarker", n1) {
                        out += "word: \(String(describing: host.parameterized("AXStringForTextMarkerRange", w))) \(String(describing: AXBox.rect(host.parameterized("AXBoundsForTextMarkerRange", w))))\n"
                    }
                    if let l = host.parameterized("AXLineTextMarkerRangeForTextMarker", n1) {
                        out += "line: \(String(describing: (host.parameterized("AXStringForTextMarkerRange", l) as? String)?.prefix(60))) \(String(describing: AXBox.rect(host.parameterized("AXBoundsForTextMarkerRange", l))))\n"
                    }
                    if let l = host.parameterized("AXParagraphTextMarkerRangeForTextMarker", n1) {
                        out += "para: \(String(describing: (host.parameterized("AXStringForTextMarkerRange", l) as? String)?.prefix(60))) \(String(describing: AXBox.rect(host.parameterized("AXBoundsForTextMarkerRange", l))))\n"
                    }
                }
                out += "leafFrame=\(String(describing: AXBox.rect(leaf.attribute("AXFrame"))))\n"
                try? out.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "runs":
            let p = ScreenSpace.mouseLocation()
            DispatchQueue.global().async {
                var el: AXUIElement?
                AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el)
                var block = el
                while let b = block, b.string("AXRole") == "AXStaticText" || b.string("AXRole") == "AXLink" { block = b.attribute("AXParent").map { $0 as! AXUIElement } }
                var out = "block=\(block?.string("AXRole") ?? "-")\n"
                for k in (block?.attribute("AXChildren") as? [AXUIElement] ?? []).prefix(12) {
                    let v = k.attributes(["AXRole", "AXValue", "AXTitle", "AXDescription"])
                    out += "\(v["AXRole"] as? String ?? "") value=[\(v["AXValue"] as? String ?? "")] title=[\(v["AXTitle"] as? String ?? "")]\n"
                }
                try? out.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "menu": status.openMenu()
        case "menuclose": status.closeMenu()
        case "close":
            NSApp.windows.filter { !($0 is OverlayWindow) && $0.isVisible && $0.styleMask.contains(.titled) }.forEach { $0.close() }
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().close() }
        case "dump":
            var info = session.debugDescription()
            info["ax"] = permissions.accessibility
            info["screen"] = permissions.screenRecording
            info["tap"] = keyTap.isRunning
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: arg.isEmpty ? "/tmp/grab-dump.json" : arg))
            }
        default: break
        }
    }
    #endif
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Grab: login item change failed: \(error.localizedDescription)")
        }
    }
}
