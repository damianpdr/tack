import Foundation

/// Turns microphone loudness into a 0...1 bar height that reads the same whether the speaker leans into the mic or
/// talks from across the room: a decibel scale whose top follows the voice.
public struct VoiceMeter: Sendable {
    /// Room noise on a built-in mic sits around here; anything quieter reads as nothing.
    static let silence: Float = -58
    /// The top of the scale never sinks below this, so in a quiet room noise isn't blown up into speech…
    static let quietestTop: Float = -40
    /// …and never rises above this, so a shout doesn't flatten everything after it.
    static let loudestTop: Float = -16
    /// How fast the top sinks back after something loud, in decibels per second.
    static let release: Float = 8

    private var top: Float = -32

    public init() {}

    /// The bar height for one window of audio with root mean square `rms`, `interval` seconds after the previous.
    public mutating func level(rms: Float, interval: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-6))
        top = min(Self.loudestTop, max(Self.quietestTop, decibels, top - Self.release * interval))
        let position = min(1, max(0, (decibels - Self.silence) / (top - Self.silence)))
        // Expanded, so the pauses between words drop away and the words stand up.
        return pow(position, 1.6)
    }
}
