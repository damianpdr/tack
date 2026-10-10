import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6b v3 on CoreML via FluidAudio. Runs one pass over the recording with token timings.
public struct ParakeetEngine: TimedTranscriptionEngine {
    public let modelDirectory: URL

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    public var displayName: String { "Parakeet · tdt-0.6b-v3" }

    public static func isDownloaded(at directory: URL) -> Bool {
        AsrModels.modelsExist(at: directory, version: .v3)
    }

    /// Downloads (if needed) and compiles the models. `progress` gets a rough 0…1 across the model files.
    public static func prepare(
        at directory: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        _ = try await ParakeetRuntime.shared.manager(directory: directory, progress: progress)
    }

    /// Timed words for raw 16 kHz samples, used for the live preview while recording. Times are from the first sample.
    public static func previewWords(samples: [Float], directory: URL, language: String?) async throws -> [TimedWord] {
        let manager = try await ParakeetRuntime.shared.manager(directory: directory)
        let hint = language.flatMap { Language(rawValue: $0.lowercased()) }
        let result = try await run(manager, samples: samples, language: hint)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No timings: spread the words evenly, which is enough to order them.
            let texts = result.text.split(whereSeparator: \.isWhitespace)
            let step = result.duration / Double(max(texts.count, 1))
            return texts.enumerated().map { index, text in
                TimedWord(text: " " + text, start: Double(index) * step, end: Double(index + 1) * step)
            }
        }
        return words(from: timings.map { ($0.token, $0.startTime, $0.endTime) })
    }

    public func transcribe(_ chunks: [URL], language: String?) async throws -> [String] {
        var texts: [String] = []
        for chunk in chunks {
            let words = try await transcribeTimed(chunk, language: language)
            texts.append(words.map(\.text).joined())
        }
        return texts
    }

    public func transcribeTimed(_ audio: URL, language: String?) async throws -> [TimedWord] {
        let manager = try await ParakeetRuntime.shared.manager(directory: modelDirectory)
        let samples = try AudioConverter().resampleAudioFile(path: audio.path)
        guard !samples.isEmpty else { return [] }
        let hint = language.flatMap { Language(rawValue: $0.lowercased()) }
        let result = try await Self.run(manager, samples: samples, language: hint)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TimedWord(text: " " + text, start: 0, end: result.duration)]
        }
        return Self.words(from: timings.map { ($0.token, $0.startTime, $0.endTime) })
    }

    /// The decoder state is `inout` across an actor hop, so it must live in a nonisolated local.
    private static func run(_ manager: AsrManager, samples: [Float], language: Language?) async throws -> ASRResult {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state, language: language)
    }

    /// Joins SentencePiece pieces into words; FluidAudio marks word starts with a leading space.
    static func words(from tokens: [(text: String, start: TimeInterval, end: TimeInterval)]) -> [TimedWord] {
        var words: [TimedWord] = []
        for token in tokens where !token.text.isEmpty {
            if token.text.hasPrefix(" ") || words.isEmpty {
                let text = token.text.hasPrefix(" ") ? token.text : " " + token.text
                words.append(TimedWord(text: text, start: token.start, end: token.end))
            } else {
                words[words.count - 1].text += token.text
                words[words.count - 1].end = token.end
            }
        }
        return words
    }
}

/// Keeps the loaded models in memory between recordings; loading compiles CoreML graphs and can take seconds.
actor ParakeetRuntime {
    static let shared = ParakeetRuntime()

    private var loaded: (directory: URL, manager: AsrManager)?
    private var loading: Task<AsrManager, Error>?

    func manager(
        directory: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> AsrManager {
        if let loaded, loaded.directory == directory { return loaded.manager }
        if let loading { return try await loading.value }
        let task = Task {
            let files = FileCounter()
            let models = try await AsrModels.downloadAndLoad(
                to: directory, version: .v3,
                progressHandler: { update in
                    if case .downloading = update.phase {
                        progress(files.fraction(update.fractionCompleted))
                    }
                })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        defer { loading = nil }
        let manager = try await task.value
        loaded = (directory, manager)
        progress(1)
        return manager
    }
}

/// FluidAudio reports progress per file, restarting at 0 for each; this turns that into one bar over the four v3 files.
private final class FileCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    private var last = 0.0
    private let total = 4.0

    func fraction(_ value: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if value < last { completed += 1 }
        last = value
        return min(1, (Double(completed) + value) / total)
    }
}
