import Foundation
import Darwin

/// Why a dropped path could not be handed to the composer; the raw value is Orca's reason token (shared/native-file-drop.ts).
public enum DragTempFailure: String, Equatable {
    case missing, changed, busy
    case permissionDenied = "permission-denied"
    case outOfSpace = "out-of-space"
    case storageUnavailable = "storage-unavailable"
    case storageNotPrivate = "storage-not-private"
    case timedOut = "timed-out"
    case tooLarge = "too-large"
    case storageFull = "storage-full"
    case copyFailed = "copy-failed"

    /// Orca's words (lib/drop-temp-copy-failure-copy.ts:9-61 and lib/drop-skip-reason-copy.ts), with the product name changed.
    public var words: String {
        switch self {
        case .missing: return "No longer at its original path."
        case .permissionDenied: return "Permission denied."
        case .changed: return "The file changed while Clawd was copying it. Try the drop again."
        case .outOfSpace: return "Not enough disk space to copy the dropped files."
        case .storageUnavailable: return "Clawd couldn't create storage for dropped files."
        case .storageNotPrivate: return "Clawd's storage for dropped files can be read by other users, so nothing was copied."
        case .timedOut: return "Copying took too long. Try the drop again."
        case .busy: return "Too many drops are still being copied. Wait a moment, then try again."
        case .tooLarge: return "Too large to copy, so Clawd couldn't hand it to the agent."
        case .storageFull: return "Clawd's storage for dropped files is full, so Clawd couldn't hand it to the agent."
        case .copyFailed: return "Try the drop again."
        }
    }
}

/// What became of one dropped path.
public enum DragTempResult: Equatable {
    /// Not a drag-provider file: the path goes on unchanged.
    case pass(String)
    case copied(from: String, to: String)
    case failed(path: String, reason: DragTempFailure)
}

/// The copy of a macOS drag provider's temporary files (screenshot thumbnails and the like) into Clawd's own storage (Orca
/// main/window/dragged-temp-file-copy.ts): `$TMPDIR/TemporaryItems/NSIRD_*` can only be opened by the process that received the drop, so the agent
/// would get EPERM on the original path. Everything runs synchronously; the caller runs it off the main thread. Every write goes through OwnState.
public final class DragTempCopier {
    public static let rootName = "chat-drops"
    public static let dirPrefix = "clawd-drop-"
    /// Orca's REMOTE_IMPORT_MAX_FILE_BYTES and _TOTAL_BYTES, DRAG_TEMP_COPY_TTL_MS, MAX_PENDING_DRAG_TEMP_COPIES and the per-drop timeout.
    public static let fileCap: Int64 = 2 * 1024 * 1024 * 1024
    public static let totalCap: Int64 = 8 * 1024 * 1024 * 1024
    public static let ttl: TimeInterval = 7 * 24 * 3600
    public static let maxPending = 8
    public static let dropTimeout: TimeInterval = 120

    private let state: OwnState
    private let temporaryDirectory: String
    private let fileCap: Int64, totalCap: Int64

    /// `temporaryDirectory` is the per-user temp directory the providers use (`NSTemporaryDirectory()`); the caps are seams for the tests.
    public init(state: OwnState, temporaryDirectory: String, fileCap: Int64 = DragTempCopier.fileCap, totalCap: Int64 = DragTempCopier.totalCap) {
        self.state = state; self.temporaryDirectory = temporaryDirectory; self.fileCap = fileCap; self.totalCap = totalCap
    }

    /// Lexical check only: whether the path holds `TemporaryItems/NSIRD_*/<something>`.
    public static func mayNeed(_ path: String) -> Bool { hasMarker(URL(fileURLWithPath: path).standardizedFileURL.pathComponents) }

    private static func hasMarker(_ parts: [String]) -> Bool {
        guard parts.count >= 3 else { return false }
        for i in 0..<(parts.count - 2) where parts[i] == "TemporaryItems" && parts[i + 1].hasPrefix("NSIRD_") { return true }
        return false
    }

    private func canonical(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func classify(_ code: Int32) -> DragTempFailure {
        switch code {
        case ENOENT: return .missing
        case EACCES, EPERM: return .permissionDenied
        case ENOSPC, EDQUOT: return .outOfSpace
        default: return .copyFailed
        }
    }

    private func sameSnapshot(_ a: stat, _ b: stat) -> Bool {
        a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && (a.st_ino == 0 || b.st_ino == 0 || a.st_ino == b.st_ino) && (a.st_dev == 0 || b.st_dev == 0 || a.st_dev == b.st_dev)
    }

    private func retainedBytes() -> Int64 {
        var total: Int64 = 0
        for dir in state.entries(of: Self.rootName) where Self.isCopyDirectory(dir.name, dir.info) {
            for file in state.entries(of: Self.rootName + "/" + dir.name) where file.info.st_mode & S_IFMT == S_IFREG { total += Int64(file.info.st_size) }
        }
        return total
    }

    static func isCopyDirectory(_ name: String, _ info: stat) -> Bool {
        guard info.st_mode & S_IFMT == S_IFDIR, name.hasPrefix(dirPrefix) else { return false }
        let tail = name.dropFirst(dirPrefix.count)
        return tail.count == 6 && tail.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// Each path of a drop, in order. A path that is not a provider file passes. `isCancelled` and the deadline are asked before every file and before every 256 KiB chunk of a copy: a cancelled drop
    /// removes the copies it made and returns nothing. `deadline` is an instant on `now`'s clock: past it the drop is `timed-out` as a whole.
    public func materialize(_ paths: [String], isCancelled: () -> Bool, now: () -> TimeInterval, deadline: TimeInterval) -> [DragTempResult] {
        var results: [DragTempResult] = []
        var made: [String] = []
        var seen: [String: DragTempResult] = [:]
        var remaining: Int64? = nil
        func abandon() { for dir in made { try? state.removeTree(dir) } }
        for path in paths {
            if isCancelled() { abandon(); return [] }
            if let earlier = seen[path] { results.append(earlier); continue }
            if now() > deadline {
                abandon()
                return paths.map { Self.mayNeed($0) ? .failed(path: $0, reason: .timedOut) : .pass($0) }
            }
            if remaining == nil, Self.mayNeed(path) { remaining = totalCap - retainedBytes() }
            let result = materializeOne(path, remaining: &remaining, made: &made, stop: { isCancelled() || now() > deadline })
            seen[path] = result
            results.append(result)
        }
        if isCancelled() { abandon(); return [] }
        return results
    }

    private func materializeOne(_ path: String, remaining: inout Int64?, made: inout [String], stop: () -> Bool) -> DragTempResult {
        guard Self.mayNeed(path) else { return .pass(path) }
        var inspected = stat()
        if lstat(path, &inspected) != 0 {
            let code = errno
            // A missing lookalike outside the temp directory is an ordinary path.
            if code == ENOENT, !(canonical(temporaryDirectory).map { path.hasPrefix($0 + "/") } ?? false), !path.hasPrefix(temporaryDirectory) { return .pass(path) }
            return .failed(path: path, reason: Self.classify(code))
        }
        // Directories and links keep the reference-in-place behaviour.
        guard inspected.st_mode & S_IFMT == S_IFREG else { return .pass(path) }
        guard let source = canonical(path), let temp = canonical(temporaryDirectory) else { return .failed(path: path, reason: .copyFailed) }
        let prefix = temp.hasSuffix("/") ? temp : temp + "/"
        guard source.hasPrefix(prefix) else { return .pass(path) }
        let below = Array(source.dropFirst(prefix.count).split(separator: "/").map(String.init))
        // Anchored at the temp root, so a nested lookalike elsewhere is not copied.
        guard below.first == "TemporaryItems", Self.hasMarker(["/"] + below) else { return .pass(path) }
        let file: ReadOnlyFile
        // Non-blocking: a path swapped for a FIFO since the lstat must not hold this thread; the fstat below refuses it as `changed`.
        do { file = try ReadOnlyFile(source, flags: O_RDONLY | O_NOFOLLOW, nonBlocking: true) } catch {
            if case FileFailure.system(let code) = error { return .failed(path: path, reason: Self.classify(code)) }
            return .failed(path: path, reason: .copyFailed)
        }
        guard let opened = try? file.metadata(), opened.st_mode & S_IFMT == S_IFREG, sameSnapshot(opened, inspected) else { return .failed(path: path, reason: .changed) }
        let size = Int64(opened.st_size)
        if size > fileCap { return .failed(path: path, reason: .tooLarge) }
        if size > (remaining ?? totalCap) { return .failed(path: path, reason: .storageFull) }
        var directory: String?
        do {
            try state.privateDirectory(Self.rootName)
            let dir = try state.makeUniqueDirectory(in: Self.rootName, prefix: Self.dirPrefix)
            directory = dir
            made.append(dir)
            let name = (source as NSString).lastPathComponent
            let target = dir + "/" + name
            try state.copyIn(from: file.descriptor, size: size, to: target, shouldStop: stop)
            var written = stat()
            let after = try file.metadata()
            guard lstat(try state.url(target).path, &written) == 0, Int64(written.st_size) == size, sameSnapshot(after, opened) else { throw OwnStorageFailure.changed }
            remaining = (remaining ?? totalCap) - size
            return .copied(from: path, to: try state.url(target).path)
        } catch {
            if let dir = directory { try? state.removeTree(dir); made.removeAll { $0 == dir } }
            switch error as? OwnStorageFailure {
            case .notPrivate?: return .failed(path: path, reason: .storageNotPrivate)
            case .unavailable?: return .failed(path: path, reason: .storageUnavailable)
            case .outOfSpace?: return .failed(path: path, reason: .outOfSpace)
            case .changed?: return .failed(path: path, reason: .changed)
            case .stopped?: return .failed(path: path, reason: .timedOut)
            case .system(let code)?: return .failed(path: path, reason: Self.classify(code))
            case nil: return .failed(path: path, reason: .copyFailed)
            }
        }
    }

    /// Removes the copies of a cancelled or abandoned drop (the directories of its `copied` results).
    public func discard(_ results: [DragTempResult]) {
        for case .copied(_, let to) in results {
            let dir = (to as NSString).deletingLastPathComponent
            let prefix = state.root.path + "/"
            guard dir.hasPrefix(prefix) else { continue }
            try? state.removeTree(String(dir.dropFirst(prefix.count)))
        }
    }

    /// `clawd-drop-XXXXXX` directories older than seven days. Anything else in the folder, and any link, stays.
    @discardableResult
    public func sweep(now: Date = Date()) -> Int {
        state.sweep(directory: Self.rootName, olderThan: Self.ttl, now: now) { name, info in Self.isCopyDirectory(name, info) }
    }
}
