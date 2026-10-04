import Carbon.HIToolbox
import CoreGraphics

/// The one keystroke Grab ever sends: ⌘V, when you ask for the next shelf item with ⌥V.
enum Keystroke {
    @MainActor static func paste() {
        // A private source, so the ⌥ you're holding isn't mixed into the event.
        let source = CGEventSource(stateID: .privateState)
        let v = CGKeyCode(KeyLayout.keyCodes(typing: "v", fallback: Int64(kVK_ANSI_V)).sorted().first ?? Int64(kVK_ANSI_V))
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down) else { continue }
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: KeyTap.syntheticTag)
            e.post(tap: .cghidEventTap)
        }
    }
}
