import AppKit
import Carbon.HIToolbox
import VoiceCore

extension KeyCombo {
    var displayString: String {
        var result = ""
        if modifiers & KeyCombo.control != 0 { result += "⌃" }
        if modifiers & KeyCombo.option != 0 { result += "⌥" }
        if modifiers & KeyCombo.shift != 0 { result += "⇧" }
        if modifiers & KeyCombo.command != 0 { result += "⌘" }
        return result + KeyCombo.keyName(for: keyCode)
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown, !KeyCombo.modifierKeyCodes.contains(Int(event.keyCode)) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= KeyCombo.control }
        if flags.contains(.option) { mask |= KeyCombo.option }
        if flags.contains(.shift) { mask |= KeyCombo.shift }
        if flags.contains(.command) { mask |= KeyCombo.command }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mask)
    }

    private static let modifierKeyCodes: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]

    private static let specialKeyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_Grave: "`",
            kVK_Space: "Space",
            kVK_Return: "↩",
            kVK_ANSI_KeypadEnter: "⌤",
            kVK_Tab: "⇥",
            kVK_Escape: "⎋",
            kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
            kVK_Home: "↖",
            kVK_End: "↘",
            kVK_PageUp: "⇞",
            kVK_PageDown: "⇟",
            kVK_Help: "Help",
            kVK_ANSI_KeypadClear: "⌧",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() {
            names[code] = "F\(index + 1)"
        }
        return names
    }()

    static func keyName(for keyCode: UInt32) -> String {
        if let name = specialKeyNames[Int(keyCode)] { return name }
        if let typed = layoutCharacter(for: keyCode) { return typed.uppercased() }
        return "Key \(keyCode)"
    }

    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let source = source?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            let typed = layoutData.withUnsafeBytes { raw -> String? in
                guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
            if let typed, !typed.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty {
                return typed
            }
        }
        return nil
    }
}
