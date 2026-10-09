import Carbon.HIToolbox
import VoiceCore

@MainActor
final class HotkeyCenter {
    var onAction: ((HotkeyAction) -> Void)?
    var onEscape: (() -> Void)?

    /// Escape is only grabbed globally while recording, so it never steals Esc from other apps otherwise.
    var escapeEnabled = false { didSet { syncEscape() } }
    /// Interactive `screencapture` uses Esc to abort the selection; it must receive it.
    var escapePaused = false { didSet { syncEscape() } }
    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            if suspended { unregisterActions() }
            syncEscape()
        }
    }

    private static let signature: OSType = 0x564F4943
    private static let escapeID: UInt32 = 100

    private var combos: [HotkeyAction: KeyCombo] = [:]
    private var actionRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var escapeRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Returns the actions whose combos could not be registered.
    func register(_ hotkeys: [HotkeyAction: KeyCombo]) -> Set<HotkeyAction> {
        combos = hotkeys
        unregisterActions()
        guard !suspended else { return [] }
        var failures: Set<HotkeyAction> = []
        for action in HotkeyAction.allCases {
            guard let combo = hotkeys[action] else { continue }
            if let ref = Self.registerHotKey(combo, id: Self.id(for: action)) {
                actionRefs[action] = ref
            } else {
                failures.insert(action)
            }
        }
        return failures
    }

    fileprivate func handle(id: UInt32) {
        if id == Self.escapeID {
            onEscape?()
        } else if let action = HotkeyAction.allCases.first(where: { Self.id(for: $0) == id }) {
            onAction?(action)
        }
    }

    private func unregisterActions() {
        for ref in actionRefs.values { UnregisterEventHotKey(ref) }
        actionRefs = [:]
    }

    private func syncEscape() {
        let wanted = escapeEnabled && !escapePaused && !suspended
        if wanted, escapeRef == nil {
            escapeRef = Self.registerHotKey(KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: 0), id: Self.escapeID)
        } else if !wanted, let ref = escapeRef {
            UnregisterEventHotKey(ref)
            escapeRef = nil
        }
    }

    private static func id(for action: HotkeyAction) -> UInt32 {
        UInt32(HotkeyAction.allCases.firstIndex(of: action)!) + 1
    }

    private static func registerHotKey(_ combo: KeyCombo, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        return status == noErr ? ref : nil
    }
}

private func hotkeyHandler(_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated { center.handle(id: id) }
    return noErr
}
