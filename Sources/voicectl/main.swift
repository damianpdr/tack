import Foundation
import VoiceCore

let usage = """
    usage:
      voicectl transcribe <audio-file> [--engine openrouter|parakeet|whisper] [--model M] [--whisper-model PATH]
                          [--language xx] [--image SECONDS:PATH]... [--clip SECONDS:TEXT]...
      voicectl models
    """

struct UsageError: LocalizedError {
    let message: String
    var errorDescription: String? { "\(message)\n\(usage)" }
}

func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
}

func timedValue(_ raw: String, flag: String) throws -> (TimeInterval, String) {
    guard let colon = raw.firstIndex(of: ":"), let seconds = TimeInterval(raw[..<colon]) else {
        throw UsageError(message: "\(flag) expects SECONDS:VALUE, got \(raw)")
    }
    return (seconds, String(raw[raw.index(after: colon)...]))
}

func transcribe(_ arguments: [String]) async throws {
    var settings = SettingsStore(url: VoicePaths.standard().settingsFile).load()
    var audioPath: String?
    var events: [CaptureEvent] = []
    var remaining = arguments[...]

    func value(for flag: String) throws -> String {
        guard let value = remaining.popFirst() else { throw UsageError(message: "\(flag) needs a value") }
        return value
    }

    while let argument = remaining.popFirst() {
        switch argument {
        case "--engine":
            switch try value(for: argument) {
            case "openrouter": settings.engine = .openRouter
            case "whisper": settings.engine = .whisperCpp
            case "parakeet": settings.engine = .parakeet
            case let other: throw UsageError(message: "unknown engine \(other)")
            }
        case "--model":
            settings.openRouterModel = try value(for: argument)
        case "--whisper-model":
            settings.whisperModelPath = absolutePath(try value(for: argument))
        case "--language":
            settings.language = try value(for: argument)
        case "--image":
            let (offset, path) = try timedValue(try value(for: argument), flag: argument)
            events.append(CaptureEvent(offset: offset, content: .image(path: absolutePath(path))))
        case "--clip":
            let (offset, text) = try timedValue(try value(for: argument), flag: argument)
            events.append(CaptureEvent(offset: offset, content: .text(text)))
        case let other where other.hasPrefix("-"):
            throw UsageError(message: "unknown option \(other)")
        default:
            guard audioPath == nil else { throw UsageError(message: "unexpected argument \(argument)") }
            audioPath = absolutePath(argument)
        }
    }
    guard let audioPath else { throw UsageError(message: "missing audio file") }

    let paths = VoicePaths.standard()
    let engine = try Transcriber.makeEngine(settings: settings, paths: paths)
    let audio = try WAVFile.read(URL(fileURLWithPath: audioPath))
    let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("voicectl-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workDir) }
    let blocks = try await Transcriber.transcribe(
        audio: audio,
        events: events,
        engine: engine,
        language: settings.language.isEmpty ? nil : settings.language,
        workDir: workDir
    )
    print(PromptComposer.compose(blocks).markdown)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "transcribe":
        try await transcribe(Array(arguments.dropFirst()))
    case "models":
        for model in try await OpenRouterCatalog.transcriptionModels() { print(model) }
    case "-h", "--help", "help":
        print(usage)
    default:
        throw UsageError(message: arguments.first.map { "unknown command \($0)" } ?? "missing command")
    }
} catch {
    FileHandle.standardError.write(Data("voicectl: \(error.localizedDescription)\n".utf8))
    exit(1)
}
