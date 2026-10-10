import Foundation

public struct SettingsStore: Sendable {
    public static let keychainService = "com.damianpdr.tack"
    static let apiKeyAccount = "openrouter-api-key"

    public let url: URL
    /// Keychain service that holds the OpenRouter key; nil keeps the key in the JSON file.
    public let keychainService: String?

    public init(url: URL, keychainService: String? = nil) {
        self.url = url
        self.keychainService = keychainService
    }

    /// A key still stored in the JSON file (from before the keychain) wins and moves to the keychain on the next save.
    public func load() -> Settings {
        var settings = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        if let keychainService, settings.openRouterAPIKey.isEmpty {
            settings.openRouterAPIKey = Keychain.read(service: keychainService, account: Self.apiKeyAccount) ?? ""
        }
        return settings
    }

    public func save(_ settings: Settings) throws {
        var settings = settings
        if let keychainService {
            try Keychain.write(settings.openRouterAPIKey, service: keychainService, account: Self.apiKeyAccount)
            settings.openRouterAPIKey = ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
