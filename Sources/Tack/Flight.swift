import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import TackCore

/// Where a capture flies into the pill from.
enum FlightOrigin {
    /// The exact on-screen rect that was captured (AppKit coordinates).
    case rect(CGRect)
    /// Around the mouse pointer, for clipboard copies.
    case mouse
    /// Where macOS shows its floating screenshot thumbnail.
    case screenshotThumbnail
}

/// Short-lived overlay animations between the screen and the pill. Each flight gets its own transparent,
/// click-through window covering just its path, closed when it lands.
@MainActor
enum Flight {
    private static var windows: [NSWindow] = []

    // MARK: Captures into the pill

    /// The picture that flies for a capture: a downscaled screenshot, or a small card for copied text and files.
    static func image(for content: CaptureEvent.Content) async -> CGImage? {
        switch content {
        case .image(let path):
            return await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
        case .text(let text):
            return card(symbol: "text.alignleft", text: text)
        case .files(let paths):
            return card(symbol: "doc.fill", text: paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        }
    }

    /// Screen rect a picture of `pixelSize` starts from.
    static func sourceRect(_ origin: FlightOrigin, pixelSize: CGSize) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        switch origin {
        case .rect(let rect):
            return rect
        case .mouse:
            let size = fit(pixelSize, in: CGSize(width: 180, height: 120))
            var rect = CGRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height)
            rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - size.width)
            rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - size.height)
            return rect
        case .screenshotThumbnail:
            let size = fit(pixelSize, in: CGSize(width: 200, height: 140))
            return CGRect(x: visible.maxX - 18 - size.width, y: visible.minY + 18, width: size.width, height: size.height)
        }
    }

    /// Lifts `image` off `source` and sends it along a swoop into `target`, the thumbnail's slot in the pill. It ends
    /// as an exact copy of the thumbnail (size, crop, corners, rim, shadow), so when `landed` swaps the real one in
    /// there is nothing to see but the impact.
    static func capture(_ image: CGImage, from source: CGRect, to target: CGRect, landed: @escaping @MainActor () -> Void) {
        let lift = 0.06
        let total = 0.34
        // A swoop: it sets off sideways, with a small hop when there's room for one, and drops into the slot from above.
        let across = target.midX - source.midX
        let control = CGPoint(x: source.midX + across * 0.6, y: max(source.midY, target.midY) + min(60, abs(across) * 0.15))
        let bounds = source.union(target).union(CGRect(origin: control, size: .zero)).insetBy(dx: -60, dy: -60).integral
        guard let root = overlay(covering: bounds) else { landed(); return }
        let local = { (point: CGPoint) in CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY) }
        let start = local(CGPoint(x: source.midX, y: source.midY))
        let end = local(CGPoint(x: target.midX, y: target.midY))
        let bend = local(control)

        let card = CALayer()
        card.shadowColor = NSColor.black.cgColor
        let picture = CALayer()
        picture.contents = image
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.borderWidth = 0.5
        picture.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        let veil = CALayer()
        veil.backgroundColor = NSColor.white.cgColor
        picture.addSublayer(veil)
        card.addSublayer(picture)
        root.addSublayer(card)

        // Every property follows the same clock, sampled per frame, so position, size and shadow can't drift apart.
        var positions: [CGPoint] = [], sizes: [CGRect] = [], centers: [CGPoint] = [], corners: [CGFloat] = []
        var shadowPaths: [CGPath] = [], shadowOpacities: [Float] = [], shadowRadii: [CGFloat] = [], shadowOffsets: [CGSize] = []
        var flashes: [Float] = []
        let steps = Int(total * 120)
        for step in 0...steps {
            let t = total * Double(step) / Double(steps)
            // A critically damped spring aimed a little past the slot: up to speed while it lifts, then easing in,
            // still moving gently when it drops in, which the pill absorbs.
            let s = settle(4 * t / total) / settle(4)
            let position = CGPoint(
                x: (1 - s) * (1 - s) * start.x + 2 * s * (1 - s) * bend.x + s * s * end.x,
                y: (1 - s) * (1 - s) * start.y + 2 * s * (1 - s) * bend.y + s * s * end.y
            )
            // Shrinks with the distance covered, at an even pace to the eye (geometrically), trailing a little at
            // first so the lift-off reads; width and height separately, so the crop eases into the thumbnail's.
            let shrink = pow(s, 1.25)
            let rise = sin(.pi / 2 * min(1, t / lift))
            let size = CGSize(
                width: source.width * pow(target.width / source.width, shrink),
                height: source.height * pow(target.height / source.height, shrink)
            )
            let corner = min(8 * rise * (1 - shrink) + 4 * shrink, min(size.width, size.height) / 2)
            let rect = CGRect(origin: .zero, size: size)
            positions.append(position)
            sizes.append(rect)
            centers.append(CGPoint(x: size.width / 2, y: size.height / 2))
            corners.append(corner)
            shadowPaths.append(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            // Lifted: a deep soft shadow; landed: the thumbnail's tight one.
            shadowOpacities.append(Float(0.4 * rise * (1 - shrink) + 0.6 * shrink))
            shadowRadii.append(16 * (1 - shrink) + 1.5 * shrink)
            shadowOffsets.append(CGSize(width: -shrink, height: -8 * (1 - shrink)))
            // The shutter: a white veil on instantly, gone within a tenth of a second.
            flashes.append(Float(t < 0.025 ? 0.3 * t / 0.025 : 0.3 * exp(-(t - 0.025) / 0.04)))
        }

        func track(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.calculationMode = .linear
            return animation
        }
        func run(_ animations: [CAAnimation], on layer: CALayer) {
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = total
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "flight")
        }
        let sizeValues = sizes.map { NSValue(rect: $0) }
        let centerValues = centers.map { NSValue(point: $0) }
        card.position = positions[0]
        card.bounds = sizes[0]
        picture.frame = sizes[0]
        veil.frame = sizes[0]
        veil.opacity = 0
        run([
            track("position", positions.map { NSValue(point: $0) }),
            track("bounds", sizeValues),
            track("shadowPath", shadowPaths),
            track("shadowOpacity", shadowOpacities),
            track("shadowRadius", shadowRadii),
            track("shadowOffset", shadowOffsets.map { NSValue(size: $0) }),
        ], on: card)
        run([track("bounds", sizeValues), track("position", centerValues), track("cornerRadius", corners)], on: picture)
        run([track("bounds", sizeValues), track("position", centerValues), track("opacity", flashes)], on: veil)

        after(total, landed)
        after(total + 0.03) { close(root) }
    }

    // MARK: Delivery to the agent

    /// A glowing packet thrown from the pill to `point`, landing with a ripple. `landing` fires `lead` seconds before
    /// it arrives, so a sound can be timed to hit with it.
    static func deliver(from source: CGRect, to point: CGPoint, lead: TimeInterval, landing: @escaping @MainActor () -> Void) {
        let duration = 0.5
        let start = CGPoint(x: source.midX, y: source.maxY - 4)
        let distance = hypot(point.x - start.x, point.y - start.y)
        // Always a visible hop, even when the input sits right under the pill.
        let control = CGPoint(x: (start.x + point.x) / 2, y: max(start.y, point.y) + max(90, min(160, distance * 0.3)))
        let bounds = CGRect(origin: start, size: .zero)
            .union(CGRect(origin: point, size: .zero))
            .union(CGRect(origin: control, size: .zero))
            .insetBy(dx: -90, dy: -90)
            .integral
        guard let root = overlay(covering: bounds) else { landing(); return }
        let local = { (p: CGPoint) in CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY) }
        let scaleFactor = root.contentsScale

        let packet = CAGradientLayer()
        packet.colors = [Brand.top.cgColor, Brand.bottom.cgColor]
        packet.startPoint = CGPoint(x: 0, y: 0.5)
        packet.endPoint = CGPoint(x: 1, y: 0.5)
        packet.bounds = CGRect(x: 0, y: 0, width: 46, height: 12)
        packet.cornerRadius = 6
        packet.position = local(start)
        packet.shadowColor = Brand.glow.cgColor
        packet.shadowOpacity = 0.9
        packet.shadowRadius = 9
        packet.shadowOffset = .zero
        packet.contentsScale = scaleFactor

        // Delayed, fading copies of the packet make a short comet tail.
        let trail = CAReplicatorLayer()
        trail.frame = CGRect(origin: .zero, size: bounds.size)
        trail.instanceCount = 6
        trail.instanceDelay = 0.022
        trail.instanceAlphaOffset = -0.16
        trail.addSublayer(packet)
        root.addSublayer(trail)

        let path = CGMutablePath()
        path.move(to: local(start))
        path.addQuadCurve(to: local(point), control: local(control))
        let throwCurve = CAMediaTimingFunction(controlPoints: 0.35, 0, 0.25, 1)
        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path
        position.timingFunction = throwCurve
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.toValue = CGSize(width: 10, height: 10)
        size.timingFunction = throwCurve
        let corner = CABasicAnimation(keyPath: "cornerRadius")
        corner.toValue = 5
        let group = CAAnimationGroup()
        group.animations = [position, size, corner]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        packet.add(group, forKey: "throw")

        after(max(0, duration - lead), landing)
        after(duration) {
            trail.removeFromSuperlayer()
            ripple(in: root, at: local(point))
        }
        after(duration + 0.6) { close(root) }
    }

    private static func ripple(in root: CALayer, at center: CGPoint) {
        for (index, color) in [Brand.glow, NSColor.white].enumerated() {
            let ring = CAShapeLayer()
            ring.contentsScale = root.contentsScale
            ring.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
            ring.position = center
            ring.fillColor = nil
            ring.strokeColor = color.withAlphaComponent(index == 0 ? 0.95 : 0.6).cgColor
            ring.lineWidth = 2
            ring.opacity = 0
            root.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.3
            grow.toValue = 3.2
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 0.5
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.08
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "ripple")
        }
        let spark = CALayer()
        spark.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        spark.cornerRadius = 6
        spark.position = center
        spark.backgroundColor = Brand.top.cgColor
        spark.shadowColor = Brand.glow.cgColor
        spark.shadowOpacity = 1
        spark.shadowRadius = 10
        spark.shadowOffset = .zero
        spark.opacity = 0
        root.addSublayer(spark)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.35
        spark.add(fade, forKey: "fade")
    }

    // MARK: Plumbing

    /// `rect` should be integral, so layer coordinates are exactly screen coordinates minus its origin.
    private static func overlay(covering rect: CGRect) -> CALayer? {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return nil }
        let window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
        let root = CALayer()
        root.contentsScale = screen.backingScaleFactor
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        windows.append(window)
        return root
    }

    private static func close(_ root: CALayer) {
        guard let index = windows.firstIndex(where: { $0.contentView?.layer === root }) else { return }
        windows.remove(at: index).orderOut(nil)
    }

    private static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }

    /// How far a critically damped spring released from rest has gone, `x` being time times its natural frequency.
    private static func settle(_ x: Double) -> Double {
        1 - (1 + x) * exp(-x)
    }

    private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    private static func card(symbol: String, text: String) -> CGImage? {
        let renderer = ImageRenderer(content: FlightCard(symbol: symbol, text: text))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.cgImage
    }
}

/// What a copied snippet looks like on its way into the pill.
private struct FlightCard: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: Brand.bottom))
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.black.opacity(0.82))
                .lineLimit(3)
        }
        .padding(10)
        .frame(width: 190, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
    }
}
