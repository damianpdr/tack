import AppKit

/// All pasteboard writes by Voice go through here so `ClipboardMonitor` can skip them.
@MainActor
enum Clipboard {
    static let ownType = NSPasteboard.PasteboardType("com.damian.voice.own")
    private(set) static var ownChangeCount = -1

    static func isOwnWrite(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.changeCount == ownChangeCount || pasteboard.types?.contains(ownType) == true
    }

    static func writeText(_ text: String) {
        write { item in item.setString(text, forType: .string) }
    }

    static func writeImage(path: String, includeFileURL: Bool) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
            writeText(path)
            return
        }
        let png = url.pathExtension.lowercased() == "png" ? data : rep.representation(using: .png, properties: [:])
        write { item in
            if let png { item.setData(png, forType: .png) }
            if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            if includeFileURL { item.setString(url.absoluteString, forType: .fileURL) }
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
