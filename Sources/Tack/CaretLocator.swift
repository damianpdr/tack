import AppKit
import ApplicationServices

/// Where text pasted into the frontmost app will land, for the delivery animation.
enum CaretLocator {
    /// Screen point (AppKit coordinates) of the text insertion point, falling back to the focused element and then to
    /// the focused window. Nil without Accessibility access or when the app exposes none of them.
    @MainActor
    static func target() async -> CGPoint? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let pid = app.processIdentifier
        let screens = NSScreen.screens.map(\.frame)
        return await Task.detached(priority: .userInitiated) { lookup(pid: pid, screens: screens) }.value
    }

    /// Blocking Accessibility calls, each capped at a quarter second so a hung app can't stall the animation.
    private static func lookup(pid: pid_t, screens: [CGRect]) -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let element: AXUIElement = attribute(app, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(element, 0.25)
            if let caret = caretRect(of: element, screens: screens) {
                return CGPoint(x: caret.midX, y: caret.midY)
            }
            if let frame = frame(of: element, screens: screens) {
                return inputPoint(in: frame)
            }
        }
        if let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute), let frame = frame(of: window, screens: screens) {
            return inputPoint(in: frame)
        }
        return nil
    }

    private static func caretRect(of element: AXUIElement, screens: [CGRect]) -> CGRect? {
        guard let range: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return onScreen(appKitRect(rect), screens: screens)
    }

    private static func frame(of element: AXUIElement, screens: [CGRect]) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent),
              extent.width > 0, extent.height > 0
        else { return nil }
        return onScreen(appKitRect(CGRect(origin: origin, size: extent)), screens: screens)
    }

    /// A large element is usually a chat transcript or a terminal, whose input sits at the bottom.
    private static func inputPoint(in frame: CGRect) -> CGPoint {
        frame.height > 160 ? CGPoint(x: frame.midX, y: frame.minY + 48) : CGPoint(x: frame.midX, y: frame.midY)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Accessibility uses a top-left origin on the primary display; AppKit a bottom-left one.
    private static func appKitRect(_ rect: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Some apps report zero or off-screen rects for hidden carets.
    private static func onScreen(_ rect: CGRect, screens: [CGRect]) -> CGRect? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard rect != .zero, screens.contains(where: { $0.contains(center) }) else { return nil }
        return rect
    }
}
