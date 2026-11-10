import Foundation
import Darwin
import ClawdProcess

/// One run of a process: its pid and its start time in microseconds. A pid alone can be reused by another process; the pair cannot.
public struct AquaGeneration: Hashable {
    public var pid: Int32
    public var start: UInt64
    public init(pid: Int32, start: UInt64) { self.pid = pid; self.start = start }
}
public struct AquaProcessFacts: Equatable {
    public var start: UInt64
    public var zombie: Bool
    public init(start: UInt64, zombie: Bool) { self.start = start; self.zombie = zombie }
}
public struct AquaCandidate: Equatable {
    public var generation: AquaGeneration
    public var zombie: Bool
    public init(generation: AquaGeneration, zombie: Bool = false) { self.generation = generation; self.zombie = zombie }
}

/// What the agent knows of Aqua's liveness comes from the kernel's process table, never from LaunchServices (amendment D-1).
public protocol AquaProcessTable: AnyObject {
    /// The application processes whose executable is an Aqua main process, zombies flagged; nil when the kernel could not be read.
    func scan() -> [AquaCandidate]?
    /// The generation facts of one pid now; nil when no such process exists.
    func facts(of pid: Int32) -> AquaProcessFacts?
    /// Whether the executable the pid runs now is an Aqua main process.
    func isAqua(pid: Int32) -> Bool
}

public enum AquaExitWatch: Equatable {
    /// The kernel holds the registration: an exit from now on is delivered.
    case registered
    /// The process was already gone (ESRCH).
    case gone
    /// The registration could not be made (no kqueue, a refusal); the errno of the refusal.
    case failed(Int32)
}

/// One registration per watched pid, delivered on the main queue through `onExit` (amendment D-2).
public protocol AquaExitRegistry: AnyObject {
    var onExit: ((Int32) -> Void)? { get set }
    /// Whether exit events can be registered at all (a kqueue was opened).
    var available: Bool { get }
    func watch(pid: Int32) -> AquaExitWatch
    func unwatch(pid: Int32)
    /// Whether a registration for the pid is held now. A delivered one-shot exit has released its own, so an event that arrives while one is
    /// still held belongs to an older registration (an older generation of the same pid).
    func holds(pid: Int32) -> Bool
    /// Closes the kqueue descriptor and its read source and opens new ones (every registration is gone); whether a kqueue is open after.
    @discardableResult func recreate() -> Bool
}

/// The identity of an executable by the bundle it lies in: `<bundle>/Contents/MacOS/<name>` where the bundle's Info.plist has the wanted
/// CFBundleIdentifier and names `<name>` as its CFBundleExecutable. The plist is read from the file system and cached per bundle path and
/// modification time; nothing asks LaunchServices. Helpers and bridges are bundles of their own inside an application and do not match.
public final class AppBundleIdentity {
    private struct Entry { var seconds: Int; var nanoseconds: Int; var identifier: String?; var executable: String? }
    private var cache: [String: Entry] = [:]
    /// How many times an Info.plist was read (a test reads it to prove the cache).
    public private(set) var plistReads = 0
    private let readPlist: (String) -> Data?
    public init(readPlist: @escaping (String) -> Data? = { try? ReadOnlyFile.data($0, limit: 1024 * 1024) }) { self.readPlist = readPlist }

    public func matches(executable path: String, identifier wanted: String) -> Bool {
        let marker = "/Contents/MacOS/"
        guard let range = path.range(of: marker, options: .backwards) else { return false }
        let name = String(path[range.upperBound...])
        guard !name.isEmpty, !name.contains("/") else { return false }
        let bundle = String(path[..<range.lowerBound])
        guard !bundle.isEmpty else { return false }
        let plist = bundle + "/Contents/Info.plist"
        var info = stat()
        guard stat(plist, &info) == 0 else { return false }
        let seconds = Int(info.st_mtimespec.tv_sec), nanoseconds = Int(info.st_mtimespec.tv_nsec)
        let entry: Entry
        if let cached = cache[bundle], cached.seconds == seconds, cached.nanoseconds == nanoseconds {
            entry = cached
        } else {
            plistReads += 1
            var identifier: String?, executable: String?
            if let data = readPlist(plist),
               let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                identifier = object["CFBundleIdentifier"] as? String
                executable = object["CFBundleExecutable"] as? String
            }
            entry = Entry(seconds: seconds, nanoseconds: nanoseconds, identifier: identifier, executable: executable)
            cache[bundle] = entry
        }
        return entry.identifier == wanted && entry.executable == name
    }
}

/// The real process table: libproc through the ClawdProcess target.
public final class KernelAquaTable: AquaProcessTable {
    public static let bundleIdentifier = "com.electron.aqua-voice"
    private let identity: AppBundleIdentity
    private let wanted: String
    public init(identity: AppBundleIdentity = AppBundleIdentity(), bundleIdentifier: String = KernelAquaTable.bundleIdentifier) {
        self.identity = identity; wanted = bundleIdentifier
    }
    public func scan() -> [AquaCandidate]? {
        let capacity = 1024
        var buffer = [ClawdAppProcess](repeating: ClawdAppProcess(), count: capacity)
        let count = Int(clawd_app_processes(&buffer, Int32(capacity)))
        guard count >= 0 else { return nil }
        var found: [AquaCandidate] = []
        for index in 0..<count {
            let process = buffer[index]
            let path = Self.string(process.path)
            guard identity.matches(executable: path, identifier: wanted) else { continue }
            found.append(AquaCandidate(generation: AquaGeneration(pid: process.pid, start: process.start_us), zombie: process.zombie != 0))
        }
        return found
    }
    public func facts(of pid: Int32) -> AquaProcessFacts? {
        var start: UInt64 = 0, zombie: Int32 = 0
        guard clawd_proc_facts(pid, &start, &zombie) == 0 else { return nil }
        return AquaProcessFacts(start: start, zombie: zombie != 0)
    }
    public func isAqua(pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard clawd_pid_path(pid, &buffer, Int32(buffer.count)) == 0 else { return false }
        return identity.matches(executable: String(cString: buffer), identifier: wanted)
    }
    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The real exit registry: one kqueue descriptor, read by one DispatchSource on the main queue made when the registry is made. A delivered
/// exit therefore runs on the main queue.
public final class KqueueExitRegistry: AquaExitRegistry {
    public var onExit: ((Int32) -> Void)?
    private var kq: Int32 = -1
    private var source: DispatchSourceRead?
    private var held = Set<Int32>()
    public var available: Bool { kq >= 0 }
    public init() { armQueue() }
    deinit { source?.cancel() }
    private func armQueue() {
        kq = clawd_kq_create()
        guard kq >= 0 else { return }
        let descriptor = kq
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        reader.setEventHandler { [weak self] in self?.drain(descriptor) }
        reader.setCancelHandler { Darwin.close(descriptor) }
        reader.resume()
        source = reader
    }
    @discardableResult public func recreate() -> Bool {
        source?.cancel(); source = nil; kq = -1; held.removeAll()
        armQueue()
        return kq >= 0
    }
    private func drain(_ descriptor: Int32) {
        var pids = [Int32](repeating: 0, count: 16)
        let count = Int(clawd_kq_drain(descriptor, &pids, Int32(pids.count)))
        guard count > 0 else { return }
        for index in 0..<count { held.remove(pids[index]); onExit?(pids[index]) }
    }
    public func watch(pid: Int32) -> AquaExitWatch {
        guard kq >= 0 else { return .failed(EBADF) }
        let result = clawd_kq_watch_exit(kq, pid)
        switch result {
        case 0: held.insert(pid); return .registered
        case 1: return .gone
        default: return .failed(result < 0 ? -result : EIO)
        }
    }
    public func unwatch(pid: Int32) { held.remove(pid); if kq >= 0 { _ = clawd_kq_unwatch(kq, pid) } }
    public func holds(pid: Int32) -> Bool { held.contains(pid) }
}

/// A table built from a plain "is Aqua running" answer: one pretend process while it is true. The runtime uses it when its environment
/// supplies no table, so a test that only says whether Aqua runs never reads the real kernel.
public final class AnswerAquaTable: AquaProcessTable {
    private let running: () -> Bool
    public init(running: @escaping () -> Bool) { self.running = running }
    private static let generation = AquaGeneration(pid: 1, start: 1)
    public func scan() -> [AquaCandidate]? { running() ? [AquaCandidate(generation: Self.generation)] : [] }
    public func facts(of pid: Int32) -> AquaProcessFacts? { running() && pid == 1 ? AquaProcessFacts(start: 1, zombie: false) : nil }
    public func isAqua(pid: Int32) -> Bool { running() && pid == 1 }
}
/// A registry that holds every registration and delivers nothing.
public final class SilentExitRegistry: AquaExitRegistry {
    public var onExit: ((Int32) -> Void)?
    public var available: Bool { true }
    public init() {}
    private var held = Set<Int32>()
    public func watch(pid: Int32) -> AquaExitWatch { held.insert(pid); return .registered }
    public func unwatch(pid: Int32) { held.remove(pid) }
    public func holds(pid: Int32) -> Bool { held.contains(pid) }
    public func recreate() -> Bool { held.removeAll(); return true }
}
