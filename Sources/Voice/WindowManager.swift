import AppKit
import SwiftUI

@MainActor
final class WindowManager {
    private let model: AppModel
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func showHistory() {
        let window = historyWindow ?? makeHistoryWindow()
        historyWindow = window
        present(window)
    }

    func toggleHistory() {
        if let window = historyWindow, window.isVisible, window.isKeyWindow, NSApp.isActive {
            window.orderOut(nil)
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { NSApp.hide(nil) }
        } else {
            showHistory()
        }
    }

    func showSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeHistoryWindow() -> NSWindow {
        let controller = NSHostingController(rootView: HistoryView(model: model))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice"
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 960, height: 720))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VoiceHistory")
        if !window.setFrameUsingName("VoiceHistory") { window.center() }
        return window
    }

    private func makeSettingsWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView(model: model))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice Settings"
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 620, height: 640))
        window.contentMinSize = NSSize(width: 480, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
