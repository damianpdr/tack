import Foundation
import VoiceCore

extension HistoryItem {
    static func text(_ text: String, sourceApp: String?) -> HistoryItem {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return HistoryItem(kind: .text, title: truncated(firstLine), text: text, blocks: [.text(text)], sourceApp: sourceApp)
    }

    static func image(path: String, size: ImageFiles.PixelSize, screenshot: Bool, sourceApp: String?) -> HistoryItem {
        let noun = screenshot ? "screenshot" : "image"
        return HistoryItem(
            kind: .image,
            title: "\(sourceApp ?? "Voice") \(noun) (\(size.label))",
            text: "",
            blocks: [.image(path: path)],
            sourceApp: sourceApp
        )
    }

    static func files(_ paths: [String], sourceApp: String?) -> HistoryItem {
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        return HistoryItem(
            kind: .file,
            title: truncated(names),
            text: paths.joined(separator: "\n"),
            blocks: paths.map { .file(path: $0) },
            sourceApp: sourceApp
        )
    }

    private static func truncated(_ text: String, limit: Int = 80) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
