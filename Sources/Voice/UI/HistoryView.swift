import AppKit
import Carbon.HIToolbox
import SwiftUI
import VoiceCore

struct HistoryView: View {
    let model: AppModel
    @State private var state: HistoryState
    @State private var recordingStart: Date?
    @FocusState private var searchFocused: Bool

    init(model: AppModel) {
        self.model = model
        _state = State(initialValue: HistoryState(model: model))
    }

    var body: some View {
        let items = state.items
        let cursor = state.cursorItem(in: items)
        VStack(spacing: 0) {
            header
            if !state.selectedItems.isEmpty {
                selectionBar(count: state.selectedItems.count)
            }
            if let error = model.lastError {
                errorBanner(error)
            }
            Divider()
            if let cursor {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        list(items: items, cursorID: cursor.id)
                            .frame(width: geometry.size.width * 0.6)
                        Divider()
                        HistoryDetail(model: model, item: cursor) { state.delete([cursor]) }
                            .id(cursor.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .background(WindowAccessor { state.attach($0) })
        .onAppear {
            state.installKeyMonitor()
            if model.phase == .recording, recordingStart == nil { recordingStart = Date() }
        }
        .onDisappear { state.removeKeyMonitor() }
        .onChange(of: state.query) { state.cursorID = nil }
        .onChange(of: searchFocused) { _, focused in state.searchFocused = focused }
        .onChange(of: state.searchFocused) { _, focused in searchFocused = focused }
        .onChange(of: model.phase) { _, phase in
            recordingStart = phase == .recording ? (recordingStart ?? Date()) : nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search history", text: $state.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if state.query.isEmpty {
                    KeyCap("/")
                } else {
                    Button {
                        state.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .frame(maxWidth: 420)
            Spacer(minLength: 8)
            engineMenu
            recordButton
            Button {
                model.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var recordButton: some View {
        switch model.phase {
        case .recording:
            Button {
                model.toggleRecording()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(HistoryFormat.duration(context.date.timeIntervalSince(recordingStart ?? context.date)))
                            .monospacedDigit()
                    }
                }
                .capsuleLabel(fill: .red, foreground: .white)
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        case .processing:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text("Transcribing…")
            }
            .capsuleLabel(fill: Color.primary.opacity(0.08), foreground: .secondary)
        default:
            Button {
                model.toggleRecording()
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Record")
                    if let combo = model.settings.hotkeys[.toggleRecording]?.displayString {
                        Text(combo)
                            .foregroundStyle(.secondary)
                    }
                }
                .capsuleLabel(fill: Color.primary.opacity(0.08), foreground: .primary)
            }
            .buttonStyle(.plain)
            .help("Start recording")
        }
    }

    private var engineMenu: some View {
        Menu {
            Picker("Engine", selection: Binding(get: { model.settings.engine }, set: { model.settings.engine = $0 })) {
                ForEach(EngineKind.allCases, id: \.self) { engine in
                    Label(engine.title, systemImage: engine.symbol).tag(engine)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Transcription Settings…") { model.showSettings(tab: .transcription) }
        } label: {
            Label(engineLabel, systemImage: model.settings.engine.symbol)
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Transcription engine")
    }

    private var engineLabel: String {
        switch model.settings.engine {
        case .openRouter:
            let name = model.settings.openRouterModel.split(separator: "/").last.map(String.init) ?? ""
            return name.isEmpty ? "Cloud" : name
        case .whisperCpp:
            return "Whisper"
        case .parakeet:
            return "Parakeet"
        }
    }

    private func selectionBar(count: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(count) selected")
                .fontWeight(.semibold)
            Text(" · paste ⏎ · stack s · delete ⌫ · clear esc")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.14))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button {
                model.lastError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.1))
    }

    // MARK: List

    private func list(items: [HistoryItem], cursorID: UUID) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        HistoryRow(
                            item: item,
                            isSelected: state.selection.contains(item.id),
                            isCursor: item.id == cursorID,
                            isBusy: model.busyItemIDs.contains(item.id)
                        )
                        .id(item.id)
                        .onTapGesture { state.click(item) }
                        .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: state.scrollRequest) {
                if let id = state.cursorID ?? items.first?.id { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: HistoryItem) -> some View {
        let targets = state.selection.contains(item.id) ? state.selectedItems : [item]
        Button(targets.count > 1 ? "Paste \(targets.count) Items" : "Paste") { model.paste(targets) }
        Button(targets.count > 1 ? "Copy \(targets.count) Items" : "Copy") { model.copy(targets) }
        if targets.count > 1 {
            Button("Stack \(targets.count) Items") { state.stack(targets) }
        }
        if item.kind == .session, item.hasAudio, item.sessionDir != nil {
            Button("Re-transcribe") { Task { await model.retranscribe(item) } }
                .disabled(model.busyItemIDs.contains(item.id))
        }
        Button("Reveal in Finder") { model.revealInFinder(item) }
        Divider()
        Button(targets.count > 1 ? "Delete \(targets.count) Items" : "Delete", role: .destructive) { state.delete(targets) }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if state.query.isEmpty {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Nothing here yet")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    hint(.toggleRecording, "start / stop recording, then talk")
                    hint(.captureRegion, "screenshot a region while recording")
                    hint(.captureScreen, "screenshot the screen while recording")
                    hint(.showHistory, "open this window")
                }
                Text("Everything you copy or screenshot lands here too.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("No results for “\(state.query)”")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ action: HotkeyAction, _ text: String) -> some View {
        HStack(spacing: 8) {
            KeyCap(model.settings.hotkeys[action]?.displayString ?? "—")
                .frame(minWidth: 52)
            Text(text)
                .font(.system(size: 12))
        }
    }
}

@MainActor @Observable
final class HistoryState {
    let model: AppModel
    var query = ""
    var cursorID: UUID?
    var selection: Set<UUID> = []
    var searchFocused = false
    private(set) var scrollRequest = 0
    @ObservationIgnored private(set) weak var window: NSWindow?
    @ObservationIgnored private var anchorID: UUID?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var reopening = true

    init(model: AppModel) {
        self.model = model
    }

    func attach(_ window: NSWindow?) {
        guard window !== self.window else { return }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        self.window = window
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reopening = true }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowBecameKey() }
            },
        ]
        if window.isKeyWindow { windowBecameKey() }
    }

    /// Each time the window is (re)opened: start from the newest item with list shortcuts active,
    /// undoing AppKit's automatic focus of the search field.
    private func windowBecameKey() {
        guard reopening else { return }
        reopening = false
        query = ""
        cursorID = nil
        scrollRequest &+= 1
        DispatchQueue.main.async { [weak self] in self?.blurSearch() }
    }

    var items: [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.history }
        return model.history.filter { $0.matches(trimmed) }
    }

    /// Selected items in chronological order (oldest first), independent of the search filter.
    var selectedItems: [HistoryItem] {
        model.history.filter { selection.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
    }

    func cursorItem(in items: [HistoryItem]) -> HistoryItem? {
        items.first { $0.id == cursorID } ?? items.first
    }

    private var targets: [HistoryItem] {
        let selected = selectedItems
        if !selected.isEmpty { return selected }
        return cursorItem(in: items).map { [$0] } ?? []
    }

    // MARK: Actions

    func move(_ delta: Int) {
        let items = items
        guard !items.isEmpty else { return }
        let current = cursorItem(in: items).flatMap { item in items.firstIndex { $0.id == item.id } } ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        setCursor(items[next].id)
    }

    func toggleCursorSelection() {
        guard let item = cursorItem(in: items) else { return }
        toggle(item.id)
        anchorID = item.id
    }

    func click(_ item: HistoryItem) {
        searchFocused = false
        let event = NSApp.currentEvent
        if event?.clickCount == 2 {
            model.paste([item])
            return
        }
        let flags = event?.modifierFlags ?? []
        if flags.contains(.command) {
            toggle(item.id)
            anchorID = item.id
        } else if flags.contains(.shift) {
            let items = items
            let anchor = anchorID ?? cursorItem(in: items)?.id
            if let anchor,
               let from = items.firstIndex(where: { $0.id == anchor }),
               let to = items.firstIndex(where: { $0.id == item.id }) {
                selection.formUnion(items[min(from, to)...max(from, to)].map(\.id))
            } else {
                selection.insert(item.id)
            }
        } else {
            anchorID = item.id
        }
        cursorID = item.id
    }

    func paste() {
        let targets = targets
        guard !targets.isEmpty else { return }
        selection = []
        model.paste(targets)
    }

    func copy() {
        let targets = targets
        guard !targets.isEmpty else { return }
        model.copy(targets)
    }

    func stack(_ items: [HistoryItem]? = nil) {
        let items = items ?? selectedItems
        guard items.count >= 2, let stacked = model.stack(items) else {
            NSSound.beep()
            return
        }
        selection = []
        query = ""
        setCursor(stacked.id)
    }

    func delete(_ items: [HistoryItem]? = nil) {
        let doomed = items ?? targets
        guard !doomed.isEmpty else { return }
        let ids = Set(doomed.map(\.id))
        let visible = self.items
        let cursorIndex = cursorItem(in: visible).flatMap { item in visible.firstIndex { $0.id == item.id } } ?? 0
        let survivors = visible.filter { !ids.contains($0.id) }
        let nextCursor = survivors.isEmpty ? nil : survivors[min(max(cursorIndex - visible[..<cursorIndex].filter { ids.contains($0.id) }.count, 0), survivors.count - 1)].id
        selection.subtract(ids)
        model.delete(doomed)
        cursorID = nextCursor
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func setCursor(_ id: UUID) {
        cursorID = id
        scrollRequest &+= 1
    }

    private func blurSearch() {
        searchFocused = false
        window?.makeFirstResponder(nil)
    }

    private var isEditingSearch: Bool {
        searchFocused || (window?.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    private func escape() {
        if isEditingSearch {
            blurSearch()
        } else if !selection.isEmpty {
            selection = []
        } else {
            window?.performClose(nil)
        }
    }

    // MARK: Keyboard

    func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func removeKeyMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil else { return event }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let code = Int(event.keyCode)

        if flags.isEmpty {
            switch code {
            case kVK_Escape:
                escape()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                paste()
                return nil
            case kVK_DownArrow:
                move(1)
                return nil
            case kVK_UpArrow:
                move(-1)
                return nil
            default:
                break
            }
        }
        if isEditingSearch { return event }

        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            if let textView = window.firstResponder as? NSTextView, textView.selectedRange().length > 0 {
                return event
            }
            copy()
            return nil
        }
        guard flags.subtracting(.shift).isEmpty else { return event }

        switch code {
        case kVK_Delete, kVK_ForwardDelete:
            delete()
            return nil
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j":
            move(1)
        case "k":
            move(-1)
        case "x", " ":
            toggleCursorSelection()
        case "s":
            stack()
        case "/":
            searchFocused = true
        default:
            return event
        }
        return nil
    }
}

struct KeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            )
    }
}

private extension View {
    func capsuleLabel(fill: Color, foreground: Color) -> some View {
        font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        view.onWindow = onWindow
    }

    final class WindowTrackingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
