import Foundation

public protocol TranscriptionEngine: Sendable {
    var displayName: String { get }
    /// Returns one transcript per chunk, in the same order.
    func transcribe(_ chunks: [URL], language: String?) async throws -> [String]
}

public struct TimedWord: Equatable, Sendable {
    /// Raw word text; a leading space marks a word start, its absence a continuation of the previous word.
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Engines that can transcribe a whole recording in one pass with word timings.
public protocol TimedTranscriptionEngine: TranscriptionEngine {
    func transcribeTimed(_ audio: URL, language: String?) async throws -> [TimedWord]
}

public enum TranscriptionError: LocalizedError, Equatable {
    case missingAPIKey
    case missingWhisperCLI
    case missingWhisperModel(String)
    case missingParakeetModel
    case http(status: Int, message: String)
    case process(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "OpenRouter API key is missing. Add it in Settings or set OPENROUTER_API_KEY."
        case .missingWhisperCLI:
            "whisper-cli not found. Install it with `brew install whisper-cpp` or set its path in Settings."
        case .missingWhisperModel(let path):
            "Whisper model not found at \(path). Download it in Settings."
        case .missingParakeetModel:
            "Parakeet model is not downloaded. Download it in Settings → Transcription."
        case .http(let status, let message):
            "OpenRouter error \(status): \(message)"
        case .process(let message):
            "whisper-cli failed: \(message)"
        case .invalidResponse(let message):
            "Unexpected transcription response: \(message)"
        }
    }
}

public struct OpenRouterEngine: TranscriptionEngine {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    static let maxConcurrentRequests = 4
    static let maxRateLimitRetries = 4

    public let apiKey: String
    public let model: String
    public let vocabulary: [String]
    public let session: URLSession

    public init(
        apiKey: String, model: String, vocabulary: [String] = [], session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.vocabulary = vocabulary
        self.session = session
    }

    /// OpenRouter forwards only the serving provider's entry, under that provider's own field names.
    /// Verified live: azure (MAI) `phraseList`, openai `prompt`; groq `prompt` per OpenRouter docs.
    /// Deepgram drops `keyterm`, so other providers get nothing rather than a request they may reject.
    static func providerOptions(vocabulary: [String]) -> [String: Any]? {
        guard !vocabulary.isEmpty else { return nil }
        let prompt = vocabulary.joined(separator: ", ")
        return [
            "azure": ["phraseList": ["phrases": vocabulary]],
            "openai": ["prompt": prompt],
            "groq": ["prompt": prompt],
        ]
    }

    public var displayName: String { "OpenRouter · \(model)" }

    public func transcribe(_ chunks: [URL], language: String?) async throws -> [String] {
        var results = [String](repeating: "", count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func enqueue() {
                let index = next
                next += 1
                group.addTask {
                    (index, try await transcribeOne(chunks[index], language: language))
                }
            }
            while next < min(chunks.count, Self.maxConcurrentRequests) { enqueue() }
            while let (index, text) = try await group.next() {
                results[index] = text
                if next < chunks.count { enqueue() }
            }
        }
        return results
    }

    private func transcribeOne(_ chunk: URL, language: String?) async throws -> String {
        let audio = try Data(contentsOf: chunk)
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audio.base64EncodedString(), "format": "wav"],
        ]
        if let language, !language.isEmpty { body["language"] = language }
        if let options = Self.providerOptions(vocabulary: vocabulary) {
            body["provider"] = ["options": options]
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Voice", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let status = (error?["code"] as? Int) ?? http?.statusCode ?? 0
            if status == 429, attempt < Self.maxRateLimitRetries {
                try await Task.sleep(
                    for: .seconds(
                        Self.rateLimitDelay(attempt: attempt, error: error, response: http)))
                attempt += 1
                continue
            }
            return try Self.parseTranscription(data: data, json: json, error: error, status: status)
        }
    }

    /// Providers behind OpenRouter (e.g. Microsoft MAI) throttle concurrent chunk uploads with a 1s Retry-After;
    /// jitter keeps the parallel chunks from colliding again on the retry.
    static func rateLimitDelay(attempt: Int, error: [String: Any]?, response: HTTPURLResponse?)
        -> Double
    {
        let metadata = error?["metadata"] as? [String: Any]
        let retryAfter =
            (metadata?["retry_after_seconds"] as? Double)
            ?? response?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            ?? 1
        return min(max(retryAfter, pow(2, Double(attempt))), 30) + Double.random(in: 0..<1)
    }

    private static func parseTranscription(
        data: Data, json: [String: Any]?, error: [String: Any]?, status: Int
    ) throws -> String {
        if let error {
            let message = error["message"] as? String ?? String(decoding: data, as: UTF8.self)
            throw TranscriptionError.http(status: status, message: message)
        }
        guard (200..<300).contains(status) else {
            throw TranscriptionError.http(status: status, message: Self.snippet(data))
        }
        guard let text = json?["text"] as? String else {
            throw TranscriptionError.invalidResponse(Self.snippet(data))
        }
        return text
    }

    static func snippet(_ data: Data) -> String {
        let text = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return text.isEmpty ? "empty response" : text
    }
}

public struct WhisperCppEngine: TimedTranscriptionEngine {
    public let cliPath: String
    public let modelPath: String
    public let vocabulary: [String]

    public init(cliPath: String, modelPath: String, vocabulary: [String] = []) {
        self.cliPath = cliPath
        self.modelPath = modelPath
        self.vocabulary = vocabulary
    }

    public var displayName: String {
        "whisper.cpp · \(URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent)"
    }

    public static func detectCLI(preferred: String) -> String? {
        let fm = FileManager.default
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) { return expanded }
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map(String.init)
        for dir in pathDirs + ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = (dir as NSString).appendingPathComponent("whisper-cli")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public func transcribe(_ chunks: [URL], language: String?) async throws -> [String] {
        guard !chunks.isEmpty else { return [] }
        let fm = FileManager.default
        let outputs = chunks.map { URL(fileURLWithPath: $0.path + ".txt") }
        for output in outputs { try? fm.removeItem(at: output) }

        var arguments = commonArguments(language: language) + ["-nt", "-otxt"]
        for chunk in chunks { arguments += ["-f", chunk.path] }
        try await run(arguments)

        return try outputs.map { output in
            guard let text = try? String(contentsOf: output, encoding: .utf8) else {
                throw TranscriptionError.invalidResponse("missing \(output.lastPathComponent)")
            }
            try? fm.removeItem(at: output)
            return text
        }
    }

    public func transcribeTimed(_ audio: URL, language: String?) async throws -> [TimedWord] {
        let base = audio.path + ".words"
        let output = URL(fileURLWithPath: base + ".json")
        try? FileManager.default.removeItem(at: output)
        defer { try? FileManager.default.removeItem(at: output) }

        var arguments =
            commonArguments(language: language) + ["-ml", "1", "-sow", "-ojf", "-of", base]
        if let preset = Self.dtwPreset(modelPath: modelPath) {
            arguments += ["-dtw", preset, "-nfa"]
        }
        try await run(arguments + ["-f", audio.path])

        guard let data = try? Data(contentsOf: output) else {
            throw TranscriptionError.invalidResponse("missing \(output.lastPathComponent)")
        }
        return try Self.parseWords(data)
    }

    /// Alignment-head preset for DTW token timestamps, which track the audio far better than whisper's segment timestamps.
    static func dtwPreset(modelPath: String) -> String? {
        let name = URL(fileURLWithPath: modelPath).lastPathComponent.lowercased()
        guard !name.contains("distil") else { return nil }
        let presets: [(String, String)] = [
            ("large-v3-turbo", "large.v3.turbo"), ("large-v3", "large.v3"),
            ("large-v2", "large.v2"), ("large-v1", "large.v1"),
            ("medium.en", "medium.en"), ("medium", "medium"), ("small.en", "small.en"),
            ("small", "small"),
            ("base.en", "base.en"), ("base", "base"), ("tiny.en", "tiny.en"), ("tiny", "tiny"),
        ]
        return presets.first { name.contains("ggml-\($0.0)") }?.1
    }

    private struct WhisperJSON: Decodable {
        struct Offsets: Decodable {
            let from: Int
            let to: Int
        }

        struct Token: Decodable {
            let text: String
            let offsets: Offsets
            let t_dtw: Int?
        }

        struct Segment: Decodable {
            let text: String
            let offsets: Offsets
            let tokens: [Token]?
        }

        let transcription: [Segment]
    }

    static func parseWords(_ data: Data) throws -> [TimedWord] {
        // Tokens can split a multi-byte character, which whisper.cpp writes out as invalid UTF-8.
        let sanitized = Data(String(decoding: data, as: UTF8.self).utf8)
        guard let json = try? JSONDecoder().decode(WhisperJSON.self, from: sanitized) else {
            throw TranscriptionError.invalidResponse(OpenRouterEngine.snippet(data))
        }
        var words: [TimedWord] = []
        for segment in json.transcription
        where !segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let times = (segment.tokens ?? [])
                .filter {
                    !$0.text.hasPrefix("[_")
                        && $0.text.unicodeScalars.contains(
                            where: CharacterSet.alphanumerics.contains)
                }
                .map { token in
                    let dtw = token.t_dtw ?? -1
                    return dtw >= 0
                        ? (Double(dtw) / 100, Double(dtw) / 100)
                        : (Double(token.offsets.from) / 1000, Double(token.offsets.to) / 1000)
                }
            if let first = times.first, let last = times.last {
                words.append(TimedWord(text: segment.text, start: first.0, end: last.1))
            } else if !words.isEmpty {
                words[words.count - 1].text += segment.text
            } else {
                let from = Double(segment.offsets.from) / 1000
                words.append(
                    TimedWord(
                        text: segment.text, start: from, end: Double(segment.offsets.to) / 1000))
            }
        }
        return words
    }

    private func commonArguments(language: String?) -> [String] {
        let threads = min(8, ProcessInfo.processInfo.activeProcessorCount)
        var arguments = [
            "-m", modelPath, "-l", (language?.isEmpty ?? true) ? "auto" : language!, "-np", "-t",
            String(threads),
        ]
        if !vocabulary.isEmpty { arguments += ["--prompt", vocabulary.joined(separator: ", ")] }
        return arguments
    }

    private func run(_ arguments: [String]) async throws {
        let fm = FileManager.default
        let log = fm.temporaryDirectory.appendingPathComponent(
            "voice-whisper-\(UUID().uuidString).log")
        guard fm.createFile(atPath: log.path, contents: nil),
            let logHandle = try? FileHandle(forWritingTo: log)
        else {
            throw TranscriptionError.process("cannot create log file at \(log.path)")
        }
        defer {
            try? logHandle.close()
            try? fm.removeItem(at: log)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = {
                    continuation.resume(returning: $0.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(
                        throwing: TranscriptionError.process(
                            "cannot launch \(cliPath): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()

        guard status == 0 else {
            let stderr = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let lines = stderr.split(separator: "\n")
            let errorLines = lines.filter {
                $0.localizedCaseInsensitiveContains("error")
                    || $0.localizedCaseInsensitiveContains("failed")
            }
            let detail = (errorLines.isEmpty ? lines.suffix(15) : errorLines.suffix(5)).joined(
                separator: "\n")
            throw TranscriptionError.process("exit code \(status)\n\(detail)")
        }
    }
}

public enum Transcriber {
    public static func makeEngine(
        settings: Settings,
        paths: VoicePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TranscriptionEngine {
        switch settings.engine {
        case .openRouter:
            var key = settings.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                key = (environment["OPENROUTER_API_KEY"] ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines)
            }
            guard !key.isEmpty else { throw TranscriptionError.missingAPIKey }
            let model = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return OpenRouterEngine(
                apiKey: key, model: model.isEmpty ? Settings().openRouterModel : model,
                vocabulary: settings.vocabulary)
        case .whisperCpp:
            guard let cli = WhisperCppEngine.detectCLI(preferred: settings.whisperCLIPath) else {
                throw TranscriptionError.missingWhisperCLI
            }
            let configured = settings.whisperModelPath.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let model =
                configured.isEmpty
                ? paths.defaultWhisperModel.path : (configured as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: model) else {
                throw TranscriptionError.missingWhisperModel(model)
            }
            return WhisperCppEngine(cliPath: cli, modelPath: model, vocabulary: settings.vocabulary)
        case .parakeet:
            guard ParakeetEngine.isDownloaded(at: paths.parakeetModels) else {
                throw TranscriptionError.missingParakeetModel
            }
            return ParakeetEngine(modelDirectory: paths.parakeetModels)
        }
    }

    public static func transcribe(
        audio: PCMAudio,
        events: [CaptureEvent],
        engine: TranscriptionEngine,
        language: String?,
        workDir: URL
    ) async throws -> [PromptBlock] {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        if let timed = engine as? TimedTranscriptionEngine {
            return try await transcribeTimed(
                audio: audio, events: events, engine: timed, language: language, workDir: workDir)
        }
        let plan = ChunkPlanner.plan(audio: audio, events: events)

        var chunkURLs: [URL] = []
        for item in plan {
            guard case .audio(let range, silent: false) = item else { continue }
            let url = workDir.appendingPathComponent(
                String(format: "chunk-%03d.wav", chunkURLs.count))
            try WAVFile.write(audio.samples[range], to: url)
            chunkURLs.append(url)
        }
        defer { for url in chunkURLs { try? FileManager.default.removeItem(at: url) } }

        let texts =
            chunkURLs.isEmpty ? [] : try await engine.transcribe(chunkURLs, language: language)
        guard texts.count == chunkURLs.count else {
            throw TranscriptionError.invalidResponse(
                "expected \(chunkURLs.count) transcripts, got \(texts.count)")
        }

        var blocks: [PromptBlock] = []
        var nextText = 0
        for item in plan {
            switch item {
            case .audio(_, silent: true):
                continue
            case .audio(_, silent: false):
                let text = clean(texts[nextText])
                nextText += 1
                guard !text.isEmpty else { continue }
                if case .text(let previous) = blocks.last {
                    blocks[blocks.count - 1] = .text(previous + " " + text)
                } else {
                    blocks.append(.text(text))
                }
            case .event(let event):
                blocks += Self.blocks(for: event)
            }
        }
        return blocks
    }

    /// One pass over the speech span so the engine keeps full context and detects the language from all of it.
    private static func transcribeTimed(
        audio: PCMAudio,
        events: [CaptureEvent],
        engine: TimedTranscriptionEngine,
        language: String?,
        workDir: URL
    ) async throws -> [PromptBlock] {
        guard let speech = ChunkPlanner.speechRange(audio: audio) else {
            return place(words: [], events: events)
        }
        let url = workDir.appendingPathComponent("speech.wav")
        try WAVFile.write(audio.samples[speech], to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let words = try await engine.transcribeTimed(url, language: language)
        let start = Double(speech.lowerBound) / PCMAudio.sampleRate
        let duration = Double(speech.count) / PCMAudio.sampleRate
        let shifted = events.map { event -> CaptureEvent in
            var event = event
            event.offset = min(max(event.offset - start, 0), duration)
            return event
        }
        return place(words: words, events: shifted)
    }

    /// Interleaves events with timed words. Each event goes into the widest inter-word gap within `snapWindow`
    /// of its offset (ties: closest), else before the first word whose midpoint is at or after it.
    /// Events never move before an earlier event; text between events is cleaned like chunk results.
    public static func place(
        words: [TimedWord], events: [CaptureEvent], snapWindow: TimeInterval = 0.6
    ) -> [PromptBlock] {
        let sorted = events.enumerated()
            .sorted {
                $0.element.offset == $1.element.offset
                    ? $0.offset < $1.offset : $0.element.offset < $1.element.offset
            }
            .map(\.element)
        var slots = [[CaptureEvent]](repeating: [], count: words.count + 1)
        var earliest = 0
        for event in sorted {
            earliest = max(earliest, slot(for: event.offset, words: words, snapWindow: snapWindow))
            slots[earliest].append(event)
        }

        var blocks: [PromptBlock] = []
        var pending = ""
        func flushText() {
            let text = clean(pending)
            pending = ""
            guard !text.isEmpty else { return }
            if case .text(let previous) = blocks.last {
                blocks[blocks.count - 1] = .text(previous + " " + text)
            } else {
                blocks.append(.text(text))
            }
        }
        for (index, slotEvents) in slots.enumerated() {
            if !slotEvents.isEmpty {
                flushText()
                for event in slotEvents { blocks += Self.blocks(for: event) }
            }
            if index < words.count { pending += words[index].text }
        }
        flushText()
        return blocks
    }

    /// Index of the word the event goes before; `words.count` means after all words.
    private static func slot(for offset: TimeInterval, words: [TimedWord], snapWindow: TimeInterval)
        -> Int
    {
        guard let first = words.first, let last = words.last, offset > first.start else { return 0 }
        guard offset < last.end else { return words.count }
        var best: (slot: Int, width: TimeInterval, distance: TimeInterval)?
        for slot in 1..<max(1, words.count) {
            let lower = words[slot - 1].end
            let upper = max(lower, words[slot].start)
            let distance = max(0, lower - offset, offset - upper)
            guard distance <= snapWindow else { continue }
            let width = upper - lower
            if best == nil || width > best!.width
                || (width == best!.width && distance < best!.distance)
            {
                best = (slot, width, distance)
            }
        }
        if let best { return best.slot }
        return words.firstIndex { ($0.start + $0.end) / 2 >= offset } ?? words.count
    }

    public static func blocks(for event: CaptureEvent) -> [PromptBlock] {
        switch event.content {
        case .image(let path): [.image(path: path)]
        case .text(let text): [.clip(text)]
        case .files(let paths): paths.map { .file(path: $0) }
        }
    }

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"\[\s*[A-Z][A-Z0-9_ ]*\s*\]"#)
    private static let parentheticalPattern = try! NSRegularExpression(
        pattern: #"\(\s*\p{L}+(?:\s+\p{L}+){0,3}\s*\)"#)
    private static let whitespacePattern = try! NSRegularExpression(pattern: #"\s+"#)
    private static let hallucinations: Set<String> = [
        "thank you",
        "thank you very much",
        "thanks for watching",
        "thank you for watching",
        "you",
        "dziękuję",
        "dziękuję bardzo",
        "dziękuję za uwagę",
        "dzięki za obejrzenie",
        "napisy stworzone przez społeczność amara.org",
        "subtitles by the amara.org community",
    ]

    static func clean(_ raw: String) -> String {
        var text = raw
        for pattern in [tagPattern, parentheticalPattern] {
            text = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = whitespacePattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".!?,…").union(.whitespaces))
        return hallucinations.contains(normalized) ? "" : text
    }
}
