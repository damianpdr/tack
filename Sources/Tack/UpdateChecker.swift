import AppKit

/// Compares the running version against the newest GitHub release.
@MainActor
enum UpdateChecker {
    /// The only place the GitHub repository is named. Change it here if the repository moves.
    nonisolated static let repository = "damianpdr/tack"

    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "updateCheck.lastAttempt"

    struct Release {
        let version: String
        let page: URL
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Launch check: runs at most once a day and says nothing unless there is something to install.
    static func checkInBackground() {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < interval {
            return
        }
        defaults.set(Date(), forKey: lastCheckKey)
        Task {
            // A missing repository or no network is not worth interrupting a launch for.
            guard let release = try? await latestRelease(), isNewer(release.version, than: currentVersion) else { return }
            showUpdate(release)
        }
    }

    /// Menu check: always reports back, including "up to date" and failures.
    static func checkNow() {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        Task {
            do {
                let release = try await latestRelease()
                if isNewer(release.version, than: currentVersion) {
                    showUpdate(release)
                } else {
                    show(title: "You're up to date", text: "Tack \(currentVersion) is the latest version.")
                }
            } catch {
                show(title: "Could not check for updates", text: error.localizedDescription, style: .warning)
            }
        }
    }

    /// True when `candidate` sorts after `current` by numeric components, so 1.10.0 beats 1.9.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = components(candidate), old = components(current)
        for index in 0..<max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    // MARK: GitHub

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private struct HTTPFailure: LocalizedError {
        let status: Int
        var errorDescription: String? {
            status == 404
                ? "github.com/\(repository) has no releases yet."
                : "GitHub answered with HTTP \(status)."
        }
    }

    private static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPFailure(status: status) }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let tag = payload.tagName
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: payload.htmlURL)
    }

    // MARK: Alerts

    private static func showUpdate(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Tack \(release.version) is available"
        alert.informativeText = "You have \(currentVersion)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }

    private static func show(title: String, text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
