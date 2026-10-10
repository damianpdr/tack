import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFiles {
    struct PixelSize {
        var width: Int
        var height: Int
        var label: String { "\(width)×\(height)" }
        var pixels: Int { width * height }
    }

    static func pixelSize(of data: Data) -> PixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(of: source)
    }

    static func pixelSize(at url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(of: source)
    }

    static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Space-free, unique PNG path inside `directory`.
    static func newPNGURL(in directory: URL, prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return directory.appendingPathComponent("\(prefix)-\(formatter.string(from: Date()))-\(suffix).png")
    }

    private static func pixelSize(of source: CGImageSource) -> PixelSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return PixelSize(width: width, height: height)
    }
}
