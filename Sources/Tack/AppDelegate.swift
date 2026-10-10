import AppKit
import Observation
import TackCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model: AppModel
        do {
            model = try AppModel()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Tack could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.model = model
        model.applyActivationPolicy()
        NSApp.mainMenu = makeMainMenu()
        model.start()
        installStatusItem()
        observePhase()
        UpdateChecker.checkInBackground()
        #if TACK_DEMO
        if ProcessInfo.processInfo.environment["TACK_DEMO"] != nil { Task { await model.runDemo() } }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model?.showHistory() }
        return true
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false
        item.menu = statusMenu
        statusItem = item
        updateStatusIcon()
    }

    private func observePhase() {
        withObservationTracking {
            _ = model?.phase
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusIcon()
                self?.observePhase()
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let recording = model?.phase == .recording
        let image = NSImage(systemSymbolName: recording ? "waveform.circle.fill" : "waveform", accessibilityDescription: "Tack")
        image?.isTemplate = !recording
        if recording {
            button.image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        } else {
            button.image = image
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu, let model else { return }
        menu.removeAllItems()
        let recordTitle = switch model.phase {
        case .recording: "Stop Recording"
        case .processing: "Transcribing…"
        case .idle, .finished, .failed: "Start Recording"
        }
        let record = menuItem(recordTitle, hotkey: .toggleRecording, action: #selector(toggleRecording))
        record.isEnabled = model.phase != .processing
        menu.addItem(record)
        if model.phase == .recording {
            menu.addItem(menuItem("Cancel Recording", hotkey: nil, action: #selector(cancelRecording), shortcut: "esc"))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Screenshot Region", hotkey: .captureRegion, action: #selector(captureRegion)))
        menu.addItem(menuItem("Screenshot Screen", hotkey: .captureScreen, action: #selector(captureScreen)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Show History", hotkey: .showHistory, action: #selector(showHistory)))
        menu.addItem(menuItem("Settings…", hotkey: nil, action: #selector(showSettings)))
        menu.addItem(menuItem("Check for Updates…", hotkey: nil, action: #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Tack", hotkey: nil, action: #selector(quit)))
    }

    private func menuItem(_ title: String, hotkey: HotkeyAction?, action: Selector, shortcut: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        let combo = hotkey.flatMap { model?.settings.hotkeys[$0] }?.displayString ?? shortcut
        if let combo {
            let text = NSMutableAttributedString(string: title)
            text.append(NSAttributedString(string: "   \(combo)", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
        }
        return item
    }

    @objc private func toggleRecording() { model?.toggleRecording() }
    @objc private func cancelRecording() { model?.cancelRecording() }
    @objc private func captureRegion() { model?.captureRegion() }
    @objc private func captureScreen() { model?.captureScreen() }
    @objc private func showHistory() { model?.showHistory() }
    @objc private func showSettings() { model?.showSettings() }
    @objc private func checkForUpdates() { UpdateChecker.checkNow() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Main menu

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Tack", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Tack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        addSubmenu(appMenu, title: "Tack", to: main)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        addSubmenu(editMenu, title: "Edit", to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let history = NSMenuItem(title: "History", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(history)
        addSubmenu(windowMenu, title: "Window", to: main)
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func addSubmenu(_ submenu: NSMenu, title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}
