import AppKit
import ClawdCore

/// What the terminal path takes from the machine it runs on (spec R9.2). Production values are in `RuntimeEnvironment.production`; a rig supplies
/// its own, so no test touches the real pasteboard, a real memory-pressure source or a real timer.
public struct ChatTermEnvironment {
    /// The agent binary: the trampoline and the guard are its headless modes.
    public var agent: String
    public var state: ChatTermState?
    /// The one-shot timers of the terminal path (idle 600 s, the one-minute re-check, the 3,600 s draft cap).
    public var timers: ChatTimers
    public var pasteboard: ChatPasteboardSource
    /// A memory-pressure source (warning and critical); the handler runs on the main queue. The token keeps it alive; nil cancels nothing.
    public var memoryPressure: (@escaping () -> Void) -> ChatTermCancellable?
    /// Seconds on one monotonic clock.
    public var now: () -> TimeInterval
    /// Seconds a resume has to fail in to count as failed early (T-6).
    public var resumeFailSeconds: TimeInterval
    public var trackSeconds: TimeInterval
    /// The write queue's cap (16 MiB; a test lowers it).
    public var maxPendingBytes: Int
    public var spawn: (ChatTermLaunch, ChatTermConfig) throws -> ChatTermChild

    public init(agent: String, state: ChatTermState?, timers: ChatTimers, pasteboard: ChatPasteboardSource,
                memoryPressure: @escaping (@escaping () -> Void) -> ChatTermCancellable?,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                resumeFailSeconds: TimeInterval = ChatTermPath.resumeFailSeconds, trackSeconds: TimeInterval = 1,
                maxPendingBytes: Int = ChatTermChild.maxPendingBytes,
                spawn: @escaping (ChatTermLaunch, ChatTermConfig) throws -> ChatTermChild = { try ChatTermChild.start($0, config: $1) }) {
        self.agent = agent; self.state = state; self.timers = timers; self.pasteboard = pasteboard; self.memoryPressure = memoryPressure
        self.now = now; self.resumeFailSeconds = resumeFailSeconds; self.trackSeconds = trackSeconds
        self.maxPendingBytes = maxPendingBytes; self.spawn = spawn
    }
}

public protocol ChatTermCancellable: AnyObject { func cancel() }

/// A dispatch memory-pressure source (warning and critical): an event, not a poll.
public final class DispatchMemoryPressure: ChatTermCancellable {
    private let source: DispatchSourceMemoryPressure
    public init(handler: @escaping () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
    }
    public func cancel() { source.cancel() }
}

/// The terminal path of the chat panel (spec R9.2 T-1..T-9): one claude in a PTY drawn by SwiftTerm's view. It owns the child across openings,
/// the view and its screen, the batching of the output, the resume bookkeeping, the idle stop with its holds and the restart lines. The
/// controller owns the panel and tells this path when an opening starts and ends.
public final class ChatTermPath {
    /// The most a resume may take to fail before the fresh fallback is tried (3 x the measured 1.75 s of P-T1 6, rounded up to a round 10).
    public static let resumeFailSeconds: TimeInterval = 10
    public static let idleStop: TimeInterval = 600
    public static let recheckSeconds: TimeInterval = 60
    public static let quietSeconds: TimeInterval = 60
    public static let draftHoldSeconds: TimeInterval = 3_600
    static let frame: TimeInterval = 1.0 / 60

    private enum Pending { case idleCap, memory, exited }

    private let env: ChatTermEnvironment
    private let settings: () -> ChatSettings
    private let log: (String) -> Void
    private let currentEvent: () -> ChatCurrentEvent?
    private let closeRequest: (ChatCloseReason) -> Void

    public private(set) var view: ChatTerminalView?
    public let delegate = ChatTerminalDelegate()
    public private(set) var child: ChatTermChild?
    private var container: ChatTerminalContainer?
    private var resume = ChatTermResume()
    private var draft = ChatTermDraft()
    private var title = ""
    private var titleState: ChatTermTitle = .unknown
    private var lastOutput = -Double.infinity
    private var open: Int?              // the generation of the live opening
    private var childSpawnedAt = 0.0
    private var childMode: ChatTermLaunch.Mode?
    private var spawnFolder = ""
    private var sawWorkThisChild = false
    /// The user typed Ctrl+C or Ctrl+D into the current child (R9.12 item 4 (b)): its early end is not a failed resume.
    private var exitKeyThisChild = false
    private var pending: Pending?
    private var awaitingReturn = false
    /// A start asked for while the last child's stop still runs (an open or a Return inside the stop's seconds), with its reason: it runs at that
    /// stop's end, so two claudes never share one session.
    private var startAfterStop: String?
    private var tail = Data()
    private var heldReported = false
    private var idleTimer: ChatTimerHandle?
    private var recheckTimer: ChatTimerHandle?
    private var capTimer: ChatTimerHandle?
    private var memory: ChatTermCancellable?
    private let buffer = TermOutput()
    private var drainScheduled = false
    private var lastDrain = -Double.infinity
    private var epoch = 0               // one number per child, so a late callback of an old child changes nothing

    public init(environment: ChatTermEnvironment, settings: @escaping () -> ChatSettings, log: @escaping (String) -> Void,
                currentEvent: @escaping () -> ChatCurrentEvent?, close: @escaping (ChatCloseReason) -> Void) {
        env = environment; self.settings = settings; self.log = log; self.currentEvent = currentEvent; closeRequest = close
        delegate.currentEvent = { [weak self] in self?.currentEvent() }
        delegate.deliver = { [weak self] in self?.deliver($0) ?? false }
        delegate.titleChanged = { [weak self] in self?.titleSet($0) }
        delegate.gridChanged = { [weak self] cols, rows in self?.child?.resize(columns: cols, rows: rows) }
        delegate.refused = { [weak self] in self?.log("CHAT notice kind=paste-refused") }
        delegate.sent = { [weak self] bytes, paste in self?.inputSent(bytes, paste: paste) }
        delegate.room = { [weak self] in self?.pasteRoom ?? Int.max }
    }

    private var pasteRoom: Int { if let child, hasLiveChild { return child.room } else { return Int.max } }

    /// What claude received from the panel: the draft rule, and the record of the user's exit keys for this child.
    private func inputSent(_ bytes: [UInt8], paste: Bool) {
        draft.sent(bytes, fromPaste: paste)
        if !paste, ChatTermExitKey.match(bytes) != nil { exitKeyThisChild = true }
    }

    public var hasLiveChild: Bool { child.map { !$0.hasExited && !$0.isStopping && !$0.hasEnded } ?? false }
    public var childPid: Int32? { child?.pid }
    public var currentTitle: String { title }
    public var titleStateForTests: ChatTermTitle { titleState }
    public var draftPending: Bool { draft.pending }
    public var needsReturn: Bool { awaitingReturn }

    // MARK: an opening

    /// The panel of a new opening takes the terminal view. Spawns when there is no live child (or writes the restart line), else reattaches.
    /// `size` is the panel's content size in points.
    public func opened(gen: Int, container: ChatTerminalContainer, size: CGSize) {
        open = gen
        self.container = container
        cancelTimers()
        memory?.cancel(); memory = nil
        delegate.resetCounts()
        let existing = view
        guard let terminal = container.terminalView else { fatalError("the terminal path was handed a container that holds no terminal view") }
        if let existing, existing !== terminal { fatalError("the container must hold the path's own view") }
        view = terminal
        wire(terminal)
        container.layoutSubtreeIfNeeded()
        container.setTitle(title)
        if hasLiveChild, let child {
            log("CHAT reattach gen=\(gen) pid=\(child.pid)")
            return
        }
        if let pending {
            switch pending {
            case .idleCap: restartLine("Claude Code was stopped after an hour unused. Your unsent text is above. Press Return to start it again.")
            case .memory: restartLine("Claude Code was stopped to free memory. Your unsent text is above. Press Return to start it again.")
            case .exited: restartLine("Claude Code exited. Press Return to start it again, or Cmd+W to close.")
            }
            awaitingReturn = true
            return
        }
        spawn(reason: "open")
    }

    /// The view the next opening's container is built around: kept across openings while the child lives or its screen is kept.
    public func viewForOpening(frame: CGRect) -> ChatTerminalView {
        if let view { return view }
        let made = ChatTerminalView(frame: frame)
        made.pasteboard = env.pasteboard
        made.chatDelegate = delegate
        made.terminalDelegate = delegate
        view = made
        return made
    }

    private func wire(_ terminal: ChatTerminalView) {
        terminal.pasteboard = env.pasteboard
        terminal.chatDelegate = delegate
        terminal.terminalDelegate = delegate
    }

    /// The opening ended (any reason). The view leaves the panel, so it has no window and SwiftTerm stops drawing it; the idle rules start.
    /// `suffix` is appended to the line as given (an outside close says what closed it).
    public func closed(reason: String, gen: Int, suffix: String = "") {
        guard open == gen else { return }
        log("CHAT close reason=\(reason) gen=\(gen) keys=\(delegate.keys) pastes=\(delegate.pastes) pasted=\(delegate.pasted) child=\(child.map { String($0.pid) } ?? "none")\(suffix)")
        open = nil
        container = nil
        view?.removeFromSuperview()
        awaitingReturn = false
        startAfterStop = nil
        if pending == .exited { pending = nil }      // the next open spawns by the open's rule
        rearm()
    }

    public var isOpen: Bool { open != nil }

    // MARK: spawn

    private func writeLine(_ text: String) {
        view?.feed(text: "\r\n" + text + "\r\n")
    }
    private func restartLine(_ text: String) { writeLine(text) }

    private func spawn(reason: String) {
        if let previous = child, previous.isStopping {
            startAfterStop = reason
            log("CHAT spawn-wait reason=\(reason) pid=\(previous.pid)")
            return
        }
        let configured = settings()
        let resolved: String
        switch ChatTermRefusal.resolve(configured) {
        case .success(let path): resolved = path
        case .failure(let refusal):
            log("CHAT refuse reason=\(refusal.reason)")
            writeLine(refusal == .missingBinary ? "\(configured.claudeMissingText()). Install it, or set the path with `clawd-pet chat claude PATH`."
                                                : "The chat folder does not exist.")
            return
        }
        let mode = resume.next(folder: configured.folder, newId: UUID().uuidString.lowercased())
        spawnFolder = configured.folder
        let token = UUID().uuidString.lowercased()
        let dimensions = view?.terminalDimensions
        let columns = max(20, dimensions?.cols ?? 80), rows = max(5, dimensions?.rows ?? 24)
        let launch = ChatTermLaunch(executable: resolved, arguments: ChatTermLaunch.arguments(mode: mode, permissions: configured.permissions, model: configured.model),
                                    environment: ChatTermLaunch.environment(configured, token: token), directory: configured.folder,
                                    columns: columns, rows: rows, token: token)
        epoch += 1
        let mine = epoch
        var config = ChatTermConfig(agent: env.agent, state: env.state)
        config.trackSeconds = env.trackSeconds
        config.maxPendingBytes = env.maxPendingBytes
        config.log = { [weak self] line in self?.log(line) }
        let sink = buffer
        config.onBytes = { [weak self] data in
            sink.append(data)
            DispatchQueue.main.async { self?.scheduleDrain() }
        }
        config.onExit = { [weak self] code, signal in self?.childExited(epoch: mine, code: code, signal: signal) }
        config.onStopped = { [weak self] _, _ in self?.childStopped(epoch: mine) }
        config.onGuardLost = {}
        let started: ChatTermChild
        do { started = try env.spawn(launch, config) } catch {
            let refusal = (error as? ChatTermRefusal) ?? .spawnFailed(0)
            log("CHAT refuse reason=\(refusal.reason)")
            writeLine("Claude Code could not be started.")
            return
        }
        child = started
        childMode = mode
        childSpawnedAt = env.now()
        sawWorkThisChild = false
        exitKeyThisChild = false
        pending = nil
        awaitingReturn = false
        draft.clear()
        title = ""; titleState = .unknown
        tail = Data()
        lastOutput = env.now()
        let modeName: String
        switch mode { case .fresh: modeName = "fresh"; case .resume: modeName = "resume" }
        log("CHAT term spawn pid=\(started.pid) mode=\(modeName) permissions=\(configured.permissions.rawValue) cols=\(columns) rows=\(rows)")
        _ = reason
    }

    // MARK: bytes

    private func deliver(_ bytes: [UInt8]) -> Bool {
        if let child, hasLiveChild { return child.send(Data(bytes)) }
        if awaitingReturn {
            if bytes == [0x0D] { awaitingReturn = false; pending = nil; spawn(reason: "return") }
            return true
        }
        return false
    }

    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        // At most 60 applications a second while output flows, none while nothing arrives; no polling timer.
        let wait = max(0, lastDrain + Self.frame - env.now())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.drain() }
    }

    /// Applies what the reader has collected to the view.
    func drain() {
        drainScheduled = false
        let data = buffer.take()
        guard !data.isEmpty else { return }
        lastDrain = env.now()
        lastOutput = lastDrain
        tail.append(data)
        if tail.count > 4096 { tail.removeFirst(tail.count - 4096) }
        view?.feed(byteArray: [UInt8](data)[...])
    }

    // MARK: title

    private func titleSet(_ text: String) {
        title = text
        let before = titleState
        titleState = ChatTermTitle.state(of: text)
        container?.setTitle(text)
        if titleState == .working { sawWorkThisChild = true; resume.sawWork(folder: spawnFolder) }
        if titleState != before, open == nil { rearm() }
    }

    // MARK: the child ends

    private func childExited(epoch number: Int, code: Int32?, signal: Int32?) {
        guard number == epoch else { return }
        drain()
        if startAfterStop != nil { return }         // Clawd's own stop, and the reopen's claude starts at its end: no exit line
        let early = env.now() - childSpawnedAt < env.resumeFailSeconds
        let text = String(decoding: tail, as: UTF8.self)
        let clawdEnded = child.map { $0.isStopping || $0.hasEnded } ?? false
        // A resume that ended before any work was seen is failed (R9.12 item 4), whatever the time and the text, except an exit of status 0, the
        // user's own exit key typed into this child, and Clawd's own stop (claude exits 129 after Clawd's SIGHUP): U is then marked at once.
        if case .resume(let id)? = childMode, !sawWorkThisChild, !clawdEnded, !exitKeyThisChild, (code ?? 1) != 0 || signal != nil {
            resume.resumeFailed(id)
            log("CHAT notice kind=resume-failed")
            if early, text.contains("No conversation found"), open != nil { child = nil; spawn(reason: "resume-failed"); return }
            guard open != nil else { child = nil; return }
            writeLine("Claude Code could not reopen the earlier conversation. Press Return to start a new one, or Cmd+W to close.")
            pending = .exited
            awaitingReturn = true
            return
        }
        if open != nil {
            writeLine("Claude Code exited. Press Return to start it again, or Cmd+W to close.")
            pending = .exited
            awaitingReturn = true
        }
    }

    private func childStopped(epoch number: Int) {
        guard number == epoch else { return }
        let waiting = startAfterStop
        startAfterStop = nil
        if let waiting, open != nil { spawn(reason: waiting); return }
        if open == nil { rearm() }
    }

    // MARK: stops from outside

    /// A hard stop of the child (an exam path, `chat off`, the agent's quit, a `chatView` change). Whatever holds the idle stop.
    public func stopHard(reason: String) {
        cancelTimers()
        memory?.cancel(); memory = nil
        pending = nil
        awaitingReturn = false
        startAfterStop = nil
        guard let child, !child.hasEnded else { return }
        child.stop(graceful: false, reason: reason)
    }

    /// The agent's SIGTERM: the stop's sweep has ended (at most `timeout` seconds) when this returns.
    public func quit(timeout: TimeInterval) {
        cancelTimers()
        startAfterStop = nil
        guard let child, !child.hasEnded else { return }
        child.stop(graceful: false, reason: "quit")
        child.waitForStop(timeout: timeout)
    }

    // MARK: the idle stop

    private func cancelTimers() {
        idleTimer?.cancel(); idleTimer = nil
        recheckTimer?.cancel(); recheckTimer = nil
        capTimer?.cancel(); capTimer = nil
        heldReported = false
    }

    /// With the panel closed and a live child: the 600 s one-shot when claude is idle and no draft is pending, the 60 s re-checks while output
    /// flows, the 3,600 s cap while a draft may be pending, and the memory-pressure source while the title is not work.
    func rearm() {
        cancelTimers()
        guard open == nil, hasLiveChild, let child else { memory?.cancel(); memory = nil; return }
        let gen = lastGeneration
        if titleState != .working, memory == nil {
            memory = env.memoryPressure { [weak self] in self?.memoryPressure() }
        } else if titleState == .working {
            memory?.cancel(); memory = nil
        }
        _ = child
        if titleState == .working {
            log("CHAT idle-held reason=working gen=\(gen)")
            return          // re-evaluated when the title changes: the 600 s count from the end of the work
        }
        if draft.pending {
            log("CHAT idle-held reason=draft gen=\(gen)")
            capTimer = env.timers.after(Self.draftHoldSeconds) { [weak self] in self?.stopForCap() }
            return
        }
        idleTimer = env.timers.after(Self.idleStop) { [weak self] in self?.idleFired() }
    }

    private var lastGeneration = 0
    public func noteGeneration(_ gen: Int) { lastGeneration = gen }

    private func idleFired() {
        guard open == nil, hasLiveChild, let child else { return }
        // A draft that became pending after the timer was armed (a paste handled after the close) holds the stop as one pending at the close.
        if draft.pending { rearm(); return }
        // No output from claude in the last 60 s covers a TUI that sets no title; while output keeps coming the check repeats once a minute.
        if env.now() - lastOutput < Self.quietSeconds {
            recheckTimer = env.timers.after(Self.recheckSeconds) { [weak self] in self?.idleFired() }
            return
        }
        child.stop(graceful: true, reason: "idle")
    }

    private func stopForCap() {
        guard open == nil, hasLiveChild, let child else { return }
        pending = .idleCap
        child.stop(graceful: true, reason: "idle-cap")
    }

    private func memoryPressure() {
        guard open == nil, hasLiveChild, titleState != .working, let child else { return }
        cancelTimers()
        if draft.pending { pending = .memory }
        child.stop(graceful: true, reason: "memory")
    }

    // MARK: tests

    public var timerCountForTests: Int { [idleTimer, recheckTimer, capTimer].compactMap { $0 }.count }
    public var memorySourceInstalled: Bool { memory != nil }
}

/// The bytes the reader thread has collected and the main queue has not applied yet.
final class TermOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    func take() -> Data { lock.lock(); defer { lock.unlock() }; let taken = data; data = Data(); return taken }
}
