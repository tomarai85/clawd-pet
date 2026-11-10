import Foundation
import Darwin
import ClawdProcess

/// What a terminal spawn needs (spec R9.2 T-1): the command line, F2.1's environment plus TERM and COLORTERM, the folder and the grid.
public struct ChatTermLaunch {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String
    public var columns: Int
    public var rows: Int
    public var token: String

    public init(executable: String, arguments: [String], environment: [String: String], directory: String, columns: Int, rows: Int, token: String) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.directory = directory
        self.columns = columns; self.rows = rows; self.token = token
    }

    public enum Mode: Equatable { case fresh(String), resume(String) }

    /// `--session-id <uuid>` or `--resume <id>`, the permission mode and `--model` when set; never `-p`, `--continue` or a stream-json flag.
    public static func arguments(mode: Mode, permissions: ChatPermissions, model: String?) -> [String] {
        var result: [String]
        switch mode {
        case .fresh(let id): result = ["--session-id", id]
        case .resume(let id): result = ["--resume", id]
        }
        // `deny` is claude's dontAsk: whatever would prompt is refused. It runs what the user's own Claude Code rules allow (P-T1 4a/4b).
        result += ["--permission-mode", permissions == .bypass ? "bypassPermissions" : "dontAsk"]
        if let model { result += ["--model", model] }
        return result
    }

    /// The guard's environment: F2.1's without the spawn token (it comes as an argument, so no sweep counts the guard as a carrier) and without TERM.
    public static func guardEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        for name in [ChatProc.tokenVariable, "TERM", "COLORTERM"] { result.removeValue(forKey: name) }
        return result
    }

    /// F2.1's environment, built from scratch, plus TERM=xterm-256color and COLORTERM=truecolor.
    public static func environment(_ settings: ChatSettings, token: String) -> [String: String] {
        var env = ChatSession.environment(settings, token: token)
        // The idle and lifecycle frames belong to the stream path's turn bookkeeping (Q13); a terminal child draws its own screen.
        env.removeValue(forKey: ChatSession.stateEventsVariable)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        return env
    }
}

public enum ChatTermRefusal: Error, Equatable {
    case missingBinary, folderMissing, stateUnwritable, guardFailed, spawnFailed(Int32)
    /// The `reason=` of the `CHAT refuse` line.
    public var reason: String {
        switch self {
        case .missingBinary: return "missing-binary"
        case .folderMissing: return "folder-missing"
        case .stateUnwritable: return "state-unwritable"
        case .guardFailed: return "guard-failed"
        case .spawnFailed: return "spawn-failed"
        }
    }

    /// The real binary (symlinks resolved, a regular executable) and the folder (a directory), checked before anything is spawned.
    public static func resolve(_ settings: ChatSettings) -> Result<String, ChatTermRefusal> {
        guard let resolved = settings.claudeLocation().resolved else { return .failure(.missingBinary) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: settings.folder, isDirectory: &isDirectory), isDirectory.boolValue else { return .failure(.folderMissing) }
        return .success(resolved)
    }
}

public enum ChatTermSpawnKind: Equatable { case terminalGuard, child }

/// What one terminal child needs from outside. Closures marked "main" run on the main queue; the others on a thread of their own.
public struct ChatTermConfig {
    /// The agent binary: the trampoline (`--pty-exec`) and the guard (`--term-guard`) are its headless modes.
    public var agent: String
    public var state: ChatTermState?
    public var log: (String) -> Void = { _ in }                          // main
    /// The master's bytes, as they are read. Reader thread.
    public var onBytes: (Data) -> Void = { _ in }
    /// The child was reaped. Main, before its sweep.
    public var onExit: (_ code: Int32?, _ signal: Int32?) -> Void = { _, _ in }
    /// A stop's sweep ended. Main.
    public var onStopped: (_ killed: Int, _ left: Int) -> Void = { _, _ in }
    /// The guard ended without a release while the child lived; the child is being hard-stopped. Main.
    public var onGuardLost: () -> Void = {}
    public var stopSeconds: TimeInterval = 3
    /// How often the sweep set grows while the child lives; 0 for none (a test drives `growOnce`).
    public var trackSeconds: TimeInterval = 1
    public var ctrlZDelay: TimeInterval = 0.2
    /// The most bytes the write queue holds (spec T-1: 16 MiB); a test lowers it to prove the refusal without pasting that much.
    public var maxPendingBytes = ChatTermChild.maxPendingBytes
    /// Test seams: the PTY's descriptors right after they are opened; each spawn right before it; each master close (descriptor, on the reader thread).
    public var ptyObserver: ((Int32, Int32) -> Void)?
    public var spawnObserver: ((ChatTermSpawnKind) -> Void)?
    public var masterCloseObserver: ((_ descriptor: Int32, _ onReaderThread: Bool, _ byWake: Bool) -> Void)?
    /// A test seam: every line the agent writes to the guard's channel, before it is written (any thread).
    public var channelObserver: ((String) -> Void)?

    public init(agent: String, state: ChatTermState?) { self.agent = agent; self.state = state }
}

/// One terminal child: claude in a PTY, started through the agent's trampoline, with its guard, its sweep set and its stop (spec R9.2 T-1, T-5,
/// T-7, T-9). Everything public is called on the main queue.
public final class ChatTermChild {
    public static let maxPendingBytes = 16 * 1024 * 1024

    public let pid: Int32
    public let identity: ProcessIdentity?
    public let token: String
    public let guardPid: Int32
    let sweep: ChatSweepSet

    private let config: ChatTermConfig
    private let master: Int32
    private let wakeRead: Int32, wakeWrite: Int32
    private let channel: ChatTermChannel
    private let masterLock = NSLock()
    private var masterClosed = false
    private let writes = DispatchQueue(label: "clawd.term.write")
    private let stopQueue = DispatchQueue(label: "clawd.term.stop")
    private let trackQueue = DispatchQueue(label: "clawd.term.track", qos: .utility)
    private let stateLock = NSLock()
    private let memberLock = NSLock()
    private var sentMembers = Set<String>()
    private var recordedMembers = Set<String>()
    private var memberWriteFailed = false
    private var memberFailureLogged = false
    private var pending = 0
    private var writesAbandoned = false
    private var exitedFlag = false
    private var hardFlag = false
    private var stoppingFlag = false
    private var stoppedFlag = false
    private var releasedFlag = false
    private var cleanupHeld = true
    private var tracker: DispatchSourceTimer?
    /// Left when claude has been reaped.
    private let reaped = DispatchGroup()
    private let executeDone = DispatchSemaphore(value: 0)
    private let readerDone = DispatchSemaphore(value: 0)
    private var finishedFlag = false

    private init(config: ChatTermConfig, pid: Int32, token: String, master: Int32, wake: (Int32, Int32), channel: ChatTermChannel, guardPid: Int32) {
        self.config = config; self.pid = pid; self.token = token; self.master = master; wakeRead = wake.0; wakeWrite = wake.1
        self.channel = channel; self.guardPid = guardPid
        identity = ChatProc.identity(of: pid)
        sweep = ChatSweepSet(token: token, pid: pid, identity: identity)
        reaped.enter()
        ChatQuit.cleanupStarting()
    }
    deinit { releaseCleanup() }

    // MARK: start

    /// The spawn order of T-9: the token is flushed to chat-state.json; the guard is spawned and its identity recorded; claude is spawned through
    /// the trampoline and its identity recorded; the guard gets the child line. A token or guard that cannot be written or spawned refuses the
    /// spawn, so no terminal child ever runs unguarded.
    public static func start(_ launch: ChatTermLaunch, config: ChatTermConfig) throws -> ChatTermChild {
        guard let state = config.state else { throw ChatTermRefusal.stateUnwritable }
        do { try state.begin(token: launch.token) } catch { throw ChatTermRefusal.stateUnwritable }
        func abandon(guardPid: Int32?, channel: [Int32], fail: ChatTermRefusal) -> ChatTermRefusal {
            if let guardPid, let write = channel.last { _ = TermProc.sendLine(write, "{\"release\":true}"); Thread { _ = TermProc.reapGuard(guardPid) }.start() }
            channel.forEach(TermProc.closeDescriptor)
            try? state.dropToken(launch.token); try? state.clearChild(token: launch.token)
            return fail
        }

        guard let ends = try? TermProc.makePipe() else { throw abandon(guardPid: nil, channel: [], fail: .guardFailed) }
        TermProc.setNonBlocking(ends.write)
        let me = ChatProc.identity(of: getpid())
        config.spawnObserver?(.terminalGuard)
        let guardPid: Int32
        do {
            guardPid = try TermProc.spawnGuard(
                agent: config.agent,
                arguments: ["--agent-pid", String(getpid()), "--agent-start", "\(me?.seconds ?? 0).\(me?.microseconds ?? 0)", "--token", launch.token],
                environment: ChatTermLaunch.guardEnvironment(launch.environment), channelRead: ends.read)
        } catch {
            throw abandon(guardPid: nil, channel: [ends.read, ends.write], fail: .guardFailed)
        }
        TermProc.closeDescriptor(ends.read)
        guard let guardIdentity = ChatProc.identity(of: guardPid), (try? state.recordGuard(guardIdentity, token: launch.token)) != nil else {
            throw abandon(guardPid: guardPid, channel: [ends.write], fail: .stateUnwritable)
        }
        config.log("CHAT guard pid=\(guardPid)")

        let pair: TermProc.Pair
        do { pair = try TermProc.openPair(columns: launch.columns, rows: launch.rows, observer: config.ptyObserver) } catch {
            var code: Int32 = 0
            if case TermProc.Failure.ptyOpen(let e)? = error as? TermProc.Failure { code = e }
            throw abandon(guardPid: guardPid, channel: [ends.write], fail: .spawnFailed(code))
        }
        config.spawnObserver?(.child)
        let pid: Int32
        do {
            pid = try TermProc.spawnTrampoline(agent: config.agent, executable: launch.executable, arguments: launch.arguments,
                                               environment: launch.environment, directory: launch.directory, slave: pair.slave)
        } catch {
            TermProc.closeDescriptor(pair.master); TermProc.closeDescriptor(pair.slave)
            var code: Int32 = 0
            if case TermProc.Failure.spawn(let e)? = error as? TermProc.Failure { code = e }
            throw abandon(guardPid: guardPid, channel: [ends.write], fail: .spawnFailed(code))
        }
        // The agent's slave is closed right after the spawn, so the master sees the end when the last process holding the slave is gone.
        TermProc.closeDescriptor(pair.slave)
        guard let wake = try? TermProc.makePipe() else {
            TermProc.closeDescriptor(pair.master)
            throw abandon(guardPid: guardPid, channel: [ends.write], fail: .spawnFailed(0))
        }
        TermProc.setNonBlocking(wake.write)
        let channel = ChatTermChannel(descriptor: ends.write, log: config.log, observer: config.channelObserver)
        let child = ChatTermChild(config: config, pid: pid, token: launch.token, master: pair.master, wake: wake, channel: channel, guardPid: guardPid)
        if let identity = child.identity {
            try? state.recordChild(pid: pid, pgid: pid, identity: identity, token: launch.token)
            channel.child(pid: pid, pgid: pid, identity: identity)
        }
        child.startThreads()
        return child
    }

    // MARK: threads

    private func startThreads() {
        func thread(_ name: String, _ body: @escaping () -> Void) {
            let t = Thread(block: body); t.name = name; t.stackSize = 512 * 1024; t.start()
        }
        thread("clawd.term.read") { [self] in readLoop() }
        thread("clawd.term.reap") { [self] in reapLoop() }
        thread("clawd.term.guard") { [self] in guardLoop() }
        startTracking()
    }

    /// The only reader and the only closer of the master. It waits on the master and on the wake descriptor, with no timeout: it runs when
    /// there is output, when the master ends, or when the stop's end or the teardown writes to the wake descriptor.
    private func readLoop() {
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        // A kqueue, not poll(2): poll does not support devices on macOS. It watches the master and the wake descriptor and has no timeout.
        let queue = clawd_kq_create()
        var byWake = false
        if queue < 0 || clawd_kq_watch_read(queue, master) != 0 || clawd_kq_watch_read(queue, wakeRead) != 0 {
            byWake = true          // could not wait: the master is closed below and the child hangs up (fail closed)
        } else {
            loop: while true {
                var kind: Int32 = 0, ident: Int32 = 0
                guard clawd_kq_wait(queue, &kind, &ident) == 0 else { break }
                if ident == wakeRead { byWake = true; break }
                let count = ChatProc.readChunk(master, into: buffer, capacity: capacity)
                if count > 0 { config.onBytes(Data(bytes: buffer, count: count)); continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break loop
            }
        }
        if queue >= 0 { TermProc.closeDescriptor(queue) }
        // The write queue stops first: nothing writes a descriptor that is about to be closed.
        stateLock.lock(); writesAbandoned = true; stateLock.unlock()
        writes.sync {}
        masterLock.lock()
        masterClosed = true
        TermProc.closeDescriptor(master)
        TermProc.closeDescriptor(wakeRead); TermProc.closeDescriptor(wakeWrite)
        masterLock.unlock()
        config.masterCloseObserver?(master, Thread.current.name == "clawd.term.read", byWake)
        readerDone.signal()
    }

    /// The view's teardown: the reader closes the master, which hangs claude up through the kernel. The only way the master closes besides
    /// the end of the master and the end of a stop.
    public func teardown() { wakeReader() }

    /// Ends the reader (and so closes the master) when claude's last process may still hold the slave.
    private func wakeReader() {
        masterLock.lock(); defer { masterLock.unlock() }
        if !masterClosed { _ = ChatProc.writeAll(wakeWrite, Data([1]), abandon: { false }) }     // the reader closes the wake pipe with the master
    }

    private func reapLoop() {
        let status = TermProc.reap(pid, stopped: { [self] in
            if let identity, TermProc.resume(identity) {
                DispatchQueue.main.async { self.config.log("CHAT term continued pid=\(self.pid) cause=stopped") }
            }
        })
        stopTracking()
        stateLock.lock(); exitedFlag = true; stateLock.unlock()
        reaped.leave()
        // What the child wrote before it exited is handed over first (a detached grandchild can hold the slave, so the wait is bounded).
        _ = readerDone.wait(timeout: .now() + 0.5)
        DispatchQueue.main.async { [self] in
            config.log("CHAT term exit pid=\(pid) code=\(status.code.map(String.init) ?? "none") signal=\(status.signal.map(String.init) ?? "none")")
            config.onExit(status.code, status.signal)
            // A sweep follows every reap, whatever the cause.
            stop(graceful: false, reason: nil)
        }
    }

    private func guardLoop() {
        _ = TermProc.reapGuard(guardPid)
        stateLock.lock(); let released = releasedFlag; stateLock.unlock()
        if released {
            try? config.state?.clearChild(token: token)
            return
        }
        DispatchQueue.main.async { [self] in
            config.log("CHAT guard-lost pid=\(guardPid)")
            config.onGuardLost()
            stop(graceful: false, reason: "guard-lost")
        }
    }

    // MARK: tracking

    private func startTracking() {
        guard config.trackSeconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: trackQueue)
        timer.schedule(deadline: .now() + config.trackSeconds, repeating: config.trackSeconds, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in _ = self?.grow(.tracking) }
        stateLock.lock(); tracker = timer; stateLock.unlock()
        timer.resume()
    }
    private func stopTracking() { stateLock.lock(); let timer = tracker; tracker = nil; stateLock.unlock(); timer?.cancel() }
    /// One growth of the sweep set now (a test drives it when the tracking is off).
    @discardableResult public func growOnce() -> [ProcessIdentity] { grow(.tracking) }

    /// One growth of the sweep set (the tracker's, the stop's or a test's), and the members it found, in the same turn: each identity not yet
    /// sent goes to the guard as a `member` line, and when the growth added an identity not yet recorded for this token (or the last write failed)
    /// chat-state.json's `members[token]` becomes the growth's living members, claude excluded (R9.12 item 1.1). A growth that added nothing sends
    /// and writes nothing.
    @discardableResult
    func grow(_ mode: ChatSweepSet.Mode) -> [ProcessIdentity] {
        let living = sweep.grow(mode)
        announce(living.filter { $0.pid != pid })
        return living
    }

    private func announce(_ members: [ProcessIdentity]) {
        memberLock.lock(); defer { memberLock.unlock() }
        let alive = Set(members.map(ChatSweepSet.key))
        sentMembers.formIntersection(alive)
        for id in members where !sentMembers.contains(ChatSweepSet.key(id)) {
            sentMembers.insert(ChatSweepSet.key(id))
            channel.member(id)
        }
        guard let state = config.state, memberWriteFailed || !alive.isSubset(of: recordedMembers) else { return }
        do {
            try state.setMembers(members.map { ChatState.Identity($0) }, token: token)
            recordedMembers = alive
            memberWriteFailed = false
        } catch {
            memberWriteFailed = true
            if !memberFailureLogged {
                memberFailureLogged = true
                let report = config.log
                DispatchQueue.main.async { report("CHAT notice kind=state-unwritable") }
            }
        }
    }

    // MARK: bytes in

    /// Queues `data` for claude. False, and nothing queued, when it would take the pending bytes over 16 MiB or the master is going away.
    /// The write runs on the write queue, off the calling thread, so a claude that reads nothing never blocks the main queue.
    @discardableResult
    public func send(_ data: Data) -> Bool {
        stateLock.lock()
        if writesAbandoned || pending + data.count > config.maxPendingBytes { stateLock.unlock(); return false }
        pending += data.count
        stateLock.unlock()
        if Self.containsControlZ(data) { armContinue() }
        let work = { [self] in
            _ = TermProc.writeAll(master, data, abandon: { self.stateLock.lock(); defer { self.stateLock.unlock() }; return self.writesAbandoned })
            stateLock.lock(); pending -= data.count; stateLock.unlock()
        }
        writes.async(execute: work)
        return true
    }

    /// Whether `data` holds a Ctrl+Z byte (memchr: a 1 MiB paste is scanned in microseconds even in an unoptimised build).
    private static func containsControlZ(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in raw.baseAddress.map { memchr($0, 0x1a, raw.count) != nil } ?? false }
    }

    /// The pending bytes (a test).
    public var pendingBytes: Int { stateLock.lock(); defer { stateLock.unlock() }; return pending }

    /// What the write queue can still take: its cap minus its pending bytes.
    public var room: Int { stateLock.lock(); defer { stateLock.unlock() }; return max(0, config.maxPendingBytes - pending) }

    /// 200 ms after a Ctrl+Z byte was forwarded, SIGCONT to claude, identity-checked: a program that left raw mode before a SIGTSTP the kernel
    /// discards (claude's group is orphaned) answers it by restoring raw mode. One one-shot, armed only by that key.
    private func armContinue() {
        guard let identity else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + config.ctrlZDelay) { [self] in
            if TermProc.resume(identity) {
                DispatchQueue.main.async { self.config.log("CHAT term continued pid=\(self.pid) cause=ctrl-z") }
            }
        }
    }

    /// The grid followed the panel: the new window size reaches claude, which gets SIGWINCH as the foreground group of its terminal.
    public func resize(columns: Int, rows: Int) {
        masterLock.lock(); defer { masterLock.unlock() }
        if !masterClosed { _ = TermProc.setWindowSize(master, columns: columns, rows: rows) }
    }

    // MARK: stop

    public var isStopping: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stoppingFlag }
    public var hasEnded: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stoppedFlag }
    public var hasExited: Bool { stateLock.lock(); defer { stateLock.unlock() }; return exitedFlag }
    private var hardRequested: Bool { stateLock.lock(); defer { stateLock.unlock() }; return hardFlag }

    /// Begins the stop of T-7: one deadline D = T0 + 3 s; claude and the living members of its group are hung up at T0 (SIGHUP, never by
    /// closing the master); then the slice's timeline. `reason` is the `CHAT stop reason=` of the line; nil for the sweep after a reap.
    public func stop(graceful: Bool, reason: String?) {
        stateLock.lock()
        if stoppingFlag || stoppedFlag {
            // A hard stop asked for during a running graceful one upgrades it.
            let upgrade = !graceful && stoppingFlag && !stoppedFlag && !hardFlag
            if !graceful { hardFlag = true }
            stateLock.unlock()
            if upgrade, let reason { config.log("CHAT stop reason=\(reason) upgraded=1") }
            return
        }
        stoppingFlag = true
        if !graceful { hardFlag = true }
        stateLock.unlock()
        if let reason { config.log("CHAT stop reason=\(reason)") }
        let seconds = config.stopSeconds
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        channel.stop(deadlineNs: deadline)
        stopQueue.async { [self] in
            let result = Self.execute(self, graceful: graceful, seconds: seconds)
            stateLock.lock(); executed = result; stateLock.unlock()
            executeDone.signal()
            DispatchQueue.main.async { self.completeStop() }
        }
    }

    private var executed: (killed: Int, left: Int)?

    /// The agent's quit path, on the main queue: waits (the main queue is not needed by the sweep) until the stop's sweep has ended or `timeout`
    /// passed, then finishes the stop here and now, so the guard is released before the agent dies.
    public func waitForStop(timeout: TimeInterval) {
        _ = executeDone.wait(timeout: .now() + timeout)
        completeStop()
    }

    /// Runs the end of the stop once, whoever gets here first.
    private func completeStop() {
        stateLock.lock()
        guard let result = executed, !finishedFlag else { stateLock.unlock(); return }
        finishedFlag = true
        stateLock.unlock()
        finishStop(killed: result.killed, left: result.left)
    }

    private func finishStop(killed: Int, left: Int) {
        config.log("CHAT sweep n=\(killed) left=\(left)")
        if left == 0 { try? config.state?.dropToken(token) } else { config.log("CHAT notice kind=stop-incomplete") }
        // The stop (or the sweep after claude's reap) has ended: the guard is released, and the reader closes the master.
        stateLock.lock(); releasedFlag = true; stoppingFlag = false; stoppedFlag = true; stateLock.unlock()
        channel.release()
        wakeReader()
        config.onStopped(killed, left)
        releaseCleanup()
    }

    private func releaseCleanup() {
        stateLock.lock(); let held = cleanupHeld; cleanupHeld = false; stateLock.unlock()
        if held { ChatQuit.cleanupEnded() }
    }

    /// The timeline of F2.2 for the terminal, on the stop queue: SIGHUP at T0 to claude and its group; a hard stop sends SIGTERM at T0, a
    /// graceful one at T0 + 1 s or at claude's reap if that comes first; SIGKILL at D - 1 s and again to anything new until D; the verdict at D
    /// counts what is still alive. It ends early once claude is reaped and nothing is left.
    static func execute(_ child: ChatTermChild, graceful: Bool, seconds: TimeInterval) -> (killed: Int, left: Int) {
        let start = ProcessInfo.processInfo.systemUptime
        func elapsed() -> TimeInterval { ProcessInfo.processInfo.systemUptime - start }
        var signalled = Set<String>()
        func refresh() -> [ProcessIdentity] { child.grow(.fresh) }
        func send(_ number: Int32) {
            for id in refresh() where ChatProc.signal(id, number) { signalled.insert(ChatSweepSet.key(id)) }
        }
        func reaped(within seconds: TimeInterval) -> Bool { child.reaped.wait(timeout: .now() + seconds) == .success }

        TermProc.hangUp(leader: child.identity, group: child.pid)
        _ = refresh()
        if graceful {
            while elapsed() < seconds - 2, !child.hardRequested, !reaped(within: 0.02) {}
        }
        send(SIGTERM)
        while elapsed() < seconds - 1 {
            Thread.sleep(forTimeInterval: 0.05)
            if child.hasExited, refresh().isEmpty { return (signalled.count, 0) }
        }
        send(SIGKILL)
        while elapsed() < seconds {
            Thread.sleep(forTimeInterval: 0.05)
            if child.hasExited, refresh().isEmpty { return (signalled.count, 0) }
            send(SIGKILL)
        }
        return (signalled.count, refresh().count)
    }
}
