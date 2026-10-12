import AppKit
import ApplicationServices
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
            Clipboard.writeText(loneImage ?? prompt.markdown)
            Self.postCommandV()
        } else if let loneImage {
            Clipboard.writeImage(path: loneImage, includeFileURL: false)
            Self.postCommandV()
        } else {
            for (index, figure) in prompt.figures.enumerated() {
                if index > 0 { try? await Task.sleep(for: .milliseconds(250)) }
                Clipboard.writeImage(path: figure, includeFileURL: false)
                Self.postCommandV()
            }
            if !prompt.richText.isEmpty {
                if !prompt.figures.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                Clipboard.writeText(prompt.richText)
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
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
