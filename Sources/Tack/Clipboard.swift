import AppKit

/// All pasteboard writes by Tack go through here so `ClipboardMonitor` can skip them.
@MainActor
enum Clipboard {
    static let ownType = NSPasteboard.PasteboardType("com.damianpdr.tack.own")
    private(set) static var ownChangeCount = -1

    static func isOwnWrite(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.changeCount == ownChangeCount || pasteboard.types?.contains(ownType) == true
    }

    static func writeText(_ text: String) {
        write { item in item.setString(text, forType: .string) }
    }

    static func writeImage(path: String, includeFileURL: Bool) {
        write(PasteboardImage(path: path), path: path, includeFileURL: includeFileURL)
    }

    /// `writeImage` with the decoding and TIFF encoding off the main thread, which can take a while for a full
    /// screen; screenshots use it so their flight into the pill isn't held up.
    static func writeImageInBackground(path: String) async {
        let image = await Task.detached(priority: .userInitiated) { PasteboardImage(path: path) }.value
        write(image, path: path, includeFileURL: false)
    }

    private static func write(_ image: PasteboardImage?, path: String, includeFileURL: Bool) {
        guard let image else {
            writeText(path)
            return
        }
        write { item in
            if let png = image.png { item.setData(png, forType: .png) }
            if let tiff = image.tiff { item.setData(tiff, forType: .tiff) }
            if includeFileURL { item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL) }
        }
    }

    static func writeFiles(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = paths.map { path -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            item.setString(path, forType: .string)
            item.setData(Data(), forType: ownType)
            return item
        }
        pasteboard.writeObjects(items)
        ownChangeCount = pasteboard.changeCount
    }

    private static func write(_ fill: (NSPasteboardItem) -> Void) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        fill(item)
        item.setData(Data(), forType: ownType)
        pasteboard.writeObjects([item])
        ownChangeCount = pasteboard.changeCount
    }
}

private struct PasteboardImage: Sendable {
    let png: Data?
    let tiff: Data?

    init?(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { return nil }
        png = url.pathExtension.lowercased() == "png" ? data : rep.representation(using: .png, properties: [:])
        tiff = rep.tiffRepresentation
    }
}
