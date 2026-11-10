import Foundation
import Darwin

/// Deterministic reader; poll() is called by vnode events in production and directly in replay tests.
public final class LogTailer {
    public let path: String
    public var onLine: (String) -> Void
    public var onBoundary: () -> Void = {}
    public var onDiagnostic: (String) -> Void = { _ in }
    public var guards: GuardSet = .all
    public private(set) var offset: Int64 = 0
    public private(set) var bufferedBytes = 0
    private var file: ReadOnlyFile?
    private var fingerprint = Data()
    private var partial = Data()
    private var discarding = false
    public static let lineLimit = 300 * 1024
    public init(path: String, onLine: @escaping (String) -> Void) {
        self.path = path; self.onLine = onLine
        // No startup look-back, including a partial line already at EOF.
        if let input = try? ReadOnlyFile(path), let info = try? input.metadata() {
            file = input; offset = info.st_size; refreshFingerprint()
            if offset > 0 { discarding = (try? input.read(offset: offset - 1, count: 1)) != Data([10]) }
        }
    }
    private func dropPartial() {
        if !partial.isEmpty || discarding { onDiagnostic("partial_dropped") }
        partial.removeAll(keepingCapacity: true); discarding = false; bufferedBytes = 0; onBoundary()
    }
    private func refreshFingerprint() {
        let length = Int(min(64, offset))
        fingerprint = (try? file?.read(offset: offset - Int64(length), count: length)) ?? Data()
    }
    private func drain() throws {
        guard let file else { return }
        let size = try file.metadata().st_size
        let observed = try file.read(offset: max(0, offset - Int64(fingerprint.count)), count: fingerprint.count)
        // B3 overrides fingerprint searching: trims/regrowth always resync to EOF.
        if guards.contains(.fingerprintResync), size < offset || observed != fingerprint {
            dropPartial(); offset = size; refreshFingerprint(); onDiagnostic("tail_resync_eof")
            if offset > 0 { discarding = try file.read(offset: offset - 1, count: 1) != Data([10]) }
            return
        }
        // Snapshot EOF: continuous writers cannot monopolize the main queue.
        while offset < size {
            let bytes = try file.read(offset: offset, count: Int(min(64 * 1024, size - offset)))
            if bytes.isEmpty { break }
            offset += Int64(bytes.count)
            for byte in bytes {
                if byte == 10 {
                    if !discarding, let line = String(data: partial, encoding: .utf8) { onLine(line) }
                    partial.removeAll(keepingCapacity: true); discarding = false
                } else if !discarding {
                    if partial.count >= Self.lineLimit {
                        partial.removeAll(keepingCapacity: true); discarding = true; onDiagnostic("oversize_dropped")
                    } else { partial.append(byte) }
                }
            }
            // Negative-control mode only: emitting an unterminated tail splits one line into two fragments.
            if !guards.contains(.partialBuffer), !partial.isEmpty, !discarding {
                if let line = String(data: partial, encoding: .utf8) { onLine(line) }
                partial.removeAll(keepingCapacity: true)
            }
        }
        bufferedBytes = partial.count; refreshFingerprint()
    }
    public func poll() {
        do {
            var target = stat()
            let exists = stat(path, &target) == 0
            if let current = file {
                let old = try current.metadata()
                if guards.contains(.renameFollow), !exists || old.st_ino != target.st_ino || old.st_dev != target.st_dev {
                    try drain(); dropPartial(); file = nil; offset = 0; fingerprint = Data()
                    onDiagnostic("rotation_followed")
                }
            }
            if file == nil, exists { file = try ReadOnlyFile(path); offset = 0; fingerprint = Data() }
            try drain()
        } catch { onDiagnostic("tail_read_failed") }
    }
}

/// Watches a separate event-only fd and the nearest existing parent. No polling timer.
public final class LogWatch {
    private let reader: LogTailer
    private let queue: DispatchQueue
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var watchedIdentity: String?
    private var watchedDirectory: String?
    public init(reader: LogTailer, queue: DispatchQueue = .main) {
        self.reader = reader; self.queue = queue
        // Close the read-before-watch race without replaying initial content.
        changed()
    }
    deinit { fileSource?.cancel(); directorySource?.cancel() }
    /// Whether a kernel file event is armed on the log or on the nearest existing directory above it.
    public var isArmed: Bool { fileSource != nil || directorySource != nil }
    private func source(path: String, handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        guard let file = try? ReadOnlyFile(path, flags: O_EVTONLY) else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: file.descriptor,
            eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { _ = file.descriptor } // Keep fd alive until cancellation is delivered.
        source.resume(); return source
    }
    /// Arms first, then reads: a change after the arm raises an event, and one before it is read by the poll. Arming can itself move
    /// a watch (a directory or the file appeared while the previous one was being armed, which raised no event for the new one),
    /// so the pair repeats until a pass moves nothing.
    private func changed() {
        for _ in 0..<16 {
            let moved = arm()
            reader.poll()
            if !moved { break }
        }
    }
    /// Returns true when a watch was replaced or created.
    @discardableResult private func arm() -> Bool {
        var moved = false
        var metadata = stat()
        let exists = stat(reader.path, &metadata) == 0
        let identity = exists ? "\(metadata.st_dev):\(metadata.st_ino)" : nil
        if identity != watchedIdentity || (identity != nil && fileSource == nil) {
            fileSource?.cancel(); fileSource = nil; watchedIdentity = nil; moved = true
            if exists, let created = source(path: reader.path, handler: { [weak self] in self?.changed() }) {
                fileSource = created; watchedIdentity = identity
            }
        }
        var directory = URL(fileURLWithPath: reader.path).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        // Include inode so replacing the log directory re-arms its vnode too.
        var info = stat(); _ = stat(directory.path, &info)
        let directoryID = "\(directory.path):\(info.st_dev):\(info.st_ino)"
        if directoryID != watchedDirectory || directorySource == nil {
            directorySource?.cancel(); directorySource = nil; watchedDirectory = nil; moved = true
            if let created = source(path: directory.path, handler: { [weak self] in self?.changed() }) {
                directorySource = created; watchedDirectory = directoryID
            }
        }
        return moved
    }
}
