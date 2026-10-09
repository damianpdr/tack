import AppKit
import CoreGraphics
import VoiceCore

/// Voice's own screenshots via `/usr/sbin/screencapture`.
@MainActor
final class ScreenshotService {
    private(set) var isCapturing = false
    private let clipsDirectory: URL

    init(clipsDirectory: URL) {
        self.clipsDirectory = clipsDirectory
    }

    /// Returns nil when the user cancels the selection or capture fails.
    func capture(region: Bool) async -> HistoryItem? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let url = ImageFiles.newPNGURL(in: clipsDirectory, prefix: "screenshot")
        var arguments = region ? ["-i", "-o", "-x"] : ["-x"]
        if !region, let display = displayIndexUnderMouse() {
            arguments += ["-D", String(display)]
        }
        arguments.append(url.path)
        await Self.run("/usr/sbin/screencapture", arguments)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = ImageFiles.pixelSize(at: url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return .image(path: url.path, size: size, screenshot: true, sourceApp: sourceApp)
    }

    /// 1-based index in `CGGetActiveDisplayList` order, which is what `screencapture -D` expects.
    private func displayIndexUnderMouse() -> Int? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        let mouse = NSEvent.mouseLocation
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        guard let index = displays.prefix(Int(count)).firstIndex(where: { CGDisplayBounds($0).contains(point) }) else { return nil }
        return index + 1
    }

    private static func run(_ executable: String, _ arguments: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                NSLog("Voice: screencapture failed to launch: \(error.localizedDescription)")
                continuation.resume()
            }
        }
    }
}

/// Picks up macOS screenshots saved to disk (⌘⇧3/4/5) while recording.
@MainActor
final class ScreenshotFolderWatcher {
    /// Item (image already copied into clips) and the screenshot file's creation date.
    var onItem: ((HistoryItem, Date) -> Void)?

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
    private static let screenshotAttribute = "com.apple.metadata:kMDItemIsScreenCaptureShot"

    private var source: DispatchSourceFileSystemObject?
    private var directory: URL?
    private var clipsDirectory: URL?
    private var since = Date.distantFuture
    private var seen: Set<String> = []

    func start(since: Date, clipsDirectory: URL) {
        stop()
        let directory = Self.screenshotDirectory()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("Voice: cannot watch screenshot folder \(directory.path)")
            return
        }
        self.directory = directory
        self.clipsDirectory = clipsDirectory
        self.since = since.addingTimeInterval(-1)
        seen = []
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func flush() {
        scan()
    }

    func stop() {
        source?.cancel()
        source = nil
        directory = nil
    }

    private func scan() {
        guard let directory, let clipsDirectory else { return }
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        let fresh = urls.compactMap { url -> (URL, Date)? in
            guard !seen.contains(url.path),
                  Self.imageExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let created = values.creationDate, created >= since,
                  getxattr(url.path, Self.screenshotAttribute, nil, 0, 0, 0) >= 0
            else { return nil }
            return (url, created)
        }
        for (url, created) in fresh.sorted(by: { $0.1 < $1.1 }) {
            seen.insert(url.path)
            guard let item = importScreenshot(url, into: clipsDirectory) else { continue }
            onItem?(item, created)
        }
    }

    private func importScreenshot(_ url: URL, into clipsDirectory: URL) -> HistoryItem? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let png = url.pathExtension.lowercased() == "png" ? data : ImageFiles.pngData(from: data)
        guard let png, let size = ImageFiles.pixelSize(of: png) else { return nil }
        let destination = ImageFiles.newPNGURL(in: clipsDirectory, prefix: "screenshot")
        do {
            try png.write(to: destination, options: .atomic)
        } catch {
            NSLog("Voice: could not import screenshot \(url.path): \(error.localizedDescription)")
            return nil
        }
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        return .image(path: destination.path, size: size, screenshot: true, sourceApp: sourceApp)
    }

    private static func screenshotDirectory() -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !location.isEmpty {
            let expanded = (location as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
