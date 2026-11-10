import Foundation
import Darwin

public enum FileFailure: Error { case invalidFlags, system(Int32), oversized, unsafePath }

/// The sole open(2) boundary for all external input, including every Aqua path.
public final class ReadOnlyFile {
    public let descriptor: Int32
    public static func accepts(flags: Int32) -> Bool {
        let forbidden = O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND
        let allowed = O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
        return flags & O_ACCMODE == O_RDONLY && flags & forbidden == 0 && flags & ~allowed == 0
    }
    /// `nonBlocking` is for a path that may have become a FIFO or a device since it was inspected: the open returns at once instead of waiting for a
    /// writer, and the caller's fstat then refuses what is not a regular file. It is not one of the flags `accepts` takes.
    public init(_ path: String, flags: Int32 = O_RDONLY, nonBlocking: Bool = false) throws {
        guard Self.accepts(flags: flags) else { throw FileFailure.invalidFlags }
        descriptor = Darwin.open(path, flags | O_CLOEXEC | (nonBlocking ? O_NONBLOCK : 0))
        guard descriptor >= 0 else { throw FileFailure.system(errno) }
    }
    deinit { Darwin.close(descriptor) }
    public func metadata() throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw FileFailure.system(errno) }
        return info
    }
    public func read(offset: Int64, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: max(0, count))
        var n: Int
        repeat { n = pread(descriptor, &bytes, bytes.count, off_t(offset)) } while n < 0 && errno == EINTR
        guard n >= 0 else { throw FileFailure.system(errno) }
        return Data(bytes.prefix(n))
    }
    public static func data(_ path: String, limit: Int = 4 * 1024 * 1024) throws -> Data {
        let file = try ReadOnlyFile(path)
        let size = try file.metadata().st_size
        guard size >= 0, size <= limit else { throw FileFailure.oversized }
        let data = try file.read(offset: 0, count: limit + 1)
        guard data.count <= limit else { throw FileFailure.oversized }
        return data
    }
}
