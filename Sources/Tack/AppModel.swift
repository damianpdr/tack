import AppKit
import Observation
import TackCore

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case recording
        case processing
        case finished(String)
        case failed(String)
    }

    let paths: TackPaths

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
            if settings.pointWhileRecording != oldValue.pointWhileRecording { syncPointerTap() }
            if settings.engine != oldValue.engine { preloadParakeet() }
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
    /// The live Parakeet transcript of the current recording, with its captures inline; empty when the preview is off.
    private(set) var live = LiveTranscript()
    @ObservationIgnored private var livePreviewTask: Task<Void, Never>?
    /// The record shortcut is being held: push-to-talk, which ends when it is released.
    private(set) var holdingToTalk = false
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    /// Typing time all voice notes in History replaced; see `SpeechStats`.
    private(set) var typingTimeSaved: TimeInterval = 0
    private(set) var hotkeyFailures: Set<HotkeyAction> = []
    private(set) var busyItemIDs: Set<UUID> = []
    var lastError: String?
    var settingsTab: SettingsTab = .general

    /// One level per bar of the icon's waveform.
    static let levelCount = 8
    static let noSpeech = "No speech"

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hotkeys = HotkeyCenter()
    @ObservationIgnored private let clipboard: ClipboardMonitor
    @ObservationIgnored private let screenshots: ScreenshotService
    @ObservationIgnored private let screenshotWatcher = ScreenshotFolderWatcher()
    @ObservationIgnored private let pointerTap = PointerTap()
    @ObservationIgnored private let paster = Paster()
    @ObservationIgnored private var pill: PillController?
    @ObservationIgnored private var windows: WindowManager?
    @ObservationIgnored private var sessionDir: URL?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var hotkeysSuspended = false
    @ObservationIgnored private var phaseResetTask: Task<Void, Never>?

    init() throws {
        let paths = TackPaths.standard()
        try paths.ensureDirectories()
        self.paths = paths
        settingsStore = SettingsStore(url: paths.settingsFile, keychainService: paths.keychainService)
        let loaded = settingsStore.load()
        // Moves an OpenRouter key left in settings.json by older builds into the keychain.
        try? settingsStore.save(loaded)
        settings = loaded
        store = try HistoryStore(paths: paths)
        sessions = SessionStore(paths: paths)
        clipboard = ClipboardMonitor(clipsDirectory: paths.clips)
        screenshots = ScreenshotService(clipsDirectory: paths.clips)
        history = store.load()
        typingTimeSaved = Self.timeSaved(in: history)
    }

    func start() {
        pill = PillController(model: self)
        windows = WindowManager(model: self)

        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.onRelease = { [weak self] action in
            if action == .toggleRecording { self?.recordKeyUp() }
        }
        hotkeys.onEscape = { [weak self] in self?.cancelRecording() }
        registerHotkeys()

        recorder.onLevel = { [weak self] level in self?.pushLevel(level) }
        // No microphone left to switch to: keep what was said so far rather than recording silence.
        recorder.onInputLost = { [weak self] error in
            guard let self, phase == .recording else { return }
            stopRecording()
            lastError = "The microphone went away, so the recording stopped early: \(error.localizedDescription)"
        }

        // The clipboard is only watched while recording, so copies made outside a recording never land in History.
        clipboard.onItem = { [weak self] item in
            guard let self, phase == .recording else { return }
            ingest(item, dedupe: true, captureAt: recorder.currentOffset)
        }

        pointerTap.onPoint = { [weak self] location in self?.point(at: location) }

        screenshotWatcher.onItem = { [weak self] item, created in
            guard let self, phase == .recording, let startDate = recorder.startDate else { return }
            let offset = min(max(0, created.timeIntervalSince(startDate)), recorder.currentOffset)
            ingest(item, dedupe: false, captureAt: offset, from: .screenshotThumbnail)
        }

        // Ultra replaces v3. Nothing has loaded a model yet, so v3 can go now.
        if ParakeetModel.ultra(paths).isDownloaded {
            try? FileManager.default.removeItem(at: paths.parakeetV3Models)
        }

        preloadParakeet()

        if !Permissions.allGranted {
            showSettings(tab: .permissions)
        } else if settings.engine == .parakeet, ParakeetModel.installed(paths) == nil {
            showSettings(tab: .transcription)
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

    /// A tap on the record shortcut toggles recording; holding it longer is push-to-talk and releasing stops.
    private static let holdToTalkThreshold: TimeInterval = 0.4
    private var recordKeyHeld = false
    private var holdStartedAt: Date?

    private func recordKeyDown() {
        guard !recordKeyHeld else { return }
        recordKeyHeld = true
        holdStartedAt = phase == .recording || phase == .processing ? nil : Date()
        toggleRecording()
        guard holdStartedAt != nil else { return }
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdToTalkThreshold))
            guard let self, !Task.isCancelled, recordKeyHeld, holdStartedAt != nil else { return }
            holdingToTalk = true
        }
    }

    private func recordKeyUp() {
        recordKeyHeld = false
        holdTask?.cancel()
        holdTask = nil
        holdingToTalk = false
        if let start = holdStartedAt, Date().timeIntervalSince(start) >= Self.holdToTalkThreshold {
            stopRecording()
        }
        holdStartedAt = nil
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        _ = recorder.stop()
        stopLivePreview()
        clipboard.stop()
        screenshotWatcher.stop()
        hotkeys.escapeEnabled = false
        if let sessionDir { try? FileManager.default.removeItem(at: sessionDir) }
        sessionDir = nil
        captures = []
        resetLevels()
        setPhase(.idle)
        syncPointerTap()
    }

    private func startRecording() {
        guard !isStarting else { return }
        isStarting = true
        phaseResetTask?.cancel()
        Task {
            defer { isStarting = false }
            guard await Permissions.requestMicrophoneAccess() else {
                fail("Microphone access denied. Allow Tack in System Settings → Privacy & Security → Microphone.")
                return
            }
            let dir: URL
            do {
                dir = try sessions.makeSessionDirectory(date: Date())
            } catch {
                fail("Could not create session folder: \(error.localizedDescription)")
                return
            }
            preloadParakeet()
            recorder.microphoneUID = settings.microphone?.uid
            do {
                try recorder.start()
            } catch {
                try? FileManager.default.removeItem(at: dir)
                fail("Could not start recording: \(error.localizedDescription)")
                return
            }
            sessionDir = dir
            captures = []
            live = LiveTranscript()
            resetLevels()
            lastError = nil
            setPhase(.recording)
            if settings.soundEffects { Sounds.play(.start) }
            hotkeys.escapeEnabled = true
            if settings.captureClipboardWhileRecording {
                clipboard.start()
            }
            startLivePreview()
            syncPointerTap()
            if settings.captureSystemScreenshots, let startDate = recorder.startDate {
                screenshotWatcher.start(since: startDate, clipsDirectory: paths.clips)
            }
        }
    }

    private func stopRecording() {
        guard phase == .recording, let dir = sessionDir else { return }
        stopLivePreview()
        clipboard.flush()
        clipboard.stop()
        screenshotWatcher.flush()
        screenshotWatcher.stop()
        setPhase(.processing)
        syncPointerTap()
        hotkeys.escapeEnabled = false
        let audio = recorder.stop()
        resetLevels()
        sessionDir = nil
        let events = captures.sorted { $0.offset < $1.offset }
        let settings = settings
        Task { await process(audio: audio, events: events, dir: dir, settings: settings) }
    }

    /// Loads Parakeet in the background, so the first recording after a launch neither waits for CoreML to load when it
    /// stops nor shows its live transcript late. Returns at once when the model is already loaded; never downloads.
    private func preloadParakeet() {
        guard settings.engine == .parakeet, let model = ParakeetModel.installed(paths) else { return }
        Task.detached(priority: .utility) { try? await ParakeetEngine.prepare(model) }
    }

    /// Re-transcribes the last few seconds with Parakeet about once a second. Never triggers the model download.
    private func startLivePreview() {
        guard settings.livePreview, settings.engine == .parakeet, let parakeet = ParakeetModel.installed(paths) else { return }
        let language = settings.language
        livePreviewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, phase == .recording else { return }
                let window = recorder.recentSamples(seconds: 8)
                guard window.samples.count >= Int(PCMAudio.sampleRate) else { continue }
                guard let words = try? await ParakeetEngine.previewWords(samples: window.samples, model: parakeet, language: language),
                      !Task.isCancelled, phase == .recording
                else { continue }
                live.update(recognized: words, windowStart: window.start)
            }
        }
    }

    /// Keeps the transcript: the pill shows it while the recording is transcribed.
    private func stopLivePreview() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
    }

    private func process(audio: PCMAudio, events: [CaptureEvent], dir: URL, settings: Settings) async {
        let voiced = await Task.detached {
            ChunkPlanner.plan(audio: audio, events: []).contains { item in
                if case .audio(_, silent: false) = item { true } else { false }
            }
        }.value
        guard voiced || !events.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            finish(Self.noSpeech)
            return
        }

        let paths = paths
        var engineName = settings.engine.title
        do {
            try await Task.detached { try SessionAudio.write(audio, in: dir) }.value
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
                finish(Self.noSpeech)
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
            // The pill settles into the logo and throws the prompt at the text cursor while the paste happens.
            let pasting = paster.willPaste(settings: self.settings)
            setPhase(.finished(pasting ? "Pasted" : "Copied"))
            if pasting {
                pill?.deliver(sound: self.settings.soundEffects)
            } else if self.settings.soundEffects {
                Sounds.play(.deliver)
            }
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
        if newPhase == .idle {
            live = LiveTranscript()
            pill?.hide()
        } else {
            pill?.show()
        }
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
            let shot = await screenshots.capture(region: region)
            if region { hotkeys.escapePaused = false }
            guard let shot, let path = shot.item.imagePaths.first else { return }
            let item = shot.item
            // The marker belongs at the moment of the capture, not at the end of a mark-up detour.
            let offset = phase == .recording ? recorder.currentOffset : nil
            let session = recorder.startDate
            if settings.annotateScreenshots { await annotate(path: path) }
            ingest(item, dedupe: false, captureAt: recorder.startDate == session ? offset : nil, from: shot.rect.map { .rect($0) } ?? .mouse)
            await Clipboard.writeImageInBackground(path: path)
        }
    }

    /// ⌃⌥-clicks are only taken while recording, and only with the setting on.
    private func syncPointerTap() {
        guard settings.pointWhileRecording, phase == .recording else {
            pointerTap.stop()
            return
        }
        if !pointerTap.start() {
            lastError = "Pointing with Control + Option + click needs Accessibility access. Allow Tack in System Settings → Privacy & Security → Accessibility."
        }
    }

    /// The window under a ⌃⌥-click joins the recording at the moment of the click, with what was clicked marked.
    private func point(at location: CGPoint) {
        guard phase == .recording, let session = recorder.startDate else { return }
        let offset = recorder.currentOffset
        Task {
            let url = ImageFiles.newPNGURL(in: paths.clips, prefix: "pointer")
            guard let shot = await PointerCapture.capture(at: location, to: url) else {
                NSSound.beep()
                return
            }
            guard phase == .recording, recorder.startDate == session, let size = ImageFiles.pixelSize(at: url) else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let item = HistoryItem.image(path: url.path, size: size, screenshot: true, sourceApp: shot.appName)
            ingest(item, dedupe: false, captureAt: offset, from: .rect(shot.rect), pointer: shot.pointer)
        }
    }

    /// Experimental mark-up pass; see `AnnotationEditor`. Esc has to reach the editor, not cancel the recording.
    private func annotate(path: String) async {
        hotkeys.escapePaused = true
        await AnnotationEditor.run(path: path)
        hotkeys.escapePaused = false
    }

    // MARK: History

    /// While recording, a capture belongs to the recording: it becomes a marker in its prompt instead of a History
    /// item of its own, and flies into the pill from `origin`. Returns nil in that case.
    @discardableResult
    private func ingest(
        _ item: HistoryItem, dedupe: Bool, captureAt offset: TimeInterval?, from origin: FlightOrigin = .mouse, pointer: String? = nil
    ) -> HistoryItem? {
        if let offset, phase == .recording, let dir = sessionDir, let content = captureContent(of: item) {
            let event = CaptureEvent(
                offset: offset, content: adopt(content, into: dir), sourceApp: item.sourceApp, label: item.title, pointer: pointer)
            live.addMarker(capture: event.id, label: Self.markerLabel(for: event.content, after: captures), at: offset)
            captures.append(event)
            pill?.land(event, from: origin, sound: settings.soundEffects)
            return nil
        }
        let stored = store.add(item, dedupe: dedupe)
        store.prune(keepingNewest: max(1, settings.historyLimit))
        reloadHistory()
        return stored
    }

    /// Moves an image Tack saved under clips/ into the session's captures/ folder, so it goes away with the recording.
    private func adopt(_ content: CaptureEvent.Content, into dir: URL) -> CaptureEvent.Content {
        guard case .image(let path) = content, path.hasPrefix(paths.clips.path + "/") else { return content }
        let folder = dir.appendingPathComponent("captures", isDirectory: true)
        let destination = folder.appendingPathComponent((path as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: path, toPath: destination.path)
        } catch {
            return content
        }
        return .image(path: destination.path)
    }

    /// Takes a capture back out of the recording: its thumbnail, its marker and the file Tack saved for it. The
    /// markers after it renumber, as the prompt will.
    func removeCapture(_ id: UUID) {
        guard phase == .recording, let index = captures.firstIndex(where: { $0.id == id }) else { return }
        let removed = captures.remove(at: index)
        if case .image(let path) = removed.content, let dir = sessionDir, path.hasPrefix(dir.path + "/") {
            try? FileManager.default.removeItem(atPath: path)
        }
        var labels: [UUID: String] = [:]
        for (index, capture) in captures.enumerated() {
            labels[capture.id] = Self.markerLabel(for: capture.content, after: captures[..<index])
        }
        live.removeMarker(capture: id, relabeling: labels)
    }

    /// How the capture will be referenced in the prompt, counting the captures before it: "figure 2", "clip 1",
    /// "file 3".
    private static func markerLabel(for content: CaptureEvent.Content, after earlier: some Sequence<CaptureEvent>) -> String {
        var figures = 0, clips = 0, files = 0
        for capture in earlier {
            switch capture.content {
            case .image: figures += 1
            case .text: clips += 1
            case .files(let paths): files += paths.count
            }
        }
        switch content {
        case .image: return "figure \(figures + 1)"
        case .text: return "clip \(clips + 1)"
        case .files: return "file \(files + 1)"
        }
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
        typingTimeSaved = Self.timeSaved(in: history)
    }

    private static func timeSaved(in items: [HistoryItem]) -> TimeInterval {
        items.reduce(0) { total, item in
            guard item.kind == .session, let duration = item.audioDuration else { return total }
            return total + SpeechStats.timeSaved(words: SpeechStats.spokenWords(in: item.blocks), duration: duration)
        }
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
            let audio = try await Task.detached { try WAVFile.read(SessionAudio.url(in: dir)) }.value
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
        case .toggleRecording: recordKeyDown()
        case .captureRegion: captureRegion()
        case .captureScreen: captureScreen()
        case .showHistory: toggleHistory()
        }
    }
}

#if TACK_DEMO
import QuartzCore

/// A scripted recording for screen captures of the pill: no microphone, no model. Its screenshots are real grabs of
/// regions of the screen, so the flights start from what is actually there. Build with
/// `swift build -Xswiftc -DTACK_DEMO` and launch with `TACK_DEMO=1` and a scratch `TACK_HOME`.
extension AppModel {
    private enum DemoCapture {
        /// Fractions of the visible frame for the origin, then the size in points.
        case region(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)
        /// Points from the top-left corner of the main screen.
        case rect(CGRect)
        case screen
        case clip(String)
    }

    /// A take read from the JSON file in `TACK_DEMO_SCRIPT`, for promo footage. Positions are points from the top-left of
    /// the main screen; times are seconds from the start of the recording.
    private struct DemoScript: Decodable {
        struct Word: Decodable { var text: String; var time: TimeInterval }
        struct Capture: Decodable { var time: TimeInterval; var rect: [CGFloat]?; var clip: String? }
        var words: [Word]
        var captures: [Capture]
        var stop: TimeInterval
        var processing: TimeInterval
        var deliver: [CGFloat]

        static func load() -> DemoScript? {
            guard let path = ProcessInfo.processInfo.environment["TACK_DEMO_SCRIPT"],
                  let data = FileManager.default.contents(atPath: path) else { return nil }
            return try? JSONDecoder().decode(DemoScript.self, from: data)
        }
    }

    /// Event times on the host clock, which screen-capture sample buffers also use, so footage can be cut to them.
    private func demoMark(_ event: String) {
        print("TACKDEMO \(event) \(CACurrentMediaTime())")
        fflush(stdout)
    }

    private static let demoWords: [(text: String, time: TimeInterval)] = [
        ("Okay,", 0.3), ("on", 0.75), ("this", 0.95), ("settings", 1.2), ("page", 1.7), ("make", 2.1), ("the", 2.35),
        ("header", 2.5), ("a", 2.95), ("bit", 3.05), ("smaller.", 3.3), ("And", 4.4), ("this", 4.6), ("button", 4.85),
        ("should", 5.3), ("use", 5.55), ("the", 5.75), ("accent", 5.9), ("color", 6.35), ("like", 7.3), ("here.", 7.55),
        ("Also", 8.2), ("the", 8.45), ("whole", 8.6), ("layout", 8.95), ("feels", 9.4), ("off.", 9.7), ("And", 10.7),
        ("this", 10.9), ("error", 11.15), ("from", 11.5), ("the", 11.65), ("console,", 11.8), ("fix", 12.9), ("it", 13.15),
        ("please.", 13.35),
    ]

    private static let demoCaptures: [(time: TimeInterval, capture: DemoCapture)] = [
        (3.9, .region(x: 0.08, y: 0.52, width: 520, height: 300)),
        (6.9, .region(x: 0.58, y: 0.40, width: 440, height: 260)),
        (10.1, .screen),
        (12.4, .clip("TypeError: Cannot read properties of undefined (reading 'map')")),
        (13.6, .region(x: 0.30, y: 0.30, width: 360, height: 220)),
    ]

    func runDemo() async {
        switch ProcessInfo.processInfo.environment["TACK_DEMO"] {
        case "settings":
            showSettings(tab: .general)
            return
        case "history":
            seedDemoHistory()
            toggleHistory()
            return
        default:
            break
        }
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows where window.isVisible && window.canBecomeMain { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(1.5))
        guard let dir = try? sessions.makeSessionDirectory(date: Date()) else { return }
        let script = DemoScript.load()
        let screenHeight = NSScreen.main?.frame.height ?? 0
        sessionDir = dir
        captures = []
        live = LiveTranscript()
        resetLevels()
        setPhase(.recording)
        demoMark("start")
        if settings.soundEffects { Sounds.play(.start) }
        let start = Date()
        let words = script.map { $0.words.map { (text: $0.text, time: $0.time) } } ?? Self.demoWords
        let steps: [(time: TimeInterval, capture: DemoCapture)] = script.map {
            $0.captures.map { step in
                if let clip = step.clip { return (step.time, .clip(clip)) }
                let r = step.rect ?? [0, 0, 0, 0]
                return (step.time, .rect(CGRect(x: r[0], y: screenHeight - r[1] - r[3], width: r[2], height: r[3])))
            }
        } ?? Self.demoCaptures

        let voice = Task { @MainActor in
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                let speaking = words.contains { t >= $0.time && t < $0.time + 0.3 }
                pushLevel(speaking ? Float(0.35 + 0.5 * abs(sin(t * 17))) : Float(0.02 + 0.03 * abs(sin(t * 5))))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        let listener = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                let t = Date().timeIntervalSince(start)
                let windowStart = max(0, t - 8)
                let heard = words.filter { $0.time >= windowStart && $0.time <= t - 0.4 }.map {
                    TimedWord(text: " " + $0.text, start: $0.time - windowStart, end: $0.time - windowStart + 0.25)
                }
                live.update(recognized: heard, windowStart: windowStart)
            }
        }
        for (index, step) in steps.enumerated() {
            await demoWait(until: step.time, from: start)
            demoMark("capture\(index + 1)")
            await demoCapture(step.capture, offset: step.time)
        }
        await demoWait(until: script?.stop ?? 14.4, from: start)
        voice.cancel()
        listener.cancel()
        resetLevels()
        setPhase(.processing)
        demoMark("stop")
        try? await Task.sleep(for: .seconds(script?.processing ?? 1.6))
        setPhase(.finished("Pasted"))
        demoMark("finished")
        // A fixed spot well above the pill, so the throw reads on video; the app aims at the text cursor.
        let visible = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let target = script.map { CGPoint(x: $0.deliver[0], y: screenHeight - $0.deliver[1]) }
            ?? CGPoint(x: visible.midX + visible.width * 0.12, y: visible.minY + visible.height * 0.55)
        pill?.deliver(to: target, sound: settings.soundEffects)
        try? await Task.sleep(for: .seconds(1.5))
        sessionDir = nil
        setPhase(.idle)
        try? await Task.sleep(for: .seconds(0.8))
        if ProcessInfo.processInfo.environment["TACK_DEMO_EXIT"] != nil { NSApp.terminate(nil) }
    }

    /// Fills the history from the `[HistoryItem]` JSON in `TACK_DEMO_HISTORY` (ISO 8601 dates), for shots of the window.
    private func seedDemoHistory() {
        guard let path = ProcessInfo.processInfo.environment["TACK_DEMO_HISTORY"],
              let data = FileManager.default.contents(atPath: path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let items = try? decoder.decode([HistoryItem].self, from: data) else { return }
        for item in items { _ = store.add(item, dedupe: false) }
        history = store.load()
        typingTimeSaved = Self.timeSaved(in: history)
    }

    private func demoWait(until time: TimeInterval, from start: Date) async {
        let delay = time - Date().timeIntervalSince(start)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }

    private func demoCapture(_ capture: DemoCapture, offset: TimeInterval) async {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let rect: CGRect
        switch capture {
        case .clip(let text):
            ingest(.text(text, sourceApp: "Demo"), dedupe: false, captureAt: offset, from: .mouse)
            return
        case .screen:
            rect = screen.frame
        case .region(let x, let y, let width, let height):
            let visible = screen.visibleFrame
            rect = CGRect(x: visible.minX + visible.width * x, y: visible.minY + visible.height * y, width: width, height: height)
        case .rect(let given):
            rect = given
        }
        let url = ImageFiles.newPNGURL(in: paths.clips, prefix: "screenshot")
        let top = CGDisplayBounds(CGMainDisplayID()).height - rect.maxY
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R", "\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))", url.path]
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
        guard let size = ImageFiles.pixelSize(at: url) else { return }
        ingest(.image(path: url.path, size: size, screenshot: true, sourceApp: "Demo"), dedupe: false, captureAt: offset, from: .rect(rect))
    }
}
#endif
