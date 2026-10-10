import AppKit
import SwiftUI

/// The app icon's palette: the waveform's warm gradient and the glow behind it.
enum Brand {
    static let top = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.36, alpha: 1)
    static let bottom = NSColor(srgbRed: 1.0, green: 0.30, blue: 0.32, alpha: 1)
    static let glow = NSColor(srgbRed: 1.0, green: 0.38, blue: 0.25, alpha: 1)

    static var gradient: [Color] { [Color(nsColor: top), Color(nsColor: bottom)] }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
