import Foundation

public enum HotkeyAction: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case toggleRecording
    case captureRegion
    case captureScreen
    case showHistory

    public var title: String {
        switch self {
        case .toggleRecording: "Record (tap, or hold to talk)"
        case .captureRegion: "Screenshot region"
        case .captureScreen: "Screenshot screen"
        case .showHistory: "Show history"
        }
    }
}

/// Carbon virtual key code + Carbon modifier mask, as accepted by `RegisterEventHotKey`.
public struct KeyCombo: Codable, Hashable, Sendable {
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case parakeet
    case openRouter

    public var title: String {
        switch self {
        case .openRouter: "OpenRouter (cloud)"
        case .parakeet: "Parakeet (local)"
        }
    }

    public var subtitle: String {
        switch self {
        case .openRouter: "Any OpenRouter transcription model. Needs an API key; audio leaves your Mac."
        case .parakeet: "Parakeet Ultra on the Neural Engine. Fast, private, 25 European languages."
        }
    }

    public var symbol: String {
        switch self {
        case .openRouter: "cloud"
        case .parakeet: "laptopcomputer"
        }
    }
}

public enum PasteMode: String, Codable, CaseIterable, Sendable {
    /// Terminals, IDEs and agent apps get text with absolute image paths; other apps get images pasted first, then text.
    case auto
    /// Every app gets text with absolute image paths.
    case textOnly

    public var title: String {
        switch self {
        case .auto: "Auto (paths for terminals/agents, images elsewhere)"
        case .textOnly: "Always text with file paths"
        }
    }
}

/// How much the pill moves and glows. Minimal shows the same things without the flourishes.
public enum PillStyle: String, Codable, CaseIterable, Sendable {
    /// Glow, springs, captures flying in and the prompt thrown to the cursor.
    case expressive
    /// White bars, plain fades, nothing flying.
    case minimal
}

/// An input device, kept by its Core Audio UID, which survives reconnects and reboots, and by name, for showing it
/// while it is unplugged.
public struct Microphone: Codable, Hashable, Sendable {
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public struct Settings: Codable, Equatable, Sendable {
    /// Everything on ⌃⌥, which types no characters (not even Polish ⌥ letters) and is free in Rectangle/Magnet:
    /// ⌃⌥R record, ⌃⌥4 region and ⌃⌥3 screen like macOS's ⌘⇧4/⌘⇧3, ⌃⌥V history like a clipboard manager.
    public static let defaultHotkeys: [HotkeyAction: KeyCombo] = [
        .toggleRecording: KeyCombo(keyCode: 15, modifiers: KeyCombo.control | KeyCombo.option),
        .captureRegion: KeyCombo(keyCode: 21, modifiers: KeyCombo.control | KeyCombo.option),
        .captureScreen: KeyCombo(keyCode: 20, modifiers: KeyCombo.control | KeyCombo.option),
        .showHistory: KeyCombo(keyCode: 9, modifiers: KeyCombo.control | KeyCombo.option),
    ]

    public var engine: EngineKind = .parakeet
    public var openRouterAPIKey: String = ""
    public var openRouterModel: String = "microsoft/mai-transcribe-2"
    /// ISO-639-1 code; empty means auto-detect.
    public var language: String = ""
    public var autoPaste: Bool = true
    public var pasteMode: PasteMode = .auto
    public var captureClipboardWhileRecording: Bool = true
    public var captureSystemScreenshots: Bool = false
    /// Experimental: open the mark-up editor for every screenshot Tack takes itself.
    public var annotateScreenshots: Bool = false
    /// ⌃⌥-click while recording captures the window under the pointer, marks what was clicked and names it in the
    /// prompt. The click never reaches the app.
    public var pointWhileRecording: Bool = false
    /// Short cues when a recording starts, a capture lands in it and the prompt is delivered.
    public var soundEffects: Bool = true
    public var pillStyle: PillStyle = .expressive
    public var showInDock: Bool = true
    public var historyLimit: Int = 2000
    public var hotkeys: [HotkeyAction: KeyCombo] = Settings.defaultHotkeys
    /// Names and jargon the transcriber should spell exactly as written.
    public var vocabulary: [String] = []
    /// Longest edge of figures attached to prompts; 0 keeps the original size.
    public var maxFigureDimension: Int = 2048
    /// Parakeet only: show the last words in the pill while recording.
    public var livePreview: Bool = true
    /// Recorded from even when macOS's default input moves, e.g. to AirPods as they connect; nil follows the default.
    /// While it is unplugged, recordings use the default input.
    public var microphone: Microphone?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        // Unknown engines (e.g. the removed whisper.cpp) fall back to the default instead of failing the whole file.
        engine = (try? c.decodeIfPresent(EngineKind.self, forKey: .engine)) ?? d.engine
        openRouterAPIKey = try c.decodeIfPresent(String.self, forKey: .openRouterAPIKey) ?? d.openRouterAPIKey
        openRouterModel = try c.decodeIfPresent(String.self, forKey: .openRouterModel) ?? d.openRouterModel
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        autoPaste = try c.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? d.autoPaste
        pasteMode = try c.decodeIfPresent(PasteMode.self, forKey: .pasteMode) ?? d.pasteMode
        captureClipboardWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .captureClipboardWhileRecording) ?? d.captureClipboardWhileRecording
        captureSystemScreenshots = try c.decodeIfPresent(Bool.self, forKey: .captureSystemScreenshots) ?? d.captureSystemScreenshots
        annotateScreenshots = try c.decodeIfPresent(Bool.self, forKey: .annotateScreenshots) ?? d.annotateScreenshots
        pointWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .pointWhileRecording) ?? d.pointWhileRecording
        soundEffects = try c.decodeIfPresent(Bool.self, forKey: .soundEffects) ?? d.soundEffects
        pillStyle = (try? c.decodeIfPresent(PillStyle.self, forKey: .pillStyle)) ?? d.pillStyle
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        let stored = try c.decodeIfPresent([HotkeyAction: KeyCombo].self, forKey: .hotkeys) ?? [:]
        hotkeys = d.hotkeys.merging(stored) { _, new in new }
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        maxFigureDimension = try c.decodeIfPresent(Int.self, forKey: .maxFigureDimension) ?? d.maxFigureDimension
        livePreview = try c.decodeIfPresent(Bool.self, forKey: .livePreview) ?? d.livePreview
        microphone = try? c.decodeIfPresent(Microphone.self, forKey: .microphone)
    }

    /// Splits free text on newlines and commas, dropping blanks and case-insensitive duplicates.
    public static func parseVocabulary(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// Something captured while recording, positioned on the audio timeline.
public struct CaptureEvent: Codable, Hashable, Identifiable, Sendable {
    public enum Content: Codable, Hashable, Sendable {
        /// Absolute path to a PNG on disk.
        case image(path: String)
        case text(String)
        case files([String])
    }

    public var id: UUID
    /// Seconds from the start of the recorded audio.
    public var offset: TimeInterval
    public var content: Content
    public var sourceApp: String?
    /// Human label, e.g. "Orca screenshot (1408×890)".
    public var label: String?
    /// What a ⌃⌥-click pointed at in an image capture; see `PromptBlock.image`.
    public var pointer: String?

    public init(
        id: UUID = UUID(), offset: TimeInterval, content: Content, sourceApp: String? = nil, label: String? = nil,
        pointer: String? = nil
    ) {
        self.id = id
        self.offset = offset
        self.content = content
        self.sourceApp = sourceApp
        self.label = label
        self.pointer = pointer
    }
}

/// Canonical, ordered content of a prompt. Everything copyable is expressed as blocks.
public enum PromptBlock: Codable, Hashable, Sendable {
    /// Inline prose (transcribed speech or a stacked text item).
    case text(String)
    /// Absolute image path, referenced inline as `[figure N]`. `pointer` says what the marked spot in the image is,
    /// e.g. `button "Save changes" in Safari, http://localhost:3000/settings`, and ends the figure's reference line.
    case image(path: String, pointer: String? = nil)
    /// Copied text, referenced inline as `[clip N]` with the content appended.
    case clip(String)
    /// Absolute file path, referenced inline as `[file N]`.
    case file(path: String)
}

public enum HistoryKind: String, Codable, Sendable {
    case text
    case image
    case file
    /// Voice recording or stack of items; `blocks` hold the composed content.
    case session
}

public struct HistoryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var kind: HistoryKind
    /// Short label for list rows.
    public var title: String
    /// Searchable/copyable text: raw text for `.text`, composed markdown for `.session`.
    public var text: String
    public var blocks: [PromptBlock]
    public var sourceApp: String?
    /// Owned directory for `.session` items created from a recording.
    public var sessionDir: String?
    /// Seconds of recorded audio; nil for items without audio.
    public var audioDuration: TimeInterval?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: HistoryKind,
        title: String,
        text: String,
        blocks: [PromptBlock],
        sourceApp: String? = nil,
        sessionDir: String? = nil,
        audioDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.title = title
        self.text = text
        self.blocks = blocks
        self.sourceApp = sourceApp
        self.sessionDir = sessionDir
        self.audioDuration = audioDuration
    }

    public var imagePaths: [String] {
        blocks.compactMap { if case .image(let path, _) = $0 { path } else { nil } }
    }

    public var filePaths: [String] {
        blocks.compactMap { if case .file(let path) = $0 { path } else { nil } }
    }

    public var hasAudio: Bool { audioDuration != nil }
}
