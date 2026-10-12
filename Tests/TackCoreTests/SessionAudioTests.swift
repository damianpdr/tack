import Foundation
import Testing
@testable import TackCore

struct SessionAudioTests {
    /// Markers are placed by time and re-transcription should give the same text, so the file must decode to the
    /// samples that went in, on the same timeline.
    @Test func m4aIsLosslessAndSmallerThanWAV() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tack-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rate = PCMAudio.sampleRate
        let burst = Int(1.5 * rate)..<Int(1.7 * rate)
        let samples = (0..<Int(3 * rate)).map { index -> Float in
            burst.contains(index) ? 0.5 * sin(2 * .pi * 440 * Float(index) / Float(rate)) : 0
        }
        try SessionAudio.write(PCMAudio(samples: samples), in: dir)

        let url = SessionAudio.url(in: dir)
        #expect(url.lastPathComponent == "audio.m4a")
        let decoded = try WAVFile.read(url)
        try #require(decoded.samples.count == samples.count)
        #expect(zip(samples, decoded.samples).allSatisfy { abs($0 - $1) <= 1.0 / 32_768 })

        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < samples.count)  // half of 16-bit WAV
    }

    @Test func olderSessionsFallBackToWAV() {
        let dir = URL(fileURLWithPath: "/nonexistent-session", isDirectory: true)
        #expect(SessionAudio.url(in: dir).lastPathComponent == "audio.wav")
    }
}
