import Carbon.HIToolbox
import Foundation

/// Maps characters to physical key codes for the active keyboard layout, so ⌥C
/// means "the key that types c" on QWERTY, AZERTY, Dvorak, Colemak…
///
/// Text Input Sources may only be queried on the main thread, which is why the
/// event tap gets a precomputed set of key codes instead of asking per keystroke.
enum KeyLayout {
    static func keyCodes(typing target: String, fallback: Int64? = Int64(kVK_ANSI_C)) -> Set<Int64> {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return Set([fallback].compactMap { $0 })
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var result = Set<Int64>()
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars
                )
                if status == noErr, length > 0,
                   String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    result.insert(Int64(code))
                }
            }
        }
        return result.isEmpty ? Set([fallback].compactMap { $0 }) : result
    }
}
