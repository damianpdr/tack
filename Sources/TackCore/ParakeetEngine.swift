import FluidAudio
import Foundation

/// A Parakeet build on disk. Tack downloads Ultra, moondream's post-training of NVIDIA Parakeet TDT 0.6b v3: same
/// languages and speed, fewer errors. Installs from before Ultra keep v3 until Ultra is downloaded.
public struct ParakeetModel: Sendable, Equatable {
    public let name: String
    public let directory: URL
    let version: AsrModelVersion

    public static func ultra(_ paths: TackPaths) -> ParakeetModel {
        ParakeetModel(name: "ultra", directory: paths.parakeetModels, version: .ultra)
    }

    public static func v3(_ paths: TackPaths) -> ParakeetModel {
        ParakeetModel(name: "tdt-0.6b-v3", directory: paths.parakeetV3Models, version: .v3)
    }

    /// The model to transcribe with: Ultra once it is downloaded, else v3 if an older Tack downloaded it.
    public static func installed(_ paths: TackPaths) -> ParakeetModel? {
        [ultra(paths), v3(paths)].first(where: \.isDownloaded)
    }

    public var isDownloaded: Bool {
        AsrModels.modelsExist(at: directory, version: version)
    }
}

/// Parakeet on CoreML via FluidAudio. Runs one pass over the recording with token timings.
public struct ParakeetEngine: TimedTranscriptionEngine {
    public let model: ParakeetModel

    public init(model: ParakeetModel) {
        self.model = model
    }

    public var displayName: String { "Parakeet · \(model.name)" }

    /// Downloads (if needed) and compiles the models. `progress` gets a rough 0…1 across the model files.
    public static func prepare(
        _ model: ParakeetModel, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        _ = try await ParakeetRuntime.shared.manager(model, progress: progress)
    }

    /// Timed words for raw 16 kHz samples, used for the live preview while recording. Times are from the first sample.
    public static func previewWords(samples: [Float], model: ParakeetModel, language: String?) async throws -> [TimedWord] {
        let manager = try await ParakeetRuntime.shared.manager(model)
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
        let manager = try await ParakeetRuntime.shared.manager(model)
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

    /// Joins SentencePiece pieces into words; FluidAudio marks word starts with a leading space. Drops `<unk>`, which
    /// Ultra emitted once in our 200 minutes of test recordings.
    static func words(from tokens: [(text: String, start: TimeInterval, end: TimeInterval)]) -> [TimedWord] {
        var words: [TimedWord] = []
        for token in tokens where !token.text.isEmpty && token.text.trimmingCharacters(in: .whitespaces) != "<unk>" {
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

    private var loaded: (model: ParakeetModel, manager: AsrManager)?
    /// Keyed by model, so a recording made with v3 while Ultra downloads does not wait for the download.
    private var loading: (model: ParakeetModel, task: Task<AsrManager, Error>)?

    func manager(
        _ model: ParakeetModel, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> AsrManager {
        if let loaded, loaded.model == model { return loaded.manager }
        if let loading, loading.model == model { return try await loading.task.value }
        let task = Task {
            let files = FileCounter()
            let models = try await AsrModels.downloadAndLoad(
                to: model.directory, version: model.version,
                progressHandler: { update in
                    if case .downloading = update.phase {
                        progress(files.fraction(update.fractionCompleted))
                    }
                })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = (model, task)
        defer { if loading?.model == model { loading = nil } }
        let manager = try await task.value
        loaded = (model, manager)
        progress(1)
        return manager
    }
}

/// FluidAudio reports progress per file, restarting at 0 for each; this turns that into one bar over the four model files.
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
