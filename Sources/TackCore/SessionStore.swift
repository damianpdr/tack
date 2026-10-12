import Foundation
import ImageIO

public struct SessionStore: Sendable {
    struct Record: Codable {
        var createdAt: Date
        var engine: String
        var duration: TimeInterval
        var blocks: [PromptBlock]
        var events: [CaptureEvent]
    }

    public let paths: TackPaths

    public init(paths: TackPaths) {
        self.paths = paths
    }

    public func makeSessionDirectory(date: Date) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.sessions, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = formatter.string(from: date)
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)-\(suffix)"
            let dir = paths.sessions.appendingPathComponent(name, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                return dir
            } catch CocoaError.fileWriteFileExists {
                suffix += 1
            }
        }
    }

    public func finalize(
        dir: URL,
        blocks: [PromptBlock],
        events: [CaptureEvent],
        engine: String,
        duration: TimeInterval,
        maxFigureDimension: Int
    ) throws -> (blocks: [PromptBlock], prompt: ComposedPrompt) {
        let fm = FileManager.default
        let dirPath = dir.standardizedFileURL.path
        var renamed: [String: String] = [:]
        var figureNumber = 0
        // Files directly in the session folder are figures from an earlier finalize (re-transcribe); captures in
        // its `captures/` subfolder and anything outside it still become figure-N.
        for case .image(let path, _) in blocks where renamed[path] == nil {
            figureNumber += 1
            guard URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path != dirPath,
                  fm.fileExists(atPath: path)
            else {
                renamed[path] = path
                continue
            }
            let ext = URL(fileURLWithPath: path).pathExtension
            let destination = dir.appendingPathComponent("figure-\(figureNumber).\(ext.isEmpty ? "png" : ext)")
            try? fm.removeItem(at: destination)
            try Self.copyFigure(from: URL(fileURLWithPath: path), to: destination, maxDimension: maxFigureDimension)
            renamed[path] = destination.path
        }

        let finalBlocks = blocks.map { block -> PromptBlock in
            if case .image(let path, let pointer) = block { return .image(path: renamed[path] ?? path, pointer: pointer) }
            return block
        }
        let finalEvents = events.map { event -> CaptureEvent in
            var event = event
            if case .image(let path) = event.content { event.content = .image(path: renamed[path] ?? path) }
            return event
        }
        let prompt = PromptComposer.compose(finalBlocks)

        let recordURL = dir.appendingPathComponent("session.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let createdAt = (try? decoder.decode(Record.self, from: Data(contentsOf: recordURL)))?.createdAt ?? Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let record = Record(createdAt: createdAt, engine: engine, duration: duration, blocks: finalBlocks, events: finalEvents)

        try Data(prompt.markdown.utf8).write(to: dir.appendingPathComponent("prompt.md"), options: .atomic)
        try Data(prompt.body.utf8).write(to: dir.appendingPathComponent("transcript.txt"), options: .atomic)
        try encoder.encode(record).write(to: recordURL, options: .atomic)
        try pointLatest(to: dir)
        return (finalBlocks, prompt)
    }

    /// Copies the image, shrinking it so its longest edge is at most `maxDimension` pixels (0 = never shrink).
    static func copyFigure(from source: URL, to destination: URL, maxDimension: Int) throws {
        guard maxDimension > 0,
              let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(image),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxDimension
        else {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil)
        else {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        CGImageDestinationAddImage(output, scaled, nil)
        guard CGImageDestinationFinalize(output) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    public func loadEvents(dir: URL) throws -> [CaptureEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Record.self, from: Data(contentsOf: dir.appendingPathComponent("session.json"))).events
    }

    private func pointLatest(to dir: URL) throws {
        let sessionsPrefix = paths.sessions.standardizedFileURL.path + "/"
        let dirPath = dir.standardizedFileURL.path
        let target = dirPath.hasPrefix(sessionsPrefix)
            ? "sessions/" + dirPath.dropFirst(sessionsPrefix.count)
            : dirPath
        let temp = paths.root.appendingPathComponent(".latest-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: temp.path, withDestinationPath: target)
        if rename(temp.path, paths.latestLink.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
