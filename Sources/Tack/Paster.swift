import AppKit
import ApplicationServices
import Carbon.HIToolbox
import TackCore

@MainActor
final class Paster {
    enum Outcome {
        case pasted
        case copied
    }

    static let agentBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "org.alacritty",
        "org.vim.MacVim",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.tabby",
        "com.todesktop.230313mzl4w4u92",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "com.stablyai.orca",
        "com.t3tools.t3code",
    ]

    /// Whether `deliver` would paste right now rather than only copy.
    func willPaste(settings: Settings) -> Bool {
        guard let target = NSWorkspace.shared.frontmostApplication else { return false }
        return target.processIdentifier != ProcessInfo.processInfo.processIdentifier && settings.autoPaste && AXIsProcessTrusted()
    }

    /// Pastes into the frontmost app when possible and always leaves the agent format on the clipboard.
    func deliver(_ blocks: [PromptBlock], settings: Settings) async -> Outcome {
        let prompt = PromptComposer.compose(blocks)
        let loneImage = Self.loneImage(blocks)
        guard willPaste(settings: settings), let target = NSWorkspace.shared.frontmostApplication else {
            writeFinal(prompt, loneImage: loneImage)
            return .copied
        }

        let agent = target.bundleIdentifier.map(Self.agentBundleIDs.contains) ?? false
        if agent || settings.pasteMode == .textOnly {
            Clipboard.writeText(loneImage ?? prompt.markdown, transient: true)
            Self.postCommandV()
        } else if let loneImage {
            Clipboard.writeImage(path: loneImage, includeFileURL: false, transient: true)
            Self.postCommandV()
        } else {
            for (index, figure) in prompt.figures.enumerated() {
                if index > 0 { try? await Task.sleep(for: .milliseconds(250)) }
                Clipboard.writeImage(path: figure, includeFileURL: false, transient: true)
                Self.postCommandV()
            }
            if !prompt.richText.isEmpty {
                if !prompt.figures.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                Clipboard.writeText(prompt.richText, transient: true)
                Self.postCommandV()
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        writeFinal(prompt, loneImage: loneImage)
        return .pasted
    }

    func copy(_ blocks: [PromptBlock]) {
        writeFinal(PromptComposer.compose(blocks), loneImage: Self.loneImage(blocks))
    }

    private func writeFinal(_ prompt: ComposedPrompt, loneImage: String?) {
        if let loneImage {
            Clipboard.writeImage(path: loneImage, includeFileURL: true)
        } else {
            Clipboard.writeText(prompt.markdown)
        }
    }

    /// A lone image that something was pointed at in goes as text instead, so its pointer line comes along.
    private static func loneImage(_ blocks: [PromptBlock]) -> String? {
        guard blocks.count == 1, case .image(let path, nil) = blocks[0] else { return nil }
        return path
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = commandVKeyCode()
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// The key that types "v" with ⌘ held in the current layout: 9 on QWERTY, another key on Dvorak. Translating with
    /// ⌘ held also covers layouts like "Dvorak – QWERTY ⌘" that turn into QWERTY under ⌘. Layouts without a "v", like
    /// Russian, fall back to the ASCII-capable layout macOS uses for shortcuts.
    static func commandVKeyCode() -> CGKeyCode {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for source in sources.compactMap({ $0?.takeRetainedValue() }) {
            if let code = keyCode(typing: "v", in: source) { return code }
        }
        return CGKeyCode(kVK_ANSI_V)
    }

    private static func keyCode(typing character: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<UInt16(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, Character(String(utf16CodeUnits: chars, count: 1)).lowercased() == String(character) {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
