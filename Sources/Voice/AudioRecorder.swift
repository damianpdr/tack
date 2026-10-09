import AVFoundation
import VoiceCore

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

/// Captures the default input as 16 kHz mono Float32 in memory.
/// Samples arrive on the audio render thread; everything else is main-thread.
final class AudioRecorder: @unchecked Sendable {
    /// Called on the main thread about 30 times per second while recording, level 0...1.
    var onLevel: ((Float) -> Void)?
    private(set) var startDate: Date?

    private static let levelWindow = Int(PCMAudio.sampleRate / 30)

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var pendingLevels: [Float] = []
    private var levelSquares: Float = 0
    private var levelCount = 0
    private var levelTimer: Timer?

    var currentOffset: TimeInterval {
        lock.withLock { Double(samples.count) / PCMAudio.sampleRate }
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMAudio.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw AudioRecorderError.unsupportedFormat }
        converter.downmix = true

        lock.withLock {
            samples = []
            samples.reserveCapacity(Int(PCMAudio.sampleRate) * 120)
            pendingLevels = []
            levelSquares = 0
            levelCount = 0
        }
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
        startDate = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.emitLevel() }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    func stop() -> PCMAudio {
        levelTimer?.invalidate()
        levelTimer = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        startDate = nil
        return lock.withLock {
            let audio = PCMAudio(samples: samples)
            samples = []
            pendingLevels = []
            return audio
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
                    pendingLevels.append(min(1, (rms * 8).squareRoot()))
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
