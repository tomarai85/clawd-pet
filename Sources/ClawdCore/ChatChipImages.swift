import Foundation
import ImageIO

/// What a chip's image came to (spec Q14).
public enum ChatChipImage {
    /// A downsampled thumbnail or preview.
    case image(CGImage)
    /// The header says the image is over 32 Mi pixels or has no positive size: nothing was decoded.
    case tooLarge
    /// An SVG: never rendered, the chip shows the image icon.
    case svg
    /// The file is not an image ImageIO can read, or could not be read.
    case unreadable
}

/// The extensions that make a path an image chip (SH/image-file-extensions.ts:1-12, by the basename's extension) and the chip's reading of its
/// file: the pixel size from the header first, then one downsampled thumbnail. Reads run off the main thread; the decode counter is the test seam
/// for "nothing was decoded".
public final class ChatChipImages {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "ico"]
    /// 56 pt at 2x.
    public static let thumbnailPixels = 112
    /// The largest preview raster asked for, whatever the body's size.
    public static let previewPixelLimit = 4096

    private let lock = NSLock()
    private var decodeCalls = 0
    private var loadCalls = 0
    public init() {}

    /// How many times a file or bytes were asked for at all (an SVG is never asked for: it is not opened, let alone rendered).
    public var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCalls }
    private func counted() { lock.lock(); loadCalls += 1; lock.unlock() }

    /// How many times a thumbnail was asked of ImageIO (the only call that can decode a raster).
    public var decodes: Int { lock.lock(); defer { lock.unlock() }; return decodeCalls }

    /// Whether `path` names an image by its basename's extension: `/tmp/x.png/y` is not one.
    public static func isImagePath(_ path: String) -> Bool {
        extensions.contains((basename(path) as NSString).pathExtension.lowercased())
    }

    public static func isSVG(_ path: String) -> Bool { (basename(path) as NSString).pathExtension.lowercased() == "svg" }

    public static func basename(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// Orca's `clawd-paste-*.png` test (NC/native-chat-image-paste.ts:12-25) for Clawd's own paste file names.
    public static func isPastedName(_ name: String) -> Bool { name.hasPrefix("clawd-paste-") && name.hasSuffix(".png") }

    /// The chip's label and tooltip: "Pasted image" for a pasted file, else the file's name.
    public static func label(for pathOrName: String) -> String {
        let name = basename(pathOrName)
        return isPastedName(name) ? "Pasted image" : name
    }

    /// The thumbnail (or preview, at `maxPixel`) of a file.
    public func load(path: String, maxPixel: Int) -> ChatChipImage {
        counted()
        if Self.isSVG(path) { return .svg }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return .unreadable }
        return load(source, maxPixel: maxPixel)
    }

    /// The thumbnail of image bytes in memory (a pasted image shown while it is saved).
    public func load(data: Data, maxPixel: Int) -> ChatChipImage {
        counted()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return .unreadable }
        return load(source, maxPixel: maxPixel)
    }

    private func load(_ source: CGImageSource, maxPixel: Int) -> ChatChipImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return .unreadable }
        guard ClipboardImage.pixelsAcceptable(width: width, height: height) else { return .tooLarge }
        lock.lock(); decodeCalls += 1; lock.unlock()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixel, Self.previewPixelLimit))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .unreadable }
        return .image(image)
    }
}
