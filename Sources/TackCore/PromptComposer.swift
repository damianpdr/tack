import Foundation

public struct ComposedPrompt: Equatable, Sendable {
    /// Prose with inline `[figure N]` / `[clip N]` / `[file N]` markers.
    public var body: String
    /// Agent/terminal format: body, reference lines with absolute paths, clip contents.
    public var markdown: String
    /// Normal-app format: body and clip contents; images are pasted separately.
    public var richText: String
    /// Figure paths; `figures[0]` is `[figure 1]`.
    public var figures: [String]
    public var clips: [String]
    public var files: [String]

    public init(body: String, markdown: String, richText: String, figures: [String], clips: [String], files: [String]) {
        self.body = body
        self.markdown = markdown
        self.richText = richText
        self.figures = figures
        self.clips = clips
        self.files = files
    }
}

public enum PromptComposer {
    public static func compose(_ blocks: [PromptBlock]) -> ComposedPrompt {
        if blocks.count == 1, case .text(let text) = blocks[0] {
            return ComposedPrompt(body: text, markdown: text, richText: text, figures: [], clips: [], files: [])
        }

        var figures: [String] = []
        var clips: [String] = []
        var files: [String] = []
        var body = ""
        var previousIsMultiline = false

        for block in blocks {
            let element: String
            var isMultiline = false
            switch block {
            case .text(let raw):
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                element = text
                isMultiline = text.contains("\n")
            case .image(let path):
                if let index = figures.firstIndex(of: path) {
                    element = "[figure \(index + 1)]"
                } else {
                    figures.append(path)
                    element = "[figure \(figures.count)]"
                }
            case .clip(let text):
                clips.append(text)
                element = "[clip \(clips.count)]"
            case .file(let path):
                files.append(path)
                element = "[file \(files.count)]"
            }
            if !body.isEmpty {
                body += previousIsMultiline || isMultiline ? "\n\n" : " "
            }
            body += element
            previousIsMultiline = isMultiline
        }

        let referenceLines = figures.enumerated().map { "[figure \($0.offset + 1)]: \(formatPath($0.element))" }
            + files.enumerated().map { "[file \($0.offset + 1)]: \(formatPath($0.element))" }
        let clipParagraphs = clips.enumerated().map { "[clip \($0.offset + 1)]:\n\(fenced($0.element))" }

        let markdownSections = [body, referenceLines.joined(separator: "\n")] + clipParagraphs
        let richSections = [body] + clipParagraphs
        return ComposedPrompt(
            body: body,
            markdown: markdownSections.filter { !$0.isEmpty }.joined(separator: "\n\n"),
            richText: richSections.filter { !$0.isEmpty }.joined(separator: "\n\n"),
            figures: figures,
            clips: clips,
            files: files
        )
    }

    private static func formatPath(_ path: String) -> String {
        path.contains(where: \.isWhitespace) ? "<\(path)>" : path
    }

    private static func fenced(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let content = text.trimmingCharacters(in: .newlines)
        return "\(fence)\n\(content)\n\(fence)"
    }
}
