import Foundation

public struct VoicePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func standard() -> VoicePaths {
        if let home = ProcessInfo.processInfo.environment["VOICE_HOME"], !home.isEmpty {
            let expanded = (home as NSString).expandingTildeInPath
            return VoicePaths(root: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return VoicePaths(root: home.appendingPathComponent(".voice", isDirectory: true))
    }

    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var database: URL { root.appendingPathComponent("history.sqlite") }
    public var clips: URL { root.appendingPathComponent("clips", isDirectory: true) }
    public var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var latestLink: URL { root.appendingPathComponent("latest") }
    public var defaultWhisperModel: URL { models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin") }

    public func ensureDirectories() throws {
        for dir in [root, clips, sessions, models] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
