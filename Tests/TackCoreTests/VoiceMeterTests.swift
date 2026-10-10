import Foundation
import Testing
@testable import TackCore

private func rms(_ decibels: Float) -> Float { pow(10, decibels / 20) }

struct VoiceMeterTests {
    /// Two seconds of speech at 30 windows a second, alternating syllable peaks and the softer parts between them.
    private func speak(_ meter: inout VoiceMeter, peak: Float, between: Float) -> (peak: Float, between: Float) {
        var levels: (Float, Float) = (0, 0)
        for window in 0..<60 {
            let loud = window % 2 == 0
            let level = meter.level(rms: rms(loud ? peak : between), interval: 1.0 / 30)
            if loud { levels.0 = level } else { levels.1 = level }
        }
        return levels
    }

    @Test func farFromTheMicStillMovesTheBars() {
        var meter = VoiceMeter()
        let far = speak(&meter, peak: -36, between: -42)
        #expect(far.peak > 0.95)
        #expect(far.between > 0.5)
    }

    @Test func closeToTheMicFillsTheBarsWithoutPinningThem() {
        var meter = VoiceMeter()
        let close = speak(&meter, peak: -20, between: -28)
        #expect(close.peak > 0.95)
        #expect(close.between < 0.85)
    }

    @Test func roomNoiseStaysLowAfterTheScaleHasSunk() {
        var meter = VoiceMeter()
        _ = speak(&meter, peak: -20, between: -28)
        var level: Float = 1
        for _ in 0..<150 { level = meter.level(rms: rms(-55), interval: 1.0 / 30) }
        #expect(level < 0.1)
        #expect(meter.level(rms: 0, interval: 1.0 / 30) == 0)
    }
}
