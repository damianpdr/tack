import AppKit
import Carbon.HIToolbox
import SwiftUI
import TackCore

struct ShortcutRecorder: View {
    let model: AppModel
    @Binding var combo: KeyCombo
    @State private var capture = ShortcutCapture()

    var body: some View {
        Button {
            if capture.isActive {
                capture.stop(model: model)
            } else {
                capture.start(model: model) { combo = $0 }
            }
        } label: {
            Text(capture.isActive ? "Type shortcut…" : combo.displayString)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(capture.isActive ? Color.accentColor : Color.primary)
                .frame(minWidth: 110)
        }
        .help(capture.isActive ? "Press the new shortcut, or Esc to cancel" : "Click to change")
        .onDisappear { capture.stop(model: model) }
    }
}

@MainActor @Observable
private final class ShortcutCapture {
    private(set) var isActive = false
    @ObservationIgnored private var monitor: Any?

    func start(model: AppModel, onCapture: @escaping (KeyCombo) -> Void) {
        guard !isActive else { return }
        isActive = true
        model.setHotkeysSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
                self.stop(model: model)
                return nil
            }
            if let combo = KeyCombo(event: event) {
                onCapture(combo)
                self.stop(model: model)
            }
            return nil
        }
    }

    func stop(model: AppModel) {
        guard isActive else { return }
        isActive = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        model.setHotkeysSuspended(false)
    }
}
