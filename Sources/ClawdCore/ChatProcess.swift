import Foundation
import Darwin
import ClawdProcess

/// The process-level primitives of the chat bridge (spec F2.1, F2.6): spawn with exactly three descriptors in a group of its own, signal a
/// process only after its pid + start time are re-read, find every process that carries a spawn token, write a line to a pipe without a signal.
/// The only file of the chat code that signals, spawns or writes to a descriptor; the lint exempts it by name.
public enum ChatProc {
    public struct Spawned {
        public let pid: Int32
        /// The agent's ends of the three pipes: claude's stdin (write end, non-blocking), stdout and stderr (read ends).
        public let stdin: Int32
        public let stdout: Int32
        public let stderr: Int32
    }
    public enum SpawnFailure: Error, Equatable { case pipe(Int32), spawn(Int32), arguments }

    public static let tokenVariable = "CLAWD_CHAT_SPAWN"

    /// A write to an exited child must fail with EPIPE, never raise a signal in the agent.
    private static let ignoreBrokenPipe: Void = { _ = Darwin.signal(SIGPIPE, SIG_IGN) }()

    // MARK: spawn

    /// Starts `executable` with `arguments` and exactly `environment`, in `directory`, in its own process group (pgid = pid), with only the three
    /// pipe ends as descriptors 0-2 (every other descriptor of the agent stays closed in the child), default signal dispositions and an empty mask.
    public static func spawn(executable: String, arguments: [String], environment: [String: String], directory: String) throws -> Spawned {
        _ = ignoreBrokenPipe
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0 else { throw SpawnFailure.pipe(errno) }
        guard pipe(&outPipe) == 0 else { let e = errno; closeAll(inPipe); throw SpawnFailure.pipe(e) }
        guard pipe(&errPipe) == 0 else { let e = errno; closeAll(inPipe + outPipe); throw SpawnFailure.pipe(e) }
        for descriptor in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(inPipe[1], F_SETFL, fcntl(inPipe[1], F_GETFL) | O_NONBLOCK)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var everySignal = sigset_t(), noSignal = sigset_t()
        sigemptyset(&everySignal); sigemptyset(&noSignal)
        for number in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGALRM, SIGTERM, SIGUSR1, SIGUSR2, SIGCHLD] { sigaddset(&everySignal, number) }
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        if argv.dropLast().contains(where: { $0 == nil }) { closeAll(inPipe + outPipe + errPipe); throw SpawnFailure.arguments }

        var pid: pid_t = 0
        ChatQuit.childStarting()
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard status == 0 else { ChatQuit.childGone(); closeAll([inPipe[1], outPipe[0], errPipe[0]]); throw SpawnFailure.spawn(status) }
        return Spawned(pid: pid, stdin: inPipe[1], stdout: outPipe[0], stderr: errPipe[0])
    }

    private static func closeAll(_ descriptors: [Int32]) { for d in descriptors where d >= 0 { close(d) } }
    public static func closeDescriptor(_ descriptor: Int32) { close(descriptor) }

    // MARK: descriptors

    /// Writes all of `data`. False when the pipe is closed (EPIPE) or `abandon` says so; never raises a signal, never blocks past `abandon`.
    public static func writeAll(_ descriptor: Int32, _ data: Data, abandon: () -> Bool = { false }) -> Bool {
        _ = ignoreBrokenPipe
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                if abandon() { return false }
                let n = write(descriptor, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN {
                    var wait = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&wait, 1, 100)
                    continue
                }
                return false
            }
            return true
        }
    }

    /// Waits up to `milliseconds` for input. 1 readable (or at end), 0 timeout, -1 failure.
    public static func waitReadable(_ descriptor: Int32, milliseconds: Int32) -> Int32 {
        var wait = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&wait, 1, milliseconds)
        if ready < 0 { return errno == EINTR ? 0 : -1 }
        return ready > 0 ? 1 : 0
    }

    /// Up to `capacity` bytes from `descriptor`: the count, 0 at end of file, -1 on failure (EINTR is retried).
    public static func readChunk(_ descriptor: Int32, into buffer: UnsafeMutableRawPointer, capacity: Int) -> Int {
        while true {
            let n = read(descriptor, buffer, capacity)
            if n < 0, errno == EINTR { continue }
            return n
        }
    }

    // MARK: waiting for exit

    /// Blocks until `pid` (our child) is reaped: (exit code, signal), either of which is nil.
    public static func reap(_ pid: Int32) -> (code: Int32?, signal: Int32?) {
        defer { ChatQuit.childGone() }
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, 0)
            if r == pid { break }
            if r < 0, errno == EINTR { continue }
            return (nil, nil)
        }
        if status & 0x7f == 0 { return ((status >> 8) & 0xff, nil) }
        return (nil, status & 0x7f)
    }

    // MARK: identities and signals

    public static func identity(of pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return ProcessIdentity(ClawdIdentity(pid: pid, uid: info.pbi_uid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec))
    }

    /// Signals `target` only while the process with that pid still has that start time, and never the agent itself. True when a signal was sent.
    @discardableResult
    public static func signal(_ target: ProcessIdentity, _ number: Int32) -> Bool {
        guard target.pid > 1, target.pid != getpid(), target.uid == getuid(), identity(of: target.pid) == target else { return false }
        return kill(target.pid, number) == 0
    }

    /// One living same-user process: its identity, parent and process group.
    public struct Row {
        public let identity: ProcessIdentity
        public let parent: Int32
        public let group: Int32
    }

    /// Every living (not zombie) process of the agent's user, other than the agent itself, in one pass.
    public static func table() -> [Row] {
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).compactMap { pid in
            guard pid > 1, pid != getpid() else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
                  info.pbi_status != UInt32(SZOMB), info.pbi_uid == getuid() else { return nil }
            return Row(identity: ProcessIdentity(ClawdIdentity(pid: pid, uid: info.pbi_uid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)),
                       parent: Int32(info.pbi_ppid), group: Int32(info.pbi_pgid))
        }
    }

    /// What one environment read shows (spec R9.5, r10): a carrier of the token, a readable environment without it, or no environment strings
    /// at all (a platform binary hides its own; a failed read looks the same).
    public enum EnvironmentRead: Equatable { case carrier, readable, hidden }

    public static func readEnvironment(of pid: Int32, token: String) -> EnvironmentRead {
        let entries = environmentEntries(of: pid)
        if entries.isEmpty { return .hidden }
        return entries.contains(Array((tokenVariable + "=" + token).utf8)) ? .carrier : .readable
    }

    /// The executable path of `pid` (`proc_pidpath`), nil when it cannot be read.
    public static func executablePath(of pid: Int32) -> String? { try? ProcessPath.of(pid: pid) }

    /// Every row of `rows` whose environment holds the entry `CLAWD_CHAT_SPAWN=<token>` (never its arguments).
    public static func carriers(of token: String, in rows: [Row]) -> [ProcessIdentity] {
        let wanted = Array((tokenVariable + "=" + token).utf8)
        return rows.filter { environmentEntries(of: $0.identity.pid).contains(wanted) }.map(\.identity)
    }

    /// The environment strings of `pid` from KERN_PROCARGS2 (argc, the executable path, padding, argc arguments, then the environment).
    static func environmentEntries(of pid: Int32) -> [[UInt8]] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var index = 4
        func skipString() { while index < size, buffer[index] != 0 { index += 1 } }
        skipString()                                                   // the executable path
        while index < size, buffer[index] == 0 { index += 1 }          // its padding
        for _ in 0..<argc where index < size { skipString(); index += 1 }
        var entries: [[UInt8]] = []
        while index < size {
            let start = index
            skipString()
            if index > start { entries.append(Array(buffer[start..<index])) }
            index += 1
        }
        return entries
    }
}

// MARK: the agent's quit (SIGTERM) while a chat child lives or a cleanup runs

/// SIGTERM handling of the agent (spec F2.6, agent quit). The handler, the hold count and the pipe's write end live in C (`ClawdProcess/quit.c`:
/// two lock-free atomics, async-signal-safe calls only). A caught signal goes back to its default across exec, so no child inherits it; an
/// ignored one would be inherited by every child. Installed by the production boot path only.
///
/// The count covers live chat children and running cleanups (a stop's sweep). With a count of 0 SIGTERM keeps its default and kills the agent at
/// once; otherwise the handler writes a byte and the main queue runs `onQuit`, then the agent dies of SIGTERM.
public enum ChatQuit {
    private static let lock = NSLock()
    private static var source: DispatchSourceRead?

    /// A chat child is about to exist (before the spawn call, so a SIGTERM during the spawn already sees it).
    static func childStarting() { clawd_quit_retain() }
    /// A chat child was reaped (or never started).
    static func childGone() { clawd_quit_release() }
    /// A cleanup (a stop's sweep) is about to run; the agent must not die before `cleanupEnded`.
    static func cleanupStarting() { clawd_quit_retain() }
    static func cleanupEnded() { clawd_quit_release() }

    /// Installs the SIGTERM handler. `onQuit` runs on the main queue when SIGTERM arrived while a chat child lived or a cleanup ran; when it returns
    /// the agent dies of SIGTERM. False when the pipe or the handler could not be set up (SIGTERM then keeps its default).
    @discardableResult
    public static func install(onQuit: @escaping () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard source == nil else { return true }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return false }
        for descriptor in ends { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(ends[1], F_SETFL, fcntl(ends[1], F_GETFL) | O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: ends[0], queue: .main)
        reader.setEventHandler {
            var byte: UInt8 = 0
            _ = read(ends[0], &byte, 1)
            onQuit()
            clawd_quit_default()
        }
        reader.resume()
        guard clawd_quit_install(ends[1]) == 0 else { reader.cancel(); close(ends[0]); close(ends[1]); return false }
        source = reader
        return true
    }
}
