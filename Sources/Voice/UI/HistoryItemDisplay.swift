import Foundation
import VoiceCore

extension HistoryItem {
    var hasTextContent: Bool {
        switch kind {
        case .text: true
        case .image, .file: false
        case .session: blocks.contains { block in
            switch block {
            case .text, .clip: true
            case .image, .file: false
            }
        }
        }
    }

    var composed: ComposedPrompt { PromptComposer.compose(blocks) }

    /// Distinct images in display order; for sessions the index + 1 is the `[figure N]` number.
    var displayImages: [String] {
        kind == .session ? composed.figures : imagePaths
    }

    var primaryText: String {
        switch kind {
        case .session:
            let body = composed.body
            return body.isEmpty ? title : body
        case .text:
            return text
        case .image:
            return ""
        case .file:
            return filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }

    @MainActor
    func metaParts(now: Date) -> [String] {
        var parts: [String] = []
        switch kind {
        case .image:
            parts.append(imageLabel)
        case .text:
            parts.append("Text")
            if let sourceApp { parts.append(sourceApp) }
            parts.append(HistoryFormat.count(HistoryFormat.wordCount(text), "word"))
        case .file:
            parts.append("File")
            if let sourceApp { parts.append(sourceApp) }
            parts.append(HistoryFormat.count(filePaths.count, "file"))
        case .session:
            if let audioDuration {
                parts.append("Voice")
                parts.append(HistoryFormat.duration(audioDuration))
            } else {
                parts.append(title.isEmpty ? "Stack" : title)
            }
            let prompt = composed
            if !prompt.figures.isEmpty { parts.append(HistoryFormat.count(prompt.figures.count, "figure")) }
            if !prompt.clips.isEmpty { parts.append(HistoryFormat.count(prompt.clips.count, "clip")) }
            if !prompt.files.isEmpty { parts.append(HistoryFormat.count(prompt.files.count, "file")) }
        }
        parts.append(HistoryFormat.relative(createdAt, now: now))
        return parts
    }

    @MainActor
    var imageLabel: String {
        let base = title.isEmpty ? (sourceApp.map { "\($0) image" } ?? "Image") : title
        guard !base.contains("×"), let path = imagePaths.first,
              let size = ThumbnailCache.shared.pixelSize(path: path)
        else { return base }
        return "\(base) (\(Int(size.width))×\(Int(size.height)))"
    }

    func matches(_ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return title.range(of: query, options: options) != nil
            || text.range(of: query, options: options) != nil
            || (sourceApp?.range(of: query, options: options) != nil)
    }
}

enum HistoryFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func absolute(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
