import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers

/// Swallows ⌃⌥-clicks while recording and reports where they landed, so pointing at something never presses it.
/// Needs Accessibility access, like pasting.
@MainActor
final class PointerTap {
    /// Global point of each ⌃⌥-click, top-left origin (Core Graphics).
    var onPoint: ((CGPoint) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// A ⌃⌥ mouse-down was swallowed; its drags and mouse-up go too, even if the keys are let go first.
    private var swallowing = false

    var isRunning: Bool { tap != nil }

    /// False when macOS refuses the tap, which happens without Accessibility access.
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: pointerTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        swallowing = false
    }

    /// True swallows the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown:
            let modifiers = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            guard modifiers == [.maskControl, .maskAlternate] else { return false }
            swallowing = true
            let point = event.location
            // Return to the event system first; the capture takes a moment.
            Task { @MainActor in self.onPoint?(point) }
            return true
        case .leftMouseDragged, .leftMouseUp:
            guard swallowing else { return false }
            if type == .leftMouseUp { swallowing = false }
            return true
        default:
            return false
        }
    }
}

/// The tap's run loop source is on the main run loop, so this runs on the main thread.
private func pointerTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<PointerTap>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { tap.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// The window under a ⌃⌥-click, captured with what was clicked marked on it, and a line saying what that is.
enum PointerCapture {
    struct Shot {
        /// The window on screen, AppKit coordinates, for the flight into the pill.
        let rect: CGRect
        let appName: String
        /// What the mark is on, e.g. `button "Save changes" in Safari, http://localhost:3000/settings`.
        let pointer: String
    }

    /// Writes the marked window to `url` as PNG. Nil when there is no window under `point` or the capture fails.
    @MainActor
    static func capture(at point: CGPoint, to url: URL) async -> Shot? {
        guard let window = window(at: point) else { return nil }
        let pid = window.pid
        let lookup = Task.detached(priority: .userInitiated) { element(at: point, pid: pid) }
        await run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(window.id), url.path])
        let element = await lookup.value
        guard let image = loadImage(url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let marked = mark(image, window: window.bounds, point: point, element: element?.frame)
        guard let marked, write(marked, to: url) else { return nil }
        return Shot(
            rect: appKitRect(window.bounds),
            appName: window.appName,
            pointer: describe(element, appName: window.appName, windowTitle: window.title)
        )
    }

    // MARK: Window

    private struct Window {
        let id: CGWindowID
        let pid: pid_t
        /// Top-left origin (Core Graphics).
        let bounds: CGRect
        let appName: String
        let title: String?
    }

    /// The frontmost ordinary window under `point` that is not Tack's own, such as the pill.
    private static func window(at point: CGPoint) -> Window? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo), bounds.contains(point),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            let appName = info[kCGWindowOwnerName as String] as? String
                ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? "an app"
            return Window(id: id, pid: pid, bounds: bounds, appName: appName, title: info[kCGWindowName as String] as? String)
        }
        return nil
    }

    // MARK: Accessibility

    private struct Element {
        /// Plain English, e.g. "button", "link", "text"; nil for containers that say nothing.
        let kind: String?
        let label: String?
        /// Top-left origin (Core Graphics).
        let frame: CGRect?
        let url: String?
    }

    /// Roles worth naming instead of the text or image inside them.
    private static let controlRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXCell",
        "AXHeading",
    ]
    /// Roles that are layout, not something one points at.
    private static let containerRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWebArea", "AXWindow", "AXLayoutArea", "AXLayoutItem",
        "AXUnknown", "AXApplication", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXSplitter", "AXToolbar",
    ]

    /// Chrome and Electron apps build their page tree only once something asks for it, so a first look can find
    /// nothing but layout. Looks again for up to half a second before settling for that.
    private static func element(at point: CGPoint, pid: pid_t) -> Element? {
        var found: Element?
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
            found = hitTest(point, pid: pid) ?? found
            if let found, found.kind != nil || found.label != nil || found.url != nil { break }
        }
        return found
    }

    /// Blocking Accessibility calls, each capped at a quarter second so a hung app can't stall the capture.
    private static func hitTest(_ point: CGPoint, pid: pid_t) -> Element? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }

        var ancestors = [hit]
        while ancestors.count < 4, let parent: AXUIElement = attribute(ancestors[ancestors.count - 1], kAXParentAttribute) {
            ancestors.append(parent)
        }
        let target = ancestors.first { role(of: $0).map(controlRoles.contains) ?? false } ?? hit
        let targetRole = role(of: target) ?? ""
        let label = label(of: target) ?? label(of: hit) ?? childText(of: target)
        let kind = containerRoles.contains(targetRole) ? nil : kind(of: targetRole)
        return Element(kind: kind, label: label, frame: frame(of: target), url: pageURL(above: hit))
    }

    private static func role(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        return attribute(element, kAXRoleAttribute)
    }

    /// "AXPopUpButton" → "pop up button", with a few names made friendlier.
    private static func kind(of role: String) -> String? {
        guard role.hasPrefix("AX"), role.count > 2 else { return nil }
        var words: [String] = []
        for character in role.dropFirst(2) {
            if character.isUppercase || words.isEmpty { words.append("") }
            words[words.count - 1].append(character)
        }
        let name = words.joined(separator: " ").lowercased()
        return ["static text": "text", "check box": "checkbox", "pop up button": "pop-up button"][name] ?? name
    }

    /// The page or window title would only repeat the address or window name that ends the line.
    private static func label(of element: AXUIElement) -> String? {
        let role = role(of: element)
        guard role != "AXWebArea", role != kAXWindowRole else { return nil }
        var names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
        // The screenshot shows a field's value anyway; macOS hides passwords, but don't even ask.
        if (attribute(element, kAXSubroleAttribute) as String?) != kAXSecureTextFieldSubrole { names.append(kAXValueAttribute) }
        names.append(kAXHelpAttribute)
        for name in names {
            if let text: String = attribute(element, name), let label = tidy(text) { return label }
        }
        return nil
    }

    /// Web buttons, links and headings often carry their words in a text child rather than a title.
    private static func childText(of element: AXUIElement) -> String? {
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children.prefix(5) where role(of: child) == kAXStaticTextRole {
            if let text: String = attribute(child, kAXValueAttribute), let label = tidy(text) { return label }
        }
        return nil
    }

    /// One line, at most 80 characters.
    private static func tidy(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// The address of the web page containing `element`, from the browser's web area.
    private static func pageURL(above element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let element = current else { return nil }
            if role(of: element) == "AXWebArea" {
                guard let url: URL = attribute(element, kAXURLAttribute),
                      ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
                else { return nil }
                return url.absoluteString
            }
            current = attribute(element, kAXParentAttribute)
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// `button "Save changes" in Safari, http://localhost:3000/settings`; the window title stands in for the address
    /// outside browsers.
    private static func describe(_ element: Element?, appName: String, windowTitle: String?) -> String {
        let what = switch (element?.kind, element?.label) {
        case let (kind?, label?): "\(kind) \"\(label)\""
        case let (nil, label?): "\"\(label)\""
        case let (kind?, nil): kind
        case (nil, nil): "the marked spot"
        }
        if let url = element?.url { return "\(what) in \(appName), \(url)" }
        if let title = windowTitle.flatMap(tidy), title != appName { return "\(what) in \(appName), window \"\(title)\"" }
        return "\(what) in \(appName)"
    }

    // MARK: Picture

    /// Outlines the clicked element, or rings the click when the element is unknown or most of the window.
    private static func mark(_ image: CGImage, window: CGRect, point: CGPoint, element: CGRect?) -> CGImage? {
        let scale = CGFloat(image.width) / window.width
        let size = CGSize(width: image.width, height: image.height)
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        // Window points, top-left origin, like the screen coordinates the rects come in.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -window.minX, y: -window.minY)

        let path: CGPath
        if let element, element.contains(point), element.width >= 4, element.height >= 4,
           element.width <= window.width * 0.6, element.height <= window.height * 0.5 {
            let outline = element.insetBy(dx: -4, dy: -4)
            path = CGPath(roundedRect: outline, cornerWidth: 6, cornerHeight: 6, transform: nil)
        } else {
            path = CGPath(ellipseIn: CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), transform: nil)
        }
        context.setLineJoin(.round)
        for (color, width) in [(NSColor.white, 6.3), (NSColor.systemRed, 3.0)] {
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }
        return context.makeImage()
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func appKitRect(_ rect: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func run(_ executable: String, _ arguments: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                NSLog("Tack: screencapture failed to launch: \(error.localizedDescription)")
                continuation.resume()
            }
        }
    }
}
