import Foundation
import Darwin

/// All Swift writes are confined here, including explicit offscreen/test artifact roots.
/// External Aqua paths never pass this boundary. No file is opened through a symlink at or below the root;
/// system symlinks above it (/tmp, /var) are fine, since only the state directory itself can be planted by a careless caller.
public final class OwnState {
    public let root: URL
    public init(root: URL) throws {
        let root = Self.normalize(root)
        let denied = ["/Library/Logs/Aqua Voice", "/Library/Application Support/Aqua Voice"]
        guard !denied.contains(where: { root.path.contains($0) }), root.path != "/" else { throw FileFailure.unsafePath }
        self.root = root
        try Self.rejectSymlinks(root, anchor: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    /// Lexical clean-up only ("." and empty parts dropped, ".." resolved): unlike standardizedFileURL it never rewrites /private/tmp to /tmp.
    private static func normalize(_ url: URL) -> URL {
        var parts: [Substring] = []
        for part in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"))
    }
    private static func rejectSymlinks(_ url: URL, anchor: URL) throws {
        var cursor = url
        while cursor.path.count >= anchor.path.count, cursor.path != "/" {
            var info = stat()
            if lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { throw FileFailure.unsafePath }
            cursor.deleteLastPathComponent()
        }
    }
    public func url(_ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw FileFailure.unsafePath }
        let result = Self.normalize(root.appendingPathComponent(relative))
        guard result.path.hasPrefix(root.path + "/") else { throw FileFailure.unsafePath }
        try Self.rejectSymlinks(result, anchor: root); return result
    }
    public func write(_ data: Data, to relative: String) throws {
        try refuseAgentLogs(relative)                                          // agent.log is only ever appended to
        let target = try url(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
    public func writeJSON<T: Encodable>(_ value: T, to relative: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try write(encoder.encode(value), to: relative)
    }
    public func readJSON<T: Decodable>(_ type: T.Type, from relative: String) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: ReadOnlyFile.data(try url(relative).path))
    }
    public func append(_ text: String, to relative: String) throws {
        try appendRaw(Data(text.utf8), to: relative)
    }
    /// An append to agent.log, under any name that resolves to it, follows the agent log's policy (`appendAgentLog`).
    public func appendRaw(_ data: Data, to relative: String) throws {
        if try isAgentLog(relative) { try appendAgentLog(data); return }
        try refuseAgentLogs(relative)                                          // agent.log.1 is written only by the rotation
        try appendBytes(data, to: relative)
    }
    private func appendBytes(_ data: Data, to relative: String) throws {
        let target = try url(relative)
        let fd = Darwin.open(target.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FileFailure.system(errno) }; defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw FileFailure.system(errno) }; offset += n
            }
        }
    }
    /// The syscalls `appendLedger` makes. Production uses `.system`; a test replaces them to force a short write or a failing fsync.
    public var ledgerIO = LedgerIO.system
    /// The syscalls `writePrivate` makes that a test replaces.
    public var privateIO = PrivateIO.system
    /// Appends one line to an existing ledger file: open(O_WRONLY|O_APPEND|O_NOFOLLOW), no O_CREAT (a missing ledger is a failure, never
    /// created here), one write(2) of the whole line, then fsync(2). Every failure throws a `LedgerFailure`: a short write is `.short`
    /// and is not retried (bytes may already be in the file), a failed fsync is `.sync` (the bytes may be present). When `sealTornTail`
    /// is set and the file's last byte is not a newline, the same single write starts with "\n", so a torn tail becomes one complete
    /// malformed line and this line is never glued onto it.
    public func appendLedger(_ line: String, to relative: String, sealTornTail: Bool = false) throws {
        let target = try url(relative)
        do { try refuseAgentLogs(relative) } catch { throw LedgerFailure.write(EPERM) }   // agent.log has its own policy
        var text = line
        if sealTornTail, try ledgerTailIsTorn(target.path) { text = "\n" + text }
        let bytes = Array(text.utf8)
        let fd = Darwin.open(target.path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw LedgerFailure.write(errno) }; defer { close(fd) }
        var n: Int
        repeat { n = bytes.withUnsafeBytes { ledgerIO.write(fd, $0.baseAddress!, $0.count) } } while n < 0 && errno == EINTR
        guard n >= 0 else { throw LedgerFailure.write(errno) }
        guard n == bytes.count else { throw LedgerFailure.short(wrote: n, wanted: bytes.count) }
        guard ledgerIO.fsync(fd) == 0 else { throw LedgerFailure.sync(errno) }
    }
    private func ledgerTailIsTorn(_ path: String) throws -> Bool {
        let file = try ReadOnlyFile(path, flags: O_RDONLY | O_NOFOLLOW)
        let size = try file.metadata().st_size
        guard size > 0 else { return false }
        return try file.read(offset: Int64(size) - 1, count: 1) != Data([0x0A])
    }
    /// Appends, and first moves a log that has reached `limit` bytes to `<name>.1` (replacing the previous one). agent.log ignores `limit`
    /// and follows its own policy.
    public func appendRotating(_ text: String, to relative: String, limit: Int) throws {
        if try isAgentLog(relative) { try appendAgentLog(Data(text.utf8)); return }
        try refuseAgentLogs(relative)
        try rotate(relative, atOrOver: limit)
        try appendBytes(Data(text.utf8), to: relative)
    }
    private func rotate(_ relative: String, atOrOver limit: Int) throws {
        let target = try url(relative)
        var info = stat()
        if lstat(target.path, &info) == 0, Int(info.st_size) >= limit {
            guard Darwin.rename(target.path, try url(relative + ".1").path) == 0 else { throw FileFailure.system(errno) }
        }
    }

    // MARK: agent.log (amendment agent-log-retention)

    public static let agentLogName = "agent.log"
    /// agent.log is moved to agent.log.1 before an append that would take it past this many bytes, so neither file is ever larger.
    public static let agentLogLimit = 3_145_728
    /// One append (one line for every writer in the agent) is at most this many bytes of UTF-8, its newline included; a longer one is cut
    /// and ends with `agentLogCutMarker`.
    public static let agentLogLineLimit = 65_536
    public static let agentLogCutMarker = " [cut]\n"

    /// Names are compared without case: on the user's (case-insensitive) volume "AGENT.LOG" is agent.log.
    private func isAgentLog(_ relative: String) throws -> Bool {
        try url(relative).path.lowercased() == url(Self.agentLogName).path.lowercased()
    }
    /// Throws for agent.log and agent.log.1, under any name that resolves to them: every OwnState writer other than the agent log's own
    /// policy and its named exception refuses them (write, writeJSON, appendLedger, rewriteInPlace, rename from or to them, counter, and an
    /// append to agent.log.1).
    private func refuseAgentLogs(_ relative: String) throws { try refuseAgentLogs(path: try url(relative).path) }
    private func refuseAgentLogs(path given: String) throws {
        let path = given.lowercased()
        let live = try url(Self.agentLogName).path.lowercased(), old = try url(Self.agentLogName + ".1").path.lowercased()
        guard path != live, path != old else { throw FileFailure.unsafePath }
    }

    /// The agent log's one policy: the line cut to the line limit, then agent.log rotated if the line would take it past the limit.
    private func appendAgentLog(_ data: Data) throws {
        let line = Self.agentLogLine(data)
        let target = try url(Self.agentLogName)
        var info = stat()
        if lstat(target.path, &info) == 0, info.st_size > 0, Int(info.st_size) + line.count > Self.agentLogLimit {
            guard Darwin.rename(target.path, try url(Self.agentLogName + ".1").path) == 0 else { throw FileFailure.system(errno) }
        }
        try appendBytes(line, to: Self.agentLogName)
    }

    /// `data` unchanged when it fits the line limit; otherwise its text cut at a Unicode scalar boundary so that the kept part and the cut
    /// marker together fit (bytes that are not UTF-8 count as the replacement character they decode to).
    public static func agentLogLine(_ data: Data) -> Data {
        guard data.count > agentLogLineLimit else { return data }
        let room = agentLogLineLimit - agentLogCutMarker.utf8.count
        var kept = String.UnicodeScalarView(), bytes = 0
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            let size = String(scalar).utf8.count
            if bytes + size > room { break }
            kept.append(scalar); bytes += size
        }
        return Data((String(kept) + agentLogCutMarker).utf8)
    }

    /// The one way around the policy, for the headless measurement modes only: a plain append (`rotatingAt: nil`) or the generic rotation
    /// at their own limit.
    public func appendAgentLogUnmanaged(_ text: String, rotatingAt limit: Int?) throws {
        if let limit { try rotate(Self.agentLogName, atOrOver: limit) }
        try appendBytes(Data(text.utf8), to: Self.agentLogName)
    }
    /// A counter file in the state directory (one little-endian UInt64 at offset 0). It starts at 0 and each increment is one pwrite(2),
    /// so counting renders costs the idle-budget measurement a syscall, not a file rewrite. The measuring tool reads it with `FileCounter.read`.
    public func counter(_ relative: String) throws -> FileCounter {
        try refuseAgentLogs(relative)
        let fd = Darwin.open(try url(relative).path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FileFailure.system(errno) }
        let counter = FileCounter(descriptor: fd)
        try counter.store()
        return counter
    }
    public func lock() throws -> Int32 {
        let fd = Darwin.open(try url("lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FileFailure.system(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw FileFailure.system(errno) }
        return fd
    }
    // Test replay mutations remain inside the explicitly supplied test artifact root.
    public func rename(_ source: String, to target: String) throws {
        try refuseAgentLogs(source); try refuseAgentLogs(target)
        guard Darwin.rename(try url(source).path, try url(target).path) == 0 else { throw FileFailure.system(errno) }
    }
    public func rewriteInPlace(_ data: Data, to relative: String) throws {
        try refuseAgentLogs(relative)
        let fd = Darwin.open(try url(relative).path, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileFailure.system(errno) }; defer { close(fd) }
        let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard n == data.count else { throw FileFailure.system(errno) }
    }
}

/// Why the chat's drop and paste storage refused (the drag-temp copy maps each to Orca's words).
public enum OwnStorageFailure: Error, Equatable { case notPrivate, unavailable, outOfSpace, changed, stopped, system(Int32) }

// MARK: dropped and pasted files (chat-drops, chat-pastes)

extension OwnState {
    /// A directory of the state root that only the user can use: made 0700 when missing, refused (`notPrivate`) when it is a link, not a directory,
    /// not the user's or open to group or others (Orca's isSafeOwnedDirectory).
    /// `repairing` first narrows a real directory of the user's own that is open to group or others (a folder an earlier build made at the default
    /// mode) to 0700; a link, a foreign owner or anything that is not a directory still refuses.
    public func privateDirectory(_ relative: String, repairing: Bool = false) throws {
        let target = try url(relative)
        var info = stat()
        if lstat(target.path, &info) != 0 {
            guard errno == ENOENT else { throw OwnStorageFailure.unavailable }
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { throw OwnStorageFailure.unavailable }
            guard lstat(target.path, &info) == 0 else { throw OwnStorageFailure.unavailable }
        }
        if repairing, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 != 0 {
            try narrow(relative, directory: true)
            guard lstat(target.path, &info) == 0 else { throw OwnStorageFailure.unavailable }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw OwnStorageFailure.notPrivate }
    }

    /// chmod to 0700 (a directory) or 0600 (a regular file) through a descriptor opened without following a link, and only for the user's own
    /// entry of that kind. Anything else throws `notPrivate`.
    public func narrow(_ relative: String, directory: Bool) throws {
        let target = try url(relative)
        let fd = Darwin.open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw OwnStorageFailure.system(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw OwnStorageFailure.notPrivate }
        guard fchmod(fd, directory ? 0o700 : 0o600) == 0 else { throw OwnStorageFailure.system(errno) }
    }

    /// Removes one file below the root (a link is removed, never followed). A missing file is not an error.
    public func removeFile(_ relative: String) throws {
        let target = try entry(relative)
        try refuseAgentLogs(path: target.path)
        guard Darwin.unlink(target.path) == 0 || errno == ENOENT else { throw FileFailure.system(errno) }
    }

    /// The URL of an entry whose last component may itself be a link (it is removed, never followed): every directory above it is checked as `url` does.
    private func entry(_ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw FileFailure.unsafePath }
        let result = Self.normalize(root.appendingPathComponent(relative))
        guard result.path.hasPrefix(root.path + "/") else { throw FileFailure.unsafePath }
        try Self.rejectSymlinks(result.deletingLastPathComponent(), anchor: root)
        return result
    }

    /// The calls a private write makes that a test replaces: the file sync (`full`: the drive's cache is flushed too) and the rename.
    public struct PrivateIO {
        public var sync: (_ descriptor: Int32, _ full: Bool) -> Int32
        public var rename: (_ from: String, _ to: String) -> Int32
        public init(sync: @escaping (Int32, Bool) -> Int32, rename: @escaping (String, String) -> Int32) { self.sync = sync; self.rename = rename }
        /// `full` asks for F_FULLFSYNC and falls back to fsync where the filesystem refuses it (Orca's journal); otherwise fsync.
        public static let system = PrivateIO(
            sync: { descriptor, full in
                if full, fcntl(descriptor, F_FULLFSYNC) == 0 { return 0 }
                return Darwin.fsync(descriptor)
            },
            rename: { Darwin.rename($0, $1) })
    }

    /// A new temp file `.<name>.<six letters or digits>.tmp` in `directory`, created exclusive, no-follow and close-on-exec at 0600.
    private func createTemp(in directory: URL, for name: String) throws -> (path: String, descriptor: Int32) {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var temp = ""
        var fd: Int32 = -1
        for _ in 0..<32 {
            temp = directory.appendingPathComponent("." + name + "." + String((0..<6).map { _ in letters[Int.random(in: 0..<letters.count)] }) + ".tmp").path
            fd = Darwin.open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 || errno != EEXIST { break }
        }
        guard fd >= 0 else { throw errno == ENOSPC || errno == EDQUOT ? OwnStorageFailure.outOfSpace : OwnStorageFailure.system(errno) }
        return (temp, fd)
    }

    /// Writes `data` as the whole content of `relative`, which lives in a private directory (0700, the user's, not a link; made when missing):
    /// a temp file `.<name>.<six letters or digits>.tmp` in the same directory created exclusive, no-follow and close-on-exec at 0600, a full
    /// write, the file sync, a rename over the target and a best-effort sync of the directory. A failed step removes the temp file and throws;
    /// the target is unchanged. `durable` is the card-and-send write (F_FULLFSYNC); the draft's is plain fsync (Orca src/main/durable-file-write.ts).
    public func writePrivate(_ data: Data, to relative: String, durable: Bool = false) throws {
        try refuseAgentLogs(relative)
        let target = try url(relative)
        let directory = target.deletingLastPathComponent()
        guard directory.path != root.path else { throw FileFailure.unsafePath }
        try privateDirectory(String(directory.path.dropFirst(root.path.count + 1)))
        let (temp, fd) = try createTemp(in: directory, for: target.lastPathComponent)
        var finished = false
        defer { if !finished { Darwin.unlink(temp) } }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw errno == ENOSPC || errno == EDQUOT ? OwnStorageFailure.outOfSpace : OwnStorageFailure.system(errno) }
                    offset += n
                }
            }
            guard privateIO.sync(fd, durable) == 0 else { throw OwnStorageFailure.system(errno) }
        }
        guard privateIO.rename(temp, target.path) == 0 else { throw OwnStorageFailure.system(errno) }
        finished = true
        let dir = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dir >= 0 { _ = Darwin.fsync(dir); close(dir) }
    }

    /// Writes `data` as a new file `relative` (0600), in a directory that already exists: a temp file `.<name>.<six letters or digits>.tmp`
    /// created exclusive and no-follow, a full write and sync, then a hard link to the final name, so the name appears whole or not at all.
    /// A file that is already there is never touched: the call throws `OwnStorageFailure.system(EEXIST)`. A failed write removes what it made.
    public func writeNew(_ data: Data, to relative: String) throws {
        try refuseAgentLogs(relative)
        let target = try url(relative)
        let directory = target.deletingLastPathComponent()
        let (temp, fd) = try createTemp(in: directory, for: target.lastPathComponent)
        defer { Darwin.unlink(temp) }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw errno == ENOSPC || errno == EDQUOT ? OwnStorageFailure.outOfSpace : OwnStorageFailure.system(errno) }
                    offset += n
                }
            }
            guard Darwin.fsync(fd) == 0 else { throw OwnStorageFailure.system(errno) }
        }
        guard Darwin.link(temp, target.path) == 0 else { throw OwnStorageFailure.system(errno) }
    }

    /// Whether `name` is a temp file of `writePrivate`: `.<name>.<six letters or digits>.tmp`.
    static func isPrivateTemp(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        let inner = Array(name.dropFirst().dropLast(4))
        guard inner.count > 7, inner[inner.count - 7] == "." else { return false }
        return inner.suffix(6).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Removes the `.<name>.<random>.tmp` files a private write left when it died between create and rename (only that pattern, regular files,
    /// and only those not changed in the last `olderThan` seconds). Returns how many.
    @discardableResult
    public func removeStaleTemps(in relative: String, olderThan age: TimeInterval = 0, now: Date = Date()) -> Int {
        var removed = 0
        for entry in entries(of: relative) where entry.info.st_mode & S_IFMT == S_IFREG && Self.isPrivateTemp(entry.name)
            && now.timeIntervalSince1970 - Double(entry.info.st_mtimespec.tv_sec) >= age {
            if (try? removeFile(relative + "/" + entry.name)) != nil { removed += 1 }
        }
        return removed
    }

    /// `removeStaleTemps` for the temp files of one writer only: the state root itself (`relative` empty) or a directory below it, and only names
    /// that start with `.` + `namePrefix`, so another writer's temp, which may be in flight, is never matched. Returns how many.
    @discardableResult
    public func removeStaleTemps(in relative: String = "", namePrefix: String) -> Int {
        let hidden = "." + namePrefix
        var removed = 0
        for entry in entries(of: relative, orRoot: relative.isEmpty) where entry.info.st_mode & S_IFMT == S_IFREG && entry.name.hasPrefix(hidden)
            && Self.isPrivateTemp(entry.name) {
            if (try? removeFile((relative.isEmpty ? "" : relative + "/") + entry.name)) != nil { removed += 1 }
        }
        return removed
    }

    /// A new 0700 directory `<prefix><six letters or digits>` under `parent` (which must already exist); its relative path.
    public func makeUniqueDirectory(in parent: String, prefix: String) throws -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        for _ in 0..<32 {
            let name = prefix + String((0..<6).map { _ in letters[Int.random(in: 0..<letters.count)] })
            let relative = parent + "/" + name
            if Darwin.mkdir(try url(relative).path, 0o700) == 0 { return relative }
            guard errno == EEXIST else { throw errno == ENOSPC || errno == EDQUOT ? OwnStorageFailure.outOfSpace : OwnStorageFailure.unavailable }
        }
        throw OwnStorageFailure.unavailable
    }

    /// Copies the first `size` bytes of an open descriptor into a new file (created exclusive, 0600, no extended attributes: only bytes are
    /// written). A source that ends early is `changed`. `shouldStop` is asked before every 256 KiB chunk: true ends the copy with `stopped` (the
    /// partial file is the caller's to remove).
    public func copyIn(from source: Int32, size: Int64, to relative: String, shouldStop: () -> Bool = { false }) throws {
        let target = try url(relative)
        let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw errno == ENOSPC || errno == EDQUOT ? OwnStorageFailure.outOfSpace : OwnStorageFailure.system(errno) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var offset: Int64 = 0
        while offset < size {
            if shouldStop() { throw OwnStorageFailure.stopped }
            let want = Int(min(Int64(buffer.count), size - offset))
            var got: Int
            repeat { got = pread(source, &buffer, want, off_t(offset)) } while got < 0 && errno == EINTR
            guard got >= 0 else { throw OwnStorageFailure.system(errno) }
            guard got > 0 else { throw OwnStorageFailure.changed }
            var done = 0
            while done < got {
                let n = buffer.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: done), got - done) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw errno == ENOSPC || errno == EDQUOT ? OwnStorageFailure.outOfSpace : OwnStorageFailure.system(errno) }
                done += n
            }
            offset += Int64(got)
        }
    }

    /// Removes a directory below the root and everything in it (links are removed, never followed). The root itself is refused.
    public func removeTree(_ relative: String) throws {
        let target = try url(relative)
        guard target.path != root.path else { throw FileFailure.unsafePath }
        try FileManager.default.removeItem(at: target)
    }

    /// What is in a directory, each entry's own lstat (links are not followed). A missing or unreadable directory is empty, and so is a
    /// directory that is itself a link.
    public func entries(of relative: String) -> [(name: String, info: stat)] { entries(of: relative, orRoot: false) }

    private func entries(of relative: String, orRoot: Bool) -> [(name: String, info: stat)] {
        guard let dir = orRoot ? root : (try? url(relative)) else { return [] }
        var info = stat()
        guard lstat(dir.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { name in
            var entry = stat()
            return lstat(dir.appendingPathComponent(name).path, &entry) == 0 ? (name, entry) : nil
        }
    }

    /// Removes the entries of `directory` that `owns` claims and whose mtime is older than `age` seconds before `now`. `owns` sees the entry's
    /// lstat, so it can refuse links. A directory that is itself a link is not entered. Returns how many were removed.
    @discardableResult
    public func sweep(directory: String, olderThan age: TimeInterval, now: Date, owns: (String, stat) -> Bool) -> Int {
        var removed = 0
        for entry in entries(of: directory) where owns(entry.name, entry.info) {
            let modified = Date(timeIntervalSince1970: TimeInterval(entry.info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) > age else { continue }
            if (try? removeTree(directory + "/" + entry.name)) != nil { removed += 1 }
        }
        return removed
    }
}

public final class FileCounter {
    private let descriptor: Int32
    public private(set) var value: UInt64 = 0
    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
    fileprivate func store() throws {
        var encoded = value.littleEndian
        let n = withUnsafeBytes(of: &encoded) { Darwin.pwrite(descriptor, $0.baseAddress, 8, 0) }
        guard n == 8 else { throw FileFailure.system(errno) }
    }
    @discardableResult public func increment() -> UInt64 {
        value &+= 1
        try? store()
        return value
    }
    /// Sets the stored value (a gauge: the number of armed timers). One pwrite(2).
    public func set(_ newValue: UInt64) {
        guard newValue != value else { return }
        value = newValue
        try? store()
    }
    /// Read-only: the value in `path`, or an error when the file is missing or not 8 bytes. A failed read is never zero.
    public static func read(path: String) throws -> UInt64 {
        let data = try ReadOnlyFile.data(path, limit: 8)
        guard data.count == 8 else { throw FileFailure.oversized }
        return data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
}

/// The two syscalls of a ledger append, as a seam for tests.
public struct LedgerIO {
    public var write: (Int32, UnsafeRawPointer, Int) -> Int
    public var fsync: (Int32) -> Int32
    public init(write: @escaping (Int32, UnsafeRawPointer, Int) -> Int, fsync: @escaping (Int32) -> Int32) { self.write = write; self.fsync = fsync }
    public static let system = LedgerIO(write: { Darwin.write($0, $1, $2) }, fsync: { Darwin.fsync($0) })
}

/// Why a ledger append failed. `.write` and `.short` leave no complete line (a short write may leave a torn tail); `.sync` means the
/// complete line was written and could not be flushed.
public enum LedgerFailure: Error, Equatable {
    case write(Int32), short(wrote: Int, wanted: Int), sync(Int32)
    public var errnoValue: Int32 {
        switch self {
        case .write(let code), .sync(let code): return code
        case .short: return EIO
        }
    }
    /// The errno to log for any error a ledger append or read can throw.
    public static func errnoOf(_ error: Error) -> Int32 {
        if let failure = error as? LedgerFailure { return failure.errnoValue }
        if case FileFailure.system(let code)? = error as? FileFailure { return code }
        return EIO
    }
}
