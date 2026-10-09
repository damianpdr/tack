import AppKit
import Observation
import VoiceCore

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case recording
        case processing
        case finished(String)
        case failed(String)
    }

    let paths: VoicePaths

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            do {
                try settingsStore.save(settings)
            } catch {
                lastError = "Could not save settings: \(error.localizedDescription)"
            }
            if settings.hotkeys != oldValue.hotkeys { registerHotkeys() }
            if settings.showInDock != oldValue.showInDock { applyActivationPolicy() }
            if settings.historyLimit != oldValue.historyLimit {
                store.prune(keepingNewest: max(1, settings.historyLimit))
                reloadHistory()
            }
        }
    }

    private(set) var history: [HistoryItem] = []
    private(set) var phase: Phase = .idle
    private(set) var levels: [Float] = Array(repeating: 0, count: AppModel.levelCount)
    private(set) var captures: [CaptureEvent] = []
    private(set) var hotkeyFailures: Set<HotkeyAction> = []
    private(set) var busyItemIDs: Set<UUID> = []
    var lastError: String?
    var settingsTab: SettingsTab = .general

    static let levelCount = 7

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hotkeys = HotkeyCenter()
    @ObservationIgnored private let clipboard: ClipboardMonitor
    @ObservationIgnored private let screenshots: ScreenshotService
    @ObservationIgnored private let screenshotWatcher = ScreenshotFolderWatcher()
    @ObservationIgnored private let paster = Paster()
    @ObservationIgnored private var pill: PillController?
    @ObservationIgnored private var windows: WindowManager?
    @ObservationIgnored private var sessionDir: URL?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var hotkeysSuspended = false
    @ObservationIgnored private var phaseResetTask: Task<Void, Never>?

    init() throws {
        let paths = VoicePaths.standard()
        try paths.ensureDirectories()
        self.paths = paths
        settingsStore = SettingsStore(url: paths.settingsFile)
        settings = settingsStore.load()
        store = try HistoryStore(paths: paths)
        sessions = SessionStore(paths: paths)
        clipboard = ClipboardMonitor(clipsDirectory: paths.clips)
        screenshots = ScreenshotService(clipsDirectory: paths.clips)
        history = store.load()
    }

    func start() {
        pill = PillController(model: self)
        windows = WindowManager(model: self)

        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.onEscape = { [weak self] in self?.cancelRecording() }
        registerHotkeys()

        recorder.onLevel = { [weak self] level in self?.pushLevel(level) }

        clipboard.onItem = { [weak self] item in
            guard let self else { return }
            let offset = phase == .recording && settings.captureClipboardWhileRecording ? recorder.currentOffset : nil
            ingest(item, dedupe: true, captureAt: offset)
        }
        clipboard.start()

        screenshotWatcher.onItem = { [weak self] item, created in
            guard let self, phase == .recording, let startDate = recorder.startDate else { return }
            let offset = min(max(0, created.timeIntervalSince(startDate)), recorder.currentOffset)
            ingest(item, dedupe: false, captureAt: offset)
        }

        if !Permissions.allGranted {
            showSettings(tab: .permissions)
        }
    }

    // MARK: Recording

    func toggleRecording() {
        switch phase {
        case .processing: return
        case .recording: stopRecording()
        case .idle, .finished, .failed: startRecording()
        }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        _ = recorder.stop()
        screenshotWatcher.stop()
        hotkeys.escapeEnabled = false
        if let sessionDir { try? FileManager.default.removeItem(at: sessionDir) }
        sessionDir = nil
        captures = []
        resetLevels()
        setPhase(.idle)
    }

    private func startRecording() {
        guard !isStarting else { return }
        isStarting = true
        phaseResetTask?.cancel()
        Task {
            defer { isStarting = false }
            guard await Permissions.requestMicrophoneAccess() else {
                fail("Microphone access denied. Allow Voice in System Settings → Privacy & Security → Microphone.")
                return
            }
            let dir: URL
            do {
                dir = try sessions.makeSessionDirectory(date: Date())
            } catch {
                fail("Could not create session folder: \(error.localizedDescription)")
                return
            }
            do {
                try recorder.start()
            } catch {
                try? FileManager.default.removeItem(at: dir)
                fail("Could not start recording: \(error.localizedDescription)")
                return
            }
            sessionDir = dir
            captures = []
            resetLevels()
            lastError = nil
            setPhase(.recording)
            hotkeys.escapeEnabled = true
            if settings.captureSystemScreenshots, let startDate = recorder.startDate {
                screenshotWatcher.start(since: startDate, clipsDirectory: paths.clips)
            }
        }
    }

    private func stopRecording() {
        guard phase == .recording, let dir = sessionDir else { return }
        clipboard.flush()
        screenshotWatcher.flush()
        screenshotWatcher.stop()
        setPhase(.processing)
        hotkeys.escapeEnabled = false
        let audio = recorder.stop()
        resetLevels()
        sessionDir = nil
        let events = captures.sorted { $0.offset < $1.offset }
        let settings = settings
        Task { await process(audio: audio, events: events, dir: dir, settings: settings) }
    }

    private func process(audio: PCMAudio, events: [CaptureEvent], dir: URL, settings: Settings) async {
        let voiced = await Task.detached {
            ChunkPlanner.plan(audio: audio, events: []).contains { item in
                if case .audio(_, silent: false) = item { true } else { false }
            }
        }.value
        guard voiced || !events.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            finish("No speech")
            return
        }

        let paths = paths
        var engineName = settings.engine.title
        do {
            try await Task.detached { try WAVFile.write(audio, to: dir.appendingPathComponent("audio.wav")) }.value
            let blocks: [PromptBlock]
            if voiced {
                let engine = try Transcriber.makeEngine(settings: settings, paths: paths)
                engineName = engine.displayName
                blocks = try await transcribe(audio: audio, events: events, engine: engine, language: settings.language, dir: dir)
            } else {
                blocks = events.flatMap(Transcriber.blocks(for:))
            }
            guard !blocks.isEmpty else {
                try? FileManager.default.removeItem(at: dir)
                finish("No speech")
                return
            }
            let result = try sessions.finalize(dir: dir, blocks: blocks, events: events, engine: engineName, duration: audio.duration, maxFigureDimension: settings.maxFigureDimension)
            ingest(HistoryItem(
                kind: .session,
                title: "Voice note",
                text: result.prompt.markdown,
                blocks: result.blocks,
                sessionDir: dir.path,
                audioDuration: audio.duration
            ), dedupe: false, captureAt: nil)
            let outcome = await paster.deliver(result.blocks, settings: self.settings)
            finish(outcome == .pasted ? "Pasted" : "Copied")
        } catch {
            let message = error.localizedDescription
            do {
                let result = try sessions.finalize(
                    dir: dir,
                    blocks: events.flatMap(Transcriber.blocks(for:)),
                    events: events,
                    engine: engineName,
                    duration: audio.duration,
                    maxFigureDimension: settings.maxFigureDimension
                )
                ingest(HistoryItem(
                    kind: .session,
                    title: "Voice note (not transcribed)",
                    text: result.prompt.markdown,
                    blocks: result.blocks,
                    sessionDir: dir.path,
                    audioDuration: audio.duration
                ), dedupe: false, captureAt: nil)
            } catch {
                lastError = "Could not save the session: \(error.localizedDescription)"
            }
            fail(message)
        }
    }

    private func transcribe(audio: PCMAudio, events: [CaptureEvent], engine: TranscriptionEngine, language: String, dir: URL) async throws -> [PromptBlock] {
        let workDir = dir.appendingPathComponent("chunks", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await Transcriber.transcribe(
            audio: audio,
            events: events,
            engine: engine,
            language: trimmed.isEmpty ? nil : trimmed,
            workDir: workDir
        )
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        if newPhase == .idle { pill?.hide() } else { pill?.show() }
    }

    private func finish(_ message: String) {
        setPhase(.finished(message))
        scheduleReset(after: .milliseconds(900))
    }

    private func fail(_ message: String) {
        lastError = message
        setPhase(.failed(message))
        scheduleReset(after: .seconds(3))
    }

    private func scheduleReset(after delay: Duration) {
        phaseResetTask?.cancel()
        phaseResetTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            switch phase {
            case .finished, .failed: setPhase(.idle)
            case .idle, .recording, .processing: break
            }
        }
    }

    func dismissPill() {
        switch phase {
        case .finished, .failed:
            phaseResetTask?.cancel()
            setPhase(.idle)
        case .idle, .recording, .processing:
            break
        }
    }

    private func pushLevel(_ level: Float) {
        guard phase == .recording else { return }
        levels.append(level)
        if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
    }

    private func resetLevels() {
        levels = Array(repeating: 0, count: Self.levelCount)
    }

    // MARK: Screenshots

    func captureRegion() { capture(region: true) }

    func captureScreen() { capture(region: false) }

    private func capture(region: Bool) {
        guard !screenshots.isCapturing else { return }
        if region { hotkeys.escapePaused = true }
        Task {
            let item = await screenshots.capture(region: region)
            if region { hotkeys.escapePaused = false }
            guard let item, let path = item.imagePaths.first else { return }
            Clipboard.writeImage(path: path, includeFileURL: false)
            ingest(item, dedupe: false, captureAt: phase == .recording ? recorder.currentOffset : nil)
        }
    }

    // MARK: History

    @discardableResult
    private func ingest(_ item: HistoryItem, dedupe: Bool, captureAt offset: TimeInterval?) -> HistoryItem {
        let stored = store.add(item, dedupe: dedupe)
        store.prune(keepingNewest: max(1, settings.historyLimit))
        reloadHistory()
        if let offset, phase == .recording, let content = captureContent(of: stored) {
            captures.append(CaptureEvent(offset: offset, content: content, sourceApp: stored.sourceApp, label: stored.title))
        }
        return stored
    }

    private func captureContent(of item: HistoryItem) -> CaptureEvent.Content? {
        switch item.kind {
        case .image: item.imagePaths.first.map { .image(path: $0) }
        case .text: .text(item.text)
        case .file: .files(item.filePaths)
        case .session: nil
        }
    }

    private func reloadHistory() {
        history = store.load()
    }

    private func orderedBlocks(_ items: [HistoryItem]) -> [PromptBlock] {
        items.sorted { $0.createdAt < $1.createdAt }.flatMap(\.blocks)
    }

    func copy(_ items: [HistoryItem]) {
        guard let first = items.first else { return }
        guard items.count == 1 else {
            Clipboard.writeText(PromptComposer.compose(orderedBlocks(items)).markdown)
            return
        }
        switch first.kind {
        case .text: Clipboard.writeText(first.text)
        case .image:
            if let path = first.imagePaths.first { Clipboard.writeImage(path: path, includeFileURL: true) }
        case .file: Clipboard.writeFiles(first.filePaths)
        case .session: paster.copy(first.blocks)
        }
    }

    func paste(_ items: [HistoryItem]) {
        guard !items.isEmpty else { return }
        let blocks = orderedBlocks(items)
        Task {
            NSApp.hide(nil)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let deadline = Date().addingTimeInterval(0.6)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            _ = await paster.deliver(blocks, settings: settings)
        }
    }

    @discardableResult
    func stack(_ items: [HistoryItem]) -> HistoryItem? {
        guard items.count >= 2 else { return nil }
        let blocks = orderedBlocks(items)
        do {
            let dir = try sessions.makeSessionDirectory(date: Date())
            do {
                let result = try sessions.finalize(dir: dir, blocks: blocks, events: [], engine: "stack", duration: 0, maxFigureDimension: settings.maxFigureDimension)
                let stored = ingest(HistoryItem(
                    kind: .session,
                    title: "Stack of \(items.count) items",
                    text: result.prompt.markdown,
                    blocks: result.blocks,
                    sessionDir: dir.path
                ), dedupe: false, captureAt: nil)
                paster.copy(result.blocks)
                return stored
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
        } catch {
            lastError = "Could not stack items: \(error.localizedDescription)"
            return nil
        }
    }

    func delete(_ items: [HistoryItem]) {
        store.delete(ids: items.map(\.id))
        reloadHistory()
    }

    func clearHistory() {
        store.deleteAll()
        reloadHistory()
    }

    func retranscribe(_ item: HistoryItem) async {
        guard item.kind == .session, item.hasAudio, let dirPath = item.sessionDir, !busyItemIDs.contains(item.id) else { return }
        busyItemIDs.insert(item.id)
        defer { busyItemIDs.remove(item.id) }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let settings = settings
        do {
            let audio = try await Task.detached { try WAVFile.read(dir.appendingPathComponent("audio.wav")) }.value
            let events = try sessions.loadEvents(dir: dir)
            let engine = try Transcriber.makeEngine(settings: settings, paths: paths)
            let blocks = try await transcribe(audio: audio, events: events, engine: engine, language: settings.language, dir: dir)
            let result = try sessions.finalize(dir: dir, blocks: blocks, events: events, engine: engine.displayName, duration: audio.duration, maxFigureDimension: settings.maxFigureDimension)
            var updated = history.first { $0.id == item.id } ?? item
            updated.title = "Voice note"
            updated.text = result.prompt.markdown
            updated.blocks = result.blocks
            updated.audioDuration = audio.duration
            store.update(updated)
            reloadHistory()
        } catch {
            lastError = "Re-transcription failed: \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ item: HistoryItem) {
        let urls: [URL] = switch item.kind {
        case .session: item.sessionDir.map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? item.imagePaths.map { URL(fileURLWithPath: $0) }
        case .image, .file: (item.imagePaths + item.filePaths).map { URL(fileURLWithPath: $0) }
        case .text: []
        }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    // MARK: Windows & hotkeys

    func showHistory() { windows?.showHistory() }

    func showSettings(tab: SettingsTab? = nil) {
        windows?.showSettings()
        guard let tab else { return }
        // TabView ignores a selection that is already set when its window is first built.
        Task { @MainActor in settingsTab = tab }
    }

    func toggleHistory() { windows?.toggleHistory() }

    func setHotkeysSuspended(_ suspended: Bool) {
        guard suspended != hotkeysSuspended else { return }
        hotkeysSuspended = suspended
        hotkeys.suspended = suspended
        if !suspended { registerHotkeys() }
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    private func registerHotkeys() {
        hotkeyFailures = hotkeys.register(settings.hotkeys)
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleRecording: toggleRecording()
        case .captureRegion: captureRegion()
        case .captureScreen: captureScreen()
        case .showHistory: toggleHistory()
        }
    }
}
