import AppKit
import CoreGraphics

/// Everything the keyboard layer can ask the session to do.
enum TapAction {
    case arm
    case disarm
    case cancel
    case copy
    case cycleMode(Int)
    case changeScope(Int)
    case cycleFormat(Int)
    /// ⌥⇧C: add to the clipboard instead of replacing it.
    case append
    /// Content moved under the cursor; cached layouts are stale.
    case scrolled
    /// An action key while armed: ⏎ open, space Quick Look, P pin, S speak, T translate, E ask, Z undo,
    /// R box, V paste next, D compare, F fill.
    case action(GrabAction)
}

enum GrabAction: String, CaseIterable {
    case open, look, pin, speak, translate, ask, undo
    /// R: grab a rectangle from here to the pointer.
    case box
    /// V: paste the next shelf item.
    case pasteNext
    /// D: compare with the clipboard.
    case compare
    /// F: fill the form under the pointer from the clipboard.
    case fill
}

/// A system-wide keyboard tap that turns "hold ⌥" into a Grab session.
///
/// The tap lives on its own high-priority thread so the rest of the app (SwiftUI
/// rendering, accessibility queries, Vision) can never make typing feel laggy.
/// All state below is confined to that thread.
///
/// Rules, in order of precedence:
/// * ⌥ on its own starts a hold. After `armDelay` the overlay arms.
/// * Any other modifier, mouse button, or unrelated key during the hold means the
///   user is doing something else (⌥-click, ⌥⇧ shortcuts, typing ç…): the hold is
///   suppressed and every event passes through untouched.
/// * While armed: C copies, ← → change the capture type, ↑ ↓ change the scope,
///   Esc cancels. Those keys (and their key-ups) are swallowed.
/// * If the user was typing a moment ago, arming also waits for the mouse to move,
///   so ⌥← / ⌥→ word-jumping in text editors keeps working.
final class KeyTap {
    struct Config {
        var armDelay: Double = 0.18
        var quickCopy = true
        var enabled = true
        /// Physical keys that type "c" in the current layout (see `KeyLayout`).
        var copyKeyCodes: Set<Int64> = [8]
        /// Physical keys for actions while armed (letters follow the layout too).
        var actionKeyCodes: [Int64: GrabAction] = [36: .open, 76: .open, 49: .look]
        var trigger: Trigger = .option
    }

    /// Marks keystrokes Grab sends itself (⌘V for the paste queue) so the tap lets them through.
    static let syntheticTag: Int64 = 0x6772_6162

    /// Delivered on the main queue.
    var onAction: ((TapAction) -> Void)?

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    /// Modifier keys only: the one thing Grab listens to all the time.
    private var flagsTap: CFMachPort?
    /// Key presses and mouse events: switched on only while ⌥ is held, so typing
    /// and moving the mouse cost Grab nothing the rest of the time.
    private var keyTap: CFMachPort?
    private var mouseTap: CFMachPort?

    private let configLock = NSLock()
    private var _config = Config()
    var config: Config {
        get { configLock.lock(); defer { configLock.unlock() }; return _config }
        set { configLock.lock(); _config = newValue; configLock.unlock() }
    }

    // MARK: Tap-thread state

    private var optionHeld = false
    private var suppressed = false
    private var armed = false
    private var holdStart: CFAbsoluteTime = 0
    private var needsMotion = false
    private var motion: CGFloat = 0
    private var lastMouse: CGPoint?
    private var swallowedKeyUps = Set<Int64>()
    private var armTimer: CFRunLoopTimer?
    private var lastScrollPost: CFAbsoluteTime = 0

    var isRunning: Bool { flagsTap != nil }

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        if keyTap != nil { return true }
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let t = Thread { [unowned self] in
            ok = self.installTaps()
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            if ok { CFRunLoopRun() }
        }
        t.name = "Grab.KeyTap"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        if ok { thread = t } else { runLoop = nil }
        return ok
    }

    func stop() {
        guard let rl = runLoop else { return }
        perform { [self] in
            for tap in [flagsTap, keyTap, mouseTap].compactMap({ $0 }) {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            flagsTap = nil
            keyTap = nil
            mouseTap = nil
            CFRunLoopStop(rl)
        }
        thread = nil
        runLoop = nil
    }

    /// Called from the main thread when it notices ⌥ is no longer down (e.g. an
    /// event was lost while the tap was briefly disabled).
    func resetHold() {
        perform { [self] in
            if optionHeld { endHold() }
        }
    }

    /// Ends the current session as if the user pressed Esc.
    func suppressCurrentHold() {
        perform { [self] in
            if optionHeld { suppress(notify: .disarm) }
        }
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    private func installTaps() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // An active tap for modifiers, so a fast ⌥C can't overtake it: the key tap
        // below is switched on before the C reaches anyone.
        guard let ft = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.flagsChanged.rawValue,
            callback: { _, type, event, refcon in
                let me = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handleFlagsEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }

        guard let kt = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue),
            callback: { _, type, event, refcon in
                let me = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handleKey(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            CFMachPortInvalidate(ft)
            return false
        }

        // Mouse events only need observing, so a listen-only tap keeps the
        // pointer completely unaffected by anything we do.
        let mouseMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let mt = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mouseMask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                me.handleMouse(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )

        let rl = CFRunLoopGetCurrent()
        for tap in [ft, kt, mt].compactMap({ $0 }) {
            CFRunLoopAddSource(rl, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        }
        CGEvent.tapEnable(tap: ft, enable: true)
        CGEvent.tapEnable(tap: kt, enable: false)
        if let mt { CGEvent.tapEnable(tap: mt, enable: false) }
        flagsTap = ft
        keyTap = kt
        mouseTap = mt
        return true
    }

    /// Key and mouse taps run only while they're needed.
    private func updateTaps() {
        let keys = optionHeld || !swallowedKeyUps.isEmpty
        let mouse = optionHeld && !suppressed
        if let keyTap, CGEvent.tapIsEnabled(tap: keyTap) != keys { CGEvent.tapEnable(tap: keyTap, enable: keys) }
        if let mouseTap, CGEvent.tapIsEnabled(tap: mouseTap) != mouse { CGEvent.tapEnable(tap: mouseTap, enable: mouse) }
    }

    // MARK: Event handling (tap thread)

    private static let modifierKeys: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
    /// Modifiers that mean "someone else's shortcut" when they join the trigger.
    private static let chordModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
    // Device-dependent bits for telling left ⌥ from right ⌥ (NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK).
    private static let leftOptionBit: UInt64 = 0x20
    private static let rightOptionBit: UInt64 = 0x40

    /// Whether the trigger is down, and which modifiers are held beyond it.
    /// For "right ⌥ only", a held left ⌥ counts as an extra ⌥.
    static func split(_ flags: CGEventFlags, _ trigger: Trigger) -> (held: Bool, extra: CGEventFlags) {
        let mods = flags.intersection(modifierKeys)
        switch trigger {
        case .option:
            return (mods.contains(.maskAlternate), mods.subtracting(.maskAlternate))
        case .rightOption:
            var extra = mods.subtracting(.maskAlternate)
            if flags.rawValue & leftOptionBit != 0 { extra.insert(.maskAlternate) }
            return (flags.rawValue & rightOptionBit != 0, extra)
        case .controlOption:
            let need: CGEventFlags = [.maskControl, .maskAlternate]
            return (mods.isSuperset(of: need), mods.subtracting(need))
        case .hyper:
            return (mods.isSuperset(of: modifierKeys), [])
        }
    }

    /// Whether the trigger's modifiers are down right now, from any thread. A backstop
    /// for lost key-ups, so it doesn't rely on left/right bits being reported here.
    static func triggerIsDown(_ trigger: Trigger) -> Bool {
        let mods = CGEventSource.flagsState(.combinedSessionState).intersection(modifierKeys)
        switch trigger {
        case .option, .rightOption: return mods.contains(.maskAlternate)
        case .controlOption: return mods.isSuperset(of: [.maskControl, .maskAlternate])
        case .hyper: return mods.isSuperset(of: modifierKeys)
        }
    }

    private func handleFlagsEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let flagsTap { CGEvent.tapEnable(tap: flagsTap, enable: true) }
        case .flagsChanged:
            handleFlags(event.flags)
            updateTaps()
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            updateTaps()
            return Unmanaged.passUnretained(event)

        case .keyDown:
            return handleKeyDown(event)

        case .keyUp:
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return Unmanaged.passUnretained(event) }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if swallowedKeyUps.remove(code) != nil {
                if !optionHeld { updateTaps() }
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlags(_ flags: CGEventFlags) {
        let (held, extra) = Self.split(flags, config.trigger)

        if !held {
            if optionHeld { endHold() }
            return
        }
        if !optionHeld {
            beginHold(chord: !extra.isEmpty)
        } else if !extra.isEmpty && !suppressed {
            // Shift is allowed once the overlay is up (⌥⇧C appends, ⌥⇧Tab cycles back);
            // anything else, or shift before arming, is someone else's shortcut.
            let onlyShift = extra.intersection(Self.chordModifiers).isEmpty
            if !(onlyShift && armed) { suppress(notify: .disarm) }
        }
    }

    private func beginHold(chord: Bool) {
        let cfg = config
        optionHeld = true
        armed = false
        holdStart = CFAbsoluteTimeGetCurrent()
        motion = 0
        lastMouse = nil
        suppressed = chord || !cfg.enabled
        guard !suppressed else { return }
        // Typing a moment ago (⌥← word jumps): wait for the mouse to move before arming.
        // The system knows when the last key went down; no need to watch typing.
        needsMotion = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 0.45
        scheduleArm(after: cfg.armDelay)
    }

    private func endHold() {
        optionHeld = false
        cancelArmTimer()
        if !swallowedKeyUps.isEmpty {
            // Their key-ups will come in a moment; after that the key tap goes quiet.
            let t = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1, 0, 0, 0) { [weak self] _ in
                guard let self, !self.optionHeld else { return }
                self.swallowedKeyUps.removeAll()
                self.updateTaps()
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .commonModes)
        }
        if armed {
            armed = false
            post(.disarm)
        }
        suppressed = false
    }

    private func suppress(notify: TapAction) {
        suppressed = true
        updateTaps()
        cancelArmTimer()
        if armed {
            armed = false
            post(notify)
        }
    }

    private func arm() {
        guard optionHeld, !suppressed, !armed else { return }
        cancelArmTimer()
        armed = true
        post(.arm)
    }

    private enum Key { case copy, left, right, up, down, escape, tab, action(GrabAction), other }

    private func classify(code: Int64) -> Key {
        switch code {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 53: return .escape
        case 48: return .tab
        default:
            let cfg = config
            if cfg.copyKeyCodes.contains(code) { return .copy }
            if let a = cfg.actionKeyCodes[code] { return .action(a) }
            return .other
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        guard optionHeld else { return pass }
        guard !suppressed else { return pass }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return pass }
        let extra = Self.split(event.flags, config.trigger).extra
        if !extra.intersection(Self.chordModifiers).isEmpty {
            suppress(notify: .disarm)
            return pass
        }
        let shift = extra.contains(.maskShift)
        if shift && !armed {
            suppress(notify: .disarm)
            return pass
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let key = classify(code: code)

        switch key {
        case .copy:
            if !armed {
                guard config.quickCopy else {
                    suppress(notify: .disarm)
                    return pass
                }
                arm()
            }
            swallowedKeyUps.insert(code)
            if !isRepeat { post(shift ? .append : .copy) }
            return nil

        case .tab:
            guard armed else {
                suppress(notify: .disarm)
                return pass
            }
            swallowedKeyUps.insert(code)
            post(.cycleFormat(shift ? -1 : 1))
            return nil

        case .left, .right, .up, .down:
            guard armed else {
                // ⌥← / ⌥→ before the overlay shows = word navigation. Let it be.
                suppress(notify: .disarm)
                return pass
            }
            swallowedKeyUps.insert(code)
            switch key {
            case .left: post(.cycleMode(-1))
            case .right: post(.cycleMode(1))
            case .up: post(.changeScope(1))
            default: post(.changeScope(-1))
            }
            return nil

        case .action(let a):
            guard armed else {
                // ⌥⏎, ⌥Space, ⌥T… before the overlay shows belong to the app.
                suppress(notify: .disarm)
                return pass
            }
            swallowedKeyUps.insert(code)
            if !isRepeat { post(.action(a)) }
            return nil

        case .escape:
            guard armed else {
                suppress(notify: .disarm)
                return pass
            }
            swallowedKeyUps.insert(code)
            suppress(notify: .cancel)
            return nil

        case .other:
            suppress(notify: .disarm)
            return pass
        }
    }

    private func handleMouse(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            updateTaps()
        case .scrollWheel:
            // Scrolling under an armed overlay moves the content; cached layouts go stale.
            let now = CFAbsoluteTimeGetCurrent()
            if armed, now - lastScrollPost > 0.08 {
                lastScrollPost = now
                post(.scrolled)
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // ⌥-click and ⌥-drag belong to the app under the cursor.
            if optionHeld && !suppressed { suppress(notify: .disarm) }
        case .mouseMoved, .leftMouseDragged:
            guard optionHeld, !suppressed, !armed, needsMotion else { return }
            let p = event.location
            if let last = lastMouse { motion += hypot(p.x - last.x, p.y - last.y) }
            lastMouse = p
            if motion > 6 && CFAbsoluteTimeGetCurrent() - holdStart >= config.armDelay {
                arm()
            }
        default:
            break
        }
    }

    // MARK: Timer

    private func scheduleArm(after delay: Double) {
        cancelArmTimer()
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0
        ) { [weak self] _ in
            guard let self else { return }
            self.armTimer = nil
            if self.optionHeld && !self.suppressed && !self.armed && !self.needsMotion {
                self.arm()
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        armTimer = timer
    }

    private func cancelArmTimer() {
        if let t = armTimer {
            CFRunLoopTimerInvalidate(t)
            armTimer = nil
        }
    }

    private func post(_ action: TapAction) {
        DispatchQueue.main.async { [weak self] in
            self?.onAction?(action)
        }
    }
}
