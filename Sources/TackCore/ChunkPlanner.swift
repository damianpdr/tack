import Foundation

public enum ChunkPlanner {
    public struct Options: Sendable {
        public var mergeWindow: TimeInterval = 1.0
        public var snapWindow: TimeInterval = 0.6
        public var edgeMargin: TimeInterval = 0.3
        public var maxChunk: TimeInterval = 180
        /// A frame is voiced when it is this many decibels above the recording's room noise…
        public var voicedAboveNoise: Float = 12
        /// …within these bounds: a noisy room never needs more than -40 dBFS, and near-silent input doesn't turn
        /// breaths and clicks into voice.
        public var voicedThresholdDBFS: ClosedRange<Float> = -52 ... -40
        public var minVoiced: TimeInterval = 0.25

        public init() {}
    }

    public enum Item: Equatable, Sendable {
        /// Sample range into the planned `PCMAudio`.
        case audio(Range<Int>, silent: Bool)
        case event(CaptureEvent)
    }

    static let frameLength = 320

    public static func plan(audio: PCMAudio, events: [CaptureEvent], options: Options = .init()) -> [Item] {
        let sorted = events.enumerated()
            .sorted { $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset }
            .map(\.element)
        let sampleCount = audio.samples.count
        guard sampleCount > 0 else { return sorted.map(Item.event) }

        let rms = frameRMS(audio.samples)
        let threshold = voicedThreshold(rms: rms, options: options)
        let duration = audio.duration
        let rate = PCMAudio.sampleRate

        var groups: [[CaptureEvent]] = []
        for event in sorted {
            if let first = groups.last?.first, event.offset - first.offset <= options.mergeWindow {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }

        var leading: [CaptureEvent] = []
        var trailing: [CaptureEvent] = []
        var cuts: [(frame: Int, events: [CaptureEvent])] = []
        let snapFrames = Int((options.snapWindow * rate) / Double(frameLength))
        for group in groups {
            let offset = group[0].offset
            if offset < options.edgeMargin {
                leading += group
                continue
            }
            if offset > duration - options.edgeMargin {
                trailing += group
                continue
            }
            let target = min(rms.count - 1, Int(offset * rate) / frameLength)
            let lower = max(0, target - snapFrames, (cuts.last?.frame ?? -1) + 1)
            let upper = min(rms.count - 1, target + snapFrames)
            if lower > upper {
                if cuts.isEmpty {
                    leading += group
                } else {
                    cuts[cuts.count - 1].events += group
                }
                continue
            }
            cuts.append((quietestFrame(in: lower...upper, rms: rms, near: target), group))
        }

        var items = leading.map(Item.event)
        var start = 0
        for cut in cuts {
            let end = min(sampleCount, cut.frame * frameLength + frameLength / 2)
            items += audioItems(start..<end, rms: rms, threshold: threshold, options: options)
            items += cut.events.map(Item.event)
            start = end
        }
        items += audioItems(start..<sampleCount, rms: rms, threshold: threshold, options: options)
        items += trailing.map(Item.event)
        return items
    }

    /// Samples from the first to the last voiced frame, padded by `edgeMargin`; nil when the audio has too little voice.
    static func speechRange(audio: PCMAudio, options: Options = .init()) -> Range<Int>? {
        let rms = frameRMS(audio.samples)
        let threshold = voicedThreshold(rms: rms, options: options)
        guard let first = rms.firstIndex(where: { $0 > threshold }),
              let last = rms.lastIndex(where: { $0 > threshold }),
              !isSilent(0..<audio.samples.count, rms: rms, threshold: threshold, options: options)
        else { return nil }
        let pad = Int(options.edgeMargin * PCMAudio.sampleRate)
        return max(0, first * frameLength - pad)..<min(audio.samples.count, (last + 1) * frameLength + pad)
    }

    /// The room noise is the recording's quietest tenth, so a built-in mic at a low input volume, where speech sits
    /// well under -40 dBFS but still far above the noise, isn't mistaken for silence.
    private static func voicedThreshold(rms: [Float], options: Options) -> Float {
        let noise = rms.isEmpty ? 0 : rms.sorted()[rms.count / 10]
        let decibels = 20 * log10(max(noise, 1e-6)) + options.voicedAboveNoise
        let bounds = options.voicedThresholdDBFS
        return pow(10, min(bounds.upperBound, max(bounds.lowerBound, decibels)) / 20)
    }

    static func frameRMS(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: frameLength).map { start in
            let end = min(samples.count, start + frameLength)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(end - start)).squareRoot()
        }
    }

    private static func quietestFrame(in range: ClosedRange<Int>, rms: [Float], near target: Int) -> Int {
        var best = range.lowerBound
        for frame in range {
            if rms[frame] < rms[best] || (rms[frame] == rms[best] && abs(frame - target) < abs(best - target)) {
                best = frame
            }
        }
        return best
    }

    private static func audioItems(_ span: Range<Int>, rms: [Float], threshold: Float, options: Options) -> [Item] {
        guard !span.isEmpty else { return [] }
        let maxSamples = max(frameLength * 2, Int(options.maxChunk * PCMAudio.sampleRate))
        var pieces: [Range<Int>] = []
        var start = span.lowerBound
        while span.upperBound - start > maxSamples {
            let windowStart = (start + maxSamples * 4 / 5) / frameLength
            let windowEnd = (start + maxSamples) / frameLength - 1
            let frame = windowStart <= windowEnd
                ? quietestFrame(in: windowStart...windowEnd, rms: rms, near: windowEnd)
                : windowEnd
            let cut = max(start + 1, frame * frameLength + frameLength / 2)
            pieces.append(start..<cut)
            start = cut
        }
        pieces.append(start..<span.upperBound)
        return pieces.map { .audio($0, silent: isSilent($0, rms: rms, threshold: threshold, options: options)) }
    }

    private static func isSilent(_ span: Range<Int>, rms: [Float], threshold: Float, options: Options) -> Bool {
        var voiced = 0
        for frame in (span.lowerBound / frameLength)...((span.upperBound - 1) / frameLength) where rms[frame] > threshold {
            let frameStart = frame * frameLength
            voiced += min(span.upperBound, frameStart + frameLength) - max(span.lowerBound, frameStart)
        }
        return Double(voiced) / PCMAudio.sampleRate < options.minVoiced
    }
}
