import AppKit
import Observation
import SwiftUI
import TackCore

@MainActor @Observable
final class PillState {
    var hovering = false
    /// False while the pill grows out of (or shrinks back into) a dot.
    var presented = false
    /// Captures still flying in; their thumbnail and marker appear when they land.
    var landing: Set<UUID> = []
    /// Bumped on every landing; the pill gulps.
    var bounce = 0
    @ObservationIgnored var capsuleWidth: CGFloat = PillView.height
    /// Thumbnail frames in the hosting view (top-left origin), the targets of capture flights.
    @ObservationIgnored var chipFrames: [UUID: CGRect] = [:]
}

/// Floating recording indicator. Never becomes key, so the user's app keeps focus.
@MainActor
final class PillController {
    private static let bottomMargin: CGFloat = 24
    private static let cancelHitWidth: CGFloat = 34
    /// The capsule animates its width inside a panel that never resizes, with room around it for the glow and the
    /// landing bounce. Only the capsule takes clicks; the rest of the panel lets them through.
    private static let panelSize = CGSize(width: 760, height: 120)

    private let model: AppModel
    private let state = PillState()
    private let panel: PillPanel
    private let hostingView: PillHostingView
    private var mouseMonitors: [Any] = []
    private var hideTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        panel = PillPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true

        hostingView = PillHostingView(rootView: PillView(model: model, state: state))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hostingView
        hostingView.onClick = { [weak self] in self?.click() }
    }

    func show() {
        hideTask?.cancel()
        hideTask = nil
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            position(on: NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
            state.presented = false
            state.hovering = false
            panel.orderFrontRegardless()
        }
        guard !state.presented else { return }
        installMouseMonitors()
        // One frame as a dot first, so the entrance animates.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard hideTask == nil else { return }
            state.presented = true
        }
    }

    func hide() {
        guard panel.isVisible, hideTask == nil else { return }
        state.presented = false
        state.hovering = false
        removeMouseMonitors()
        panel.ignoresMouseEvents = true
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            state.landing = []
            state.chipFrames = [:]
            hideTask = nil
        }
    }

    /// Flies a capture from where it was taken into its slot in the pill; the pill gulps and pins it when it lands.
    func land(_ event: CaptureEvent, from origin: FlightOrigin, sound: Bool) {
        guard panel.isVisible, !still else {
            arrive(sound: sound)
            return
        }
        state.landing.insert(event.id)
        Task { @MainActor in
            let image = await Flight.image(for: event.content)
            // Give the deck a frame to open the empty slot the capture flies into.
            try? await Task.sleep(for: .milliseconds(20))
            guard let image, panel.isVisible, state.landing.contains(event.id) else {
                state.landing.remove(event.id)
                arrive(sound: sound)
                return
            }
            let source = Flight.sourceRect(origin, pixelSize: CGSize(width: image.width, height: image.height))
            let target = chipRect(event.id) ?? capsuleRect.insetBy(
                dx: (capsuleRect.width - CaptureChip.size.width) / 2,
                dy: (capsuleRect.height - CaptureChip.size.height) / 2
            )
            Flight.capture(image, from: source, to: target) {
                self.state.landing.remove(event.id)
                self.arrive(sound: sound)
            }
        }
    }

    /// Throws the finished prompt from the pill to the text cursor of the app it is pasted into.
    func deliver(sound: Bool) {
        Task { @MainActor in deliver(to: await CaretLocator.target(), sound: sound) }
    }

    func deliver(to point: CGPoint?, sound: Bool) {
        guard let point, panel.isVisible, !still else {
            if sound { Sounds.play(.deliver) }
            return
        }
        Flight.deliver(from: capsuleRect, to: point, lead: Sounds.lead(.deliver)) {
            if sound { Sounds.play(.deliver) }
        }
    }

    /// Nothing flies with Reduce motion on, or in the minimal style.
    private var still: Bool {
        Brand.reduceMotion || model.settings.pillStyle == .minimal
    }

    private func arrive(sound: Bool) {
        state.bounce += 1
        if sound { Sounds.play(.pin) }
    }

    private var capsuleRect: CGRect {
        let frame = panel.frame
        let width = state.capsuleWidth
        return CGRect(x: frame.midX - width / 2, y: frame.midY - PillView.height / 2, width: width, height: PillView.height)
    }

    /// The thumbnail's slot on screen. Only its centre is taken from layout, which may still be mid-transition; the
    /// size is the thumbnail's own, so the flight ends exactly on it.
    private func chipRect(_ id: UUID) -> CGRect? {
        guard let rect = state.chipFrames[id] else { return nil }
        let frame = panel.frame
        let size = CaptureChip.size
        return CGRect(x: frame.minX + rect.midX - size.width / 2, y: frame.maxY - rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func position(on screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = Self.panelSize
        let capsuleMidY = visible.minY + Self.bottomMargin + PillView.height / 2
        let origin = CGPoint(x: (visible.midX - size.width / 2).rounded(), y: (capsuleMidY - size.height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    // MARK: Mouse

    /// The panel ignores the mouse except over the capsule. The pill is never key, so hover comes from monitors.
    private func installMouseMonitors() {
        guard mouseMonitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }) {
            mouseMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        }) {
            mouseMonitors.append(monitor)
        }
        trackMouse()
    }

    private func removeMouseMonitors() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors = []
    }

    private func trackMouse() {
        let inside = state.presented && capsuleRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if state.hovering != inside { state.hovering = inside }
    }

    private func click() {
        let rect = capsuleRect
        let mouse = NSEvent.mouseLocation
        guard rect.contains(mouse) else { return }
        switch model.phase {
        case .recording:
            if state.hovering, mouse.x - rect.minX <= Self.cancelHitWidth {
                model.cancelRecording()
            } else {
                model.toggleRecording()
            }
        case .finished, .failed:
            model.dismissPill()
        case .idle, .processing:
            break
        }
    }
}

private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PillHostingView: NSHostingView<PillView> {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        onClick?()
    }
}

struct PillView: View {
    static let height: CGFloat = 38
    /// Characters of live transcript kept laid out; the line shows the newest that fit its width.
    static let transcriptLength = 120

    let model: AppModel
    let state: PillState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentWidth: CGFloat = PillView.height

    /// The minimal style: the same content without glow, springs or flourishes.
    private var calm: Bool { model.settings.pillStyle == .minimal }

    var body: some View {
        // Expressive grows the pill out of a dot; minimal only fades it.
        let width = state.presented || calm ? max(Self.height, contentWidth) : Self.height
        ZStack {
            if !calm { glow(width: width) }
            Capsule()
                .fill(Color.black)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
                .overlay(holdRing)
                .frame(width: width, height: Self.height)
            // Anchored at the left edge, so the bars ride the capsule's edge as it grows instead of jumping to re-center
            // the moment a word is added.
            content
                .fixedSize()
                .padding(.horizontal, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .frame(width: width, height: Self.height, alignment: .leading)
                .clipShape(Capsule())
                .opacity(state.presented ? 1 : 0)
        }
        // A capture drops in from above: the pill gives under it and springs back once.
        .keyframeAnimator(initialValue: 0.0, trigger: state.bounce) { view, impact in
            view
                .scaleEffect(x: 1 + 0.025 * impact, y: 1 - 0.06 * impact)
                .offset(y: 2.5 * impact)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(reduceMotion || calm ? 0 : 1, duration: 0.06)
                SpringKeyframe(0, duration: 0.5, spring: Spring(response: 0.34, dampingRatio: 0.58))
            }
        }
        .scaleEffect(state.presented || calm ? 1 : 0.45)
        .opacity(state.presented ? 1 : 0)
        .animation(spring(response: 0.4, damping: 0.74), value: width)
        .animation(spring(response: 0.42, damping: 0.66), value: state.presented)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: width, initial: true) { state.capsuleWidth = width }
    }

    /// Calm keeps the timing, so the capsule and the ticker inside it move together, and drops the bounce.
    private func spring(response: Double, damping: Double) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return .spring(response: response, dampingFraction: calm ? 1 : damping)
    }

    // MARK: Content

    private var content: some View {
        let tail = model.live.tail(maxCharacters: Self.transcriptLength)
        let recording = model.phase == .recording
        let processing = model.phase == .processing
        return HStack(spacing: 8) {
            if state.hovering, recording {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(0.22)))
                    .transition(calm ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
            if case .failed = model.phase {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            } else if calm, case .finished(let message) = model.phase, message != AppModel.noSpeech {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            } else {
                BrandBars(levels: model.levels, mode: barsMode, calm: calm, active: state.presented)
            }
            if recording || processing {
                if tail.tokens.isEmpty {
                    if processing {
                        Text("Transcribing")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .modifier(Shimmer(active: !calm))
                            .opacity(calm ? 0.5 : 1)
                            .transition(.opacity)
                    }
                } else {
                    TranscriptLine(tokens: tail.tokens, landing: state.landing, calm: calm)
                        .modifier(Shimmer(active: processing && !calm))
                        .opacity(processing && calm ? 0.5 : 1)
                        .transition(calm ? .opacity : .blurRise)
                }
            }
            if recording, !model.captures.isEmpty {
                CaptureDeck(captures: model.captures, state: state, calm: calm)
                    .transition(calm ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
            switch model.phase {
            case .finished(let message):
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .transition(calm ? .opacity : .blurRise)
            case .failed(let message):
                Text(Self.shortened(message))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .transition(.opacity)
            case .idle, .recording, .processing:
                EmptyView()
            }
        }
        .animation(spring(response: 0.36, damping: 0.8), value: model.phase)
        .animation(spring(response: 0.3, damping: 0.8), value: state.hovering)
    }

    private var barsMode: BrandBars.Mode {
        switch model.phase {
        case .idle, .recording: .live
        case .processing: .working
        case .finished(let message): message == AppModel.noSpeech ? .rest : .logo
        case .failed: .rest
        }
    }

    // MARK: Decoration

    /// The icon's warm glow, breathing with the voice.
    private func glow(width: CGFloat) -> some View {
        let level = model.phase == .recording ? CGFloat(model.levels.suffix(3).max() ?? 0) : 0
        let base: Double = switch model.phase {
        case .recording: 0.2
        case .processing: 0.22
        case .finished(let message): message == AppModel.noSpeech ? 0 : 0.45
        case .idle, .failed: 0
        }
        return Capsule()
            .fill(LinearGradient(colors: Brand.gradient, startPoint: .leading, endPoint: .trailing))
            .frame(width: width * 0.9, height: Self.height * 0.75)
            .blur(radius: 14)
            .opacity(state.presented ? base + 0.55 * Double(level) : 0)
            .scaleEffect(x: 1 + 0.05 * level, y: 1 + (reduceMotion ? 0 : 0.5 * level))
            .animation(.easeOut(duration: 0.16), value: level)
            .animation(.easeInOut(duration: 0.3), value: base)
    }

    /// Push-to-talk: a warm rim while the record shortcut is held, a white one in the minimal style.
    private var holdRing: some View {
        Capsule()
            .strokeBorder(
                calm ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(LinearGradient(colors: Brand.gradient, startPoint: .leading, endPoint: .trailing)),
                lineWidth: 1.5
            )
            .opacity(model.holdingToTalk && model.phase == .recording ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: model.holdingToTalk)
    }

    private static func shortened(_ message: String) -> String {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return firstLine.count > 60 ? String(firstLine.prefix(59)) + "…" : firstLine
    }
}

// MARK: - Bars

/// The icon's waveform, alive: eight gradient bars on springs. They breathe in silence, wave while transcribing,
/// and settle into the icon itself, white mark included, when the prompt is done. Calm, they are white, follow
/// without overshooting and wave slowly.
private struct BrandBars: View {
    enum Mode: Equatable {
        case live
        case working
        case logo
        case rest
    }

    static let count = 8
    static let barWidth: CGFloat = 2.5
    static let gap: CGFloat = 1.5
    static let maxHeight: CGFloat = 16
    static let markGap: CGFloat = 4
    static let markWidth: CGFloat = 2.2
    static let markHeight: CGFloat = 19
    /// The icon's bar heights, left to right.
    static let logo: [CGFloat] = [0.22, 0.45, 0.78, 1.0, 0.62, 0.86, 0.40, 0.24]
    static let barsWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * gap

    let levels: [Float]
    let mode: Mode
    let calm: Bool
    let active: Bool
    @State private var physics = BarPhysics(count: BrandBars.count)

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            Canvas { graphics, size in
                let time = context.date.timeIntervalSinceReferenceDate
                physics.step(toward: targets(at: time), mode: mode, critical: calm, time: time)
                draw(in: &graphics, size: size, time: time)
            }
        }
        .frame(width: Self.barsWidth + (mode == .logo ? Self.markGap + Self.markWidth : 0), height: 22)
    }

    private func targets(at time: TimeInterval) -> [CGFloat] {
        (0..<Self.count).map { index in
            let i = Double(index)
            switch mode {
            case .live:
                let breath = 0.24 + 0.08 * sin(time * 2.4 + i * 0.75)
                let level = index < levels.count ? CGFloat(levels[index]) : 0
                return max(CGFloat(breath), level * 0.95 + 0.05)
            case .working:
                return calm ? CGFloat(0.3 + 0.1 * sin(time * 2.6 - i * 0.7)) : CGFloat(0.32 + 0.26 * sin(time * 5 - i * 0.7))
            case .logo:
                return Self.logo[index]
            case .rest:
                return 0.12
            }
        }
    }

    private func draw(in graphics: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let midY = size.height / 2
        var bars = Path()
        for (index, height) in physics.heights.enumerated() {
            let barHeight = max(Self.barWidth, min(1.25, height) * Self.maxHeight)
            let x = CGFloat(index) * (Self.barWidth + Self.gap)
            bars.addRoundedRect(
                in: CGRect(x: x, y: midY - barHeight / 2, width: Self.barWidth, height: barHeight),
                cornerSize: CGSize(width: Self.barWidth / 2, height: Self.barWidth / 2)
            )
        }
        graphics.opacity = mode == .rest ? 0.5 : 1
        graphics.fill(bars, with: calm ? .color(.white.opacity(0.85)) : .linearGradient(
            Gradient(colors: Brand.gradient),
            startPoint: CGPoint(x: 0, y: midY - Self.maxHeight / 2),
            endPoint: CGPoint(x: 0, y: midY + Self.maxHeight / 2)
        ))
        guard mode == .logo else { return }
        // The icon's white mark pops up after the bars start settling.
        let progress = min(1, max(0, (time - physics.modeStart - 0.12) / 0.34))
        let markHeight = Self.markHeight * Self.easeOutBack(progress)
        guard markHeight > 0.5 else { return }
        graphics.opacity = 0.94
        graphics.fill(
            Path(roundedRect: CGRect(x: Self.barsWidth + Self.markGap, y: midY - markHeight / 2, width: Self.markWidth, height: markHeight), cornerRadius: Self.markWidth / 2),
            with: .color(.white)
        )
    }

    private static func easeOutBack(_ t: Double) -> Double {
        let c = 1.9
        let x = t - 1
        return 1 + (c + 1) * x * x * x + c * x * x
    }
}

/// Per-bar damped springs, stepped once per frame by the bars' timeline.
private final class BarPhysics {
    private(set) var heights: [CGFloat]
    private var velocities: [CGFloat]
    private var lastTime: TimeInterval?
    private var mode: BrandBars.Mode?
    private(set) var modeStart: TimeInterval = 0

    init(count: Int) {
        heights = Array(repeating: 0.12, count: count)
        velocities = Array(repeating: 0, count: count)
    }

    /// `critical` damps every mode critically, so bars follow without overshooting.
    func step(toward targets: [CGFloat], mode: BrandBars.Mode, critical: Bool, time: TimeInterval) {
        if mode != self.mode {
            self.mode = mode
            modeStart = time
        }
        // Stiffness and damping: a lively overshoot for the voice, a smooth follow for the wave, a bouncy settle into
        // the logo.
        let (stiffness, bouncyDamping): (CGFloat, CGFloat) = switch mode {
        case .live: (650, 23)
        case .working: (380, 39)
        case .logo: (320, 13)
        case .rest: (300, 32)
        }
        let damping = critical ? 2 * stiffness.squareRoot() : bouncyDamping
        var remaining = CGFloat(min(max(0, time - (lastTime ?? time)), 1.0 / 20))
        lastTime = time
        let step: CGFloat = 1.0 / 240
        while remaining > 0 {
            let dt = min(step, remaining)
            remaining -= dt
            for index in heights.indices {
                let acceleration = stiffness * (targets[index] - heights[index]) - damping * velocities[index]
                velocities[index] += acceleration * dt
                heights[index] += velocities[index] * dt
            }
        }
    }
}

// MARK: - Transcript

/// The live transcript as a ticker: new words appear at the right edge, out of a blur unless calm, and push older
/// ones out under a fade at the left. Captures appear inline as "figure N" chips.
private struct TranscriptLine: View {
    static let maxWidth: CGFloat = 280
    static let spacing: CGFloat = 3.5
    private static let wordFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let markerFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    let tokens: [LiveTranscript.Token]
    let landing: Set<UUID>
    let calm: Bool
    @State private var memory = Memory()

    /// What the line looked like at the last update. Deliberately not observed: it only informs the next update.
    private final class Memory {
        /// Each token's distance from the line's right edge.
        var distances: [Int: CGFloat] = [:]
        var frameWidth: CGFloat = 0
        /// How far right each token started when it was added, kept so it doesn't change mid-entrance.
        var offsets: [Int: CGFloat] = [:]
    }

    var body: some View {
        let visible = tokens.filter { token in
            if case .marker(let capture, _) = token.kind { return !landing.contains(capture) }
            return true
        }
        let widths = visible.map(Self.width(of:))
        let lineWidth = max(0, widths.reduce(0) { $0 + $1 + Self.spacing } - Self.spacing)
        let frameWidth = min(lineWidth, Self.maxWidth)
        let offsets = entranceOffsets(visible, widths: widths, frameWidth: frameWidth)
        HStack(spacing: Self.spacing) {
            ForEach(visible) { token in
                let arrival = AnyTransition.offset(x: offsets[token.id] ?? 0)
                switch token.kind {
                case .word(let text):
                    Text(text)
                        .font(Font(Self.wordFont))
                        .foregroundStyle(.white.opacity(0.92))
                        .transition(.asymmetric(insertion: arrival.combined(with: calm ? .opacity : .blurRise), removal: .opacity))
                case .marker(_, let label):
                    MarkerChip(label: label, calm: calm)
                        .transition(.asymmetric(
                            insertion: arrival.combined(with: calm ? .opacity : .scale(scale: 0.6).combined(with: .opacity)),
                            removal: .opacity
                        ))
                }
            }
        }
        .fixedSize()
        // Room above and below for words rising out of their blur.
        .padding(.vertical, 8)
        .frame(width: frameWidth, alignment: .trailing)
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: lineWidth > Self.maxWidth ? 32 : 0)
                Rectangle()
            }
        }
        .padding(.vertical, -8)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: visible.map(\.id))
    }

    /// Where new tokens start, relative to where they end up: as far right as the older word before them is about to
    /// move left, so they arrive attached to it instead of sliding over it. Measured here rather than read back from
    /// layout, which would come a frame late.
    private func entranceOffsets(_ visible: [LiveTranscript.Token], widths: [CGFloat], frameWidth: CGFloat) -> [Int: CGFloat] {
        var distances: [Int: CGFloat] = [:]
        var run: CGFloat = 0
        for (token, width) in zip(visible, widths).reversed() {
            distances[token.id] = run
            run += width + Self.spacing
        }
        var offsets: [Int: CGFloat] = [:]
        // The line is right-aligned in a frame whose left edge stays put, so a token moves left by how much more
        // follows it, less how much the frame grew.
        var leftward: CGFloat = 0
        for token in visible {
            if let before = memory.distances[token.id], let after = distances[token.id] {
                leftward = (after - before) - (frameWidth - memory.frameWidth)
            } else {
                offsets[token.id] = max(0, leftward)
            }
        }
        // A token keeps its offset while it's on the line, so a re-render mid-entrance can't change it.
        memory.offsets = memory.offsets.merging(offsets) { kept, _ in kept }.filter { distances[$0.key] != nil }
        memory.distances = distances
        memory.frameWidth = frameWidth
        return memory.offsets
    }

    private static func width(of token: LiveTranscript.Token) -> CGFloat {
        switch token.kind {
        case .word(let text):
            ceil((text as NSString).size(withAttributes: [.font: wordFont]).width)
        case .marker(_, let label):
            ceil((label as NSString).size(withAttributes: [.font: markerFont]).width) + 12
        }
    }
}

private struct MarkerChip: View {
    let label: String
    let calm: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .fixedSize()
            .foregroundStyle(calm ? .white.opacity(0.9) : .black.opacity(0.85))
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(calm ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(LinearGradient(colors: Brand.gradient, startPoint: .top, endPoint: .bottom))))
    }
}

/// A band of full opacity sweeping over dimmed content while the transcript is finalized.
private struct Shimmer: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.mask {
            if active {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.4), location: 0),
                            .init(color: .black, location: 0.5),
                            .init(color: .black.opacity(0.4), location: 1),
                        ],
                        startPoint: UnitPoint(x: phase * 2.4 - 1.2, y: 0.5),
                        endPoint: UnitPoint(x: phase * 2.4 - 0.2, y: 0.5)
                    )
                }
            } else {
                Rectangle()
            }
        }
    }
}

private struct BlurRise: ViewModifier {
    /// 0 is in place, 1 is gone.
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: 5 * amount)
            .opacity(1 - amount)
            .offset(y: 5 * amount)
    }
}

extension AnyTransition {
    fileprivate static var blurRise: AnyTransition {
        .modifier(active: BlurRise(amount: 1), identity: BlurRise(amount: 0))
    }
}

// MARK: - Captures

/// The newest captures as a small fanned deck, newest on top, with a rolling count of the older ones in front.
private struct CaptureDeck: View {
    private static let visible = 4
    let captures: [CaptureEvent]
    let state: PillState
    /// Straight and without springs, for the minimal style.
    let calm: Bool

    var body: some View {
        let shown = Array(captures.suffix(Self.visible))
        let older = captures.count - shown.count
        HStack(spacing: -7) {
            if older > 0 {
                Text("+\(older)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.78))
                    .contentTransition(.numericText(value: Double(older)))
                    .padding(.trailing, 11)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, capture in
                CaptureChip(content: capture.content, inFlight: state.landing.contains(capture.id))
                    .rotationEffect(.degrees(calm ? 0 : Self.tilt(fromNewest: shown.count - 1 - index)))
                    .zIndex(Double(index))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        state.chipFrames[capture.id] = frame
                    }
                    .transition(calm ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: calm ? 1 : 0.68), value: captures.map(\.id))
        .animation(.spring(response: 0.38, dampingFraction: calm ? 1 : 0.68), value: older)
    }

    private static func tilt(fromNewest position: Int) -> Double {
        [0, -6, 5, -8][min(position, 3)]
    }
}

private struct CaptureChip: View {
    static let size = CGSize(width: 30, height: 22)
    let content: CaptureEvent.Content
    /// Hidden while its flight is on the way. The flight ends exactly on top of it, so it appears without a fade and
    /// only takes the impact: pressed in like a pin, with a glint.
    let inFlight: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            switch content {
            case .image(let path):
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.25)
                }
                Color.clear.task(id: path) {
                    image = await ThumbnailCache.shared.image(path: path, maxPixel: 96)
                }
            case .text:
                symbol("text.alignleft")
            case .files:
                symbol("doc.fill")
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white)
                .keyframeAnimator(initialValue: 0.0, trigger: inFlight) { flash, opacity in
                    flash.opacity(opacity)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(inFlight ? 0 : 0.35, duration: 0.01)
                        LinearKeyframe(0, duration: 0.25)
                    }
                }
        }
        .shadow(color: .black.opacity(0.6), radius: 1.5, x: -1, y: 0)
        .keyframeAnimator(initialValue: 1.0, trigger: inFlight) { chip, scale in
            chip.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(inFlight ? 1 : 0.86, duration: 0.05)
                SpringKeyframe(1, duration: 0.4, spring: Spring(response: 0.28, dampingRatio: 0.6))
            }
        }
        .opacity(inFlight ? 0 : 1)
    }

    private func symbol(_ name: String) -> some View {
        ZStack {
            Color(white: 0.24)
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
