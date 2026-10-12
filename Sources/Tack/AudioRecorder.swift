import AVFoundation
import CoreAudio
import TackCore

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .unsupportedFormat: "The microphone format is not supported."
        }
    }
}

/// Captures the default input as 16 kHz mono Float32 in memory. When the input changes mid-recording (AirPods
/// connecting, a USB mic unplugged), it moves to the new default input and keeps appending to the same samples.
/// Samples arrive on the audio render thread; everything else is main-thread.
final class AudioRecorder: @unchecked Sendable {
    /// Called on the main thread about 30 times per second while recording, level 0...1.
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread when the input changed and no input could be started again. The samples recorded
    /// so far are kept until `stop()`.
    var onInputLost: ((Error) -> Void)?
    private(set) var startDate: Date?

    private static let levelWindow = Int(PCMAudio.sampleRate / 30)
    /// Bluetooth inputs take a moment to settle after a switch, so a failed restart is tried again a few times.
    private static let restartAttempts = 4

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var restartScheduled = false
    private let lock = NSLock()
    private var samples: [Float] = []
    private var pendingLevels: [Float] = []
    private var levelSquares: Float = 0
    private var levelCount = 0
    private var meter = VoiceMeter()
    private var levelTimer: Timer?

    var currentOffset: TimeInterval {
        lock.withLock { Double(samples.count) / PCMAudio.sampleRate }
    }

    /// The last `seconds` of audio recorded so far, and the recording offset of its first sample.
    func recentSamples(seconds: TimeInterval) -> (samples: [Float], start: TimeInterval) {
        lock.withLock {
            let recent = Array(samples.suffix(Int(seconds * PCMAudio.sampleRate)))
            return (recent, Double(samples.count - recent.count) / PCMAudio.sampleRate)
        }
    }

    func start() throws {
        lock.withLock {
            samples = []
            samples.reserveCapacity(Int(PCMAudio.sampleRate) * 120)
            pendingLevels = []
            levelSquares = 0
            levelCount = 0
            meter = VoiceMeter()
        }
        try startEngine()
        startDate = Date()
        observeInputChanges()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.emitLevel() }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    func stop() -> PCMAudio {
        stopObservingInputChanges()
        levelTimer?.invalidate()
        levelTimer = nil
        stopEngine()
        startDate = nil
        return lock.withLock {
            let audio = PCMAudio(samples: samples)
            samples = []
            pendingLevels = []
            return audio
        }
    }

    /// A new engine binds to the current default input in its current format; an engine keeps the device it started
    /// on, and stops for good when that device goes away or changes format.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMAudio.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw AudioRecorderError.unsupportedFormat }
        converter.downmix = true

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter, outputFormat: outputFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    // MARK: Input changes

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func observeInputChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let engine, notification.object as AnyObject === engine else { return }
            scheduleRestart(attempt: 1)
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRestart(attempt: 1) }
        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        defaultInputListener = listener
    }

    private func stopObservingInputChanges() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let defaultInputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultInputListener)
        }
        defaultInputListener = nil
    }

    /// A switch fires several notifications in a row; they collapse into one restart once the burst is over.
    private func scheduleRestart(attempt: Int) {
        guard startDate != nil, !restartScheduled else { return }
        restartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(attempt == 1 ? 150 : 500)) { [weak self] in
            guard let self else { return }
            restartScheduled = false
            restartEngine(attempt: attempt)
        }
    }

    private func restartEngine(attempt: Int) {
        guard startDate != nil else { return }
        stopEngine()
        do {
            try startEngine()
        } catch {
            if attempt < Self.restartAttempts {
                scheduleRestart(attempt: attempt + 1)
            } else {
                onInputLost?(error)
            }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))

        lock.withLock {
            samples.append(contentsOf: chunk)
            for sample in chunk {
                levelSquares += sample * sample
                levelCount += 1
                if levelCount == Self.levelWindow {
                    let rms = (levelSquares / Float(levelCount)).squareRoot()
                    pendingLevels.append(meter.level(rms: rms, interval: Float(Self.levelWindow) / Float(PCMAudio.sampleRate)))
                    levelSquares = 0
                    levelCount = 0
                }
            }
            if pendingLevels.count > 6 { pendingLevels.removeFirst(pendingLevels.count - 6) }
        }
    }

    private func emitLevel() {
        let level: Float? = lock.withLock { pendingLevels.isEmpty ? nil : pendingLevels.removeFirst() }
        if let level { onLevel?(level) }
    }
}
