import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Orca's clipboard image rules (shared/clipboard-image.ts:1-38) and the folder its pasted images live in (main/window/clipboard-image-temp-file.ts,
/// native-chat-paste-files.ts). Every write goes through OwnState.
public enum ClipboardImage {
    /// CLIPBOARD_IMAGE_MAX_PIXELS and CLIPBOARD_IMAGE_MAX_SOURCE_BYTES (24 Mi base64 characters hold 18 MiB).
    public static let maxPixels = 32 * 1024 * 1024
    public static let maxBytes = (24 * 1024 * 1024 / 4) * 3
    public static let tooLarge = "Clipboard image is too large"
    public static let failed = "Image paste failed."
    public static let folder = "chat-pastes"
    public static let ttl: TimeInterval = 30 * 24 * 3600
    /// A temp file of a paste write that died is removed once it is this old (a write in flight is never this old).
    public static let tempAge: TimeInterval = 3600

    /// The image's pixel size from its header, without decoding it (nil: not an image).
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Whether width x height is a size Orca takes: positive and at most 32 Mi pixels.
    public static func pixelsAcceptable(width: Int, height: Int) -> Bool {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && width > 0 && height > 0 && count <= maxPixels
    }

    /// PNG bytes of an image (any type ImageIO reads); nil when it cannot be encoded. Runs off the main thread.
    public static func encodePNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// `chat-pastes/clawd-paste-<ms since 1970>-<UUID>.png`.
    public static func fileName(milliseconds: Int64, id: UUID) -> String { "clawd-paste-\(milliseconds)-\(id.uuidString).png" }

    /// Writes the PNG into the one paste folder and returns the file's absolute path. The folder is private (0700; a default-mode one an earlier
    /// build made is narrowed first, a link or a foreign one refuses with `notPrivate`) and the file is 0600 (D16).
    public static func store(_ png: Data, in state: OwnState, milliseconds: Int64, id: UUID) throws -> String {
        let relative = folder + "/" + fileName(milliseconds: milliseconds, id: id)
        try state.privateDirectory(folder, repairing: true)
        try state.writePrivate(png, to: relative)
        return try state.url(relative).path
    }

    private static func isPasteFile(_ name: String, _ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && name.hasPrefix("clawd-paste-") && name.hasSuffix(".png") && name.count > "clawd-paste-.png".count
    }

    /// Regular `clawd-paste-*.png` files older than 30 days. Links, folders and everything else stay. The walk also narrows the paste folder
    /// and the pastes an earlier build left at the default mode to 0700 and 0600.
    @discardableResult
    public static func sweep(in state: OwnState, now: Date = Date()) -> Int {
        if !state.entries(of: folder).isEmpty { try? state.privateDirectory(folder, repairing: true) }
        for entry in state.entries(of: folder) where isPasteFile(entry.name, entry.info) && entry.info.st_mode & 0o077 != 0 {
            try? state.narrow(folder + "/" + entry.name, directory: false)
        }
        state.removeStaleTemps(in: folder, olderThan: tempAge, now: now)
        return state.sweep(directory: folder, olderThan: ttl, now: now) { name, info in isPasteFile(name, info) }
    }
}
