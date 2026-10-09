import AppKit
import ImageIO
import SwiftUI

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let images = NSCache<NSString, NSImage>()
    private var pixelSizes: [String: CGSize] = [:]

    init() {
        images.countLimit = 400
    }

    func cachedImage(path: String, maxPixel: Int) -> NSImage? {
        images.object(forKey: key(path, maxPixel))
    }

    func image(path: String, maxPixel: Int) async -> NSImage? {
        if let cached = cachedImage(path: path, maxPixel: maxPixel) { return cached }
        let cgImage = await Task.detached(priority: .userInitiated) {
            ThumbnailCache.makeThumbnail(path: path, maxPixel: maxPixel)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        images.setObject(image, forKey: key(path, maxPixel))
        return image
    }

    /// Pixel dimensions read from the file header, without decoding the image.
    func pixelSize(path: String) -> CGSize? {
        if let size = pixelSizes[path] { return size }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let size = CGSize(width: width, height: height)
        pixelSizes[path] = size
        return size
    }

    private func key(_ path: String, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(path)" as NSString
    }

    nonisolated private static func makeThumbnail(path: String, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Whole image scaled to fit the available width, for the detail pane.
struct ImagePreview: View {
    let path: String
    var maxHeight: CGFloat = 280
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
        .task(id: path) {
            image = await ThumbnailCache.shared.image(path: path, maxPixel: 1200)
        }
    }
}

struct ThumbnailView: View {
    let path: String
    let height: CGFloat
    var maxWidth: CGFloat = 140
    var badge: Int?
    @State private var image: NSImage?

    private var maxPixel: Int { Int(max(height, maxWidth) * 2) }

    var body: some View {
        let width = displayWidth
        ZStack(alignment: .topLeading) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: width, height: height)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
            if let badge {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .task(id: path) {
            image = ThumbnailCache.shared.cachedImage(path: path, maxPixel: maxPixel)
            if image == nil {
                image = await ThumbnailCache.shared.image(path: path, maxPixel: maxPixel)
            }
        }
    }

    private var displayWidth: CGFloat {
        guard let size = ThumbnailCache.shared.pixelSize(path: path), size.height > 0 else { return height }
        return min(max(height * size.width / size.height, height * 0.6), maxWidth)
    }
}
