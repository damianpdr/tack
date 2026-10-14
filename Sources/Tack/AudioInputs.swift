import CoreAudio
import Observation

/// Core Audio input devices: the list Settings offers and the lookups the recorder binds with.
enum AudioInputs {
    struct Device: Hashable, Identifiable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Every device with at least one input stream, in Core Audio's order.
    static func all() -> [Device] {
        var address = devicesAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
            return Device(id: id, uid: uid, name: string(kAudioObjectPropertyName, of: id) ?? uid)
        }
    }

    static func device(uid: String) -> AudioDeviceID? {
        all().first { $0.uid == uid }?.id
    }

    static func defaultInput() -> AudioDeviceID? {
        var address = defaultInputAddress
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// The input devices for Settings, kept current while it is open as devices come and go.
@MainActor @Observable
final class AudioInputList {
    private(set) var devices: [AudioInputs.Device] = []
    private(set) var defaultName: String?
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        refresh()
        guard listener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for address in [AudioInputs.devicesAddress, AudioInputs.defaultInputAddress] {
            var address = address
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = listener
    }

    func stop() {
        guard let listener else { return }
        for address in [AudioInputs.devicesAddress, AudioInputs.defaultInputAddress] {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = nil
    }

    private func refresh() {
        devices = AudioInputs.all()
        let defaultID = AudioInputs.defaultInput()
        defaultName = devices.first { $0.id == defaultID }?.name
    }
}
