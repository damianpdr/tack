import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TackCore

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
            Section {
                PillStylePicker(style: $model.settings.pillStyle) { style in
                    // Each style brings its sound default along; the toggle below can still override it.
                    model.settings.soundEffects = style == .expressive
                }
                Toggle("Play sounds", isOn: $model.settings.soundEffects)
            } header: {
                Text("Pill")
            } footer: {
                SettingsFootnote("Minimal drops the glow, and nothing flies in or out. Picking it turns sounds off; you can turn them back on.")
            }
            Section("Pasting") {
                Toggle("Paste automatically into the frontmost app", isOn: $model.settings.autoPaste)
                Picker("Paste mode", selection: $model.settings.pasteMode) {
                    ForEach(PasteMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            Section {
                Toggle("Capture clipboard copies", isOn: $model.settings.captureClipboardWhileRecording)
                Toggle("Capture macOS screenshots saved to disk", isOn: $model.settings.captureSystemScreenshots)
                Toggle("Mark up screenshots before adding them (experimental)", isOn: $model.settings.annotateScreenshots)
                Toggle("Point at things with Control + Option + click", isOn: $model.settings.pointWhileRecording)
            } header: {
                Text("While recording")
            } footer: {
                SettingsFootnote("Hold Control + Option and click anything to add its window to the prompt, with what you clicked outlined and named next to the figure: the button or link text, and the page address in browsers. The click itself doesn't reach the app.")
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
                SettingsFootnote("Longest edge of figures attached to a prompt. Agents downscale larger images anyway, so this saves upload time and tokens. The full-size original stays in History.")
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
    @State private var customModel = false

    private static let languages: [(code: String, name: String)] = [("", "Auto-detect"), ("pl", "Polski"), ("en", "English")]
    private static let customTag = "custom"
    /// Models tested with Tack, including the vocabulary hint.
    private static let recommendedModels: [(id: String, name: String)] = [
        ("microsoft/mai-transcribe-2", "MAI-Transcribe 2"),
        ("openai/gpt-4o-transcribe", "GPT-4o Transcribe"),
        ("openai/gpt-4o-mini-transcribe", "GPT-4o mini Transcribe"),
    ]

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
            Picker("Model", selection: modelSelection) {
                ForEach(Self.recommendedModels, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
                Divider()
                Text("Custom…").tag(Self.customTag)
            }
            if showsCustomModel {
                customModelRow
            }
        }
        .task { await loadCatalog() }
    }

    private var showsCustomModel: Bool {
        customModel || !Self.recommendedModels.contains { $0.id == model.settings.openRouterModel }
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { showsCustomModel ? Self.customTag : model.settings.openRouterModel },
            set: { tag in
                customModel = tag == Self.customTag
                if tag != Self.customTag { model.settings.openRouterModel = tag }
            }
        )
    }

    private var customModelRow: some View {
        LabeledContent("Model ID") {
            HStack(spacing: 6) {
                TextField("Model ID", text: $model.settings.openRouterModel, prompt: Text("vendor/model"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
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

    private func loadCatalog() async {
        guard catalog.isEmpty else { return }
        do {
            catalog = try await OpenRouterCatalog.transcriptionModels()
            catalogError = catalog.isEmpty ? "No models found" : nil
        } catch {
            catalogError = "Could not load models: \(error.localizedDescription)"
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

private struct ParakeetSection: View {
    @Bindable var model: AppModel
    private let loader = ParakeetLoader.shared

    var body: some View {
        let ultra = ParakeetModel.ultra(model.paths)
        let installed = loader.ready ? ultra : ParakeetModel.installed(model.paths)
        Section {
            if let progress = loader.progress {
                HStack {
                    ProgressView(value: progress)
                    Text(progress < 1 ? "\(Int(progress * 100))%" : "Preparing…")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            } else if installed == ultra {
                Label("Model ready: Parakeet Ultra", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Text(installed == nil
                        ? "Download the model once (~630 MB). After that, everything runs on this Mac."
                        : "Using Parakeet v3. Parakeet Ultra makes fewer mistakes at the same speed (~630 MB download).")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download") { loader.start(ultra) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = loader.error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Toggle("Show live transcript in the pill", isOn: $model.settings.livePreview)
        } header: {
            Text("Parakeet")
        } footer: {
            SettingsFootnote("Parakeet Ultra, moondream's post-training of NVIDIA Parakeet TDT 0.6b v3 (CC-BY-4.0), via FluidAudio. Detects the language on its own; choosing one above only filters out other alphabets.")
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

    func start(_ model: ParakeetModel) {
        guard progress == nil else { return }
        progress = 0
        error = nil
        Task {
            do {
                try await ParakeetEngine.prepare(model) { value in
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
    @State private var draft = ""

    var body: some View {
        let terms = model.settings.vocabulary
        Section {
            HStack(spacing: 8) {
                TextField("Add a term", text: $draft, prompt: Text("Add a name or term, then press Return"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(Settings.parseVocabulary(draft).isEmpty)
            }
            if !terms.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        VocabularyChip(term: term) {
                            model.settings.vocabulary.removeAll { $0 == term }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if model.settings.engine == .parakeet {
                Label("Parakeet does not use vocabulary hints yet.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text("Vocabulary")
                Spacer()
                if !terms.isEmpty {
                    Button("Clear All") { model.settings.vocabulary = [] }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        } footer: {
            SettingsFootnote("Names and jargon to spell exactly, e.g. Supabase, Kubernetes, useEffect. Paste a comma-separated list to add many at once. Used by OpenRouter models from OpenAI, Microsoft and Groq.")
        }
    }

    private func add() {
        let added = Settings.parseVocabulary(draft)
        guard !added.isEmpty else { return }
        model.settings.vocabulary = Settings.parseVocabulary((model.settings.vocabulary + added).joined(separator: "\n"))
        draft = ""
    }
}

private struct VocabularyChip: View {
    let term: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(term)
                .font(.system(size: 12, weight: .medium))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove \(term)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
    }
}

/// Wraps subviews onto new lines like text.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(width: bounds.width, subviews: subviews).origins
        for (view, origin) in zip(subviews, origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

/// Section footers read left to right like System Settings, instead of the grouped form's trailing alignment.
private struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Tack needs these to record, paste and take screenshots.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } footer: {
                SettingsFootnote("Screen Recording takes effect after restarting Tack.")
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
