import Foundation

public struct TackPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func standard() -> TackPaths {
        if let home = ProcessInfo.processInfo.environment["TACK_HOME"], !home.isEmpty {
            let expanded = (home as NSString).expandingTildeInPath
            return TackPaths(root: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return TackPaths(root: defaultRoot)
    }

    private static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tack", isDirectory: true)
    }

    /// Keychain service for this folder's secrets. Any `TACK_HOME` other than ~/.tack gets its own, so scratch and
    /// development builds never ask for the installed app's keychain item.
    public var keychainService: String {
        root == Self.defaultRoot.standardizedFileURL ? SettingsStore.keychainService : "\(SettingsStore.keychainService) \(root.path)"
    }

    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var database: URL { root.appendingPathComponent("history.sqlite") }
    public var clips: URL { root.appendingPathComponent("clips", isDirectory: true) }
    public var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var latestLink: URL { root.appendingPathComponent("latest") }

    /// FluidAudio expects the directory to end in the model repo's folder name.
    public var parakeetModels: URL { models.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true) }

    public func ensureDirectories() throws {
        for dir in [root, clips, sessions, models] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
