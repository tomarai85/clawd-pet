import Foundation
import Darwin
import ClawdProcess

/// The process-level primitives of the terminal path (spec R9.2 T-1, T-5, T-7, T-9): the PTY, the posix_spawn of the trampoline and of the guard,
/// the waitpid that sees a stopped child, the writes to the master and to the guard's channel. With ChatProcess.swift, the only file of the
/// chat code that spawns, signals or writes to a descriptor; the lint exempts it by name. No fork anywhere: Clawd's own posix_spawn.
public enum TermProc {
    public struct Pair { public let master: Int32; public let slave: Int32 }
    public enum Failure: Error, Equatable { case ptyOpen(Int32), spawn(Int32), pipe(Int32), arguments }

    /// The slice's signal defaults for a child (ChatProcess.spawn): the signals the agent may have changed go back to their defaults.
    private static let defaultedSignals = [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGALRM, SIGTERM, SIGUSR1, SIGUSR2, SIGCHLD]
    private static let nameLock = NSLock()

    // MARK: the PTY

    /// `/dev/ptmx` and the slave, both opened with O_CLOEXEC, so a spawn on another thread of the agent between the open and the spawn inherits
    /// neither. The window size is set on the master before the child exists. `observer` sees both descriptors right after they are opened.
    public static func openPair(columns: Int, rows: Int, observer: ((Int32, Int32) -> Void)? = nil) throws -> Pair {
        let master = Darwin.open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard master >= 0 else { throw Failure.ptyOpen(errno) }
        guard grantpt(master) == 0, unlockpt(master) == 0 else { let e = errno; close(master); throw Failure.ptyOpen(e) }
        nameLock.lock()
        let name = ptsname(master).map { String(cString: $0) }
        nameLock.unlock()
        guard let name else { close(master); throw Failure.ptyOpen(ENOTTY) }
        let slave = Darwin.open(name, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard slave >= 0 else { let e = errno; close(master); throw Failure.ptyOpen(e) }
        _ = clawd_pty_set_size(master, Int32(columns), Int32(rows))
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        observer?(master, slave)
        return Pair(master: master, slave: slave)
    }

    public static func setWindowSize(_ master: Int32, columns: Int, rows: Int) -> Bool { clawd_pty_set_size(master, Int32(columns), Int32(rows)) == 0 }

    public static func descriptorFlags(_ descriptor: Int32) -> Int32 { fcntl(descriptor, F_GETFD) }

    public static func closeDescriptor(_ descriptor: Int32) { close(descriptor) }

    /// A pipe whose two ends are close-on-exec.
    public static func makePipe() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw Failure.pipe(errno) }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        return (ends[0], ends[1])
    }

    public static func setNonBlocking(_ descriptor: Int32) { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) }

    // MARK: spawn

    private static func attributes() -> posix_spawnattr_t? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        var everySignal = sigset_t(), noSignal = sigset_t()
        sigemptyset(&everySignal); sigemptyset(&noSignal)
        for number in defaultedSignals { sigaddset(&everySignal, number) }
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        // A session leader is its own group leader; SETSID replaces the slice's SETPGROUP, because a group leader cannot call setsid.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        return attributes
    }

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] { strings.map { strdup($0) } + [nil] }

    /// Starts `agent --pty-exec -- executable arguments...` with the slave as descriptors 0-2 and `directory` as the working directory: the
    /// trampoline closes the rest, takes the slave as its controlling terminal and execs `executable` in place, so the pid returned is claude's.
    public static func spawnTrampoline(agent: String, executable: String, arguments: [String], environment: [String: String], directory: String,
                                       slave: Int32) throws -> Int32 {
        ChatQuit.childStarting()
        var attributes = attributes(); defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        for number: Int32 in 0...2 { posix_spawn_file_actions_adddup2(&actions, slave, number) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        let argv = cStrings([agent, "--pty-exec", "--", executable] + arguments)
        let envp = cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer { (argv + envp).forEach { free($0) } }
        if argv.dropLast().contains(where: { $0 == nil }) { ChatQuit.childGone(); throw Failure.arguments }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, agent, &actions, &attributes, argv, envp)
        guard status == 0 else { ChatQuit.childGone(); throw Failure.spawn(status) }
        return pid
    }

    /// Starts the terminal guard: descriptor 0 the read end of the channel, 1 and 2 /dev/null, a session of its own, nothing else inherited.
    public static func spawnGuard(agent: String, arguments: [String], environment: [String: String], channelRead: Int32) throws -> Int32 {
        var attributes = attributes(); defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, channelRead, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv = cStrings([agent, "--term-guard"] + arguments)
        let envp = cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer { (argv + envp).forEach { free($0) } }
        if argv.dropLast().contains(where: { $0 == nil }) { throw Failure.arguments }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, agent, &actions, &attributes, argv, envp)
        guard status == 0 else { throw Failure.spawn(status) }
        return pid
    }

    // MARK: waiting

    /// Blocks until `pid` (our child) ends. A child that stops is reported to `stopped` (the caller continues it) and waited for again:
    /// (exit code, signal), either of which is nil.
    public static func reap(_ pid: Int32, stopped: () -> Void) -> (code: Int32?, signal: Int32?) {
        defer { ChatQuit.childGone() }
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WUNTRACED)
            if result == pid {
                if status & 0xff == 0x7f { stopped(); continue }
                break
            }
            if result < 0, errno == EINTR { continue }
            return (nil, nil)
        }
        if status & 0x7f == 0 { return ((status >> 8) & 0xff, nil) }
        return (nil, status & 0x7f)
    }

    /// Waits for the guard (the agent is its parent): its exit status, or nil.
    public static func reapGuard(_ pid: Int32) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { break }
            if result < 0, errno == EINTR { continue }
            return nil
        }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    // MARK: signals

    /// SIGHUP to the process and the living members of its group, each identity-checked: what the master's close would deliver, without closing it.
    @discardableResult
    public static func hangUp(leader: ProcessIdentity?, group: Int32) -> Int {
        var sent = 0
        if let leader, ChatProc.signal(leader, SIGHUP) { sent += 1 }
        for row in ChatProc.table() where row.group == group {
            if ChatProc.signal(row.identity, SIGHUP) { sent += 1 }
        }
        return sent
    }

    /// SIGCONT to a stopped child, identity-checked.
    @discardableResult
    public static func resume(_ target: ProcessIdentity) -> Bool { ChatProc.signal(target, SIGCONT) }

    // MARK: bytes

    /// Writes all of `data` to the non-blocking master. A full PTY (EAGAIN) is waited out with a short, growing sleep, not poll(2), which does
    /// not support devices on macOS. False when the master is gone or `abandon` says so; never raises a signal, never blocks past `abandon`.
    public static func writeAll(_ descriptor: Int32, _ data: Data, abandon: () -> Bool) -> Bool {
        var offset = 0
        var pause: useconds_t = 2_000
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                if abandon() { return false }
                let n = write(descriptor, base + offset, raw.count - offset)
                if n > 0 { offset += n; pause = 2_000; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { usleep(pause); pause = min(pause * 2, 50_000); continue }
                return false
            }
            return true
        }
    }

    /// One line to the guard's channel (non-blocking, under 512 bytes). False when the pipe is gone or full.
    public static func sendLine(_ descriptor: Int32, _ text: String) -> Bool {
        let data = Data((text + "\n").utf8)
        guard data.count < 512 else { return false }
        return ChatProc.writeAll(descriptor, data, abandon: { false })
    }

    /// A write to the non-blocking channel that gives up after `seconds`: done, full (the pipe stayed full, nobody is reading), or broken (the
    /// reader is gone). A write of under PIPE_BUF bytes goes whole or not at all, so a line is never split.
    enum Written { case done, full, broken }
    private static let ignoreBrokenPipe: Void = { _ = Darwin.signal(SIGPIPE, SIG_IGN) }()

    static func writeBounded(_ descriptor: Int32, _ data: Data, seconds: TimeInterval) -> Written {
        _ = ignoreBrokenPipe
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        var offset = 0
        return data.withUnsafeBytes { raw -> Written in
            guard let base = raw.baseAddress else { return .done }
            while offset < raw.count {
                let n = write(descriptor, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    if DispatchTime.now().uptimeNanoseconds >= deadline { return .full }
                    usleep(2_000)
                    continue
                }
                return .broken
            }
            return .done
        }
    }
}

/// The agent's end of the guard's channel (R9.12 item 1.2). It is written from the main queue (the child, stop and release lines), the tracker's
/// queue and the stop queue (member lines), and closed on the main queue at the release. Every write and the close happen under one lock, and
/// nothing is written after the close, so no thread writes a descriptor number that may have been closed and reused. A line that cannot be
/// written within 100 ms (the guard is not reading) is dropped and counted; the first drop logs `CHAT notice kind=guard-channel-full`.
final class ChatTermChannel {
    static let bound: TimeInterval = 0.1

    private let lock = NSLock()
    private let descriptor: Int32
    private var closed = false
    private var droppedLines = 0
    private var reported = false
    /// The `CHAT` log (main queue).
    private let log: (String) -> Void
    /// A test seam: every line, before it is written.
    private let observer: ((String) -> Void)?

    init(descriptor: Int32, log: @escaping (String) -> Void, observer: ((String) -> Void)? = nil) {
        self.descriptor = descriptor; self.log = log; self.observer = observer
    }

    /// Lines dropped because the pipe stayed full.
    var dropped: Int { lock.lock(); defer { lock.unlock() }; return droppedLines }

    /// One line, bounded by `bound`. False when it was not written (a full pipe, a gone guard, a closed channel, a line of 512 bytes or more).
    @discardableResult
    func send(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return put(text)
    }

    /// With the lock held.
    private func put(_ text: String) -> Bool {
        guard !closed else { return false }
        observer?(text)
        let data = Data((text + "\n").utf8)
        guard data.count < 512 else { return false }
        switch TermProc.writeBounded(descriptor, data, seconds: Self.bound) {
        case .done: return true
        case .broken: return false
        case .full:
            droppedLines += 1
            if !reported {
                reported = true
                let report = log
                DispatchQueue.main.async { report("CHAT notice kind=guard-channel-full") }
            }
            return false
        }
    }

    @discardableResult
    func child(pid: Int32, pgid: Int32, identity: ProcessIdentity) -> Bool {
        send("{\"child\":{\"pid\":\(pid),\"pgid\":\(pgid),\"startSec\":\(identity.seconds),\"startUsec\":\(identity.microseconds)}}")
    }
    @discardableResult
    func member(_ identity: ProcessIdentity) -> Bool {
        send("{\"member\":{\"pid\":\(identity.pid),\"startSec\":\(identity.seconds),\"startUsec\":\(identity.microseconds)}}")
    }
    @discardableResult
    func stop(deadlineNs: UInt64) -> Bool { send("{\"stop\":{\"deadlineNs\":\(deadlineNs)}}") }

    /// The release line, then the close, under one lock.
    func release() {
        lock.lock(); defer { lock.unlock() }
        _ = put("{\"release\":true}")
        closeHeld()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closeHeld()
    }

    private func closeHeld() {
        guard !closed else { return }
        closed = true
        TermProc.closeDescriptor(descriptor)
    }
}

/// The trampoline (`clawd-pet-agent --pty-exec -- <claude> <arguments>`, spec R9.2 T-1, r10): runs first in the agent binary's main.swift, before
/// the launch guard, the lock and any application object. It closes every descriptor above 2, makes descriptor 0 its controlling terminal and
/// execs in place, with the environment it was given.
public enum TermExec {
    public static func run(_ arguments: [String]) -> Never {
        guard arguments.count >= 2, arguments[0] == "--" else { fail(EINVAL) }
        if clawd_close_descriptors_above(2) < 0 { fail(errno) }
        if clawd_pty_take_controlling(0) != 0 { fail(errno) }
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.dropFirst().map { strdup($0) } + [nil]
        execv(arguments[1], argv)
        fail(errno)
    }

    private static func fail(_ code: Int32) -> Never {
        let line = Array("clawd: Claude Code could not be started (\(code))\n".utf8)
        _ = line.withUnsafeBufferPointer { write(2, $0.baseAddress, $0.count) }
        exit(127)
    }
}
