import AppKit
import ImageIO
import SwiftUI

/// Experimental: mark a screenshot with arrows and rectangles before it joins a prompt.
/// Self-contained on purpose — deleting this file, `Settings.annotateScreenshots` and the
/// `annotate(path:)` call in `AppModel` removes the feature.
@MainActor
enum AnnotationEditor {
    /// Shows the editor for the PNG at `path`, overwriting it with the flattened marks when the
    /// user confirms. Skipping, closing the window or an unreadable file leave the PNG untouched.
    static func run(path: String) async {
        guard controller == nil, let image = loadImage(path: path) else { return }
        let controller = AnnotationWindowController(image: image)
        self.controller = controller
        defer { self.controller = nil }
        // The screenshot never activates Tack, so this is the app the user was working in.
        let previous = NSWorkspace.shared.frontmostApplication
        let shapes = await controller.show()
        if !shapes.isEmpty, let data = flatten(shapes, onto: image) {
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                NSLog("Tack: could not write annotated screenshot \(path): \(error.localizedDescription)")
            }
        }
        if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous?.activate() }
    }

    /// Only one editor at a time; a screenshot taken while it is open skips the mark-up pass.
    private static var controller: AnnotationWindowController?

    private static func loadImage(path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Strokes `shapes` (image-pixel coordinates, top-left origin) onto a copy of `image` as PNG data.
    static func flatten(_ shapes: [AnnotationShape], onto image: CGImage) -> Data? {
        let size = CGSize(width: image.width, height: image.height)
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        // Flip so shape coordinates match what the editor showed.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let width = AnnotationShape.strokeWidth(for: size)
        for shape in shapes {
            let path = shape.path(strokeWidth: width).cgPath
            context.addPath(path)
            context.setStrokeColor(AnnotationShape.outlineColor.cgColor)
            context.setLineWidth(width * AnnotationShape.outlineRatio)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(AnnotationShape.strokeColor.cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }
}

/// One mark, in image-pixel coordinates with a top-left origin.
struct AnnotationShape: Equatable {
    enum Tool: Hashable {
        case arrow
        case rectangle
    }

    static let strokeColor = NSColor.systemRed
    static let outlineColor = NSColor.white
    /// The white outline is drawn underneath as a wider stroke of the same path.
    static let outlineRatio: CGFloat = 2.1

    var tool: Tool
    var from: CGPoint
    var to: CGPoint

    /// Scales with the screenshot so a mark reads the same on a 4K grab and on a small region.
    static func strokeWidth(for size: CGSize) -> CGFloat {
        max(3, (min(size.width, size.height) * 0.005).rounded())
    }

    func path(strokeWidth: CGFloat) -> Path {
        switch tool {
        case .arrow: arrowPath(strokeWidth: strokeWidth)
        case .rectangle: Path(CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y)))
        }
    }

    private func arrowPath(strokeWidth: CGFloat) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        let dx = to.x - from.x, dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return path }
        let angle = atan2(dy, dx)
        // Short arrows keep a proportionally smaller head so it never swallows the shaft.
        let head = min(strokeWidth * 7, length * 0.45)
        let spread = 0.42
        for side in [-1.0, 1.0] {
            path.move(to: to)
            path.addLine(to: CGPoint(
                x: to.x - head * cos(angle + spread * side),
                y: to.y - head * sin(angle + spread * side)
            ))
        }
        return path
    }
}

/// Hosts `AnnotationView` in a key panel and resumes `show()` once the user is done.
@MainActor
private final class AnnotationWindowController: NSObject, NSWindowDelegate {
    private static let toolbarHeight: CGFloat = 44

    private let image: CGImage
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<[AnnotationShape], Never>?

    init(image: CGImage) {
        self.image = image
    }

    /// Returns the shapes to flatten, empty when the user skipped.
    func show() async -> [AnnotationShape] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: [])
    }

    private func present() {
        let pixelSize = CGSize(width: image.width, height: image.height)
        let displaySize = Self.displaySize(for: pixelSize)
        let view = AnnotationView(
            image: NSImage(cgImage: image, size: NSSize(width: pixelSize.width, height: pixelSize.height)),
            pixelSize: pixelSize,
            displaySize: displaySize,
            toolbarHeight: Self.toolbarHeight,
            onFinish: { [weak self] shapes in self?.finish(with: shapes) }
        )
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: displaySize.width, height: displaySize.height + Self.toolbarHeight)),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Mark up screenshot"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = controller
        panel.setContentSize(NSSize(width: displaySize.width, height: displaySize.height + Self.toolbarHeight))
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(with shapes: [AnnotationShape]) {
        guard let continuation else { return }
        self.continuation = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        continuation.resume(returning: shapes)
    }

    /// The image fits in 80% of the screen under the mouse, never scaled past its natural size.
    private static func displaySize(for pixelSize: CGSize) -> CGSize {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let scale = min(
            visible.width * 0.8 / pixelSize.width,
            max(visible.height * 0.8 - toolbarHeight, 120) / pixelSize.height,
            screen?.backingScaleFactor ?? 2
        )
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }
}

private struct AnnotationView: View {
    let image: NSImage
    let pixelSize: CGSize
    let displaySize: CGSize
    let toolbarHeight: CGFloat
    let onFinish: ([AnnotationShape]) -> Void

    @State private var tool: AnnotationShape.Tool = .arrow
    @State private var shapes: [AnnotationShape] = []
    @State private var draft: AnnotationShape?

    /// Display points per image pixel.
    private var scale: CGFloat { displaySize.width / pixelSize.width }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            Divider()
            toolbar
        }
        .frame(width: displaySize.width, height: displaySize.height + toolbarHeight)
    }

    private var canvas: some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: displaySize.width, height: displaySize.height)
            .overlay {
                Canvas { context, _ in
                    context.scaleBy(x: scale, y: scale)
                    let width = AnnotationShape.strokeWidth(for: pixelSize)
                    for shape in shapes + [draft].compactMap({ $0 }) {
                        let path = shape.path(strokeWidth: width)
                        context.stroke(path, with: .color(Color(AnnotationShape.outlineColor)), style: style(width * AnnotationShape.outlineRatio))
                        context.stroke(path, with: .color(Color(AnnotationShape.strokeColor)), style: style(width))
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        draft = AnnotationShape(tool: tool, from: pixel(value.startLocation), to: pixel(value.location))
                    }
                    .onEnded { value in
                        draft = nil
                        shapes.append(AnnotationShape(tool: tool, from: pixel(value.startLocation), to: pixel(value.location)))
                    }
            )
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Tool", selection: $tool) {
                Image(systemName: "arrow.up.right").tag(AnnotationShape.Tool.arrow)
                Image(systemName: "rectangle").tag(AnnotationShape.Tool.rectangle)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button("Undo") { shapes.removeLast() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(shapes.isEmpty)
            Text("Drag to draw")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Skip") { onFinish([]) }
                .keyboardShortcut(.cancelAction)
            Button("Done") { onFinish(shapes) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .frame(height: toolbarHeight)
    }

    private func style(_ lineWidth: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }

    /// Display point → image pixel, clamped to the image.
    private func pixel(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x / scale, 0), pixelSize.width),
            y: min(max(point.y / scale, 0), pixelSize.height)
        )
    }
}
