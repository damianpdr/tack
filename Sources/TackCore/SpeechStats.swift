import Foundation

/// How much typing a voice note replaced.
public enum SpeechStats {
    /// Average typing speed the savings are measured against.
    public static let typingWordsPerMinute: Double = 40

    /// Words spoken in a prompt; captures and their markers don't count.
    public static func spokenWords(in blocks: [PromptBlock]) -> Int {
        blocks.reduce(0) { count, block in
            guard case .text(let text) = block else { return count }
            return count + text.split(whereSeparator: \.isWhitespace).filter { word in
                word.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            }.count
        }
    }

    public static func typingTime(words: Int) -> TimeInterval {
        Double(words) / typingWordsPerMinute * 60
    }

    /// Typing time minus the time spent recording, never negative.
    public static func timeSaved(words: Int, duration: TimeInterval) -> TimeInterval {
        max(0, typingTime(words: words) - duration)
    }

    /// How many times faster than typing, or nil for a recording too short to say.
    public static func speedup(words: Int, duration: TimeInterval) -> Double? {
        guard words > 0, duration >= 1 else { return nil }
        return typingTime(words: words) / duration
    }
}
