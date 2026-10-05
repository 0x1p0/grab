import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Pixels we've already looked at for a given rectangle.
private struct Analysis {
    let date: Date
    /// Where the pixels came from. (The pixels themselves aren't kept: a full
    /// capture is tens of megabytes, and only its layout is needed afterwards.)
    let captureRect: CGRect
    let captureScale: CGFloat
    let layout: TextLayout
    let didOCR: Bool
    /// The capture covers the whole scope, so `layout` holds all of its text.
    let covers: Bool
    let thumbnail: CGImage?
    let pixels: PixelMap?
    /// The scope this was taken for, so nearby cursor positions can reuse it.
    let scopeFrame: CGRect

    var fullText: String? {
        didOCR && covers ? layout.text.cleanedForClipboard.nonBlank : nil
    }
}

/// Code whose layout was learned from pixels.
private struct CodeModel {
    let date: Date
    let analysis: CodeAnalysis
    let grid: CodeGrid
    let fileURL: URL?
    let fromOCR: Bool
}

/// Remembers the scope the user picked with ↑ / ↓ so it survives small mouse moves.
private struct StickyScope {
    let kind: ScopeKind
    let element: AXUIElement?
    let codeKind: CodeScope.Kind?
    let tablePart: TableRef.Part?

    init(_ s: Scope) {
        kind = s.kind
        element = (s.kind == .element || s.kind == .window) ? s.element : nil
        codeKind = s.code?.kind
        tablePart = s.tableRef?.part
    }

    /// How big a text scope is: word 0 … paragraph 3 (OCR'd text counts the same).
    static func level(_ k: ScopeKind) -> Int? {
        switch k {
        case .word, .ocrWord: 0
        case .line, .ocrLine: 1
        case .sentence: 2
        case .paragraph, .ocrParagraph: 3
        default: nil
        }
    }

    /// The scope matching this choice, or for text the next size up that exists
    /// here (Line when there's no word under the cursor).
    func pick(from scopes: [Scope]) -> Scope? {
        if let exact = scopes.first(where: matches) { return exact }
        guard codeKind == nil, let want = Self.level(kind) else { return nil }
        return scopes
            .compactMap { s -> (Scope, Int)? in
                guard s.code == nil, let l = Self.level(s.kind), l >= want else { return nil }
                return (s, l)
            }
            .min { $0.1 < $1.1 }?.0
    }

    func matches(_ s: Scope) -> Bool {
        guard s.kind == kind, s.code?.kind == codeKind, s.tableRef?.part == tablePart else { return false }
        if let e = element {
            guard let o = s.element else { return false }
            return CFEqual(e, o)
        }
        return true
    }
}

/// One ⌥-hold, from arming to release. Owns targeting, modes, analysis and copying.
@MainActor
final class Session {
    let model: OverlayModel
    let overlay: OverlayController

    var onLostOption: (() -> Void)?
    var statusItemFrame: (() -> CGRect?)?
    /// After a copy; the argument is when the grab lands in the menu bar icon.
    var onCopied: ((TimeInterval) -> Void)?
    /// Ends the ⌥ hold for the key tap too (after opening a panel, Quick Look…).
    var onEndHold: (() -> Void)?

    private let inspector = Inspector()
    private let axQueue = DispatchQueue(label: "app.grab.ax", qos: .userInteractive)
    private static let myPID = getpid()

    /// Accessibility work runs in order on its own queue, so the HUD never waits on a slow
    /// app. Grab's own windows are the exception: macOS answers questions about them
    /// in-process, on whichever thread asks, and their views may only be touched on the
    /// main thread. That work still waits its turn on the queue, but runs on the main thread.
    private func onAXQueue(own: Bool, _ work: @escaping () -> Void) {
        axQueue.async {
            if own { DispatchQueue.main.sync(execute: work) } else { work() }
        }
    }

    private static func isOwn(_ e: AXUIElement?) -> Bool { e.map { $0.pid == myPID } ?? false }

    /// Whether the pointer is over one of Grab's own windows (Settings, Welcome, a pin, the
    /// menu bar icon…). Errs on the side of yes: then the work just runs on the main thread.
    private func ownWindow(at p: CGPoint) -> Bool {
        NSApp.windows.contains { w in
            w.isVisible && !(w is OverlayWindow) && ScreenSpace.toAX(w.frame).contains(p)
        }
    }

    private(set) var armed = false
    private var debugHold = false
    private var generation = 0

    private var inspection: Inspection?
    private var selectedID: UUID?
    private var sticky: StickyScope?
    private var userMode: GrabMode?
    private(set) var mode: GrabMode = .text

    private var pendingCopy = false
    /// C was pressed while pixels were still being read (holds the ⇧ flag).
    private var waitingCopy: Bool?
    /// Disarm as soon as the pending copy finishes (grab:// URLs).
    private var oneShot = false
    private var copying = false

    private var timer: Timer?
    private var lastPoint = CGPoint.zero
    private var dirty = true
    private var lastInspect: CFTimeInterval = 0
    private var inspecting = false

    private var analyses: [String: Analysis] = [:]
    /// QR scans around the cursor, by 40 pt cell.
    private var qrScans: [String: (date: Date, code: Barcode?)] = [:]
    private var qrScanning = Set<String>()
    private var qrDwell: DispatchWorkItem?
    /// Second, tighter OCR passes around the cursor, by small cell.
    private var focusScans: [String: (date: Date, layout: TextLayout)] = [:]
    private var focusScanning = Set<String>()
    private var analyzing = Set<String>()
    private var dwell: DispatchWorkItem?

    private var resolved: [ElementKey: String] = [:]
    private var resolving = Set<ElementKey>()
    private var resolvedTables: [String: String] = [:]
    private var resolvingTables = Set<String>()

    private var loupeBusy = false
    private var toastWork: DispatchWorkItem?
    private var linkCache: [String: URL?] = [:]

    private var codeModels: [String: CodeModel] = [:]
    private var codeLoading = Set<String>()
    private var lastScroll: CFTimeInterval = 0
    private var codeRetry: DispatchWorkItem?
    private var appendCount = 0
    private var smartCache: [String: SmartTypes.Analysis] = [:]
    private var lastSnap: (kind: ScopeKind, frame: CGRect)?
    private var lastSnapTime: CFTimeInterval = 0
    private var lastAnnouncement: CFTimeInterval = 0
    /// ⌥V was pressed; the paste goes out when the keys are released.
    private var pastePending = false
    /// ⌥R: the corner a box is being drawn from; the pointer is the other corner.
    private var boxAnchor: CGPoint?
    static let boxRole = "GrabBox"

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    init(overlay: OverlayController) {
        self.overlay = overlay
        self.model = overlay.model
    }

    func handle(_ action: TapAction) {
        switch action {
        case .arm: arm()
        case .disarm: disarm()
        case .cancel: disarm(cancelled: true)
        case .copy: copy()
        case .cycleMode(let d): cycleMode(d)
        case .changeScope(let d): changeScope(d)
        case .cycleFormat(let d): cycleFormat(d)
        case .append: copy(append: true)
        case .scrolled: scrolled()
        case .action(let a): perform(a)
        }
    }

    private var current: Scope? {
        guard let ins = inspection else { return nil }
        if let id = selectedID, let s = ins.scopes.first(where: { $0.id == id }) { return s }
        return ins.scopes[safe: ins.defaultIndex]
    }

    private var currentIndex: Int? {
        guard let ins = inspection, let s = current else { return nil }
        return ins.scopes.firstIndex { $0.id == s.id }
    }

    // MARK: Arm / disarm

    func arm(debug: Bool = false) {
        guard !armed else { return }
        armed = true
        debugHold = debug
        generation += 1
        inspection = nil
        selectedID = nil
        sticky = nil
        userMode = nil
        pendingCopy = false
        waitingCopy = nil
        analyses.removeAll()
        analyzing.removeAll()
        qrScans.removeAll()
        qrScanning.removeAll()
        focusScans.removeAll()
        focusScanning.removeAll()
        resolved.removeAll()
        resolving.removeAll()
        resolvedTables.removeAll()
        resolvingTables.removeAll()
        loupeBusy = false
        linkCache.removeAll()
        codeModels.removeAll()
        codeLoading.removeAll()
        appendCount = 0
        lastSnap = nil
        boxAnchor = nil
        if smartCache.count > 600 { smartCache.removeAll() }
        axQueue.async { [inspector] in inspector.reset() }

        lastPoint = pointer()
        dirty = true
        Permissions.shared.refresh()

        let s = Settings.shared
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            model.session += 1
            model.target = nil
            model.loupe = nil
            model.busy = false
            model.cursor = lastPoint
            model.hints = s.showHints
            model.spotlight = s.spotlight
            model.warning = IsSecureEventInputEnabled()
                ? "Secure input is on in another app, so \(s.trigger.chord("C")) can't be heard right now."
                : nil
            model.options = []
            model.preview = .none
            model.formats = []
            model.format = nil
            model.literalColor = nil
            model.boxing = false
        }
        // The mascot wakes (if it dozed off) and peeks out from under the menu bar.
        let kind = MascotKind(rawValue: s.mascot) ?? .snap
        let wasAsleep = Buddy.shared.wake()
        // Never alongside a trip or a shrug already on screen: one mascot at a time.
        let peekOK = s.mascotPeek && kind != .off && kind != .classic && !Buddy.shared.isAway
            && model.fly == nil && model.oops == nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withTransaction(t) {
            model.pet = nil
            model.petHover = false
            model.peek = peekOK ? peekAnchor(near: lastPoint).map { Peek(anchor: $0.point, kind: kind, sleepy: wasAsleep, notch: $0.notch) } : nil
        }
        withAnimation(.easeOut(duration: 0.16)) { model.visible = true }
        overlay.show()

        if Permissions.shared.screenRecording {
            Task { await ScreenGrabber.shared.warmUp() }
            Task { await VisionService.shared.prewarm() }
        }
        requestInspection()
        startTimer()
    }

    /// Grabs what's under the cursor right now without holding ⌥ (URL scheme, Shortcuts).
    func grabNow(mode: GrabMode?) {
        guard !armed else { return }
        arm(debug: true)
        oneShot = true
        if let mode { userMode = mode }
        pendingCopy = true
        // Give up if nothing turns up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.oneShot else { return }
            self.oneShot = false
            self.disarm(cancelled: true)
        }
    }

    func disarm(cancelled: Bool = false) {
        guard armed else { return }
        if !cancelled { flushWaitingCopy(force: true) }
        waitingCopy = nil
        releaseCaches()
        armed = false
        debugHold = false
        generation += 1
        timer?.invalidate()
        timer = nil
        dwell?.cancel()
        pendingCopy = false
        boxAnchor = nil
        model.boxing = false
        model.petHover = false
        withAnimation(.easeOut(duration: cancelled ? 0.12 : 0.2)) {
            model.visible = false
        }
        if model.toast == nil && !copying {
            overlay.hide(after: 0.3)
        }
    }

    /// Everything learned during a hold is for that hold only: let it go, so Grab
    /// sits at its minimum between uses.
    private func releaseCaches() {
        analyses.removeAll()
        analyzing.removeAll()
        qrScans.removeAll()
        qrScanning.removeAll()
        focusScans.removeAll()
        focusScanning.removeAll()
        codeModels.removeAll()
        codeLoading.removeAll()
        resolved.removeAll()
        resolving.removeAll()
        resolvedTables.removeAll()
        resolvingTables.removeAll()
        linkCache.removeAll()
        smartCache.removeAll()
        model.loupe = nil
        axQueue.async { [inspector] in inspector.reset() }
        scheduleMemoryRelief()
    }

    /// Freed captures leave pages the allocator would otherwise keep cached; hand
    /// them back to macOS once the hold, and any copy it started, are over.
    private func scheduleMemoryRelief(after delay: TimeInterval = 1.2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.armed else { return }
            if self.copying || self.model.fly != nil {
                self.scheduleMemoryRelief(after: 1)
                return
            }
            DispatchQueue.global(qos: .utility).async { _ = malloc_zone_pressure_relief(nil, 0) }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard armed else { return }
        if !debugHold && !KeyTap.triggerIsDown(Settings.shared.trigger) {
            onLostOption?()
            disarm()
            return
        }
        let p = pointer()
        if hypot(p.x - lastPoint.x, p.y - lastPoint.y) > 0.4 {
            lastPoint = p
            dirty = true
            if model.pixelColor { model.cursor = p }
        }
        if var peek = model.peek {
            // Pointing at it keeps it out; otherwise it ducks back after a few seconds.
            let now = Date()
            let hover = peek.isOut(at: now) && peek.hitRect.contains(p) && !Buddy.shared.isAway
            model.set(\.petHover, hover)
            if hover, peek.retractAt.timeIntervalSince(now) < 1 {
                peek.retractAt = now.addingTimeInterval(1.5)
                model.peek = peek
            }
        } else {
            model.set(\.petHover, false)
        }
        let now = CACurrentMediaTime()
        if !inspecting && ((dirty && now - lastInspect > 0.03) || now - lastInspect > 0.4) {
            requestInspection()
        }
        if model.pixelColor { requestLoupe() }
    }

    private func pointer() -> CGPoint {
        #if DEBUG
        if let p = debugPoint { return p }
        #endif
        return ScreenSpace.mouseLocation()
    }

    // MARK: Inspection

    private func requestInspection() {
        if boxAnchor != nil {
            dirty = false
            lastInspect = CACurrentMediaTime()
            applyBox()
            return
        }
        inspecting = true
        dirty = false
        let p = lastPoint
        let gen = generation
        let inspector = self.inspector
        onAXQueue(own: ownWindow(at: p)) { [weak self] in
            let ins = inspector.inspect(at: p)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inspecting = false
                    self.lastInspect = CACurrentMediaTime()
                    guard self.armed, gen == self.generation else { return }
                    self.apply(ins)
                }
            }
        }
    }

    private func apply(_ fresh: Inspection) {
        var ins = fresh
        fill(&ins)
        augment(&ins)
        augmentCode(&ins)
        detectSmart(&ins)

        // The size picked with ↑ ↓ holds for the whole ⌥ hold, even where it
        // doesn't exist for a moment (a space between words, a gap between lines).
        let selected = sticky.flatMap { $0.pick(from: ins.scopes) } ?? ins.scopes[safe: ins.defaultIndex]

        inspection = ins
        selectedID = selected?.id
        updateMode()
        ensureText()
        scheduleAnalysis()
        scheduleCode()
        pushModel()
        targetChanged()
        flushWaitingCopy()

        if pendingCopy {
            pendingCopy = false
            copy()
        }
    }

    /// Re-applies analysis results to the inspection we already have.
    private func reapply() {
        guard var ins = inspection else { return }
        fill(&ins)
        augment(&ins)
        augmentCode(&ins)
        detectSmart(&ins)
        inspection = ins
        if let st = sticky {
            if !ins.scopes.contains(where: { $0.id == selectedID }) || !(ins.scopes.first { $0.id == selectedID }.map(st.matches) ?? false) {
                selectedID = (st.pick(from: ins.scopes) ?? ins.scopes[safe: ins.defaultIndex])?.id
            }
        } else {
            selectedID = ins.scopes[safe: ins.defaultIndex]?.id
        }
        updateMode()
        ensureText()
        scheduleAnalysis()
        scheduleCode()
        pushModel()
        flushWaitingCopy()
    }

    // MARK: Code learned from pixels

    /// Code we can read but not locate (Chrome, VS Code, Cursor…): read the text,
    /// OCR the region once, and align the two into a grid.
    private func scheduleCode() {
        guard let region = inspection?.codeRegion, Permissions.shared.screenRecording else { return }
        let key = region.key
        if let m = codeModels[key], Date().timeIntervalSince(m.date) < 10 { return }
        guard !codeLoading.contains(key) else { return }
        let sinceScroll = CACurrentMediaTime() - lastScroll
        if sinceScroll < 0.2 {
            codeRetry?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.scheduleCode() }
            codeRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22 - sinceScroll, execute: work)
            return
        }
        codeLoading.insert(key)
        let gen = generation
        Task { @MainActor [weak self] in
            let built = await Task.detached(priority: .userInitiated) { await Self.buildCodeModel(region) }.value
            guard let self else { return }
            self.codeLoading.remove(key)
            guard self.armed, gen == self.generation, let built else { return }
            self.codeModels[key] = built
            self.reapply()
        }
    }

    /// Files with this exact name, most recently used first.
    nonisolated private static func spotlight(name: String) -> [URL] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemFSName == '\(name.replacingOccurrences(of: "'", with: ""))'"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let deadline = Date().addingTimeInterval(1.5)
        while task.isRunning && Date() < deadline { usleep(20_000) }
        if task.isRunning { task.terminate() }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let urls = out.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { !$0.path.contains("/node_modules/") && !$0.path.contains("/.build/") && !$0.path.contains("/Library/Caches/") }
        let dated = urls.prefix(40).map { u in (u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
    }

    nonisolated private static func readSource(_ url: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size < 4_000_000, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    nonisolated private static func buildCodeModel(_ region: CodeRegion) async -> CodeModel? {
        guard let cap = try? await ScreenGrabber.shared.capture(region.rect, maxPixels: 9_000_000) else { return nil }
        let fast = await VisionService.shared.recognize(cap, accurate: false)
        // Split by line-number gutters (sidebars and other panes fall away); else use everything.
        var bands = CodeGridBuilder.bands(in: fast, region: region.rect).map { band in
            (band, CodeGridBuilder.rows(from: fast.filter { band.contains($0.rect.center) }))
        }
        bands.append((region.rect, CodeGridBuilder.rows(from: fast)))

        var source: String?
        var file: URL?
        switch region.source {
        case .text(let t): source = t
        case .file(let u):
            source = readSource(u)
            file = u
        case .ocr: break
        }
        if let source {
            let a = CodeAnalysis(text: source, language: region.language ?? .guess(source), terminal: region.isTerminal)
            for (band, rows) in bands {
                if let grid = CodeGridBuilder.align(rows: rows, to: a, region: band) {
                    return CodeModel(date: Date(), analysis: a, grid: grid, fileURL: file, fromOCR: false)
                }
            }
        }
        // Editors that don't say which file is open (Cursor's agent window…): read the
        // name off the tab or breadcrumb, find it with Spotlight, and keep the one whose
        // lines match what's on screen.
        if case .ocr = region.source, !region.isTerminal, UserDefaults.standard.object(forKey: "spotlightFiles") as? Bool ?? true {
            for (band, rows) in bands.dropLast() {
                for name in CodeGridBuilder.fileNames(above: band, in: fast).prefix(2) {
                    for url in spotlight(name: name) {
                        guard let text = readSource(url) else { continue }
                        let a = CodeAnalysis(text: text, language: CodeLanguage.forFile(url) ?? .guess(text))
                        if let grid = CodeGridBuilder.align(rows: rows, to: a, region: band) {
                            return CodeModel(date: Date(), analysis: a, grid: grid, fileURL: url, fromOCR: false)
                        }
                    }
                }
            }
        }
        // No usable source (or unsaved edits): rebuild the code from the pixels themselves.
        let band = bands.first?.0 ?? region.rect
        let accurateLines = await VisionService.shared.recognize(cap, accurate: true).filter { band.contains($0.rect.center) }
        let accurate = CodeGridBuilder.rows(from: accurateLines)
        guard let (text, grid) = CodeGridBuilder.reconstruct(rows: accurate, region: band) else { return nil }
        let a = CodeAnalysis(text: text, language: region.language ?? .guess(text), terminal: region.isTerminal)
        return CodeModel(date: Date(), analysis: a, grid: grid, fileURL: nil, fromOCR: true)
    }

    private func augmentCode(_ ins: inout Inspection) {
        guard let region = ins.codeRegion, let m = codeModels[region.key],
              let cursor = m.grid.offset(at: ins.point, in: m.analysis) else { return }
        let title = m.fileURL.map { "File · \($0.lastPathComponent)" } ?? region.title
        var code = Inspector.makeCodeScopes(analysis: m.analysis, cursor: cursor, title: title, fileURL: m.fileURL,
                                            cwd: ins.workingDirectory) { m.grid.rect(for: $0, in: m.analysis) }
        if m.fromOCR { for i in code.indices { code[i].textIsOCR = true } }
        ins.scopes.removeAll { s in
            guard region.rect.insetBy(dx: -2, dy: -2).contains(s.frame) else { return false }
            if s.kind.isTextRange { return true }
            // Text runs and spans inside the code are just noise next to real code scopes.
            return s.kind == .element && s.frame.width * s.frame.height < region.rect.width * region.rect.height * 0.9
        }
        ins.scopes += code
        ins.sortScopes()
        if let preferred = ins.scopes.first(where: { $0.isPreferred }) { ins.defaultID = preferred.id }
    }

    private func scrolled() {
        lastScroll = CACurrentMediaTime()
        codeModels.removeAll()
        analyses.removeAll()
        qrScans.removeAll()
        focusScans.removeAll()
        dirty = true
    }

    /// Copies lazily-resolved container text into the scopes.
    private func fill(_ ins: inout Inspection) {
        for i in ins.scopes.indices where ins.scopes[i].textPending {
            guard let key = ins.scopes[i].tableKey, let t = resolvedTables[key] else { continue }
            ins.scopes[i].text = t.isEmpty ? nil : t
            ins.scopes[i].textPending = false
        }
        guard !resolved.isEmpty else { return }
        for i in ins.scopes.indices where ins.scopes[i].textPending && ins.scopes[i].tableRef == nil {
            guard let e = ins.scopes[i].element, let t = resolved[ElementKey(element: e)] else { continue }
            ins.scopes[i].text = t.isEmpty ? nil : t
            ins.scopes[i].textPending = false
        }
    }

    /// Dates, phone numbers, prices, JSON, stack traces… in each scope's text.
    private func detectSmart(_ ins: inout Inspection) {
        let word = ins.scopes.first { $0.kind == .word || $0.kind == .ocrWord }?.text
        for i in ins.scopes.indices {
            let s = ins.scopes[i]
            guard s.kind != .table, s.kind != .list, s.kind != .barcode, let t = s.bestText else { continue }
            let key = "\(t.count)|\(t.hashValue)"
            let analysis: SmartTypes.Analysis
            if let cached = smartCache[key] {
                analysis = cached
            } else {
                analysis = SmartTypes.analyze(t)
                smartCache[key] = analysis
            }
            ins.scopes[i].smart = SmartTypes.choose(analysis, near: word)
        }
    }

    /// A light tick when the border lands on something new; VoiceOver hears what it is.
    private func targetChanged() {
        guard let s = current else { return }
        if let last = lastSnap, last.kind == s.kind, last.frame.isNearlyEqual(s.frame, tolerance: 2) { return }
        let first = lastSnap == nil
        lastSnap = (s.kind, s.frame)
        let now = CACurrentMediaTime()
        if !first, Settings.shared.snapHaptics, now - lastSnapTime > 0.09 {
            lastSnapTime = now
            Haptics.perform(.alignment)
        }
        if NSWorkspace.shared.isVoiceOverEnabled, now - lastAnnouncement > 0.6 {
            lastAnnouncement = now
            announce("\(s.label). \(mode.title).")
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Which pixels to analyse for a scope: all of an image or video frame when it's
    /// a sensible size, otherwise a window around the cursor at full resolution
    /// (downscaling is what loses small text), snapped to a grid so small mouse
    /// moves reuse the result.
    private func analysisRegion(_ s: Scope, at p: CGPoint) -> (key: String, rect: CGRect, covers: Bool)? {
        guard s.frame.isFinite, p.x.isFinite, p.y.isFinite else { return nil }
        if s.role == Self.boxRole {
            // A box is read whole, whatever its size.
            let f = s.frame.integral
            guard f.isUsable, let key = f.gridKey else { return nil }
            return (key, f, true)
        }
        var r = s.frame
        let scale = screenScale(for: s.frame)
        let pixels = s.frame.width * s.frame.height * scale * scale
        if s.isBackdrop || !(s.isVisual && pixels <= 4_000_000) {
            let cell: CGFloat = 220
            let cx = (floor(p.x / cell) + 0.5) * cell
            let cy = (floor(p.y / cell) + 0.5) * cell
            r = CGRect(x: cx - 560, y: cy - 330, width: 1120, height: 660).intersection(s.frame)
        }
        // The window around the cursor can miss the scope entirely (a scope that
        // ends before the cursor's grid cell), which leaves a null rectangle.
        let f = r.integral
        guard f.isUsable, let key = f.gridKey else { return nil }
        let covers = f.contains(s.frame.insetBy(dx: 1, dy: 1))
        return (key, f, covers)
    }

    private func qrCell(_ p: CGPoint) -> String { "\(floor(p.x / 40).clampedInt),\(floor(p.y / 40).clampedInt)" }
    private func focusCell(_ p: CGPoint) -> String { "\(floor(p.x / 80).clampedInt),\(floor(p.y / 14).clampedInt)" }

    private func scheduleFocusOCR(at p: CGPoint, within bounds: CGRect) {
        let cell = focusCell(p)
        guard !focusScanning.contains(cell) else { return }
        focusScanning.insert(cell)
        let gen = generation
        let band = CGRect(x: p.x - 480, y: p.y - 70, width: 960, height: 140).intersection(bounds)
        Task { @MainActor [weak self] in
            let layout = await Task.detached(priority: .userInitiated) { () -> TextLayout in
                guard band.width > 8, band.height > 8, let cap = try? await ScreenGrabber.shared.capture(band) else { return TextLayout() }
                return await VisionService.shared.read(cap, barcodes: false)
            }.value
            guard let self else { return }
            self.focusScanning.remove(cell)
            guard self.armed, gen == self.generation else { return }
            self.focusScans[cell] = (Date(), layout)
            self.reapply()
        }
    }

    private func barcodeScope(_ code: Barcode, link: URL?) -> Scope {
        var b = Scope(kind: .barcode, frame: code.rect.insetBy(dx: -3, dy: -3), label: code.kind == "QR" ? "QR code" : code.kind)
        b.barcode = code.payload
        b.barcodeKind = code.kind
        b.isVisual = true
        b.analysisDone = true
        b.linkURL = link
        return b
    }

    /// Adds what we learned from pixels: QR codes, and recognized words / lines /
    /// paragraphs under the cursor.
    private func augment(_ ins: inout Inspection) {
        let p = ins.point
        let defaultID = ins.defaultID
        let defaultRole = ins.scopes.first { $0.id == defaultID }?.role
        var added: [Scope] = []
        var newDefault: UUID?
        var codesSeen = Set<String>()

        // A code found by the cursor scan wins: it's exactly where you're pointing.
        if let scan = qrScans[qrCell(p)], let code = scan.code,
           code.rect.insetBy(dx: -10, dy: -10).contains(p) {
            let b = barcodeScope(code, link: ins.scopes.first(where: { $0.linkURL != nil && $0.frame.contains(p) })?.linkURL)
            added.append(b)
            newDefault = b.id
            codesSeen.insert(code.payload)
            for i in ins.scopes.indices where ins.scopes[i].frame.contains(code.rect.center) {
                ins.scopes[i].barcode = ins.scopes[i].barcode ?? code.payload
                ins.scopes[i].barcodeKind = ins.scopes[i].barcodeKind ?? code.kind
            }
        }

        for i in ins.scopes.indices {
            let s = ins.scopes[i]
            guard let a = analysis(for: s, at: p) else { continue }
            #if DEBUG
            let exact = analysisRegion(s, at: p).map { analyses[$0.key] != nil } ?? false
            debugTrace.append("\(s.label) exact=\(exact) cap=\(a.captureRect.integral) ocr=\(a.didOCR) paras=\(a.layout.paragraphs.count) hit=\(a.layout.hit(p) != nil) lines=\(a.layout.paragraphs.flatMap(\.lines).filter { $0.rect.insetBy(dx: -6, dy: -6).contains(p) }.map { "\($0.rect.integral):\($0.text.prefix(16))" })")
            #endif
            ins.scopes[i].analysisDone = true
            if !s.isBackdrop && a.covers { ins.scopes[i].thumbnail = a.thumbnail }
            ins.scopes[i].pixelSize = CGSize(width: s.frame.width * a.captureScale, height: s.frame.height * a.captureScale)
            // Icons and logos: whatever OCR "reads" in them is noise.
            let icon = s.isVisual && min(s.frame.width, s.frame.height) < 48
            if a.didOCR, !icon, s.text?.nonBlank == nil, !s.textPending, let t = a.fullText, Self.meaningful(t) {
                ins.scopes[i].ocrText = t
                ins.scopes[i].textIsOCR = true
            }
            if s.role == Self.boxRole {
                // Everything in the box counts, not just what's under the pointer.
                if let code = a.layout.barcodes.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
                    ins.scopes[i].barcode = code.payload
                    ins.scopes[i].barcodeKind = code.kind
                }
                for t in a.layout.tables where s.frame.contains(t.rect.center) {
                    var ts = Scope(kind: .table, frame: t.rect.insetBy(dx: -3, dy: -3), label: "Table", text: t.tsv)
                    ts.textIsOCR = true
                    ts.analysisDone = true
                    added.append(ts)
                }
                continue
            }

            for code in a.layout.barcodes where !codesSeen.contains(code.payload) {
                let underCursor = code.rect.insetBy(dx: -8, dy: -8).contains(p)
                let prominent = code.rect.width * code.rect.height >= 0.18 * max(s.area, 1)
                guard underCursor || (prominent && a.layout.barcodes.count == 1) else { continue }
                codesSeen.insert(code.payload)
                ins.scopes[i].barcode = code.payload
                ins.scopes[i].barcodeKind = code.kind
                let b = barcodeScope(code, link: s.linkURL)
                added.append(b)
                if underCursor && newDefault == nil { newDefault = b.id }
            }

            // Text the accessibility tree doesn't know about: in images, canvases,
            // video, games, remote screens…
            guard a.didOCR, !icon, s.isBackdrop || (s.text?.nonBlank == nil && !s.textPending) else { continue }
            // Text detection depends on the crop; when the wide pass missed what's under
            // the cursor, a tight band around it gets it.
            var found = a.layout.hit(p)
            if found == nil {
                let cell = focusCell(p)
                if let f = focusScans[cell] {
                    found = f.layout.hit(p)
                    if Date().timeIntervalSince(f.date) > Self.refreshAfter { scheduleFocusOCR(at: p, within: a.captureRect) }
                } else {
                    scheduleFocusOCR(at: p, within: a.captureRect)
                }
            }
            // A table in the picture (a screenshot of a spreadsheet, a receipt…).
            if let t = a.layout.tables.first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }) {
                var ts = Scope(kind: .table, frame: t.rect.insetBy(dx: -3, dy: -3), label: "Table", text: t.tsv)
                ts.textIsOCR = true
                ts.analysisDone = true
                added.append(ts)
            }
            // A stray glyph read off an icon isn't text worth offering.
            if let h = found, !Self.meaningful(h.paragraph.text) { found = nil }
            guard let hit = found else {
                // No text here: maybe a picture, icon or colored block that nothing describes.
                // Only once the focused text pass has also come back empty, or a line of
                // text it's about to find would be taken for a picture.
                let focusDone = focusScans[focusCell(p)] != nil
                if focusDone, let obj = a.pixels?.object(at: p), obj.rect.width * obj.rect.height < s.area * 0.85 {
                    var o = Scope(kind: .element, frame: obj.rect, label: obj.isSolid ? "Swatch" : "Image")
                    o.isVisual = !obj.isSolid
                    o.isBackdrop = obj.isSolid
                    o.analysisDone = true
                    o.linkURL = s.linkURL
                    o.depth = 0
                    added.append(o)
                    if newDefault == nil, s.id == defaultID { newDefault = o.id }
                }
                continue
            }
            func ocrScope(_ kind: ScopeKind, _ rect: CGRect, _ label: String, _ text: String) -> Scope {
                var o = Scope(kind: kind, frame: rect.insetBy(dx: -2, dy: -2), label: label, text: text.cleanedForClipboard)
                o.textIsOCR = true
                o.analysisDone = true
                o.linkURL = s.linkURL
                return o
            }
            let para = ocrScope(.ocrParagraph, hit.paragraph.rect, hit.paragraph.lines.count > 1 ? "Paragraph" : "Line", hit.paragraph.text)
            added.append(para)
            if hit.paragraph.lines.count > 1 { added.append(ocrScope(.ocrLine, hit.line.rect, "Line", hit.line.text)) }
            if let w = hit.word, w.text.count < 64, w.text != hit.line.text {
                added.append(ocrScope(.ocrWord, w.rect, "Word", w.text))
            }
            if newDefault == nil, s.id == defaultID, defaultRole != "AXImage", !s.linkIsSelf { newDefault = para.id }
        }

        guard !added.isEmpty else { return }
        // Fresh OCR scopes replace older ones from a previous pass over the same spot.
        ins.scopes.removeAll { s in [.ocrWord, .ocrLine, .ocrParagraph, .barcode].contains(s.kind) && added.contains { $0.kind == s.kind } }
        ins.scopes += added
        ins.sortScopes()
        if let nd = newDefault, ins.scopes.contains(where: { $0.id == nd }) {
            ins.defaultID = nd
        } else if !ins.scopes.contains(where: { $0.id == defaultID }) {
            ins.defaultID = Inspector.chooseDefault(ins.scopes)
        }
    }

    /// Recognized text with at least two letters or digits; single glyphs read off
    /// icons and photos are noise.
    static func meaningful(_ t: String) -> Bool {
        t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= 2
    }

    /// Pixel results stay valid for the whole hold (until something scrolls); after
    /// this long they're refreshed in the background for content that changes,
    /// like video, while the old result keeps showing.
    private static let refreshAfter: TimeInterval = 6

    /// The analysis for `s` around `p`: the exact grid cell's, or while that one is
    /// still running, any earlier one of the same scope that covers the point.
    /// Without this, moving between cells blanked the OCR result for a moment.
    private func analysis(for s: Scope, at p: CGPoint) -> Analysis? {
        let exact = analysisRegion(s, at: p).flatMap { analyses[$0.key] }
        if let e = exact, !cutsText(e, at: p) { return e }
        let others = analyses.values.filter {
            $0.scopeFrame.isNearlyEqual(s.frame, tolerance: 2) && $0.captureRect.insetBy(dx: 24, dy: 24).contains(p) && !cutsText($0, at: p)
        }
        return others.max { margin($0, at: p) < margin($1, at: p) } ?? exact
    }

    /// How far `p` is from the capture edges that cut through the scope (edges that
    /// are the scope's own don't count).
    private func margin(_ a: Analysis, at p: CGPoint) -> CGFloat {
        let c = a.captureRect, f = a.scopeFrame
        var m = CGFloat.infinity
        if c.minX > f.minX + 1 { m = min(m, p.x - c.minX) }
        if c.maxX < f.maxX - 1 { m = min(m, c.maxX - p.x) }
        if c.minY > f.minY + 1 { m = min(m, p.y - c.minY) }
        if c.maxY < f.maxY - 1 { m = min(m, c.maxY - p.y) }
        return m
    }

    /// The text under `p` runs into an edge where this capture cut the scope, so it
    /// would be read half ("over year, driven by…").
    private func cutsText(_ a: Analysis, at p: CGPoint) -> Bool {
        guard let hit = a.layout.hit(p) else { return margin(a, at: p) < 120 }
        let r = hit.paragraph.rect, c = a.captureRect, f = a.scopeFrame
        let tol: CGFloat = 6
        return (c.minX > f.minX + 1 && r.minX - c.minX < tol) || (c.maxX < f.maxX - 1 && c.maxX - r.maxX < tol)
            || (c.minY > f.minY + 1 && r.minY - c.minY < tol) || (c.maxY < f.maxY - 1 && c.maxY - r.maxY < tol)
    }

    private func scheduleAnalysis() {
        scheduleQRScan()
        guard Permissions.shared.screenRecording, let s = current, inspection?.codeRegion == nil else { return }
        guard !s.kind.isTextRange, s.kind != .barcode else { return }
        let wantsPixels = s.isVisual || s.isBackdrop || (s.text?.nonBlank == nil && !s.textPending)
        guard wantsPixels else { return }
        guard let (key, frame, covers) = analysisRegion(s, at: lastPoint) else { return }
        if analyzing.contains(key) { return }
        if let existing = analyses[key], Date().timeIntervalSince(existing.date) < Self.refreshAfter { return }

        dwell?.cancel()
        let ocr = s.isBackdrop || s.text?.nonBlank == nil
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            self?.runAnalysis(key: key, frame: frame, scopeFrame: s.frame, ocr: ocr, covers: covers, gen: gen)
        }
        dwell = work
        // A box being drawn changes size constantly; read it once it rests.
        DispatchQueue.main.asyncAfter(deadline: .now() + (s.role == Self.boxRole ? 0.16 : 0.06), execute: work)
    }

    private func runAnalysis(key: String, frame: CGRect, scopeFrame: CGRect, ocr: Bool, covers: Bool, gen: Int) {
        guard armed, gen == generation, !analyzing.contains(key) else { return }
        analyzing.insert(key)
        Task { @MainActor [weak self] in
            let analysis = await Task.detached(priority: .userInitiated) { () -> Analysis? in
                guard let cap = try? await ScreenGrabber.shared.capture(frame, maxPixels: 8_000_000) else { return nil }
                var layout = ocr ? await VisionService.shared.read(cap) : TextLayout()
                if layout.barcodes.isEmpty { layout.barcodes = await VisionService.shared.barcodes(cap) }
                // A thumbnail is only shown for things captured whole.
                let thumb = covers ? Thumbnail.make(cap.image, maxSide: 200) : nil
                return Analysis(date: Date(), captureRect: cap.rect, captureScale: cap.scale, layout: layout, didOCR: ocr, covers: covers, thumbnail: thumb,
                                pixels: covers ? nil : PixelMap(cap), scopeFrame: scopeFrame)
            }.value
            guard let self else { return }
            self.analyzing.remove(key)
            guard let analysis, self.armed, gen == self.generation else { return }
            self.analyses[key] = analysis
            self.reapply()
        }
    }

    /// Looks for a QR code or barcode right under the cursor whenever it rests on
    /// something that isn't plain text, so codes are found even when apps don't
    /// expose them as images (CSS backgrounds, canvases, video, screenshots).
    private func scheduleQRScan() {
        guard boxAnchor == nil, Permissions.shared.screenRecording, let s = current, inspection?.codeRegion == nil else { return }
        if s.kind == .barcode || (s.kind.isTextRange && !s.textIsOCR) || s.kind == .code { return }
        let p = lastPoint
        let cell = qrCell(p)
        if let cached = qrScans[cell], Date().timeIntervalSince(cached.date) < Self.refreshAfter { return }
        guard !qrScanning.contains(cell) else { return }
        qrDwell?.cancel()
        let gen = generation
        let bounds = ScreenSpace.displayBounds().first { $0.contains(p) } ?? s.frame
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.armed, gen == self.generation, !self.qrScanning.contains(cell) else { return }
            self.qrScanning.insert(cell)
            Task { @MainActor [weak self] in
                let code = await Task.detached(priority: .userInitiated) { await BarcodeScanner.scan(at: p, within: bounds) }.value
                guard let self else { return }
                self.qrScanning.remove(cell)
                guard self.armed, gen == self.generation else { return }
                self.qrScans[cell] = (Date(), code)
                if code != nil { self.reapply() }
            }
        }
        qrDwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func ensureText() {
        if let s = current, s.textPending, let ref = s.tableRef, let key = s.tableKey {
            guard resolvedTables[key] == nil, !resolvingTables.contains(key) else { return }
            resolvingTables.insert(key)
            let gen = generation
            let inspector = self.inspector
            onAXQueue(own: Self.isOwn(ref.table)) { [weak self] in
                let text = inspector.tableText(ref)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.resolvingTables.remove(key)
                        guard gen == self.generation else { return }
                        self.resolvedTables[key] = text ?? ""
                        self.reapply()
                    }
                }
            }
            return
        }
        guard let s = current, s.textPending, let e = s.element else { return }
        let key = ElementKey(element: e)
        guard resolved[key] == nil, !resolving.contains(key) else { return }
        resolving.insert(key)
        let web = inspection?.webArea
        let gen = generation
        let inspector = self.inspector
        onAXQueue(own: Self.isOwn(e)) { [weak self] in
            let text = inspector.resolveText(for: s, webArea: web)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resolving.remove(key)
                    guard gen == self.generation else { return }
                    self.resolved[key] = text ?? ""
                    self.reapply()
                }
            }
        }
    }

    private func fetchText(_ s: Scope) async -> String? {
        let web = inspection?.webArea
        let inspector = self.inspector
        return await withCheckedContinuation { c in
            onAXQueue(own: Self.isOwn(s.element)) { c.resume(returning: inspector.resolveText(for: s, webArea: web)) }
        }
    }

    // MARK: Modes

    private func linkURL(for s: Scope) -> URL? {
        if let u = s.linkURL { return u }
        if let code = s.barcode, let u = URL(string: code), Inspector.isLinkScheme(u), u.host != nil { return u }
        return detectedLink(in: s.bestText)
    }

    /// The word under the cursor, used to pick the right link out of a line.
    private var hoveredWord: String? {
        inspection?.scopes.first { $0.kind == .word || $0.kind == .ocrWord }?.text
    }

    private func detectedLink(in text: String?) -> URL? {
        guard let t = text, t.count <= 4000, let det = Self.linkDetector else { return nil }
        let word = hoveredWord
        let key = t + "\u{1}" + (word ?? "")
        if let cached = linkCache[key] { return cached }
        let ns = t as NSString
        let found = det.matches(in: t, range: NSRange(location: 0, length: ns.length)).compactMap { m -> (URL, String)? in
            guard let u = m.url, ["http", "https", "mailto", "ftp"].contains(u.scheme?.lowercased() ?? "") else { return nil }
            return (u, ns.substring(with: m.range))
        }
        let url = found.first { word != nil && $0.1.contains(word!) }?.0
            ?? found.first { $0.0.scheme?.hasPrefix("http") == true }?.0
            ?? found.first?.0
        linkCache[key] = url
        return url
    }

    private func isPureLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), let det = Self.linkDetector,
              let m = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return false }
        return m.range.length == (t as NSString).length
    }

    private func options(for s: Scope) -> [ModeOption] {
        let sr = Permissions.shared.screenRecording
        var out: [ModeOption] = []

        if s.kind == .table {
            out.append(ModeOption(mode: .text, enabled: true, title: "Table", symbol: "tablecells"))
        } else if s.kind == .list {
            out.append(ModeOption(mode: .text, enabled: true, title: "List", symbol: "list.bullet"))
        } else if let c = s.code {
            out.append(c.isTerminal
                ? ModeOption(mode: .text, enabled: true, title: "Text", symbol: "terminal")
                : ModeOption(mode: .text, enabled: true, title: "Code", symbol: "chevron.left.forwardslash.chevron.right"))
        } else if s.kind != .barcode {
            let hasAX = s.text?.nonBlank != nil && !s.textIsOCR
            if hasAX || s.textPending {
                out.append(ModeOption(mode: .text, enabled: true, title: "Text", symbol: "text.quote"))
            } else if s.bestText != nil || (sr && !s.analysisDone && !(s.isVisual && min(s.frame.width, s.frame.height) < 48)) {
                out.append(ModeOption(mode: .text, enabled: true, title: "OCR", symbol: "text.viewfinder"))
            } else if !sr {
                out.append(ModeOption(mode: .text, enabled: false, title: "OCR", symbol: "text.viewfinder"))
            }
        }
        if linkURL(for: s) != nil {
            out.append(ModeOption(mode: .link, enabled: true, title: "Link", symbol: "link"))
        }
        if s.barcode != nil {
            let qr = (s.barcodeKind ?? "QR") == "QR"
            out.append(ModeOption(mode: .qr, enabled: true, title: qr ? "QR" : (s.barcodeKind ?? "Code"), symbol: qr ? "qrcode" : "barcode"))
        }
        if let f = s.fileURL ?? s.pathURL {
            let folder = f.hasDirectoryPath && f.pathExtension.isEmpty
            out.append(ModeOption(mode: .file, enabled: true, title: folder ? "Folder" : "File", symbol: folder ? "folder.fill" : "doc.fill"))
        }
        out.append(ModeOption(mode: .image, enabled: sr, title: "Image", symbol: "photo"))
        out.append(ModeOption(mode: .color, enabled: sr || s.colorLiteral != nil, title: "Color", symbol: s.colorLiteral != nil ? "paintpalette.fill" : "eyedropper.halffull"))
        return out
    }

    private func smartMode(for s: Scope, enabled: [GrabMode]) -> GrabMode {
        func ok(_ m: GrabMode) -> Bool { enabled.contains(m) }
        if s.role == Self.boxRole {
            if s.barcode != nil, ok(.qr) { return .qr }
            if s.bestText != nil || !s.analysisDone, ok(.text) { return .text }
            return ok(.image) ? .image : (enabled.first ?? .text)
        }
        if s.kind == .barcode, ok(.qr) { return .qr }
        if s.fileURL != nil, ok(.file) { return .file }
        if s.linkIsSelf, ok(.link) { return .link }
        if s.isVisual {
            if s.barcode != nil, ok(.qr) { return .qr }
            if ok(.image) && s.kind != .window { return .image }
        }
        if let t = s.text?.nonBlank, isPureLink(t), ok(.link) { return .link }
        // Pointing right at #ED6E2A in some text means the color.
        if s.colorLiteral != nil, ok(.color) { return .color }
        if s.isBackdrop, ok(.color) { return .color }
        if ok(.text) { return .text }
        if ok(.image) { return .image }
        return enabled.first ?? .text
    }

    private func updateMode() {
        guard let s = current else { return }
        let enabled = options(for: s).filter(\.enabled).map(\.mode)
        if let u = userMode, enabled.contains(u) {
            mode = u
        } else if s.kind != .barcode, let bid = inspection?.bundleID, let raw = Settings.shared.appRules[bid],
                  let rule = GrabMode(rawValue: raw), enabled.contains(rule) {
            mode = rule
        } else {
            mode = smartMode(for: s, enabled: enabled)
        }
    }

    func cycleMode(_ delta: Int) {
        guard armed || debugHold, let s = current else { return }
        let enabled = options(for: s).filter(\.enabled).map(\.mode)
        guard enabled.count > 1 else {
            Sound.shared.play(.bump)
            Haptics.perform(.generic)
            return
        }
        let i = enabled.firstIndex(of: mode) ?? 0
        mode = enabled[(i + delta + enabled.count) % enabled.count]
        userMode = mode
        Sound.shared.play(.tick)
        Haptics.perform(.alignment)
        pushModel()
        if model.pixelColor {
            model.cursor = lastPoint
            requestLoupe()
        } else {
            model.loupe = nil
        }
    }

    func cycleFormat(_ delta: Int) {
        guard armed || debugHold, let s = current else { return }
        let (family, opts, selected) = formatInfo(s, mode)
        guard opts.count > 1 else {
            Sound.shared.play(.bump)
            Haptics.perform(.generic)
            return
        }
        let i = opts.firstIndex { $0.id == selected?.id } ?? 0
        Formats.select(opts[(i + delta + opts.count) % opts.count], for: family)
        Sound.shared.play(.tick)
        Haptics.perform(.alignment)
        pushModel()
    }

    func changeScope(_ delta: Int) {
        guard armed || debugHold, let ins = inspection, let i = currentIndex else { return }
        let n = i + delta
        guard ins.scopes.indices.contains(n) else {
            Sound.shared.play(.bump)
            Haptics.perform(.generic)
            return
        }
        selectedID = ins.scopes[n].id
        sticky = StickyScope(ins.scopes[n])
        updateMode()
        ensureText()
        scheduleAnalysis()
        Sound.shared.play(.scope)
        Haptics.perform(.alignment)
        pushModel()
    }

    // MARK: Model

    private func pushModel() {
        guard let ins = inspection, let s = current else {
            model.set(\.target, nil)
            model.set(\.preview, .unavailable("Nothing under the cursor"))
            return
        }
        let idx = currentIndex ?? 0
        model.set(\.target, s.frame)
        model.set(\.targetIsText, s.kind.isTextRange)
        model.set(\.scopeLabel, s.label)
        model.set(\.scopeIndex, idx)
        model.set(\.scopeCount, ins.scopes.count)
        model.set(\.mode, mode)
        model.set(\.literalColor, mode == .color ? s.colorLiteral : nil)
        model.set(\.options, options(for: s))
        let info = formatInfo(s, mode)
        model.set(\.formats, info.options.count > 1 ? info.options : [])
        model.set(\.format, info.selected?.id)
        model.set(\.preview, formattedPreview(s, info) ?? preview(for: s))
        if !model.pixelColor { model.set(\.loupe, nil) }
    }

    private func formatInfo(_ s: Scope, _ m: GrabMode) -> (family: FormatFamily, options: [FormatOption], selected: FormatOption?) {
        let family = Formats.family(for: s, mode: m)
        let opts = Formats.options(family, scope: s, source: (inspection?.sourceTitle, inspection?.sourceURL))
        return (family, opts, Formats.selected(family, in: opts))
    }

    /// Shows what the chosen format will produce, when it changes the text.
    private func formattedPreview(_ s: Scope, _ info: (family: FormatFamily, options: [FormatOption], selected: FormatOption?)) -> Preview? {
        guard let opt = info.selected else { return nil }
        let f = opt.id
        if let custom = Formats.customFormat(f) {
            if let name = custom.shortcut { return .text("Runs “\(name)” on it and copies the result", meta: "Shortcut · \(custom.name)") }
            let sample: Payload? = {
                switch mode {
                case .text: return s.bestText.map { .text($0.cleanedForClipboard) }
                case .link: return linkURL(for: s).map { .link($0) }
                default: return nil
                }
            }()
            guard let sample else { return nil }
            let out = Template.render(custom.template, values: templateValues(sample, scope: s))
            let lines = out.components(separatedBy: "\n")
            if lines.count > 1 { return .snippet(lines.prefix(4).map { $0.truncated(64) }.joined(separator: "\n") + (lines.count > 4 ? "\n…" : ""), meta: custom.name) }
            return .text(out.truncated(160), meta: custom.name)
        }
        if f == "picture", info.family == .code || info.family == .terminal {
            return .text("A shareable picture of this code, in color", meta: "Picture")
        }
        if f == "receipt", info.family == .text || info.family == .list {
            return .text(info.family == .list ? "Every item rung up on a till receipt, prices made up" : "Printed out as a till receipt", meta: "Receipt")
        }
        if mode == .image, f == "sticker" { return .text("The subject cut out with a white border, like a sticker", meta: "Sticker") }
        if mode == .image, f == "polaroid" { return .text("An instant photo, with where and when written underneath", meta: "Polaroid") }
        if mode == .text, let v = s.smart, !["plain", "code", "markdown", "reference", "permalink"].contains(f),
           let out = SmartTypes.render(v, as: f) {
            let meta = "\(v.kind.title) · \(opt.title)"
            switch out {
            case .text(let t):
                let lines = t.components(separatedBy: "\n")
                if lines.count > 1 {
                    return .snippet(lines.prefix(4).map { $0.truncated(64) }.joined(separator: "\n") + (lines.count > 4 ? "\n…" : ""), meta: meta)
                }
                return .text(t.truncated(160), meta: meta)
            case .link(let u):
                var rest = u.path
                if let q = u.query { rest += "?" + q }
                return .link(host: u.host ?? u.absoluteString, path: rest)
            case .event(_, let name):
                let when = SmartTypes.render(v, as: "local").flatMap { if case .text(let t) = $0 { return t }; return nil } ?? ""
                return .text("“\(name)”", meta: "Calendar event · " + when)
            }
        }
        if mode == .text, f == "cite", let t = s.bestText {
            return .text(Formats.cite(t.cleanedForClipboard, title: inspection?.sourceTitle, url: inspection?.sourceURL).oneLine.truncated(160),
                         meta: "Quote with source")
        }
        if mode == .text, f == "font" { return .text("Font, size and color of the text under the cursor", meta: s.inWeb ? "CSS" : "Font") }
        if mode == .text, f == "selector" { return .text("CSS selector for this element", meta: s.label) }
        if mode == .text, f == "fields" { return .text("Every field in this form as JSON", meta: s.label) }
        if mode == .link, f == "attime", let page = s.videoPage {
            return .link(host: page.host ?? "youtu.be", path: page.path + "?t=…")
        }
        return nil
    }

    private func screenScale(for r: CGRect) -> CGFloat {
        NSScreen.screens.first { ScreenSpace.toAX($0.frame).contains(r.center) }?.backingScaleFactor ?? 2
    }

    private func preview(for s: Scope) -> Preview {
        switch mode {
        case .text:
            if let c = s.code, let t = s.text {
                let lines = t.components(separatedBy: "\n")
                var meta = c.isTerminal ? "" : (c.language.isEmpty ? "Code" : c.language.capitalizedFirst)
                meta += meta.isEmpty ? "" : " · "
                meta += lines.count == 1 ? "\(t.count) characters" : "\(lines.count) lines"
                if let f = c.fileURL, let l = c.lines { meta += " · \(f.lastPathComponent):\(l.lowerBound)" }
                if s.textIsOCR { meta += " · recognized" }
                let shown = lines.prefix(4).map { $0.truncated(64) }.joined(separator: "\n") + (lines.count > 4 ? "\n…" : "")
                return .snippet(shown, meta: meta)
            }
            if s.kind == .list, let t = s.text {
                let items = t.components(separatedBy: "\n")
                let shown = items.prefix(4).map { "• " + $0.truncated(64) }.joined(separator: "\n")
                return .snippet(shown + (items.count > 4 ? "\n…" : ""), meta: "\(items.count) items")
            }
            if s.kind == .table, let t = s.text {
                let rows = t.components(separatedBy: "\n")
                let cols = rows.map { $0.components(separatedBy: "\t").count }.max() ?? 1
                let shown = rows.prefix(4).map { $0.replacingOccurrences(of: "\t", with: "  │  ").truncated(70) }.joined(separator: "\n")
                return .snippet(shown + (rows.count > 4 ? "\n…" : ""), meta: "\(rows.count) rows × \(cols) columns")
            }
            if let t = s.bestText {
                let clean = t.cleanedForClipboard
                let words = clean.split { $0.isWhitespace || $0.isNewline }.count
                var meta = words == 1 ? "\(clean.count) characters" : "\(words) words"
                if s.textIsOCR || s.text?.nonBlank == nil { meta += " · recognized" }
                return .text(clean.oneLine.truncated(160), meta: meta)
            }
            if s.textPending { return .loading("Reading text…") }
            if !s.analysisDone && Permissions.shared.screenRecording {
                return .loading(VisionService.preparing ? "Getting text recognition ready after the update…" : "Looking for text…")
            }
            return .unavailable("No text here")
        case .link:
            guard let u = linkURL(for: s) else { return .unavailable("No link") }
            if u.scheme == "mailto" { return .link(host: u.absoluteString.replacingOccurrences(of: "mailto:", with: ""), path: "") }
            var rest = u.path
            if let q = u.query { rest += "?" + q }
            if rest == "/" { rest = "" }
            return .link(host: u.host ?? u.absoluteString, path: rest)
        case .qr:
            if let payload = s.barcode, payload.uppercased().hasPrefix("WIFI:") {
                let w = Formats.wifi(payload)
                return .code("Wi-Fi “\(w.network ?? "?")”" + (w.password.map { " · password \($0)" } ?? ""), kind: "QR")
            }
            return .code(s.barcode ?? "", kind: s.barcodeKind ?? "QR")
        case .file:
            guard let f = s.fileURL ?? s.pathURL else { return .unavailable("No file") }
            let folder = (f.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            return .file(name: f.lastPathComponent, folder: folder, url: f)
        case .image:
            let size = s.pixelSize ?? CGSize(width: s.frame.width * screenScale(for: s.frame), height: s.frame.height * screenScale(for: s.frame))
            return .image(width: Int(size.width.rounded()), height: Int(size.height.rounded()), thumb: s.thumbnail)
        case .color:
            if let c = s.colorLiteral {
                return .color(c, formatted: c.formatted(Settings.shared.colorFormat))
            }
            if let l = model.loupe {
                return .color(l.color, formatted: l.color.formatted(Settings.shared.colorFormat))
            }
            return .loading("Sampling…")
        }
    }

    private func requestLoupe() {
        guard model.pixelColor, !loupeBusy, Permissions.shared.screenRecording else { return }
        loupeBusy = true
        let p = lastPoint
        let gen = generation
        Task { @MainActor [weak self] in
            let sample = try? await ScreenGrabber.shared.loupe(at: p, pixels: 15)
            guard let self else { return }
            self.loupeBusy = false
            guard self.armed, gen == self.generation, self.model.pixelColor, let sample else { return }
            self.model.loupe = sample
            self.model.set(\.preview, .color(sample.color, formatted: sample.color.formatted(Settings.shared.colorFormat)))
        }
    }

    // MARK: Copy

    func copy(append: Bool = false) {
        guard armed || debugHold else { return }
        if let peek = model.peek, peek.isOut(), peek.hitRect.contains(lastPoint), !Buddy.shared.isAway {
            petMascot()
            return
        }
        guard let s = current else {
            pendingCopy = true
            return
        }
        guard !copying, waitingCopy == nil else { return }
        // Pixels are still being read here: copy once they say what's under the
        // cursor, instead of copying the whole window's text.
        if awaitingPixels(s) {
            waitingCopy = append
            model.busy = true
            scheduleAnalysis()
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.flushWaitingCopy(force: true)
            }
            return
        }
        performCopy(s, append: append)
    }

    /// The HUD can't yet say what's under the cursor: OCR may still find text there.
    private func awaitingPixels(_ s: Scope) -> Bool {
        guard Permissions.shared.screenRecording, !s.analysisDone, s.kind != .barcode, s.code == nil,
              !s.kind.isTextRange, inspection?.codeRegion == nil else { return false }
        if s.isBackdrop { return true }
        return mode == .text && s.text?.nonBlank == nil && !s.textPending && s.ocrText == nil
    }

    private func flushWaitingCopy(force: Bool = false) {
        guard let append = waitingCopy, let s = current else { return }
        guard force || !awaitingPixels(s) else { return }
        waitingCopy = nil
        model.busy = false
        performCopy(s, append: append)
    }

    private func performCopy(_ s: Scope, append: Bool) {
        guard !copying else { return }
        copying = true
        let m = mode
        let point = lastPoint
        let busy = DispatchWorkItem { [weak self] in self?.model.busy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: busy)

        Task { @MainActor [weak self] in
            guard let self else { return }
            var result = await self.resolve(s, mode: m, at: point)
            if case .success(let raw) = result { result = await self.finalize(raw, scope: s, mode: m, at: point) }
            busy.cancel()
            self.model.busy = false
            self.copying = false
            switch result {
            case .success(let payload):
                let fmt = self.formatInfo(s, m).selected?.id
                let secret = Settings.shared.protectSecrets && self.isSecret(payload, format: fmt, scope: s)
                var appended = false
                if append {
                    appended = self.addToShelf(payload, scope: s, mode: m)
                } else {
                    var adaptive: (language: String, enabled: Bool)?
                    if m == .text, let c = s.code, fmt == nil || fmt == "code" {
                        adaptive = (c.isTerminal ? "console" : c.language, Settings.shared.adaptivePaste)
                    }
                    Clipboard.write(payload, secret: secret, adaptive: adaptive)
                    self.appendCount = 1
                }
                self.celebrate(payload, scope: s, mode: m, at: point, appended: appended, secret: secret)
            case .failure(let error):
                self.fail(error, mode: m)
            }
            if self.oneShot {
                self.oneShot = false
                self.disarm()
            }
        }
    }

    /// ⌥⇧C: the grab joins the shelf, and the clipboard holds the whole shelf.
    private func addToShelf(_ payload: Payload, scope s: Scope, mode m: GrabMode) -> Bool {
        let shelf = Shelf.shared
        if shelf.items.isEmpty, let existing = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank,
           existing.count < 100_000 {
            shelf.add(Shelf.Item(payload: .text(existing), title: existing, mode: .text, thumbnail: nil))
        }
        var thumb: NSImage?
        var title = s.label
        switch payload {
        case .text(let t), .code(let t), .color(_, let t): title = t
        case .link(let u): title = u.absoluteString
        case .file(let u): title = u.lastPathComponent
        case .image(let img, _):
            title = "Image \(img.width) × \(img.height)"
            thumb = Thumbnail.make(img, maxSide: 80).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
        shelf.add(Shelf.Item(payload: payload, title: title, mode: m, thumbnail: thumb))
        shelf.syncClipboard()
        appendCount = shelf.items.count
        Panels.shared.showShelf()
        return true
    }

    private func isSecret(_ p: Payload, format: String?, scope s: Scope) -> Bool {
        if s.barcode?.uppercased().hasPrefix("WIFI:") == true, format == "password" || format == nil { return true }
        if case .text(let t) = p { return Secrets.looksSecret(t) }
        if case .code(let t) = p { return Secrets.looksSecret(t) }
        return false
    }

    /// Formats that need more work than reshaping text: reading fonts and form
    /// fields, lifting subjects, permalinks, calendar files…
    private func finalize(_ p: Payload, scope s: Scope, mode m: GrabMode, at point: CGPoint) async -> Result<Payload, Error> {
        let info = formatInfo(s, m)
        let f = info.selected?.id ?? ""
        let inspector = self.inspector
        let own = Self.isOwn(s.element ?? inspection?.leaf)
        func onAX<T>(_ work: @escaping @Sendable () -> T) async -> T {
            await withCheckedContinuation { c in onAXQueue(own: own) { c.resume(returning: work()) } }
        }
        func failed(_ why: String) -> Result<Payload, Error> { .failure(GrabError.failed(why)) }

        if let custom = Formats.customFormat(f) {
            return await renderCustom(custom, p, scope: s)
        }
        if f == "receipt", info.family == .text || info.family == .list, case .text(let t) = p {
            let isList = info.family == .list
            let lines = isList
                ? t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : FunFormats.wrap(t, width: 32)
            guard !lines.isEmpty, let r = FunFormats.receipt(lines: lines, isList: isList, store: storeName, cashier: cashierName) else {
                return failed("Couldn't print the receipt")
            }
            return .success(.image(r.image, pointSize: r.pointSize))
        }
        if f == "picture", info.family == .code || info.family == .terminal, case .text(let code) = p {
            let lang = s.code?.isTerminal == true ? "console" : (s.code?.language ?? "")
            let title = s.code?.fileURL?.lastPathComponent ?? (s.code?.isTerminal == true ? "Terminal" : nil)
            let first = s.code?.fileURL != nil ? s.code?.lines?.lowerBound : nil
            guard let img = CodeImage.render(code, language: lang, title: title, firstLine: first) else { return failed("Couldn't draw the code") }
            return .success(.image(img, pointSize: CGSize(width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)))
        }
        switch info.family {
        case .text:
            switch f {
            case "cite":
                guard case .text(let t) = p else { break }
                return .success(.text(Formats.cite(t, title: inspection?.sourceTitle, url: inspection?.sourceURL)))
            case "font":
                let leaf = inspection?.leaf, web = inspection?.webArea
                guard let d = await onAX({ inspector.fontDescription(at: point, leaf: leaf, webArea: web) }) else {
                    return failed("No font info here")
                }
                return .success(.text(d))
            case "selector":
                guard let e = s.element, let sel = await onAX({ inspector.cssSelector(e) }) else { return failed("No selector for this") }
                return .success(.text(sel))
            case "fields":
                guard let e = s.element else { return failed("No form here") }
                let pairs = await onAX { inspector.formFields(e) }
                guard !pairs.isEmpty else { return failed("No fields found") }
                return .success(.text(Formats.jsonString(pairs)))
            default: break
            }
        case .link where f == "attime":
            guard let page = s.videoPage else { break }
            var secs: Int?
            if let e = s.element { secs = await onAX { inspector.videoTime(near: e) } }
            var c = URLComponents(url: page, resolvingAgainstBaseURL: false)
            if let secs, secs > 0 { c?.queryItems = [URLQueryItem(name: "t", value: "\(secs)")] }
            return .success(.link(c?.url ?? page))
        case .code where f == "permalink":
            guard let file = s.code?.fileURL, let lines = s.code?.lines, let u = Git.permalink(file: file, lines: lines) else {
                return failed("No remote for this repository")
            }
            return .success(.link(u))
        case .file where f == "icon":
            guard case .file(let u) = p, let img = ImageTools.icon(for: u) else { return failed("No icon") }
            return .success(.image(img, pointSize: CGSize(width: 512, height: 512)))
        case .image:
            guard case .image(let img, let size) = p else { break }
            switch f {
            case "subject":
                guard let cut = await VisionService.shared.subject(of: img) else {
                    return failed("No subject found")
                }
                let k = img.width > 0 ? size.width / CGFloat(img.width) : 1
                return .success(.image(cut, pointSize: CGSize(width: CGFloat(cut.width) * k, height: CGFloat(cut.height) * k)))
            case "sticker":
                guard let cut = await VisionService.shared.subject(of: img) else { return failed("No subject to make a sticker of") }
                let scale = img.width > 0 && size.width > 0 ? CGFloat(img.width) / size.width : 2
                guard let sticker = await Task.detached(priority: .userInitiated, operation: { FunFormats.sticker(cut, scale: scale) }).value else {
                    return failed("Couldn't make the sticker")
                }
                return .success(.image(sticker, pointSize: CGSize(width: CGFloat(sticker.width) / scale, height: CGFloat(sticker.height) / scale)))
            case "polaroid":
                let caption = storeName + " · " + Date().formatted(.dateTime.month(.abbreviated).day())
                guard let photo = FunFormats.polaroid(img, pointSize: size, caption: caption) else { return failed("Couldn't make the photo") }
                return .success(.image(photo.image, pointSize: photo.pointSize))
            case "palette":
                let colors = await Task.detached(priority: .userInitiated, operation: { ImageTools.palette(of: img) }).value
                guard !colors.isEmpty else { return failed("No colors found") }
                return .success(.text(colors.map { $0.formatted(Settings.shared.colorFormat) }.joined(separator: "\n")))
            case "datauri":
                guard let uri = ImageTools.dataURI(img) else { return failed("Couldn't encode the image") }
                return .success(.text(uri))
            default:
                // Pasting looking finished: pictures of text get room around them, and
                // corners are softly rounded.
                guard Settings.shared.roundImageCorners else { break }
                let textual = s.kind.isTextRange || s.kind == .table || s.kind == .list
                    || (s.kind == .element && !s.isVisual && !s.isBackdrop && s.bestText != nil)
                if textual {
                    // Tables keep their outer lines: those are part of the table.
                    let tidy = s.kind != .table && s.kind != .list
                    let base = ImageTools.textCard(img, pointSize: size, tidyEdges: tidy) ?? (img, size)
                    // Never trim the edges of text: they may hold the tops and tails of letters.
                    let r = ImageTools.rounded(base.image, pointSize: base.pointSize, trimBleed: false) ?? base
                    return .success(.image(r.image, pointSize: r.pointSize))
                }
                if let rounded = ImageTools.rounded(img, pointSize: size) {
                    return .success(.image(rounded.image, pointSize: rounded.pointSize))
                }
            }
        default: break
        }

        // Smart formats: dates, addresses, JSON… (and the ones offered on code).
        if m == .text, let v = s.smart, f != "plain", let out = SmartTypes.render(v, as: f) {
            switch out {
            case .text(let t): return .success(.text(t))
            case .link(let u): return .success(.link(u))
            case .event(let ics, let name):
                guard let url = TempFiles.write(ics, name: name, ext: "ics") else { return failed("Couldn't create the event") }
                return .success(.file(url))
            }
        }
        return .success(applyFormat(p, scope: s, mode: m))
    }

    /// Where a grab came from, short: "youtube.com", or the app's name.
    private var storeName: String {
        if let host = inspection?.sourceURL?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return inspection?.appName ?? "Grab"
    }

    /// Who rings up a receipt: the mascot, if there is one.
    private var cashierName: String {
        let kind = MascotKind(rawValue: Settings.shared.mascot) ?? .snap
        return kind == .off || kind == .classic ? "Grab" : kind.title
    }

    /// Values for `{tokens}` in your own formats.
    private func templateValues(_ p: Payload, scope s: Scope) -> [String: String] {
        var text = ""
        var url = inspection?.sourceURL
        switch p {
        case .text(let t), .code(let t): text = t
        case .link(let u):
            url = u
            text = (s.text?.cleanedForClipboard.nonBlank ?? u.absoluteString).oneLine
        case .file(let u): text = u.path
        case .color(_, let f): text = f
        case .image: text = ""
        }
        return Template.values(text: text, url: url, title: inspection?.sourceTitle, app: inspection?.appName,
                               language: s.code?.language, file: s.code?.fileURL, line: s.code?.lines?.lowerBound)
    }

    private func renderCustom(_ f: CustomFormat, _ p: Payload, scope s: Scope) async -> Result<Payload, Error> {
        guard let name = f.shortcut else {
            return .success(.text(Template.render(f.template, values: templateValues(p, scope: s))))
        }
        let input: Data?, ext: String
        switch p {
        case .image(let img, _):
            input = ImageTools.pngData(img)
            ext = "png"
        default:
            input = templateValues(p, scope: s)["text"]?.data(using: .utf8)
            ext = "txt"
        }
        guard let input, let out = await ShortcutRunner.run(name, input: input, ext: ext) else {
            return .failure(GrabError.failed("“\(name)” didn't return anything"))
        }
        switch out {
        case .text(let t): return .success(.text(t))
        case .image(let data):
            guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                return .failure(GrabError.failed("“\(name)” returned an unreadable image"))
            }
            return .success(.image(img, pointSize: CGSize(width: img.width, height: img.height)))
        }
    }

    private func resolve(_ s: Scope, mode m: GrabMode, at point: CGPoint) async -> Result<Payload, Error> {
        do {
            switch m {
            case .text:
                // Recognized words, lines and paragraphs are read with the accurate model already.
                if let t = s.text?.cleanedForClipboard.nonBlank { return .success(.text(t)) }
                if s.textPending, let ref = s.tableRef {
                    let inspector = self.inspector
                    let t = await withCheckedContinuation { c in onAXQueue(own: Self.isOwn(ref.table)) { c.resume(returning: inspector.tableText(ref)) } }
                    if let t = t?.nonBlank { return .success(.text(t)) }
                    throw GrabError.noText
                }
                if s.textPending, let t = await fetchText(s)?.cleanedForClipboard.nonBlank { return .success(.text(t)) }

                // Read the pixels properly: full resolution, accurate model, language correction.
                if let t = s.ocrText?.cleanedForClipboard.nonBlank { return .success(.text(t)) }
                let cap = try await ScreenGrabber.shared.capture(s.frame, maxPixels: 16_000_000)
                let layout = await VisionService.shared.read(cap)
                if let t = layout.text.cleanedForClipboard.nonBlank { return .success(.text(t)) }
                throw GrabError.noText

            case .link:
                guard let u = linkURL(for: s) else { throw GrabError.nothing }
                if u.scheme?.lowercased() == "mailto" {
                    // An email address is more useful as the address itself.
                    let address = u.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
                    return .success(.text(address.removingPercentEncoding ?? address))
                }
                return .success(.link(u))

            case .qr:
                guard let code = s.barcode else { throw GrabError.nothing }
                return .success(.code(code))

            case .file:
                if let f = s.fileURL { return .success(.file(f)) }
                guard let p = s.pathURL else { throw GrabError.nothing }
                guard FileManager.default.fileExists(atPath: p.path) else { throw GrabError.noFile }
                return .success(.file(p))

            case .image:
                if let u = s.imageURL, let original = await ImageFetcher.fetch(u) {
                    return .success(.image(original, pointSize: CGSize(width: original.width, height: original.height)))
                }
                let cap = try await ScreenGrabber.shared.capture(s.frame)
                return .success(.image(cap.image, pointSize: cap.rect.size))

            case .color:
                if let c = s.colorLiteral { return .success(.color(c, c.formatted(Settings.shared.colorFormat))) }
                let sample = try await ScreenGrabber.shared.loupe(at: point, pixels: 3)
                return .success(.color(sample.color, sample.color.formatted(Settings.shared.colorFormat)))
            }
        } catch {
            return .failure(error)
        }
    }

    /// The user's chosen format for this kind of grab (⌥ + Tab).
    private func applyFormat(_ p: Payload, scope s: Scope, mode m: GrabMode) -> Payload {
        let (family, _, selected) = formatInfo(s, m)
        guard let f = selected?.id else { return p }
        switch (family, p) {
        case (.code, .text(let t)), (.terminal, .text(let t)):
            if f == "markdown" { return .text(Formats.markdownFence(t, language: s.code?.isTerminal == true ? "console" : (s.code?.language ?? ""))) }
            if f == "reference", let file = s.code?.fileURL, let lines = s.code?.lines { return .text(Formats.reference(file: file, lines: lines)) }
            return p
        case (.table, .text(let t)):
            return .text(Formats.table(t, as: f))
        case (.list, .text(let t)):
            return .text(Formats.list(t, as: f))
        case (.wifi, .code(let payload)):
            let w = Formats.wifi(payload)
            if f == "password", let pw = w.password { return .text(pw) }
            if f == "network", let n = w.network { return .text(n) }
            return p
        case (.text, .text(let t)):
            if f == "number", let n = Formats.number(in: t) { return .text(n) }
            if f == "oneline" { return .text(Formats.oneLine(t)) }
            if f == "quote" { return .text(Formats.quote(t)) }
            return p
        case (.link, .link(let u)):
            let title = (s.text?.cleanedForClipboard.nonBlank ?? u.host ?? u.absoluteString).oneLine
            if f == "markdown" { return .text("[\(title)](\(u.absoluteString))") }
            if f == "title" { return .text(title) }
            return p
        case (.file, .file(let u)):
            if f == "path" { return .text(u.path) }
            if f == "name" { return .text(u.lastPathComponent) }
            return p
        default:
            return p
        }
    }

    private func celebrate(_ payload: Payload, scope s: Scope, mode m: GrabMode, at point: CGPoint, appended: Bool = false, secret: Bool = false) {
        // Grabs in quick succession make a combo: each one rings a step higher.
        let combo = Settings.shared.combos ? Buddy.shared.grabbed() : { Buddy.shared.grabbed(); return 1 }()
        Sound.shared.play(.copy, pitch: Self.comboPitch(combo))
        Haptics.perform(.levelChange)

        var title = "Copied"
        var detail = ""
        var thumb: CGImage?
        var color: RGBAColor?
        switch payload {
        case .text(let t):
            if let c = s.code, m == .text {
                title = c.isTerminal ? "Copied \(s.label.lowercased())" : "Copied \(c.kind == .file ? "file contents" : s.label.components(separatedBy: " · ").first!.lowercased())"
                if c.kind == .function || c.kind == .type, let name = s.label.components(separatedBy: " · ").last, s.label.contains(" · ") {
                    title += " \(name)"
                }
                let n = t.components(separatedBy: "\n").count
                detail = n > 1 ? "\(n) lines · " + t.oneLine.truncated(50) : t.truncated(70)
            } else {
                title = s.textIsOCR || s.text == nil ? "Copied recognized text" : "Copied text"
                detail = "“" + t.oneLine.truncated(70) + "”"
            }
        case .link(let u):
            title = "Copied link"
            detail = u.absoluteString.truncated(70)
        case .code(let c):
            title = "Copied \(s.barcodeKind == nil || s.barcodeKind == "QR" ? "QR code" : s.barcodeKind!)"
            detail = c.oneLine.truncated(70)
        case .file(let f):
            title = "Copied file"
            detail = f.lastPathComponent
        case .image(let img, _):
            title = "Copied image"
            detail = "\(img.width) × \(img.height)"
            thumb = Thumbnail.make(img, maxSide: 120)
        case .color(let c, let f):
            title = "Copied color"
            detail = f
            color = c
        }

        let historyTitle = detail
        if let v = s.smart, m == .text, let opt = formatInfo(s, m).selected, opt.id != "plain" {
            title = "Copied \(v.kind.title.lowercased()) · \(opt.title)"
        }
        if secret {
            title = "Copied secret"
            detail = "Hidden from clipboard managers · clears in 1 min"
        }
        if appended {
            title = "Added to shelf"
            detail = "\(appendCount) grabs · " + detail
        }
        if let opt = formatInfo(s, m).selected, ["sticker", "polaroid", "receipt"].contains(opt.id) {
            title = "Copied \(opt.title.lowercased())"
        }
        if NSWorkspace.shared.isVoiceOverEnabled { announce(title) }
        model.flash += 1
        showToast(Toast(success: true, title: title, detail: detail, mode: m, color: color, thumb: thumb, combo: combo))
        if combo >= 5, combo % 5 == 0 { comboBurst(combo, at: point, mode: m) }

        let landing = launchMascot(payload: payload, scope: s, mode: m, at: point, color: color, thumb: thumb)
        // A soft tap on the trackpad as it lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + landing) { Haptics.perform(.alignment) }

        let historyThumb = thumb.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        var item = History.Item(mode: m, payload: payload, title: secret ? "Secret" : historyTitle, thumbnail: historyThumb, color: color)
        // The page or window title, unless it just repeats the app's name.
        item.source = inspection?.sourceTitle.flatMap { t in t == inspection?.appName ? nil : t.nonBlank }
        item.sourceURL = inspection?.sourceURL
        item.appName = inspection?.appName
        item.bundleID = inspection?.bundleID
        item.isSecret = secret
        History.shared.add(item)
        Settings.shared.grabCount += 1
        onCopied?(landing)

        var text: String?
        var pixels = 0
        switch payload {
        case .text(let t), .code(let t): text = t
        case .link(let u): text = u.absoluteString
        case .file(let u): text = u.path
        case .color(_, let f): text = f
        case .image(let img, _): pixels = img.width * img.height
        }
        let event = GrabEvent(mode: m, text: text, color: color, bundleID: inspection?.bundleID, codeKind: s.code?.kind.rawValue,
                              ocr: s.textIsOCR || (m == .text && s.text == nil), box: s.role == Self.boxRole, appended: appended,
                              format: formatInfo(s, m).selected?.id, pixels: pixels)
        NotificationCenter.default.post(name: .grabDidCopy, object: event)
        let ready = Journal.shared.takeReadyMonth()
        Journal.shared.record(event, combo: combo)
        let badges = Badges.shared.check(event, combo: combo)
        Journal.shared.noteBadges(badges)
        if let milestone = Stats.shared.takeMilestone() {
            followUp(Toast(success: true, title: "\(milestone.formatted()) grabs!",
                           detail: Stats.savedPhrase(Stats.shared.seconds).capitalizedFirst + " so far", mode: .text), sound: .boing)
        }
        announce(badges)
        if let ready {
            followUp(Toast(success: true, title: "Your \(Journal.title(ready)) Wrapped is ready",
                           detail: "Open it from Grab's menu: ⋯ → Grab Wrapped", mode: .image), sound: .fanfare)
        }
    }

    /// The copy sound climbs a major scale as a combo grows.
    nonisolated static func comboPitch(_ combo: Int) -> Int {
        let steps = [0, 2, 4, 5, 7, 9, 11, 12]
        return steps[min(max(combo, 1), steps.count) - 1]
    }

    private func comboBurst(_ combo: Int, at point: CGPoint, mode m: GrabMode) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let b = Burst(at: point, combo: combo, colors: Theme.colors(for: m))
        overlay.show()
        model.burst = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Sound.shared.play(.fanfare) }
        Haptics.perform(.levelChange)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            if self?.model.burst?.id == b.id { self?.model.burst = nil }
        }
    }

    /// Toasts that follow a grab's own (a milestone, a badge…), one after another.
    private var followUpAt = Date.distantPast

    private func followUp(_ toast: Toast, sound: Sound.Effect) {
        let at = max(Date().addingTimeInterval(1.6), followUpAt)
        followUpAt = at.addingTimeInterval(1.9)
        DispatchQueue.main.asyncAfter(deadline: .now() + at.timeIntervalSinceNow) { [weak self] in
            Sound.shared.play(sound)
            self?.showToast(toast)
        }
    }

    private func announce(_ badges: [Badge]) {
        for b in badges {
            followUp(Toast(success: true, title: "Badge unlocked · \(b.title)", detail: b.detail, mode: .text, badge: b), sound: .chime)
        }
    }

    /// C while pointing at the peeking mascot: a giggle, until it's had enough.
    private func petMascot() {
        let reaction = Buddy.shared.pet()
        model.pet = PetEvent(reaction: reaction)
        model.peek?.retractAt = Date().addingTimeInterval(2.2)
        Haptics.perform(.generic)
        switch reaction {
        case .giggle(let n):
            Sound.shared.play(.giggle, pitch: (n - 1) * 2)
        case .annoyed:
            Sound.shared.play(.hmph)
            let id = model.peek?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, self.model.peek?.id == id else { return }
                self.model.peek = nil
                self.model.petHover = false
            }
        }
        announce(Badges.shared.checkPet(reaction, total: Buddy.shared.petsTotal))
    }

    /// Into the notch: aimed inside it, so what's carried is pulled up behind the black and gone.
    nonisolated static func notchLanding(_ notch: CGRect) -> CGPoint {
        CGPoint(x: notch.midX, y: notch.minY + notch.height * 0.3)
    }

    /// Where the mascot peeks from: the notch, or the menu bar icon, on the screen in use.
    private func peekAnchor(near p: CGPoint) -> (point: CGPoint, notch: CGRect?)? {
        guard let screen = NSScreen.screens.first(where: { ScreenSpace.toAX($0.frame).contains(p) }) else { return nil }
        let frame = ScreenSpace.toAX(screen.frame)
        let rim = ScreenSpace.toAX(screen.visibleFrame).minY
        if Settings.shared.notchCatch, let n = Notch.rect(on: screen) {
            return (CGPoint(x: n.midX, y: max(rim, n.maxY)), n)
        }
        if let item = statusItemFrame?(), item.midX > frame.minX, item.midX < frame.maxX {
            return (CGPoint(x: item.midX, y: rim), nil)
        }
        return nil
    }

    // MARK: Mascot

    /// Sends the grab to the menu bar with the chosen mascot. Returns when it lands.
    @discardableResult
    private func launchMascot(payload: Payload, scope s: Scope, mode m: GrabMode, at point: CGPoint, color: RGBAColor?, thumb: CGImage?) -> TimeInterval {
        var kind = MascotKind(rawValue: Settings.shared.mascot) ?? .snap
        // Walked off in a huff: the plain chip covers for it.
        if kind != .off, Buddy.shared.isAway { kind = .classic }
        guard kind != .off, let item = statusItemFrame?() else { return 0.3 }
        let colors = Theme.colors(for: m, sample: color)
        let content: Cargo.Content
        switch payload {
        case .text(let t):
            if s.code != nil { content = .code(t.components(separatedBy: "\n").prefix(3).joined(separator: "\n")) }
            else { content = .text(String(Formats.oneLine(t).prefix(48))) }
        case .link(let u): content = .symbol("link", u.host ?? "link")
        case .code(let c): content = .symbol(s.barcodeKind == nil || s.barcodeKind == "QR" ? "qrcode" : "barcode", String(c.prefix(18)))
        case .file(let f): content = .symbol(f.hasDirectoryPath ? "folder.fill" : "doc.fill", f.lastPathComponent)
        case .image(let img, _): content = thumb.map { .image($0) } ?? (Thumbnail.make(img, maxSide: 160).map { .image($0) } ?? .symbol("photo", "Image"))
        case .color(let c, _): content = .color(c)
        }
        let from = m == .color ? point : s.frame.center
        let target = m == .color ? CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36) : s.frame
        let notch = Settings.shared.notchCatch ? Notch.rect(near: from) : nil
        var trip = Fly(from: from, to: notch.map(Self.notchLanding) ?? item.center, mode: m, color: color,
                       target: target, kind: kind, cargo: Cargo(content: content, colors: colors))
        trip.notch = notch
        trip.pumped = Buddy.shared.mood() == .pumped
        switch payload {
        case .image(let img, _): trip.heavy = img.width * img.height > 3_000_000
        case .text(let t), .code(let t): trip.heavy = t.count > 2_000
        default: break
        }
        return fly(trip)
    }

    private func fly(_ f: Fly) -> TimeInterval {
        overlay.show()
        // The peeking mascot is the one that goes: it doesn't stay behind to watch itself.
        model.peek = nil
        model.petHover = false
        model.fly = f
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion {
            for (at, effect) in f.kind.cues {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { Sound.shared.play(effect) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + f.kind.duration + 0.05) { [weak self] in
            guard let self, self.model.fly?.id == f.id else { return }
            self.model.fly = nil
            if !self.armed && self.model.toast == nil { self.overlay.hide(after: 0.05) }
        }
        return reduceMotion ? 0.3 : f.kind.dropTime
    }

    /// Settings: let the chosen mascot carry a hello from `point` to the menu bar.
    func previewMascot(at point: CGPoint) {
        let kind = MascotKind(rawValue: Settings.shared.mascot) ?? .snap
        guard kind != .off, let item = statusItemFrame?() else { return }
        let notch = Settings.shared.notchCatch ? Notch.rect(near: point) : nil
        var trip = Fly(from: point, to: notch.map(Self.notchLanding) ?? item.center, mode: .text, color: nil,
                       target: CGRect(x: point.x - 60, y: point.y - 24, width: 120, height: 48), kind: kind,
                       cargo: Cargo(content: .text("Hello from Grab"), colors: Theme.brand))
        trip.notch = notch
        let landing = fly(trip)
        Sound.shared.play(.copy)
        onCopied?(landing)
    }

    private func fail(_ error: Error, mode m: GrabMode) {
        Sound.shared.play(.error)
        Haptics.perform(.generic)
        let kind = MascotKind(rawValue: Settings.shared.mascot) ?? .snap
        if kind != .off, kind != .classic, !Buddy.shared.isAway, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let oops = Oops(at: lastPoint, kind: kind)
            model.peek = nil
            model.petHover = false
            model.oops = oops
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
                if self?.model.oops?.id == oops.id { self?.model.oops = nil }
            }
        }
        let message = (error as? GrabError)?.errorDescription ?? "Couldn't grab that"
        let hint = m == .text ? "Try ← → for Image, or ↑ ↓ to change the area" : "Try ← → for another type"
        showToast(Toast(success: false, title: message, detail: hint, mode: m))
    }

    private func showToast(_ t: Toast) {
        toastWork?.cancel()
        overlay.show()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) { model.toast = t }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.24)) { self.model.toast = nil }
            if !self.armed { self.overlay.hide(after: 0.35) }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (t.success ? 1.3 : 1.8), execute: work)
    }

    // MARK: Actions

    /// ⏎ open · space Quick Look · P pin · S speak · T translate · E ask · Z undo.
    private func perform(_ a: GrabAction) {
        guard armed || debugHold else { return }
        if a == .undo {
            if Clipboard.undo() {
                Sound.shared.play(.tick)
                Haptics.perform(.alignment)
                showToast(Toast(success: true, title: "Clipboard restored", detail: "Undid the last grab", mode: mode))
            } else {
                Sound.shared.play(.bump)
                showToast(Toast(success: false, title: "Nothing to undo", detail: "Something else changed the clipboard since", mode: mode))
            }
            return
        }
        switch a {
        case .box:
            toggleBox()
            return
        case .pasteNext:
            pasteNext()
            return
        default:
            break
        }
        if a == .speak, Speaker.shared.isSpeaking {
            Speaker.shared.stop()
            Sound.shared.play(.tick)
            return
        }
        guard let s = current, !copying else {
            Sound.shared.play(.bump)
            return
        }
        let m = mode
        let point = lastPoint
        copying = true
        let busy = DispatchWorkItem { [weak self] in self?.model.busy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: busy)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                busy.cancel()
                self.model.busy = false
                self.copying = false
            }
            switch a {
            case .speak, .translate, .ask:
                guard let text = await self.actionText(s, mode: m, at: point) else {
                    self.fail(GrabError.noText, mode: m)
                    return
                }
                if a == .speak {
                    Speaker.shared.speak(text)
                    Sound.shared.play(.tick)
                    self.showToast(Toast(success: true, title: "Speaking", detail: "\(Trigger.current.chord("S")) again to stop", mode: .text))
                    return
                }
                let task: AssistTask = a == .translate ? .translate : (s.textIsOCR && s.code == nil && s.smart == nil ? .fix : .explain)
                self.endHold()
                Panels.shared.ask(text, task: task, near: point)
            case .pin:
                var result = await self.resolve(s, mode: m, at: point)
                if case .success(let raw) = result { result = await self.finalize(raw, scope: s, mode: m, at: point) }
                guard case .success(let p) = result else {
                    if case .failure(let e) = result { self.fail(e, mode: m) }
                    return
                }
                self.endHold()
                Sound.shared.play(.scope)
                // Pictures of the screen and text read from it can be kept live.
                let fromPixels = s.role == Self.boxRole || s.textIsOCR || (s.text == nil && s.ocrText != nil)
                switch p {
                case .image(let img, let size):
                    let live = s.imageURL == nil || s.role == Self.boxRole ? Panels.LiveSource(rect: s.frame, reads: false) : nil
                    Panels.shared.pin(.image(img, size: size), near: point, live: live)
                case .text(let t) where m == .text && fromPixels && s.code == nil:
                    Panels.shared.pin(.text(t, mono: false), near: point, live: Panels.LiveSource(rect: s.frame, reads: true))
                case .text(let t), .code(let t): Panels.shared.pin(.text(t, mono: s.code != nil || m == .qr), near: point)
                case .link(let u): Panels.shared.pin(.text(u.absoluteString, mono: false), near: point)
                case .file(let u): Panels.shared.pin(.text(u.path, mono: true), near: point)
                case .color(_, let f): Panels.shared.pin(.text(f, mono: true), near: point)
                }
            case .open:
                await self.open(s, mode: m, at: point)
            case .look:
                await self.quickLook(s, mode: m, at: point)
            case .compare:
                await self.compare(s, mode: m, at: point)
            case .fill:
                await self.fillForm(s, at: point)
            case .undo, .box, .pasteNext:
                break
            }
        }
    }

    // MARK: Box

    /// ⌥R starts a box at the pointer; move to size it, C copies everything inside.
    /// R again goes back to pointing.
    private func toggleBox() {
        if boxAnchor != nil {
            boxAnchor = nil
            model.set(\.boxing, false)
            Sound.shared.play(.scope)
            Haptics.perform(.alignment)
            inspection = nil
            selectedID = nil
            requestInspection()
            return
        }
        guard Permissions.shared.screenRecording else {
            Sound.shared.play(.bump)
            showToast(Toast(success: false, title: "Boxes need Screen Recording", detail: "Grab reads what's inside from the pixels", mode: mode))
            return
        }
        boxAnchor = lastPoint
        sticky = nil
        userMode = nil
        model.set(\.boxing, true)
        Sound.shared.play(.scope)
        Haptics.perform(.alignment)
        applyBox()
    }

    private func applyBox() {
        guard let a = boxAnchor else { return }
        let p = lastPoint
        let r = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: max(abs(p.x - a.x), 3), height: max(abs(p.y - a.y), 3))
        var box = Scope(kind: .element, frame: r, label: "Box · \(Int(r.width.rounded())) × \(Int(r.height.rounded()))")
        box.isVisual = true
        box.role = Self.boxRole
        // Keep the same scope (and its results) while the box doesn't change.
        if let old = inspection?.scopes.first(where: { $0.role == Self.boxRole }), old.frame.isNearlyEqual(r, tolerance: 0.5) {
            return
        }
        var ins = Inspection(point: p, pid: 0, scopes: [box], defaultID: box.id)
        // The app whose window is under the box. Grab's own normal windows count (the practice
        // tiles), its overlay and floating panels don't.
        let me = getpid()
        if let w = WindowList.top(at: CGPoint(x: r.midX, y: r.midY), accept: { $0.layer < WindowList.overlayLayer && ($0.pid != me || $0.layer == 0) }),
           let app = NSRunningApplication(processIdentifier: w.pid) {
            ins.pid = w.pid
            ins.appName = app.localizedName
            ins.bundleID = app.bundleIdentifier
        }
        apply(ins)
    }

    // MARK: Paste queue

    /// ⌥V: pastes the shelf one item at a time, in order, into whatever has focus.
    private func pasteNext() {
        let shelf = Shelf.shared
        guard !pastePending else {
            Sound.shared.play(.bump)
            return
        }
        guard let (item, index) = shelf.takeNext() else {
            Sound.shared.play(.bump)
            showToast(Toast(success: false, title: "The shelf is empty",
                            detail: "\(Trigger.current.chord("⇧C")) collects things to paste one by one", mode: mode))
            return
        }
        Clipboard.write(item.payload)
        pastePending = true
        pasteOnRelease(until: Date().addingTimeInterval(10))
        Sound.shared.play(.tick)
        Haptics.perform(.alignment)
        let n = shelf.items.count
        let detail = index + 1 < n ? "Next: " + shelf.items[index + 1].title.oneLine.truncated(48) : "That was the last · \(Trigger.current.chord("V")) starts over"
        showToast(Toast(success: true, title: "Pasted \(index + 1) of \(n)", detail: detail, mode: item.mode))
    }

    /// ⌘V is sent once every modifier is up: a ⌘V sent while you still hold ⌥ would
    /// reach the app as ⌘⌥V (Paste and Match Style, or Move in Finder).
    private func pasteOnRelease(until deadline: Date) {
        let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        if held.isEmpty {
            pastePending = false
            Keystroke.paste()
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in self?.pasteOnRelease(until: deadline) }
        } else {
            // Held too long: leave it on the clipboard for a manual ⌘V.
            pastePending = false
        }
    }

    // MARK: Compare

    /// ⌥D: the clipboard against what's under the pointer.
    private func compare(_ s: Scope, mode m: GrabMode, at point: CGPoint) async {
        guard let clip = NSPasteboard.general.string(forType: .string)?.nonBlank else {
            Sound.shared.play(.bump)
            showToast(Toast(success: false, title: "Nothing to compare with", detail: "Copy one version, then \(Trigger.current.chord("D")) over the other", mode: m))
            return
        }
        guard let text = await actionText(s, mode: m, at: point)?.nonBlank else {
            fail(GrabError.noText, mode: m)
            return
        }
        let old = clip.cleanedForClipboard, new = text.cleanedForClipboard
        if old == new {
            Sound.shared.play(.copy)
            showToast(Toast(success: true, title: "Identical", detail: "Same as your clipboard, character for character", mode: .text))
            return
        }
        endHold()
        Sound.shared.play(.scope)
        Panels.shared.compare(old: old, new: new, near: point)
    }

    // MARK: Fill

    /// ⌥F: values on the clipboard (from a form copied with ⇥ Fields, or "Label: value"
    /// lines) typed into the matching fields of the form under the pointer.
    private func fillForm(_ s: Scope, at point: CGPoint) async {
        let values = FormFill.parse(NSPasteboard.general.string(forType: .string) ?? "")
        guard !values.isEmpty else {
            Sound.shared.play(.bump)
            showToast(Toast(success: false, title: "No form data on the clipboard",
                            detail: "Copy a form with ⇥ Fields, or lines like “Name: Ada”", mode: .text))
            return
        }
        let inspector = self.inspector
        let start = s.element ?? inspection?.leaf
        guard let start else {
            fail(GrabError.failed("No form here"), mode: .text)
            return
        }
        let result: (filled: Int, fields: Int)? = await withCheckedContinuation { c in
            onAXQueue(own: Self.isOwn(start)) {
                guard let root = inspector.formRoot(around: start) else { return c.resume(returning: nil) }
                c.resume(returning: inspector.fillForm(root, with: values))
            }
        }
        guard let result, result.fields > 0 else {
            fail(GrabError.failed("No form here"), mode: .text)
            return
        }
        guard result.filled > 0 else {
            Sound.shared.play(.bump)
            showToast(Toast(success: false, title: "No fields matched", detail: "Labels on the clipboard: " + values.prefix(3).map(\.0).joined(separator: ", "), mode: .text))
            return
        }
        Sound.shared.play(.copy)
        Haptics.perform(.levelChange)
        model.flash += 1
        showToast(Toast(success: true, title: "Filled \(result.filled) of \(result.fields) fields", detail: "Check them before you submit", mode: .text))
    }

    /// Ends the hold after handing off to another window.
    private func endHold() {
        onEndHold?()
        disarm(cancelled: true)
    }

    /// Text to speak, translate or ask about: the text of the scope, recognized if need be.
    private func actionText(_ s: Scope, mode m: GrabMode, at point: CGPoint) async -> String? {
        switch m {
        case .link: if let u = linkURL(for: s), s.bestText == nil { return u.absoluteString }
        case .qr: return s.barcode
        default: break
        }
        if case .success(.text(let t)) = await resolve(s, mode: .text, at: point) { return t }
        return nil
    }

    private func open(_ s: Scope, mode m: GrabMode, at point: CGPoint) async {
        var target: URL?
        switch m {
        case .link:
            target = linkURL(for: s)
        case .qr:
            if let c = s.barcode, let u = URL(string: c), u.scheme != nil, Inspector.isLinkScheme(u) { target = u }
            else if let c = s.barcode { target = WebSearch.url(for: c) }
        case .file:
            target = s.fileURL ?? s.pathURL
            if let t = target, !FileManager.default.fileExists(atPath: t.path) { fail(GrabError.noFile, mode: m); return }
        case .image:
            if case .success(.image(let img, _)) = await resolve(s, mode: .image, at: point) {
                target = ImageTools.temporaryPNG(img, name: "Grab \(s.label)")
            }
        case .color:
            break
        case .text:
            if let v = s.smart {
                switch v.kind {
                case .date:
                    if case .event(let ics, let name)? = SmartTypes.render(v, as: "ics") { target = TempFiles.write(ics, name: name, ext: "ics") }
                case .address:
                    if case .link(let u)? = SmartTypes.render(v, as: "apple") { target = u }
                case .phone:
                    if case .link(let u)? = SmartTypes.render(v, as: "tel") { target = u }
                case .email:
                    target = v.link
                case .tracking, .flight, .isbn, .doi:
                    target = v.link
                case .error:
                    if case .link(let u)? = SmartTypes.render(v, as: "search") { target = u }
                default:
                    break
                }
            }
            if target == nil, let t = s.bestText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                if isPureLink(t), let u = URL(string: t.contains("://") ? t : "https://" + t) { target = u }
                else if let u = linkURL(for: s), s.linkIsSelf { target = u }
                else { target = WebSearch.url(for: Formats.oneLine(String(t.prefix(300)))) }
            }
        }
        guard let target else {
            Sound.shared.play(.bump)
            Haptics.perform(.generic)
            return
        }
        Sound.shared.play(.scope)
        endHold()
        NSWorkspace.shared.open(target)
    }

    private func quickLook(_ s: Scope, mode m: GrabMode, at point: CGPoint) async {
        var urls: [URL] = []
        switch m {
        case .file:
            if let f = s.fileURL ?? s.pathURL, FileManager.default.fileExists(atPath: f.path) { urls = [f] }
        case .image:
            if case .success(.image(let img, _)) = await resolve(s, mode: .image, at: point),
               let u = ImageTools.temporaryPNG(img, name: "Grab \(s.label)") { urls = [u] }
        case .text, .qr:
            if case .success(let p) = await resolve(s, mode: m, at: point) {
                var text = ""
                switch p {
                case .text(let t), .code(let t): text = t
                default: break
                }
                var ext = "txt"
                if let file = s.code?.fileURL, s.code?.kind == .file { urls = [file] }
                else if let lang = s.code?.language, !lang.isEmpty { ext = lang == "console" ? "txt" : lang }
                if urls.isEmpty, !text.isEmpty, let u = TempFiles.write(text, name: "Grab \(s.label)", ext: ext) { urls = [u] }
            }
        case .link, .color:
            break
        }
        guard !urls.isEmpty else {
            Sound.shared.play(.bump)
            showToast(Toast(success: false, title: "Nothing to preview", detail: "Space previews files, images and text", mode: m))
            return
        }
        endHold()
        Panels.shared.quickLook(urls)
    }

    // MARK: Debug

    #if DEBUG
    /// Runs the pixel pipeline for the current code region and reports each stage.
    func debugCode(to path: String) {
        guard let region = inspection?.codeRegion else {
            try? "no code region".write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        Task.detached {
            var out = "region \(region.rect) title=\(region.title)\n"
            guard let cap = try? await ScreenGrabber.shared.capture(region.rect, maxPixels: 9_000_000) else {
                try? (out + "capture failed").write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
            let fast = VisionEngine.recognize(cap, accurate: false, correction: false)
            out += "ocr lines: \(fast.count)\n"
            let bands = CodeGridBuilder.bands(in: fast, region: region.rect)
            out += "bands: \(bands)\n"
            for band in bands + [region.rect] {
                let rows = CodeGridBuilder.rows(from: fast.filter { band.contains($0.rect.center) })
                out += "band \(band): rows=\(rows.count)\n"
                let names = CodeGridBuilder.fileNames(above: band, in: fast)
                out += "  names=\(names)\n"
                for n in names.prefix(2) {
                    for url in Session.spotlightForDebug(n) {
                        var ok = "unreadable"
                        if let t = Session.readForDebug(url) {
                            let a = CodeAnalysis(text: t, language: CodeLanguage.forFile(url) ?? .guess(t))
                            ok = CodeGridBuilder.align(rows: rows, to: a, region: band) != nil ? "ALIGNED" : "no-align"
                        }
                        out += "  \(url.path) \(ok)\n"
                    }
                }
                for l in fast where l.rect.maxY <= band.minY + 4 && l.rect.maxY > band.minY - 90 { out += "  header: \(l.text) \(l.rect)\n" }
                for r in rows.prefix(14) { out += String(format: "   y=%.0f x=%.0f-%.0f #%@ %@\n", r.y, r.minX, r.maxX, r.lineNumber.map(String.init) ?? "-", r.text) }
                if let (text, grid) = CodeGridBuilder.reconstruct(rows: rows, region: band) {
                    out += "  reconstruct ok lh=\(grid.lineHeight) cw=\(grid.charWidth) left=\(grid.left)\n" + text.prefix(400) + "\n"
                } else {
                    out += "  reconstruct failed\n"
                }
            }
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    nonisolated static func spotlightForDebug(_ n: String) -> [URL] { spotlight(name: n) }
    nonisolated static func readForDebug(_ u: URL) -> String? { readSource(u) }

    /// Inspect a fixed point instead of the mouse (debug hooks), so tests never move the pointer.
    var debugPoint: CGPoint?

    var debugTrace: [String] = []

    func debugAction(_ name: String) {
        if let a = GrabAction(rawValue: name) { perform(a) }
    }

    func debugDescription() -> [String: Any] {
        var out: [String: Any] = [
            "armed": armed,
            "mode": mode.title,
            "point": [lastPoint.x, lastPoint.y],
        ]
        if let ins = inspection {
            out["app"] = ins.appName ?? ""
            out["bundle"] = ins.bundleID ?? ""
            out["selected"] = currentIndex ?? -1
            out["default"] = ins.defaultIndex
            out["scopes"] = ins.scopes.map { s -> [String: Any] in
                [
                    "kind": "\(s.kind)",
                    "label": s.label,
                    "role": s.role ?? "",
                    "depth": s.depth,
                    "frame": [s.frame.minX, s.frame.minY, s.frame.width, s.frame.height].map { Double($0) },
                    "text": (s.text ?? "").truncated(200),
                    "ocr": (s.ocrText ?? "").truncated(200),
                    "pending": s.textPending,
                    "link": s.linkURL?.absoluteString ?? "",
                    "file": s.fileURL?.path ?? "",
                    "image": s.imageURL?.absoluteString ?? "",
                    "barcode": s.barcode ?? "",
                    "visual": s.isVisual,
                    "code": s.code.map { "\($0.kind.rawValue) \($0.language) \($0.lines.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "")" } ?? "",
                    "color": s.colorLiteral?.hex ?? "",
                    "path": s.pathURL?.path ?? "",
                    "smart": s.smart.map { "\($0.kind.rawValue):\($0.raw.truncated(40))" } ?? "",
                    "flags": [s.hasFields ? "fields" : nil, s.inWeb ? "web" : nil, s.videoPage != nil ? "video" : nil].compactMap { $0 }.joined(separator: ","),
                ]
            }
            if let s = current {
                out["options"] = options(for: s).map { "\($0.title)\($0.enabled ? "" : "(off)")" }
                out["formats"] = model.formats.map { $0.id == model.format ? "[\($0.title)]" : $0.title }
            }
            out["codeRegion"] = ins.codeRegion.map { "\($0.title) \($0.rect)" } ?? ""
            out["source"] = [ins.sourceTitle ?? "", ins.sourceURL?.absoluteString ?? ""]
            out["chain"] = ins.debugChain
            out["trace"] = Array(debugTrace.suffix(6))
            debugTrace.removeAll()
            out["preview"] = "\(model.preview)".truncated(300)
            out["toast"] = model.toast.map { "\($0.title) — \($0.detail)" } ?? ""
            out["note"] = Inspector.fillNote
        }
        return out
    }
    #endif
}

enum Thumbnail {
    static func make(_ image: CGImage, maxSide: CGFloat) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let k = min(1, maxSide / max(w, h))
        let tw = max(1, Int(w * k)), th = max(1, Int(h * k))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }
}

enum ImageFetcher {
    /// Fetches an image's original bytes (web images, local files), so "copy image"
    /// gives you the real thing rather than a screenshot of it.
    static func fetch(_ url: URL) async -> CGImage? {
        var data: Data?
        switch url.scheme?.lowercased() {
        case "file":
            data = try? Data(contentsOf: url)
        case "http", "https", "data":
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 2.5
            cfg.timeoutIntervalForResource = 4
            let session = URLSession(configuration: cfg)
            if let (d, response) = try? await session.data(from: url) {
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { break }
                data = d
            }
        default:
            break
        }
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              image.width >= 4, image.height >= 4 else { return nil }
        return image
    }
}
