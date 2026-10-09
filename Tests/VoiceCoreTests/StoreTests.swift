import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VoiceCore

private func temporaryPaths() throws -> VoicePaths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-tests-\(UUID().uuidString)", isDirectory: true)
    let paths = VoicePaths(root: root)
    try paths.ensureDirectories()
    return paths
}

struct SettingsStoreTests {
    @Test func missingKeysUseDefaultsAndHotkeysMerge() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let json = #"{"engine":"whisperCpp","unknown":1,"hotkeys":{"captureRegion":{"keyCode":1,"modifiers":256}}}"#
        try Data(json.utf8).write(to: paths.settingsFile)

        let settings = SettingsStore(url: paths.settingsFile).load()
        var expected = Settings()
        expected.engine = .whisperCpp
        expected.hotkeys[.captureRegion] = KeyCombo(keyCode: 1, modifiers: KeyCombo.command)
        #expect(settings == expected)
    }

    @Test func corruptFileFallsBackAndSaveRoundTripsPrivately() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = SettingsStore(url: paths.settingsFile)
        try Data("{not json".utf8).write(to: paths.settingsFile)
        #expect(store.load() == Settings())

        var settings = Settings()
        settings.openRouterAPIKey = "sk-or-test"
        settings.hotkeys[.showHistory] = KeyCombo(keyCode: 9, modifiers: KeyCombo.control)
        try store.save(settings)
        #expect(store.load() == settings)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.settingsFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

@MainActor
struct HistoryStoreTests {
    @Test func textDuplicatesBumpExistingItem() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try HistoryStore(paths: paths)
        let first = store.add(HistoryItem(createdAt: Date(timeIntervalSince1970: 1), kind: .text, title: "hi", text: "hi", blocks: [.text("hi")]), dedupe: true)
        store.add(HistoryItem(createdAt: Date(timeIntervalSince1970: 2), kind: .text, title: "other", text: "other", blocks: [.text("other")]), dedupe: true)
        let again = store.add(HistoryItem(createdAt: Date(timeIntervalSince1970: 3), kind: .text, title: "hi", text: "hi", blocks: [.text("hi")], sourceApp: "Safari"), dedupe: true)

        #expect(again.id == first.id)
        let items = try HistoryStore(paths: paths).load()
        #expect(items.map(\.text) == ["hi", "other"])
        #expect(items[0].createdAt == Date(timeIntervalSince1970: 3))
        #expect(items[0].sourceApp == "Safari")
    }

    @Test func imageDuplicateDeletesNewClipFileAndDeleteRemovesOwnedFiles() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try HistoryStore(paths: paths)
        let fm = FileManager.default
        let original = paths.clips.appendingPathComponent("a.png")
        let duplicate = paths.clips.appendingPathComponent("b.png")
        try Data([1, 2, 3]).write(to: original)
        try Data([1, 2, 3]).write(to: duplicate)
        let outside = paths.root.appendingPathComponent("outside.png")
        try Data([4, 5]).write(to: outside)

        let image = store.add(HistoryItem(kind: .image, title: "a", text: "", blocks: [.image(path: original.path)]), dedupe: true)
        let deduped = store.add(HistoryItem(kind: .image, title: "b", text: "", blocks: [.image(path: duplicate.path)]), dedupe: true)
        #expect(deduped.id == image.id)
        #expect(!fm.fileExists(atPath: duplicate.path))
        #expect(fm.fileExists(atPath: original.path))

        let external = store.add(HistoryItem(kind: .image, title: "o", text: "", blocks: [.image(path: outside.path)]), dedupe: true)
        let sessionDir = paths.sessions.appendingPathComponent("2026-01-01_00-00-00")
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let session = store.add(HistoryItem(kind: .session, title: "s", text: "", blocks: [.image(path: original.path)], sessionDir: sessionDir.path), dedupe: true)

        store.delete(ids: [image.id, external.id, session.id])
        #expect(store.load().isEmpty)
        #expect(!fm.fileExists(atPath: original.path))
        #expect(!fm.fileExists(atPath: sessionDir.path))
        #expect(fm.fileExists(atPath: outside.path))
    }

    @Test func pruneKeepsNewest() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try HistoryStore(paths: paths)
        for index in 0..<5 {
            store.add(HistoryItem(createdAt: Date(timeIntervalSince1970: Double(index)), kind: .text, title: "\(index)", text: "\(index)", blocks: []), dedupe: false)
        }
        store.prune(keepingNewest: 2)
        #expect(store.load().map(\.text) == ["4", "3"])
    }
}

struct SessionStoreTests {
    @Test func finalizeCopiesFiguresRewritesPathsAndPointsLatest() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fm = FileManager.default
        let store = SessionStore(paths: paths)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let dir = try store.makeSessionDirectory(date: date)
        let second = try store.makeSessionDirectory(date: date)
        #expect(second.lastPathComponent == dir.lastPathComponent + "-2")

        let external = paths.root.appendingPathComponent("Screen Shot.png")
        let other = paths.root.appendingPathComponent("other.jpg")
        let inside = dir.appendingPathComponent("already.png")
        for url in [external, other, inside] { try Data([7]).write(to: url) }
        let events = [
            CaptureEvent(offset: 1, content: .image(path: external.path)),
            CaptureEvent(offset: 2, content: .image(path: inside.path)),
            CaptureEvent(offset: 3, content: .image(path: other.path)),
        ]
        let blocks: [PromptBlock] = [.text("see"), .image(path: external.path), .image(path: inside.path), .image(path: external.path), .image(path: other.path)]

        let result = try store.finalize(dir: dir, blocks: blocks, events: events, engine: "test", duration: 4, maxFigureDimension: 0)
        let figure1 = dir.appendingPathComponent("figure-1.png").path
        let figure3 = dir.appendingPathComponent("figure-3.jpg").path
        #expect(result.blocks == [.text("see"), .image(path: figure1), .image(path: inside.path), .image(path: figure1), .image(path: figure3)])
        #expect(result.prompt.figures == [figure1, inside.path, figure3])
        #expect(fm.fileExists(atPath: figure1) && fm.fileExists(atPath: figure3))
        #expect(fm.fileExists(atPath: external.path))

        #expect(try String(contentsOf: dir.appendingPathComponent("prompt.md"), encoding: .utf8) == result.prompt.markdown)
        #expect(try String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8) == result.prompt.body)
        #expect(try store.loadEvents(dir: dir).map(\.content) == [.image(path: figure1), .image(path: inside.path), .image(path: figure3)])
        #expect(try fm.destinationOfSymbolicLink(atPath: paths.latestLink.path) == "sessions/\(dir.lastPathComponent)")

        _ = try store.finalize(dir: second, blocks: [.text("next")], events: [], engine: "test", duration: 1, maxFigureDimension: 0)
        #expect(try String(contentsOf: paths.latestLink.appendingPathComponent("prompt.md"), encoding: .utf8) == "next")
    }

    @Test func figuresShrinkToLongestEdgeAndSmallOnesStayUntouched() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = SessionStore(paths: paths)
        let dir = try store.makeSessionDirectory(date: Date())
        let wide = paths.root.appendingPathComponent("wide.png")
        let small = paths.root.appendingPathComponent("small.png")
        try writePNG(width: 3000, height: 1500, to: wide)
        try writePNG(width: 400, height: 300, to: small)

        let result = try store.finalize(dir: dir, blocks: [.image(path: wide.path), .image(path: small.path)], events: [], engine: "test", duration: 0, maxFigureDimension: 2048)
        #expect(try result.prompt.figures.map(pixelSize) == [[2048, 1024], [400, 300]])
        #expect(try pixelSize(wide.path) == [3000, 1500])
    }
}

private func writePNG(width: Int, height: Int, to url: URL) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func pixelSize(_ path: String) throws -> [Int] {
    let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return [properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0]
}

struct VocabularyTests {
    @Test func splitsOnNewlinesAndCommasTrimsAndDropsDuplicates() {
        #expect(Settings.parseVocabulary("TrollboxPanel, useOrderbook\n\n  Tailwind  \ntrollboxpanel,,layout.tsx") == ["TrollboxPanel", "useOrderbook", "Tailwind", "layout.tsx"])
    }
}
