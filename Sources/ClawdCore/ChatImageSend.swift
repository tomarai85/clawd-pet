import Foundation
import Darwin

/// Why a draft's images cannot be sent, in Orca's user words (SH/agent-session-failure-copy.ts:43-60).
public enum ChatImageRefusal: String, Equatable, Error {
    case tooBig, tooMany, total, type, empty, notFile, unreadable

    public var words: String {
        switch self {
        case .tooBig: return "An image on this message is larger than 5 MB, so the message was not sent."
        case .tooMany: return "Claude accepts at most 20 images in one message, so this message was not sent."
        case .total: return "The images on this message add up to more than 11 MB, so the message was not sent."
        case .type: return "Claude accepts only PNG, JPEG, GIF, and WebP images, so this message was not sent."
        case .empty: return "An image on this message is empty, so the message was not sent."
        case .notFile: return "An image on this message isn't a file, so the message was not sent."
        case .unreadable: return "An attachment on this message couldn't be read, so the message was not sent."
        }
    }
}

/// The user frame's content for a draft with images: the image blocks in chip order and then one text block (Orca
/// MC/claude-structured-dispatch-content.ts:120-194), built as JSON text off the main thread. The session writes the frame around it.
public final class ChatImagePayload: Equatable {
    /// The JSON array of the content blocks, as UTF-8 text.
    public let contentJSON: Data
    public let paths: [String]
    /// The images' raw bytes added up.
    public let rawBytes: Int
    public var count: Int { paths.count }

    init(contentJSON: Data, paths: [String], rawBytes: Int) {
        self.contentJSON = contentJSON; self.paths = paths; self.rawBytes = rawBytes
    }

    public static func == (lhs: ChatImagePayload, rhs: ChatImagePayload) -> Bool { lhs === rhs }
}

/// Reading and encoding the images of a send (spec Q16). Everything here is meant to run off the main thread.
public enum ChatImageSend {
    public static let maxFileBytes = 5 * 1024 * 1024
    public static let maxCount = 20
    /// Orca's 20 MiB, lowered because the message's own replay echoes the frame (the d-image-replay capture shows it carries the data) and must
    /// stay under the 16 MiB line cap (ChatSessionConfig.maxLineBytes).
    public static let maxTotalBytes = 11 * 1024 * 1024
    public static let lineCapBytes = 16 * 1024 * 1024
    /// What the frame around the content may take (the uuid, the session id and the keys), kept free under the line cap.
    public static let framingBytes = 64 * 1024

    public static let mediaTypes: [String: String] = ["gif": "image/gif", "jpeg": "image/jpeg", "jpg": "image/jpeg", "png": "image/png", "webp": "image/webp"]

    /// The media type of a path by its extension, nil for a type Claude does not take.
    public static func mediaType(of path: String) -> String? {
        mediaTypes[(path as NSString).pathExtension.lowercased()]
    }

    /// A regular file whose size is the same before and after the read, at most 5 MiB (MC/claude-structured-dispatch-content.ts:64-110).
    /// `beforeRead` runs between the first size check and the read, `afterRead` between the read and the second size check (a test changes the file there).
    public static func read(_ path: String, beforeRead: () -> Void = {}, afterRead: () -> Void = {}) -> Result<Data, ChatImageRefusal> {
        // Non-blocking: opening a named pipe must not wait for a writer; the first fstat then refuses it.
        guard let file = try? ReadOnlyFile(path, nonBlocking: true), let info = try? file.metadata() else { return .failure(.unreadable) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notFile) }
        if info.st_size > Int64(maxFileBytes) { return .failure(.tooBig) }
        beforeRead()
        // One byte more than the size: a file that grew shows as more than it said.
        guard let data = try? file.read(offset: 0, count: Int(info.st_size) + 1) else { return .failure(.unreadable) }
        afterRead()
        guard let after = try? file.metadata() else { return .failure(.unreadable) }
        if data.count > maxFileBytes { return .failure(.tooBig) }
        // Not the image's fault: the file changed while it was read.
        if after.st_size != info.st_size || Int(after.st_size) != data.count { return .failure(.unreadable) }
        if data.isEmpty { return .failure(.empty) }
        return .success(data)
    }

    /// About the size of the content, so that it is built in one allocation and never grown by copying: the files' base64 plus a little for each block.
    private static func estimatedContentBytes(paths: [String], text: String) -> Int {
        var bytes = 256 + text.utf8.count * 2
        for path in paths.prefix(maxCount) {
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Int64(maxFileBytes) else { continue }
            bytes += Int(info.st_size + 2) / 3 * 4 + 160
        }
        return min(bytes, lineCapBytes)
    }

    /// The content of a send: each path's image block, then the text block when the draft has text. The first refusal wins, in Orca's order per
    /// image (count, read, total, type). The cap is checked on the whole encoded content too, so a draft full of escapes cannot push the replay
    /// past the line cap.
    public static func prepare(paths: [String], text: String, starting: (Int) -> Void = { _ in }, beforeRead: () -> Void = {}, afterRead: () -> Void = {}) -> Result<ChatImagePayload, ChatImageRefusal> {
        var json = Data(capacity: estimatedContentBytes(paths: paths, text: text))
        json.append(0x5B)
        var raw = 0
        var count = 0
        var first = true
        for path in paths {
            starting(count)
            count += 1
            if count > maxCount { return .failure(.tooMany) }
            let data: Data
            switch read(path, beforeRead: beforeRead, afterRead: afterRead) {
            case .success(let bytes): data = bytes
            case .failure(let refusal): return .failure(refusal)
            }
            raw += data.count
            if raw > maxTotalBytes { return .failure(.total) }
            guard let media = mediaType(of: path) else { return .failure(.type) }
            if !first { json.append(0x2C) }
            first = false
            json.append(contentsOf: Array("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"\(media)\",\"data\":\"".utf8))
            json.append(data.base64EncodedData())
            json.append(contentsOf: Array("\"}}".utf8))
        }
        if !text.isEmpty {
            guard let quoted = try? JSONEncoder().encode(text) else { return .failure(.unreadable) }
            if !first { json.append(0x2C) }
            json.append(contentsOf: Array("{\"type\":\"text\",\"text\":".utf8))
            json.append(quoted)
            json.append(0x7D)
        }
        json.append(0x5D)
        if json.count + framingBytes > lineCapBytes { return .failure(.total) }
        return .success(ChatImagePayload(contentJSON: json, paths: paths, rawBytes: raw))
    }
}
