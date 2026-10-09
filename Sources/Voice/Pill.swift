import AppKit
import Observation
import SwiftUI
import VoiceCore

@MainActor @Observable
final class PillState {
    var hovering = false
}

/// Floating recording indicator. Never becomes key, so the user's app keeps focus.
@MainActor
final class PillController {
    private static let bottomMargin: CGFloat = 24
    private static let cancelHitWidth: CGFloat = 34

    private let model: AppModel
    private let state = PillState()
    private let panel: PillPanel
    private let hostingView: PillHostingView
    private var size = CGSize(width: 60, height: PillView.height)
    private var screen: NSScreen?

    init(model: AppModel) {
        self.model = model
        panel = PillPanel(
            contentRect: NSRect(origin: .zero, size: size),
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

        hostingView = PillHostingView(rootView: PillView(model: model, state: state))
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView

        hostingView.onContentSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.fitContent() }
        }
        hostingView.onHover = { [weak self] hovering in self?.state.hovering = hovering }
        hostingView.onClick = { [weak self] x in self?.click(atX: x) }
    }

    func show() {
        guard !panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        state.hovering = false
        fitContent()
        position()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        state.hovering = false
    }

    private func fitContent() {
        let newSize = hostingView.intrinsicContentSize
        guard newSize.width > 0, newSize.height > 0, newSize != size else { return }
        size = newSize
        position()
    }

    private func position() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = CGPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + Self.bottomMargin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func click(atX x: CGFloat) {
        switch model.phase {
        case .recording:
            if state.hovering, x <= Self.cancelHitWidth {
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
    var onHover: ((Bool) -> Void)?
    var onClick: ((CGFloat) -> Void)?
    var onContentSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?(point.x)
    }
}

struct PillView: View {
    static let height: CGFloat = 38

    let model: AppModel
    let state: PillState

    var body: some View {
        HStack(spacing: 6) {
            content
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Capsule().fill(Color.black))
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .recording:
            if state.hovering, model.phase == .recording {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(0.22)))
            }
            LevelBars(levels: model.levels)
            CaptureMarks(count: model.captures.count)
        case .processing:
            WaveBars()
        case .finished(let message):
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        case .failed(let message):
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            Text(Self.shortened(message))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private static func shortened(_ message: String) -> String {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return firstLine.count > 60 ? String(firstLine.prefix(59)) + "…" : firstLine
    }
}

private struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Bar(level: CGFloat(level))
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

private struct WaveBars: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<AppModel.levelCount, id: \.self) { index in
                    Bar(level: 0.3 + 0.25 * CGFloat(sin(time * 5 - Double(index) * 0.7)))
                }
            }
            .frame(height: 14)
        }
    }
}

private struct Bar: View {
    let level: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.5 + 0.5 * level))
            .frame(width: 2, height: max(2, level * 14))
    }
}

private struct CaptureMarks: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 3) {
                ForEach(0..<min(count, 3), id: \.self) { _ in
                    Text("|")
                }
                if count > 3 {
                    Text("+\(count - 3)")
                }
            }
            .font(.system(size: 11, weight: .light))
            .foregroundStyle(Color.white.opacity(0.78))
            .transition(.opacity)
        }
    }
}
