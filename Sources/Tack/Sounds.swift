import AppKit

/// Three short cues, synthesized at launch so there are no audio assets to ship.
@MainActor
enum Sounds {
    enum Effect: CaseIterable {
        /// Recording started: two soft rising notes.
        case start
        /// A capture landed in the recording: a short wooden "tock", like a pin pressed into cork.
        case pin
        /// The prompt reached the agent: a short whoosh that lands with a soft thud.
        case deliver
    }

    /// How far into a cue its landing is. The delivery throw starts its cue this much early, so the thud hits with it.
    static func lead(_ effect: Effect) -> TimeInterval {
        effect == .deliver ? deliverLanding : 0
    }

    private static let deliverLanding = 0.12

    static func play(_ effect: Effect) {
        guard let sound = sounds[effect] else { return }
        // A rapid second capture restarts the cue instead of being swallowed by the one still playing.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private static let sounds: [Effect: NSSound] = Dictionary(uniqueKeysWithValues: Effect.allCases.compactMap { effect in
        NSSound(data: wav(for: effect)).map { (effect, $0) }
    })

    private static let sampleRate = 44_100.0
    /// One knob for how present the cues are: every one plays at this fraction of its designed level.
    private static let level = 0.5

    private static func wav(for effect: Effect) -> Data {
        var noise = Noise()
        switch effect {
        case .start:
            return render(duration: 0.32, gain: 0.32) { t in
                0.55 * note(t, 587.33, at: 0, decay: 0.07)
                    + 0.5 * note(t, 880, at: 0.075, decay: 0.12)
                    + 0.05 * note(t, 1760, at: 0.075, decay: 0.05)
            }
        case .pin:
            return render(duration: 0.16, gain: 0.27) { t in
                0.55 * sin(2 * .pi * 1250 * t) * exp(-t / 0.016)
                    + 0.55 * sin(2 * .pi * 190 * t) * exp(-t / 0.035)
                    + 0.1 * noise.next() * exp(-t / 0.003)
            }
        case .deliver:
            let landing = deliverLanding
            var low = 0.0, band = 0.0, phase = 0.0
            return render(duration: 0.45, gain: 0.285) { t in
                // Band-passed noise sweeping up as it flies, dying away quickly once it lands.
                let cutoff = 400 + 1600 * min(1, t / landing)
                let f = 2 * sin(.pi * cutoff / sampleRate)
                let high = noise.next() - low - band
                band += f * high
                low += f * band
                let envelope = t < landing ? pow(sin(.pi / 2 * t / landing), 2) : exp(-(t - landing) / 0.012)
                let whoosh = 0.3 * band * envelope
                // The thud: a sine dropping in pitch, with its octave so laptop speakers carry it.
                let local = t - landing
                guard local >= 0 else { return whoosh }
                phase += 2 * .pi * (130 + 110 * exp(-local / 0.025)) / sampleRate
                return whoosh + (sin(phase) + 0.25 * sin(2 * phase)) * min(1, local / 0.003) * exp(-local / 0.09)
            }
        }
    }

    /// A sine with a 4 ms attack and an exponential decay, silent before `start`.
    private static func note(_ t: Double, _ frequency: Double, at start: Double, decay: Double) -> Double {
        let local = t - start
        guard local >= 0 else { return 0 }
        return sin(2 * .pi * frequency * local) * min(1, local / 0.004) * exp(-local / decay)
    }

    /// 16-bit mono PCM in a WAV container, which `NSSound(data:)` reads directly.
    private static func render(duration: Double, gain: Double, _ sample: (Double) -> Double) -> Data {
        let count = Int(duration * sampleRate)
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let t = Double(index) / sampleRate
            // A short fade-out so no cue ends on a click.
            let tail = min(1, Double(count - index) / (0.01 * sampleRate))
            let value = Int16(max(-1, min(1, sample(t) * gain * level * tail)) * Double(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    /// Deterministic white noise in -1...1, so every launch sounds the same.
    private struct Noise {
        private var state: UInt32 = 0x9E37_79B9

        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / Double(UInt32.max) * 2 - 1
        }
    }
}
