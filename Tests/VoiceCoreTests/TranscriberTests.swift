import Foundation
import Testing
@testable import VoiceCore

private final class ScriptedEngine: TranscriptionEngine, @unchecked Sendable {
    let replies: [String]
    private(set) var receivedChunks: [URL] = []

    init(replies: [String]) { self.replies = replies }

    var displayName: String { "scripted" }

    func transcribe(_ chunks: [URL], language: String?) async throws -> [String] {
        receivedChunks = chunks
        return Array(replies.prefix(chunks.count))
    }
}

private final class ScriptedTimedEngine: TimedTranscriptionEngine, @unchecked Sendable {
    let words: [TimedWord]
    private(set) var receivedDurations: [TimeInterval] = []

    init(words: [TimedWord]) { self.words = words }

    var displayName: String { "scripted timed" }

    func transcribe(_ chunks: [URL], language: String?) async throws -> [String] {
        Issue.record("chunked path used for a timed engine")
        return []
    }

    func transcribeTimed(_ audio: URL, language: String?) async throws -> [TimedWord] {
        receivedDurations.append(try WAVFile.read(audio).duration)
        return words
    }
}

private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedWord {
    TimedWord(text: " " + text, start: start, end: end)
}

private func clip(_ offset: TimeInterval, _ text: String) -> CaptureEvent {
    CaptureEvent(offset: offset, content: .text(text))
}

struct PlaceTests {
    let sentence = [word("one", 0.0, 0.4), word("two", 0.5, 0.9), word("three", 1.5, 1.9), word("four.", 2.0, 2.4)]

    @Test func eventInsideAGapLandsThere() {
        let blocks = Transcriber.place(words: sentence, events: [clip(1.2, "e")])
        #expect(blocks == [.text("one two"), .clip("e"), .text("three four.")])
    }

    @Test func eventSnapsToWidestGapInWindow() {
        let blocks = Transcriber.place(words: sentence, events: [clip(0.45, "e")])
        #expect(blocks == [.text("one two"), .clip("e"), .text("three four.")])
    }

    @Test func eventInsideContiguousWordsGoesToNearestEdge() {
        let words = [word("alpha", 0, 1), word("beta", 1, 2), word("gamma", 2, 3)]
        #expect(Transcriber.place(words: words, events: [clip(1.8, "e")]) == [.text("alpha beta"), .clip("e"), .text("gamma")])
        #expect(Transcriber.place(words: words, events: [clip(1.2, "e")]) == [.text("alpha"), .clip("e"), .text("beta gamma")])
    }

    @Test func withoutNearbyGapEventPrecedesFirstWordWithLaterMidpoint() {
        let words = [word("long", 0, 2), word("longer", 2, 4.4)]
        #expect(Transcriber.place(words: words, events: [clip(1.3, "e")]) == [.text("long"), .clip("e"), .text("longer")])
        #expect(Transcriber.place(words: words, events: [clip(3.3, "e")]) == [.text("long longer"), .clip("e")])
    }

    @Test func eventsOutsideSpeechGoFirstAndLast() {
        let blocks = Transcriber.place(words: sentence, events: [clip(9, "late"), clip(0, "start"), clip(2.4, "end"), clip(-1, "early")])
        #expect(blocks == [.clip("early"), .clip("start"), .text("one two three four."), .clip("end"), .clip("late")])
    }

    @Test func eventsInOneGapKeepTimeThenInputOrder() {
        let blocks = Transcriber.place(words: sentence, events: [clip(1.3, "c"), clip(1.1, "a"), clip(1.3, "d"), clip(1.2, "b")])
        #expect(blocks == [.text("one two"), .clip("a"), .clip("b"), .clip("c"), .clip("d"), .text("three four.")])
    }

    @Test func eventOrderFollowsTimeAcrossAllOffsets() {
        let words = [word("a", 0.3, 0.5), word("b", 0.55, 0.7), word("c", 1.6, 1.7), word("d", 1.72, 2.8), word("e", 2.85, 3.0)]
        let events = stride(from: -0.5, through: 3.5, by: 0.05).map { clip($0, String(format: "%.2f", $0)) }
        let placed = Transcriber.place(words: words, events: events.reversed()).compactMap { block -> String? in
            if case .clip(let text) = block { text } else { nil }
        }
        #expect(placed == events.map { if case .text(let text) = $0.content { text } else { "" } })
    }

    @Test func textIsCleanedAndHallucinatedSpansDropped() {
        let words = [word("[BLANK_AUDIO]", 0, 0.2), word("hello", 0.3, 0.6), TimedWord(text: "!", start: 0.6, end: 0.6), word("Thank", 2, 2.2), word("you.", 2.2, 2.4)]
        #expect(Transcriber.place(words: words, events: [clip(1.3, "e")]) == [.text("hello!"), .clip("e")])
    }
}

struct TranscriberTests {
    @Test func skipsSilentChunksAndCleansResults() async throws {
        let voiced: [Float] = (0..<Int(PCMAudio.sampleRate)).map { $0 % 2 == 0 ? 0.3 : -0.3 }
        let silence = [Float](repeating: 0, count: Int(PCMAudio.sampleRate) * 3)
        let audio = PCMAudio(samples: voiced + voiced + silence + voiced + voiced)
        let events = [
            CaptureEvent(offset: 1.0, content: .image(path: "/a.png")),
            CaptureEvent(offset: 2.5, content: .files(["/x", "/y"])),
            CaptureEvent(offset: 4.0, content: .text("copied")),
            CaptureEvent(offset: 6.0, content: .text("copied again")),
        ]
        let engine = ScriptedEngine(replies: ["  hello [BLANK_AUDIO]  world ", "(music) more", "Thank you.", "again\n  there"])
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-transcriber-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let blocks = try await Transcriber.transcribe(audio: audio, events: events, engine: engine, language: nil, workDir: workDir)

        #expect(engine.receivedChunks.count == 4)
        #expect(blocks == [
            .text("hello world"), .image(path: "/a.png"), .text("more"), .file(path: "/x"), .file(path: "/y"),
            .clip("copied"), .clip("copied again"), .text("again there"),
        ])
    }

    @Test func timedEngineGetsTrimmedSpeechWithShiftedEvents() async throws {
        let voiced: [Float] = (0..<Int(PCMAudio.sampleRate) * 2).map { $0 % 2 == 0 ? 0.3 : -0.3 }
        let silence = [Float](repeating: 0, count: Int(PCMAudio.sampleRate) * 2)
        let engine = ScriptedTimedEngine(words: [word("first", 0.3, 1.0), word("second", 1.5, 2.3)])
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-transcriber-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let blocks = try await Transcriber.transcribe(
            audio: PCMAudio(samples: silence + voiced + silence),
            events: [clip(0.5, "before"), clip(3.0, "middle"), clip(6.0, "after")],
            engine: engine, language: nil, workDir: workDir
        )

        #expect(engine.receivedDurations == [2.6])
        #expect(blocks == [.clip("before"), .text("first"), .clip("middle"), .text("second"), .clip("after")])
    }

    @Test func silentAudioSkipsTimedEngine() async throws {
        let engine = ScriptedTimedEngine(words: [word("ghost", 0, 1)])
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-transcriber-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let noise = (0..<Int(PCMAudio.sampleRate) * 3).map { _ in Float.random(in: -0.005...0.005) }

        let blocks = try await Transcriber.transcribe(
            audio: PCMAudio(samples: noise), events: [clip(2, "b"), clip(1, "a")], engine: engine, language: nil, workDir: workDir
        )

        #expect(engine.receivedDurations.isEmpty)
        #expect(blocks == [.clip("a"), .clip("b")])
    }
}
