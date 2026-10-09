// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon grid: 824 pt squircle centred in 1024, with a soft drop shadow.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1),
        CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // Warm glow behind the waveform.
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1.0, green: 0.38, blue: 0.25, alpha: 0.40),
        CGColor(red: 1.0, green: 0.38, blue: 0.25, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512 * s, y: 470 * s), startRadius: 0,
                           endCenter: CGPoint(x: 512 * s, y: 470 * s), endRadius: 420 * s, options: [])
    ctx.restoreGState()

    // Waveform bars inside a pill, echoing the recording pill, followed by a capture tick.
    let bars: [CGFloat] = [0.22, 0.45, 0.78, 1.0, 0.62, 0.86, 0.40, 0.24]
    let barWidth: CGFloat = 46 * s
    let gap: CGFloat = 26 * s
    let maxHeight: CGFloat = 360 * s
    let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    let tickGap: CGFloat = 44 * s
    let tickWidth: CGFloat = 22 * s
    var x = 512 * s - (total + tickGap + tickWidth) / 2
    let midY = 512 * s
    let fill = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1.0, green: 0.62, blue: 0.36, alpha: 1),
        CGColor(red: 1.0, green: 0.30, blue: 0.32, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    for level in bars {
        let height = max(barWidth, level * maxHeight)
        let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    ctx.clip()
    ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: midY + maxHeight / 2), end: CGPoint(x: 0, y: midY - maxHeight / 2), options: [])
    ctx.restoreGState()

    // The `|` capture mark: a thin white tick, like a screenshot landing mid-sentence.
    x += tickGap - gap
    let tick = CGRect(x: x, y: midY - 150 * s, width: tickWidth, height: 300 * s)
    ctx.addPath(CGPath(roundedRect: tick, cornerWidth: tickWidth / 2, cornerHeight: tickWidth / 2, transform: nil))
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    ctx.fillPath()

    // Hairline rim.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s), cornerWidth: 184 * s, cornerHeight: 184 * s, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(3 * s)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! process.run()
process.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
