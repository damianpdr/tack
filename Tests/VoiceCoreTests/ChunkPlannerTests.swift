import Foundation
import Testing
@testable import VoiceCore

private func makeAudio(_ segments: [(seconds: Double, amplitude: Float)]) -> PCMAudio {
    var samples: [Float] = []
    for segment in segments {
        let count = Int((segment.seconds * PCMAudio.sampleRate).rounded())
        samples += (0..<count).map { $0 % 2 == 0 ? segment.amplitude : -segment.amplitude }
    }
    return PCMAudio(samples: samples)
}

private func sample(_ seconds: Double) -> Int { Int((seconds * PCMAudio.sampleRate).rounded()) }

private func event(_ offset: TimeInterval, _ text: String = "x") -> CaptureEvent {
    CaptureEvent(offset: offset, content: .text(text))
}

private extension ChunkPlanner.Item {
    var range: Range<Int>? { if case .audio(let range, _) = self { range } else { nil } }
    var isSilent: Bool? { if case .audio(_, let silent) = self { silent } else { nil } }
    var event: CaptureEvent? { if case .event(let event) = self { event } else { nil } }
}

struct ChunkPlannerTests {
    @Test func eventsWithinMergeWindowShareOneBoundary() {
        let audio = makeAudio([(6, 0.3)])
        let a = event(2.0, "a"), b = event(2.9, "b"), c = event(3.5, "c")
        let items = ChunkPlanner.plan(audio: audio, events: [c, b, a])
        #expect(items.count == 6)
        #expect(items.compactMap(\.event) == [a, b, c])
        #expect(items[1].event == a && items[2].event == b && items[4].event == c)
        let first = items[0].range!
        #expect(abs(first.upperBound - sample(2.0)) <= ChunkPlanner.frameLength)
        #expect(abs(items[3].range!.upperBound - sample(3.5)) <= ChunkPlanner.frameLength)
    }

    @Test func eventsNearEdgesGoOutsideAudio() {
        let audio = makeAudio([(6, 0.3)])
        let early = event(0.2), negative = event(-1), late = event(5.8), beyond = event(9)
        let items = ChunkPlanner.plan(audio: audio, events: [late, early, beyond, negative])
        #expect(items.count == 5)
        #expect(items[0].event == negative && items[1].event == early)
        #expect(items[2].range == 0..<audio.samples.count && items[2].isSilent == false)
        #expect(items[3].event == late && items[4].event == beyond)
    }

    @Test func zeroLengthAudioYieldsOnlyEvents() {
        let events = [event(1, "b"), event(0, "a")]
        #expect(ChunkPlanner.plan(audio: PCMAudio(samples: []), events: events) == [.event(events[1]), .event(events[0])])
    }

    @Test func boundarySnapsIntoNearbySilentGap() {
        let audio = makeAudio([(2, 0.3), (0.4, 0), (2.6, 0.3)])
        let items = ChunkPlanner.plan(audio: audio, events: [event(2.6)])
        #expect(items.count == 3)
        let cut = items[0].range!.upperBound
        #expect(cut > sample(2.0) && cut < sample(2.4))
        #expect(items[0].isSilent == false && items[2].isSilent == false)
        #expect(items[2].range!.lowerBound == cut)
    }

    @Test func longSpansSplitAtQuietestFrameInLastFifth() {
        var options = ChunkPlanner.Options()
        options.maxChunk = 2
        let audio = makeAudio([(1.7, 0.3), (0.1, 0), (3.2, 0.3)])
        let ranges = ChunkPlanner.plan(audio: audio, events: [], options: options).compactMap(\.range)
        #expect(ranges.count == 3)
        #expect(ranges[0].upperBound > sample(1.7) && ranges[0].upperBound < sample(1.8))
        #expect(ranges.allSatisfy { $0.count <= sample(2) })
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == audio.samples.count)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    @Test func spansWithTooLittleVoiceAreSilent() {
        let audio = makeAudio([(2, 0.3), (1, 0), (0.1, 0.3), (1.9, 0.001)])
        let items = ChunkPlanner.plan(audio: audio, events: [event(2.5)])
        #expect(items.count == 3)
        #expect(items[0].isSilent == false)
        #expect(items[2].isSilent == true)
    }

    @Test func snappedBoundariesStayStrictlyIncreasing() {
        let audio = makeAudio([(2.48, 0.3), (0.02, 0), (0.06, 0.3), (0.04, 0.05), (2.4, 0.3)])
        let items = ChunkPlanner.plan(audio: audio, events: [event(2.0, "a"), event(3.05, "b")])
        let ranges = items.compactMap(\.range)
        #expect(ranges.count == 3)
        #expect(ranges.allSatisfy { !$0.isEmpty })
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(items.compactMap(\.event).map(\.content) == [.text("a"), .text("b")])
    }
}
