import Foundation

/// The live preview's rolling transcript. Each preview pass re-recognizes an overlapping window of recent audio;
/// merging the passes here keeps a word's identity across them, so the pill only animates words that are new or
/// corrected. Capture markers sit between the words by recording time.
public struct LiveTranscript: Equatable, Sendable {
    public struct Token: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case word(String)
            /// A capture inline in the speech, labelled like its prompt reference ("figure 1", "clip 2").
            case marker(capture: UUID, label: String)
        }

        public let id: Int
        public var kind: Kind
        /// Seconds from the start of the recording.
        public var time: TimeInterval
    }

    /// Words this close to the start of a window may be cut mid-word, so the previous pass keeps them.
    static let edgeMargin: TimeInterval = 0.6
    /// The same word recognized in two passes starts within this much of itself.
    static let sameWordTolerance: TimeInterval = 0.35
    /// Older words are dropped; the pill only ever shows the tail.
    static let keptWords = 80

    public private(set) var words: [Token] = []
    public private(set) var markers: [Token] = []
    private var nextID = 0

    public init() {}

    public var isEmpty: Bool { words.isEmpty }

    /// Replaces everything recognized after the start of `window` with the new pass. `recognized` carries times
    /// relative to the window start, as the engine returns them.
    public mutating func update(recognized: [TimedWord], windowStart: TimeInterval) {
        let cut = windowStart > 0 ? windowStart + Self.edgeMargin : 0
        let kept = words.filter { $0.time < cut }
        var replaced = words.filter { $0.time >= cut }
        var merged = kept
        for word in recognized {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let time = windowStart + word.start
            guard !text.isEmpty, time >= cut else { continue }
            let key = Self.normalized(text)
            // A word straddling the cut: the previous pass already has it.
            if merged.count == kept.count, let last = kept.last, Self.normalized(last.text) == key,
               abs(last.time - time) < Self.sameWordTolerance {
                continue
            }
            if let index = replaced.firstIndex(where: { Self.normalized($0.text) == key && abs($0.time - time) < Self.sameWordTolerance }) {
                let match = replaced.remove(at: index)
                merged.append(Token(id: match.id, kind: .word(text), time: time))
            } else {
                merged.append(Token(id: makeID(), kind: .word(text), time: time))
            }
        }
        words = Array(merged.suffix(Self.keptWords))
        if merged.count > Self.keptWords, let first = words.first { markers.removeAll { $0.time < first.time } }
    }

    public mutating func addMarker(capture: UUID, label: String, at time: TimeInterval) {
        markers.append(Token(id: makeID(), kind: .marker(capture: capture, label: label), time: time))
        markers.sort { $0.time < $1.time }
    }

    /// Words and markers in spoken order. A marker follows every word that started before it.
    public var tokens: [Token] {
        var result: [Token] = []
        result.reserveCapacity(words.count + markers.count)
        var markerIndex = 0
        for word in words {
            while markerIndex < markers.count, markers[markerIndex].time <= word.time {
                result.append(markers[markerIndex])
                markerIndex += 1
            }
            result.append(word)
        }
        result.append(contentsOf: markers[markerIndex...])
        return result
    }

    /// The newest tokens that fit in `maxCharacters`, and whether older ones were left out.
    public func tail(maxCharacters: Int) -> (tokens: [Token], truncated: Bool) {
        let all = tokens
        var length = 0
        var start = all.endIndex
        while start > all.startIndex {
            let cost = Self.length(of: all[start - 1]) + (length == 0 ? 0 : 1)
            if length + cost > maxCharacters, start < all.endIndex { break }
            length += cost
            start -= 1
        }
        return (Array(all[start...]), start > all.startIndex)
    }

    private mutating func makeID() -> Int {
        nextID += 1
        return nextID
    }

    private static func length(of token: Token) -> Int {
        switch token.kind {
        case .word(let text): text.count
        case .marker(_, let label): label.count + 2
        }
    }

    /// Case and punctuation change between passes ("smaller" becomes "smaller.") without being a new word.
    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

extension LiveTranscript.Token {
    var text: String {
        switch kind {
        case .word(let text): text
        case .marker(_, let label): label
        }
    }
}
