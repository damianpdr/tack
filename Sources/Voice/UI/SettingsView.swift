import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoiceCore

enum SettingsTab: Hashable {
    case general
    case transcription
    case permissions
    case storage
}

struct SettingsView: View {
    @Bindable var model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            TranscriptionSettings(model: model)
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(SettingsTab.transcription)
            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
            StorageSettings(model: model)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsTab.storage)
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Shortcuts") {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent {
                        HStack(spacing: 6) {
                            if model.hotkeyFailures.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .help("This shortcut could not be registered")
                            }
                            ShortcutRecorder(model: model, combo: hotkeyBinding(action))
                        }
                    } label: {
                        Text(action.title)
                    }
                }
                if !model.hotkeyFailures.isEmpty {
                    Text("Could not register: \(failedTitles). Another app may be using the same shortcut — pick a different one.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Text("Click a shortcut, then press the new keys. Esc cancels.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") { model.settings.hotkeys = Settings.defaultHotkeys }
                        .disabled(model.settings.hotkeys == Settings.defaultHotkeys)
                }
            }
            Section("Pasting") {
                Toggle("Paste automatically into the frontmost app", isOn: $model.settings.autoPaste)
                Picker("Paste mode", selection: $model.settings.pasteMode) {
                    ForEach(PasteMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            Section("While recording") {
                Toggle("Capture clipboard copies", isOn: $model.settings.captureClipboardWhileRecording)
                Toggle("Capture macOS screenshots saved to disk", isOn: $model.settings.captureSystemScreenshots)
            }
            Section {
                Picker("Figure size", selection: $model.settings.maxFigureDimension) {
                    Text("Original").tag(0)
                    Text("2560 px").tag(2560)
                    Text("2048 px (Codex, GPT)").tag(2048)
                    Text("1568 px (Claude)").tag(1568)
                }
            } header: {
                Text("Screenshots in prompts")
            } footer: {
                Text("Longest edge of figures attached to a prompt. Agents downscale larger images anyway, so this saves upload time and tokens. The full-size original stays in History.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Show in Dock", isOn: $model.settings.showInDock)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        LaunchAtLogin.isEnabled = enabled
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private var failedTitles: String {
        HotkeyAction.allCases.filter { model.hotkeyFailures.contains($0) }.map(\.title).joined(separator: ", ")
    }

    private func hotkeyBinding(_ action: HotkeyAction) -> Binding<KeyCombo> {
        Binding(
            get: { model.settings.hotkeys[action] ?? Settings.defaultHotkeys[action] ?? KeyCombo(keyCode: 0, modifiers: 0) },
            set: { model.settings.hotkeys[action] = $0 }
        )
    }
}

// MARK: Transcription

private struct TranscriptionSettings: View {
    @Bindable var model: AppModel
    @State private var catalog: [String] = []
    @State private var catalogError: String?
    @State private var customLanguage = false
    private let download = ModelDownload.shared

    private static let languages: [(code: String, name: String)] = [("", "Auto-detect"), ("pl", "Polski"), ("en", "English")]
    private static let customTag = "custom"

    var body: some View {
        Form {
            Section("Engine") {
                ForEach(EngineKind.allCases, id: \.self) { engine in
                    EngineOption(engine: engine, isSelected: model.settings.engine == engine) {
                        model.settings.engine = engine
                    }
                }
            }
            Section {
                Picker("Language", selection: languageSelection) {
                    ForEach(Self.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                    Text("Other…").tag(Self.customTag)
                }
                if showsCustomLanguage {
                    TextField("Language code", text: $model.settings.language, prompt: Text("ISO 639-1, e.g. de"))
                }
            }
            switch model.settings.engine {
            case .openRouter: openRouterSection
            case .parakeet: ParakeetSection(model: model)
            case .whisperCpp: whisperSection
            }
            VocabularySection(model: model)
        }
        .formStyle(.grouped)
        .onAppear {
            customLanguage = !Self.languages.contains { $0.code == model.settings.language }
        }
    }

    private var showsCustomLanguage: Bool {
        customLanguage || !Self.languages.contains { $0.code == model.settings.language }
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { showsCustomLanguage ? Self.customTag : model.settings.language },
            set: { tag in
                if tag == Self.customTag {
                    customLanguage = true
                } else {
                    customLanguage = false
                    model.settings.language = tag
                }
            }
        )
    }

    // MARK: OpenRouter

    private var openRouterSection: some View {
        Section("OpenRouter") {
            LabeledContent("API key") {
                SecureField("API key", text: $model.settings.openRouterAPIKey, prompt: Text("sk-or-…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
            }
            HStack {
                if model.settings.openRouterAPIKey.isEmpty, ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?.isEmpty == false {
                    Text("Using OPENROUTER_API_KEY from the environment.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("Get an API key", destination: URL(string: "https://openrouter.ai/keys")!)
            }
            .font(.callout)
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    TextField("Model", text: $model.settings.openRouterModel, prompt: Text("openai/gpt-4o-transcribe"))
                        .labelsHidden()
                    Menu {
                        if catalog.isEmpty {
                            Text(catalogError ?? "Loading…")
                        }
                        ForEach(catalog, id: \.self) { name in
                            Button(name) { model.settings.openRouterModel = name }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Transcription models available on OpenRouter")
                }
            }
        }
        .task { await loadCatalog() }
    }

    private func loadCatalog() async {
        guard catalog.isEmpty else { return }
        do {
            catalog = try await OpenRouterCatalog.transcriptionModels()
            catalogError = catalog.isEmpty ? "No models found" : nil
        } catch {
            catalogError = "Could not load models: \(error.localizedDescription)"
        }
    }

    // MARK: whisper.cpp

    private var effectiveModelPath: String {
        model.settings.whisperModelPath.isEmpty ? model.paths.defaultWhisperModel.path : model.settings.whisperModelPath
    }

    private var whisperSection: some View {
        let detectedCLI = WhisperCppEngine.detectCLI(preferred: model.settings.whisperCLIPath)
        let modelExists = FileManager.default.fileExists(atPath: effectiveModelPath)
        let defaultModelExists = FileManager.default.fileExists(atPath: model.paths.defaultWhisperModel.path)
        return Section("whisper.cpp") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("whisper-cli", text: $model.settings.whisperCLIPath, prompt: Text("Auto-detect"))
                if let detectedCLI {
                    status(ok: true, "Using \(detectedCLI)")
                } else {
                    status(ok: false, "whisper-cli not found. Install it with: brew install whisper-cpp")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Model", text: $model.settings.whisperModelPath, prompt: Text(model.paths.defaultWhisperModel.path))
                    Button("Choose…", action: chooseModel)
                }
                if modelExists {
                    status(ok: true, "Model found: \((effectiveModelPath as NSString).lastPathComponent)")
                } else {
                    status(ok: false, "Model missing: \(effectiveModelPath)")
                }
            }
            if !defaultModelExists || download.progress != nil {
                downloadRow
            }
        }
    }

    @ViewBuilder
    private var downloadRow: some View {
        if let progress = download.progress {
            HStack {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
                Button("Cancel") { download.cancel() }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button("Download large-v3-turbo (q5_0, ~550 MB)") {
                    download.start(to: model.paths.defaultWhisperModel) {
                        if !FileManager.default.fileExists(atPath: model.settings.whisperModelPath) {
                            model.settings.whisperModelPath = ""
                        }
                    }
                }
                if let error = download.error {
                    status(ok: false, error)
                }
            }
        }
    }

    private func status(ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .font(.callout)
            .foregroundStyle(ok ? Color.green : Color.red)
            .textSelection(.enabled)
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.directoryURL = model.paths.models
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.whisperModelPath = url.path
        }
    }
}

private struct EngineOption: View {
    let engine: EngineKind
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: engine.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(engine.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor @Observable
private final class ModelDownload {
    static let shared = ModelDownload()

    private(set) var progress: Double?
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(to destination: URL, onSuccess: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        progress = 0
        error = nil
        task = Task {
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await WhisperModelDownloader.download(to: destination) { value in
                    Task { @MainActor in ModelDownload.shared.report(value) }
                }
                onSuccess()
            } catch {
                if !Task.isCancelled { self.error = "Download failed: \(error.localizedDescription)" }
            }
            if !Task.isCancelled {
                progress = nil
                task = nil
            }
        }
    }

    private func report(_ value: Double) {
        if progress != nil { progress = value }
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }
}

private struct ParakeetSection: View {
    @Bindable var model: AppModel
    private let loader = ParakeetLoader.shared

    var body: some View {
        let downloaded = loader.ready || ParakeetEngine.isDownloaded(at: model.paths.parakeetModels)
        Section {
            if let progress = loader.progress {
                HStack {
                    ProgressView(value: progress)
                    Text(progress < 1 ? "\(Int(progress * 100))%" : "Preparing…")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            } else if downloaded {
                Label("Model ready: parakeet-tdt-0.6b-v3", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Text("Download the model once (~470 MB). After that, everything runs on this Mac.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download") { loader.start(directory: model.paths.parakeetModels) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = loader.error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Parakeet")
        } footer: {
            Text("NVIDIA Parakeet TDT 0.6b v3 (CC-BY-4.0) via FluidAudio. Detects the language on its own; choosing one above only filters out other alphabets. Vocabulary hints are not used by this engine.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

@MainActor @Observable
private final class ParakeetLoader {
    static let shared = ParakeetLoader()

    private(set) var progress: Double?
    private(set) var error: String?
    private(set) var ready = false

    func start(directory: URL) {
        guard progress == nil else { return }
        progress = 0
        error = nil
        Task {
            do {
                try await ParakeetEngine.prepare(at: directory) { value in
                    Task { @MainActor in
                        if ParakeetLoader.shared.progress != nil { ParakeetLoader.shared.progress = value }
                    }
                }
                ready = true
            } catch {
                self.error = "Download failed: \(error.localizedDescription)"
            }
            progress = nil
        }
    }
}

private struct VocabularySection: View {
    @Bindable var model: AppModel
    @State private var text = ""

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .onChange(of: text) { _, newValue in
                    model.settings.vocabulary = Settings.parseVocabulary(newValue)
                }
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("Project names, components and jargon to spell exactly, one per line or comma-separated (e.g. TrollboxPanel, useOrderbookStream, Tailwind). Used by whisper.cpp and by OpenRouter models from OpenAI, Microsoft (MAI) and Groq; other providers ignore it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear { text = model.settings.vocabulary.joined(separator: "\n") }
    }
}

// MARK: Permissions

private struct PermissionsSettings: View {
    @State private var statuses: [PermissionKind: PermissionStatus] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    row(kind)
                }
            } header: {
                Text("Voice needs these to record, paste and take screenshots.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Screen Recording takes effect after restarting Voice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() {
        for kind in PermissionKind.allCases {
            statuses[kind] = Permissions.status(kind)
        }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let status = statuses[kind] ?? Permissions.status(kind)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(kind))
                Text(purpose(kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notDetermined, .denied:
                Button("Grant…") {
                    Permissions.request(kind)
                    refresh()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func title(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    private func purpose(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: "Record your voice."
        case .accessibility: "Paste automatically into the frontmost app."
        case .screenRecording: "Screenshot shortcuts and screenshots while recording."
        }
    }
}

// MARK: Storage

private struct StorageSettings: View {
    @Bindable var model: AppModel
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section("Data") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.paths.root.path)
                            .textSelection(.enabled)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.paths.root])
                        }
                    }
                }
                Text("Agents can read the newest prompt with: cat \(model.paths.latestLink.path)/prompt.md")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("History") {
                LabeledContent("Keep newest") {
                    HStack(spacing: 6) {
                        TextField("Items", value: $model.settings.historyLimit, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Stepper("Items", value: $model.settings.historyLimit, in: 50...100_000, step: 100)
                            .labelsHidden()
                        Text("items")
                    }
                }
                HStack {
                    Text(HistoryFormat.count(model.history.count, "item"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                        .disabled(model.history.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This deletes every item, including recorded sessions, clips and screenshots. It cannot be undone.")
        }
    }
}
