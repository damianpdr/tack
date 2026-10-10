import Foundation
import Testing
@testable import TackCore

private func words(_ items: [(String, TimeInterval)]) -> [TimedWord] {
    items.map { TimedWord(text: " " + $0.0, start: $0.1, end: $0.1 + 0.3) }
}

struct LiveTranscriptTests {
    @Test func overlappingPassesKeepWordIdentityAndOnlyNewWordsGetNewIDs() {
        var live = LiveTranscript()
        live.update(recognized: words([("make", 0.2), ("the", 0.6), ("header", 0.9)]), windowStart: 0)
        let first = live.words.map(\.id)

        // The next pass covers the same audio plus more: the same words a little shifted, punctuation added, a new one.
        live.update(recognized: words([("make", 0.25), ("the", 0.62), ("Header,", 0.88), ("smaller", 1.4)]), windowStart: 0)
        #expect(live.words.map(\.text) == ["make", "the", "Header,", "smaller"])
        #expect(Array(live.words.map(\.id).prefix(3)) == first)
        #expect(!first.contains(live.words[3].id))
    }

    @Test func correctedWordIsReplacedAndWordAtWindowEdgeIsNotDuplicated() {
        var live = LiveTranscript()
        live.update(recognized: words([("one", 0.1), ("two", 1.0), ("tree", 2.0)]), windowStart: 0)
        let ids = live.words.map(\.id)
        // Window starts at 0.7: "two" (1.0) is right at the edge and kept from the first pass; "tree" becomes "three".
        live.update(recognized: words([("two", 0.35), ("three", 1.3)]), windowStart: 0.7)
        #expect(live.words.map(\.text) == ["one", "two", "three"])
        #expect(live.words[1].id == ids[1])
        #expect(live.words[2].id != ids[2])
    }

    @Test func markersSitBetweenWordsByTimeAndTailTruncates() {
        var live = LiveTranscript()
        let capture = UUID()
        live.addMarker(capture: capture, label: "figure 1", at: 1.5)
        live.update(recognized: words([("look", 0.5), ("here", 1.0), ("please", 2.0)]), windowStart: 0)
        #expect(live.tokens.map(\.text) == ["look", "here", "figure 1", "please"])
        #expect(live.tokens[2].kind == .marker(capture: capture, label: "figure 1"))

        let tail = live.tail(maxCharacters: 18)
        #expect(tail.tokens.map(\.text) == ["figure 1", "please"])
        #expect(tail.truncated)
        #expect(live.tail(maxCharacters: 100).truncated == false)
        #expect(live.tail(maxCharacters: 2).tokens.map(\.text) == ["please"])
    }
}

struct SpeechStatsTests {
    @Test func countsSpokenWordsOnlyAndComparesWithTyping() {
        let blocks: [PromptBlock] = [.text("Make the header — smaller,"), .image(path: "/a.png"), .text("then ship it"), .clip("not spoken words")]
        #expect(SpeechStats.spokenWords(in: blocks) == 7)
        #expect(SpeechStats.typingTime(words: 80) == 120)
        #expect(SpeechStats.timeSaved(words: 80, duration: 30) == 90)
        #expect(SpeechStats.timeSaved(words: 10, duration: 60) == 0)
        #expect(SpeechStats.speedup(words: 80, duration: 30) == 4)
        #expect(SpeechStats.speedup(words: 0, duration: 30) == nil)
    }
}
