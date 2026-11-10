import Foundation

/// One-shot timers on the main queue: `DispatchChatTimers` in production, a manual one in the tests (the idle exit and the interrupt grace).
public protocol ChatTimers: AnyObject {
    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> ChatTimerHandle
}
public protocol ChatTimerHandle { func cancel() }

public final class DispatchChatTimers: ChatTimers {
    private final class Handle: ChatTimerHandle {
        let source: DispatchSourceTimer
        init(_ source: DispatchSourceTimer) { self.source = source }
        func cancel() { source.cancel() }
    }
    public init() {}
    public func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> ChatTimerHandle {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + seconds, leeway: .milliseconds(100))
        source.setEventHandler(handler: block)
        source.resume()
        return Handle(source)
    }
}

public struct ChatSessionConfig {
    /// Read at every spawn (the settings are live; a running child keeps the flags it started with).
    public var settings: () -> ChatSettings
    /// One `CHAT ...` line, no chat text and no paths.
    public var log: (String) -> Void
    public var timers: ChatTimers
    /// Seconds on one monotonic clock.
    public var now: () -> TimeInterval
    public var idleSeconds: TimeInterval = 600
    public var interruptGraceSeconds: TimeInterval = 5
    /// At most one main-queue update per this many seconds while streaming (spec F2.3).
    public var batchInterval: TimeInterval = 0.05
    /// One stdout line up to this many bytes (spec F2.3: 16 MiB); a longer one is skipped to its newline.
    public var maxLineBytes = 16 * 1024 * 1024
    /// The absolute length of a stop (spec F2.2: one deadline D = T0 + 3 s).
    public var stopSeconds: TimeInterval = 3
    /// How often the set of processes a child has started is grown while the child lives (spec F2.6).
    public var trackSeconds: TimeInterval = 1
    /// Where `/resume` finds Claude Code's live-session registry: a spawn with `--resume` is refused while another process holds the conversation.
    /// The default lists nothing; the production value is built in the runtime wiring.
    public var resume: ChatResume.Roots = .none

    public init(settings: @escaping () -> ChatSettings, log: @escaping (String) -> Void = { _ in }, timers: ChatTimers = DispatchChatTimers(),
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings; self.log = log; self.timers = timers; self.now = now
    }
}

/// The growing set of processes one chat child has started (spec F2.6): the child, its group, every token carrier and every descendant of any of
/// them, each as pid + start time, so a reused pid is never signalled. It only grows while its members live: a process seen once stays until it
/// is gone. The token finds only processes whose environment the kernel shows (not the system's own tools, which hide it); the descendant walk
/// finds those, but only while they still have a parent in the set, which is why the session grows it every second and not only at the stop.
final class ChatSweepSet {
    /// How a growth reads environments (spec R9.5, r10). `tracking` keeps what it has learned: a readable environment without the token is not
    /// read again while that identity lives, and a hidden one is read again only when its executable path changed or cannot be read. `fresh`
    /// reads every environment of every non-member and consults no record: the stop's own enumerations, the guard's stop and the start sweep,
    /// so a process that changed its environment by an exec since the last growth is still found.
    enum Mode { case tracking, fresh }

    private let token: String
    private let pid: Int32
    private let identity: ProcessIdentity?
    private let lock = NSLock()
    private var members: [String: ProcessIdentity] = [:]
    /// Identities read once as a readable environment without the token.
    private var readable: Set<String> = []
    /// Identities whose environment was hidden or unreadable, with the executable path read before and after that read when the two agreed.
    private var hidden: [String: String?] = [:]

    private let readTable: () -> [ChatProc.Row]
    private let findCarriers: ((String, [ChatProc.Row]) -> [ProcessIdentity])?
    private let readEnvironment: (Int32) -> ChatProc.EnvironmentRead
    private let readPath: (Int32) -> String?

    /// `table` and the readers are the live process table and the environment and path reads; the tests pass synthetic ones. `carriers`, when
    /// given, replaces the per-process reads altogether (a test that only needs the walk).
    init(token: String, pid: Int32, identity: ProcessIdentity?,
         table: @escaping () -> [ChatProc.Row] = { ChatProc.table() },
         carriers: ((String, [ChatProc.Row]) -> [ProcessIdentity])? = nil,
         environment: ((Int32) -> ChatProc.EnvironmentRead)? = nil,
         path: @escaping (Int32) -> String? = { ChatProc.executablePath(of: $0) }) {
        self.token = token; self.pid = pid; self.identity = identity; readTable = table; findCarriers = carriers
        readEnvironment = environment ?? { [token] in ChatProc.readEnvironment(of: $0, token: token) }
        readPath = path
    }

    static func key(_ id: ProcessIdentity) -> String { "\(id.pid):\(id.seconds):\(id.microseconds)" }

    /// Adds recorded members (R9.12 item 1): identities another process of the agent's kind tracked earlier. Each is checked against the live
    /// table at every growth like any member (a pid that now names another process is dropped, never signalled), and the walk goes on from it.
    func seed(_ identities: [ProcessIdentity]) {
        lock.lock(); defer { lock.unlock() }
        for id in identities { members[Self.key(id)] = id }
    }

    /// Grows the set from the live table and returns the members that are alive now (the dead are dropped).
    func grow(_ mode: Mode) -> [ProcessIdentity] {
        lock.lock(); defer { lock.unlock() }
        let rows = readTable()
        // Only members whose pid and start time still match the table survive; a pid reused by another process is not a member, so neither it
        // nor its children are walked from. The records of identities gone from the table are dropped, so they never outgrow it.
        let alive = Set(rows.map { Self.key($0.identity) })
        members = members.filter { alive.contains($0.key) }
        readable = readable.filter { alive.contains($0) }
        hidden = hidden.filter { alive.contains($0.key) }
        func add(_ id: ProcessIdentity) { members[Self.key(id)] = id }
        if let findCarriers {
            findCarriers(token, rows).forEach(add)
        } else {
            for row in rows where members[Self.key(row.identity)] == nil {
                let key = Self.key(row.identity)
                if mode == .tracking {
                    if readable.contains(key) { continue }
                    if let recorded = hidden[key], let path = recorded, readPath(row.identity.pid) == path { continue }
                }
                let before = readPath(row.identity.pid)
                switch readEnvironment(row.identity.pid) {
                case .carrier:
                    add(row.identity); readable.remove(key); hidden.removeValue(forKey: key)
                case .readable:
                    if mode == .tracking { readable.insert(key) }
                case .hidden:
                    if mode == .tracking { hidden[key] = (before == readPath(row.identity.pid)) ? before : nil }
                }
            }
        }
        let leader = rows.first { $0.identity.pid == pid }
        let groupTaken = leader.map { identity != nil && $0.identity != identity } ?? false
        if !groupTaken {
            rows.filter { $0.group == pid }.forEach { add($0.identity) }
            if let leader { add(leader.identity) }
        }
        var known = Set(members.values.map(\.pid))
        var grew = true
        while grew {
            grew = false
            for row in rows where known.contains(row.parent) && !known.contains(row.identity.pid) {
                add(row.identity); known.insert(row.identity.pid); grew = true
            }
        }
        return Array(members.values)
    }
}

/// One spawned `claude`: its descriptors, its reader state and the hand-off its reader threads fill.
final class ChatChild {
    let id: Int
    let spawned: ChatProc.Spawned
    let token: String
    let identity: ProcessIdentity?
    let handoff = ChatHandoff()
    /// Everything this child has started that is still alive, grown every second while the child lives and again by the stop.
    let sweep: ChatSweepSet
    let permissions: ChatPermissions
    /// A `/resume` retired this child: nothing it says is applied, before or after its stop has finished.
    var retiredByResume: Bool { lock.lock(); defer { lock.unlock() }; return retiredFlag }
    func retire() { lock.lock(); retiredFlag = true; lock.unlock() }
    private var retiredFlag = false
    /// Left when the child has been reaped.
    let reaped = DispatchGroup()
    private let lock = NSLock()
    private var exitedFlag = false
    private var stdinClosed = false
    private var hardRequestedFlag = false
    private var tail = Data()
    private let writes: DispatchQueue
    let stdoutDone = DispatchSemaphore(value: 0)
    let stderrDone = DispatchSemaphore(value: 0)

    init(id: Int, spawned: ChatProc.Spawned, token: String, permissions: ChatPermissions) {
        self.id = id; self.spawned = spawned; self.token = token; self.permissions = permissions
        identity = ChatProc.identity(of: spawned.pid)
        sweep = ChatSweepSet(token: token, pid: spawned.pid, identity: identity)
        writes = DispatchQueue(label: "clawd.chat.write.\(id)")
        reaped.enter()
        ChatQuit.cleanupStarting()
    }
    deinit { releaseCleanup() }

    private var cleanupHeld = true
    /// The agent's quit waits for this child's cleanup: held from the child's creation (so the gap between its exit and the start of its sweep is
    /// covered too) until its stop has ended. Released once.
    func releaseCleanup() {
        lock.lock(); let held = cleanupHeld; cleanupHeld = false; lock.unlock()
        if held { ChatQuit.cleanupEnded() }
    }

    private var tracker: DispatchSourceTimer?
    private let trackQueue = DispatchQueue(label: "clawd.chat.track", qos: .utility)

    /// While the child lives, grows the sweep set every `interval` seconds on a background queue.
    func startTracking(every interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: trackQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in _ = self?.sweep.grow(.tracking) }
        lock.lock(); tracker = timer; lock.unlock()
        timer.resume()
    }
    func stopTracking() { lock.lock(); let timer = tracker; tracker = nil; lock.unlock(); timer?.cancel() }
    /// One growth on the tracking queue (the end of a turn).
    func trackOnce() { trackQueue.async { [weak self] in _ = self?.sweep.grow(.tracking) } }

    var exited: Bool { lock.lock(); defer { lock.unlock() }; return exitedFlag }
    func markExited() { lock.lock(); exitedFlag = true; lock.unlock() }
    var hardRequested: Bool { lock.lock(); defer { lock.unlock() }; return hardRequestedFlag }
    func requestHard() { lock.lock(); hardRequestedFlag = true; lock.unlock() }
    private var inputClosed: Bool { lock.lock(); defer { lock.unlock() }; return stdinClosed }

    /// Serial, off the main thread. A failure reports itself to the hand-off.
    /// `completion` gets true when the whole line was written, false when it was not (a write error, or the input closed first).
    func enqueue(_ line: String, onFailure: (() -> Void)? = nil, completion: ((Bool) -> Void)? = nil) {
        enqueue(frame: [Data((line + "\n").utf8)], onFailure: onFailure, completion: completion)
    }

    /// The same for a line given in pieces that are written one after the other: an image send's content (up to 15 MiB) is never copied into a joined line.
    func enqueue(frame pieces: [Data], onFailure: (() -> Void)? = nil, completion: ((Bool) -> Void)? = nil) {
        writes.async { [self] in
            if inputClosed { completion?(false); return }
            var written = true
            for piece in pieces where written { written = ChatProc.writeAll(spawned.stdin, piece, abandon: { self.inputClosed }) }
            if !written, let onFailure, !inputClosed { onFailure() }
            completion?(written)
        }
    }

    /// Closes claude's stdin once everything queued before it is written (or abandoned).
    func closeStdin() {
        lock.lock(); let already = stdinClosed; stdinClosed = true; lock.unlock()
        if already { return }
        writes.async { [spawned] in ChatProc.closeDescriptor(spawned.stdin) }
    }

    func appendStderr(_ bytes: UnsafeRawBufferPointer) {
        lock.lock(); defer { lock.unlock() }
        tail.append(contentsOf: bytes)
        if tail.count > 64 * 1024 { tail.removeFirst(tail.count - 64 * 1024) }
    }
    /// The last `count` non-empty stderr lines.
    func stderrLines(_ count: Int) -> [String] {
        lock.lock(); let data = tail; lock.unlock()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        return Array(lines.filter { !$0.isEmpty }.suffix(count))
    }
}

/// The chat bridge (spec F2.1-F2.3, F2.6 without the guard): one long-lived `claude -p` child per conversation, driven over stream-json.
/// Everything public happens on the main queue. Reader threads parse and hand events over in batches; the stop timeline runs on its own queue.
public final class ChatSession: ChatSessionDriving {
    public private(set) var transcript: ChatTranscript
    public private(set) var turn: ChatTurnState = .none
    public var onChange: (() -> Void)?
    public var onTurnStarted: (() -> Void)?
    public var onTurnEnded: ((ChatTurnOutcome) -> Void)?
    public var onSendFailed: ((String) -> Void)?
    public var onCatalog: ((ChatCatalogFrame) -> Void)?
    public var onSendSettled: ((ChatSendVerdict) -> Void)?
    public var onChildLost: ((ChatChildLoss) -> Void)?
    public var onConversationCleared: (() -> Void)?
    public var hasUnsettledSend: Bool { ledger.hasPending }

    private var config: ChatSessionConfig
    private var child: ChatChild?
    private var nextChildId = 1
    private var turnNumber = 0
    private var turnStart: TimeInterval = 0
    private var interruptRequested = false
    private var interruptSerial = 0
    /// What the newest child's init said it can do (reset at each spawn). With `interrupt_cancel_queued_v1` an interrupt asks the CLI to cancel the
    /// sends it left queued; without it, each send the receipt lists as `still_queued` is withdrawn with `cancel_async_message` (Q13).
    private var capabilities: Set<String> = []
    /// The interrupt request awaiting its receipt, and whether it asked for the queue to be cancelled.
    private var interruptRequest: (id: String, cancelQueued: Bool)?
    /// The `cancel_async_message` requests awaiting an answer, by request id, each with the send it asks to withdraw.
    private var withdrawRequests: [String: String] = [:]
    private var withdrawSerial = 0
    private var interruptTimer: ChatTimerHandle?
    private var idleTimer: ChatTimerHandle?
    private var conversationId: String?
    /// The conversation id an init has named, kept across respawns: the next spawn resumes it, even when the child before it ended without an init
    /// (a resumed child stopped in its first seconds must not fork the chat), and the right-click menu's Copy Session ID (Q19) offers it.
    private var confirmedId: String?
    public var sessionID: String? { confirmedId }
    private var drainScheduled = false
    private var lastDrain: TimeInterval = -1
    private var stopping: StopRun?
    /// The child a `/resume` is stopping: nothing it still says names the conversation (its late init would otherwise put the old id back).
    private var retired: ChatChild?
    /// Every written user frame until it is delivered, not delivered or in doubt (Q13; main queue).
    private var ledger = ChatSendLedger()
    /// The child has sent a `session_state_changed` frame since it spawned: `idle` ends its turns, and a result no longer does (Q13).
    private var sawSessionState = false
    /// Whether the newest child was spawned with `--resume`, and whether its init has come (a refusal is only ever heard before it).
    private var childResumed = false
    private var childInitialized = false
    /// The outcome of the turn's latest result, held until the CLI says `idle`.
    private var pendingOutcome: ChatTurnOutcome?
    /// A result came since the turn began (the tools of a turn that ends without one are settled at its end).
    private var resultSeen = false
    /// An interrupt was sent and its result has not come yet.
    private var interruptPending = false
    /// The spawn token of the newest child (for the tests; the log never carries it).
    private(set) var lastToken: String?
    /// The newest child's pid and spawn token (for the headless test mode and the tests).
    public var spawnedForTests: (pid: Int32, token: String)? { child.map { ($0.spawned.pid, $0.token) } }
    /// The running child itself: a test keeps it to push frames from it after it was stopped.
    var childForTests: ChatChild? { child }
    private let stopQueue = DispatchQueue(label: "clawd.chat.stop")

    private final class StopRun {
        let child: ChatChild
        let done = DispatchSemaphore(value: 0)
        init(child: ChatChild) { self.child = child }
    }

    public init(config: ChatSessionConfig, timeZone: TimeZone = .current) {
        self.config = config
        transcript = ChatTranscript(timeZone: timeZone)
    }

    // MARK: send

    @discardableResult
    public func send(_ request: ChatSendRequest) -> Bool {
        let text = request.text
        guard stopping == nil, request.payload != nil || !text.allSatisfy({ $0.isWhitespace }), request.chips.isEmpty || request.payload != nil else { return false }
        if turn == .running, request.steer { return steer(request) }
        guard turn == .none else { return false }
        if child == nil, !spawn() { changed(); return false }
        guard let child else { return false }
        cancelIdle()
        transcript.expectedSessionId = conversationId
        transcript.expectedPermissionMode = child.permissions == .bypass ? "bypassPermissions" : "default"
        transcript.appendUser(text, uuid: request.uuid, images: request.payload?.paths ?? [])
        turn = .running
        turnNumber += 1
        turnStart = config.now()
        interruptRequested = false; interruptPending = false
        pendingOutcome = nil; resultSeen = false
        config.log("CHAT send turn=\(turnNumber) chars=\(text.count)" + Self.imageCounts(request, always: true))
        handToChild(request, child)
        onTurnStarted?()
        changed()
        return true
    }

    /// A send written into the running turn (Q13): Claude folds it into the turn or runs it as its own after the result. Its entry is pending and
    /// ends nothing; the replay places it.
    private func steer(_ request: ChatSendRequest) -> Bool {
        guard let child else { return false }
        transcript.appendPendingUser(uuid: request.uuid, text: request.text, images: request.payload?.paths ?? [])
        config.log("CHAT steer turn=\(turnNumber) chars=\(request.text.count)" + Self.imageCounts(request))
        handToChild(request, child)
        changed()
        return true
    }

    /// ` images=<n> bytes=<n>` (counts only: the log rule). A send always names them, a steer only when it carries images.
    private static func imageCounts(_ request: ChatSendRequest, always: Bool = false) -> String {
        guard let payload = request.payload else { return always ? " images=0 bytes=0" : "" }
        return " images=\(payload.count) bytes=\(payload.rawBytes)"
    }

    /// Adds the send to the ledger and hands its frame to the child's writer.
    private func handToChild(_ request: ChatSendRequest, _ child: ChatChild) {
        var entry = ChatLedgerEntry(request: request, child: child.id)
        if request.steer { entry.turn = turnNumber }
        ledger.add(entry)
        let uuid = request.uuid
        if let line = Self.userFrame(request, conversationId: conversationId ?? "") {
            child.enqueue(frame: line, onFailure: { [weak child] in child?.handoff.push(bridge: .writeFailed) }, completion: { written in
                DispatchQueue.main.async { [weak self] in self?.sendFinished(uuid, written: written) }
            })
        } else {
            child.handoff.push(bridge: .writeFailed)
            DispatchQueue.main.async { [weak self] in self?.sendFinished(uuid, written: false) }
        }
    }

    /// Whether the stdout reader keeps its line buffer's capacity after a line of `bytes`: only an ordinary one, never the 15 MiB replay of an image send.
    static func keepsReaderBuffer(afterLine bytes: Int) -> Bool { bytes <= 64 * 1024 }

    /// The user frame as one line with its newline, in three pieces (what comes before the content, the content, what follows): the content is the
    /// text, or (a send with images) the payload's block array, spliced in as it is and not copied.
    static func userFrame(_ request: ChatSendRequest, conversationId: String) -> [Data]? {
        guard let uuid = jsonString(request.uuid), let session = jsonString(conversationId) else { return nil }
        let content: Data
        if let payload = request.payload { content = payload.contentJSON } else if let text = jsonString(request.text) { content = Data(text.utf8) } else { return nil }
        return [Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":".utf8), content,
                Data("},\"uuid\":\(uuid),\"parent_tool_use_id\":null,\"session_id\":\(session)}\n".utf8)]
    }

    private static func jsonString(_ text: String) -> String? {
        guard let data = try? JSONEncoder().encode(text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The write of a send ended. A line completely written waits for its verdict (or, when its child is already gone, is in doubt); a line not
    /// completely written is given back, exactly once: nothing reached the child.
    private func sendFinished(_ uuid: String, written: Bool) {
        if written {
            ledger.written(uuid)
            if let entry = ledger.entry(uuid), child?.id != entry.child { settle(ledger.childEnded()) }
            return
        }
        guard let verdict = ledger.unwritten(uuid) else { return }
        let entry = verdict.entry
        config.log("CHAT send-unwritten chars=\(entry.text.count)")
        if entry.steer { transcript.removeUser(uuid: uuid) }
        onSendFailed?(entry.text)
        onSendSettled?(verdict)
    }

    /// Acts on what the ledger decided: the transcript entry follows, one line counts the outcomes, and the owner of the queue is told.
    private func settle(_ verdicts: [ChatSendVerdict]) {
        guard !verdicts.isEmpty else { return }
        var counts: [String: Int] = [:]
        for verdict in verdicts {
            let entry = verdict.entry
            switch verdict {
            case .delivered(_, let late):
                transcript.placeUser(uuid: entry.uuid)
                if entry.steer { config.log("CHAT steer-delivered turn=\(turnNumber) folded=\(!late && entry.turn == turnNumber && turn == .running ? 1 : 0)") }
                counts["delivered", default: 0] += 1
            case .notDelivered:
                transcript.removeUser(uuid: entry.uuid)
                counts["not-delivered", default: 0] += 1
            case .doubt:
                transcript.markUnconfirmed(uuid: entry.uuid)
                counts["doubt", default: 0] += 1
            case .unwritten: break
            }
            onSendSettled?(verdict)
        }
        for (outcome, count) in counts.sorted(by: { $0.key < $1.key }) { config.log("CHAT send-settled outcome=\(outcome) n=\(count)") }
        changed()
    }

    // MARK: resume

    @discardableResult
    public func resume(_ id: String, title: String) -> Bool {
        guard turn == .none, stopping == nil, !ledger.hasPending, ChatResume.isSessionId(id), id.lowercased() != confirmedId?.lowercased() else { return false }
        if let live = child {
            retired = live
            live.retire()
            beginStop(hard: false, reason: .resume)
        }
        confirmedId = id
        transcript.appendResumed(title)
        config.log("CHAT resume session=\(id.prefix(8))")
        changed()
        return true
    }

    // MARK: interrupt and stop

    public func interrupt() {
        guard turn == .running, let child, !interruptRequested else { return }
        interruptRequested = true
        interruptPending = true
        interruptSerial += 1
        // Orca asks a CLI that advertises it to cancel the queued sends in the same round trip (MC/claude-structured-control-actions.ts:36-41).
        let cancelQueued = capabilities.contains(Self.cancelQueuedCapability)
        var body: [String: Any] = ["subtype": "interrupt"]
        if cancelQueued { body["cancel_queued"] = true }
        let id = "clawd-\(interruptSerial)"
        interruptRequest = (id, cancelQueued)
        writeControl(["type": "control_request", "request_id": id, "request": body], to: child)
        let number = turnNumber
        interruptTimer?.cancel()
        interruptTimer = config.timers.after(config.interruptGraceSeconds) { [weak self] in
            guard let self, self.turn == .running, self.turnNumber == number else { return }
            self.config.log("CHAT interrupt-timeout turn=\(number)")
            self.beginStop(hard: true, reason: .userStop)
        }
    }

    private static let cancelQueuedCapability = "interrupt_cancel_queued_v1"

    private func writeControl(_ object: [String: Any], to child: ChatChild) {
        if let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) {
            child.enqueue(line) { [weak child] in child?.handoff.push(bridge: .writeFailed) }
        }
    }

    /// The interrupt's receipt (Q13). A CLI that was asked to cancel the queue names what it withdrew in `cancelled`: those sends never ran. One that
    /// was not names the sends it left queued in `still_queued`, and each of ours is withdrawn with `cancel_async_message` (Orca
    /// MC/claude-structured-control-actions.ts:42-52); its answer settles it. A send neither names runs next as its own turn, as the capture shows.
    private func controlAnswered(id: String, ok: Bool, stillQueued: [String], cancelled: [String], withdrawn: Bool, from child: ChatChild) {
        if let request = interruptRequest, request.id == id {
            interruptRequest = nil
            guard ok else { return }
            if request.cancelQueued {
                settle(cancelled.flatMap { ledger.withdraw($0) })
            } else {
                for uuid in stillQueued where ledger.entry(uuid) != nil {
                    withdrawSerial += 1
                    let requestId = "clawd-withdraw-\(withdrawSerial)"
                    withdrawRequests[requestId] = uuid
                    writeControl(["type": "control_request", "request_id": requestId, "request": ["subtype": "cancel_async_message", "message_uuid": uuid]], to: child)
                }
            }
        } else if let uuid = withdrawRequests.removeValue(forKey: id), ok, withdrawn {
            settle(ledger.withdraw(uuid))
        }
    }

    public func stop(_ reason: ChatStopReason) {
        switch reason {
        case .idle, .panelClosedLong, .userStop, .resume: beginStop(hard: false, reason: reason)
        case .exam, .chatOff, .agentQuit: beginStop(hard: true, reason: reason)
        }
    }

    /// For the agent's quit path: begins the stop and returns once its sweep has ended (at most `timeout` seconds); the main queue is not needed
    /// by the sweep, so waiting here is safe.
    public func stopAndWait(_ reason: ChatStopReason, timeout: TimeInterval = 4) {
        stop(reason)
        guard let run = stopping else { return }
        _ = run.done.wait(timeout: .now() + timeout)
        // The main queue was not running while this waited, so the stop's own hand-off to it (`stopped`) has not run. Every send still unconfirmed
        // is made a doubt now, before the caller goes on to quit, after the child's last lines were applied.
        drain(run.child)
        settle(ledger.childEnded(unreported: true))
    }

    /// The agent's SIGTERM path (spec F2.6): a hard stop whose sweep has ended, or `timeout` seconds have passed, when this returns.
    public func quit(timeout: TimeInterval = 4) {
        stopAndWait(.agentQuit, timeout: timeout)
    }

    private func beginStop(hard: Bool, reason: ChatStopReason?) {
        guard let child else { return }
        if let run = stopping {
            if hard && run.child === child { child.requestHard() }
            return
        }
        cancelIdle()
        interruptTimer?.cancel(); interruptTimer = nil
        if let reason { config.log("CHAT stop reason=\(reason.rawValue)") }
        let wasRunning = turn == .running
        let run = StopRun(child: child)
        stopping = run
        turn = .stopping
        if hard { child.requestHard() }
        if wasRunning {
            transcript.endTurnWithoutResult()
            finishTurn(.interrupted)
        }
        let seconds = config.stopSeconds
        stopQueue.async { [weak self] in
            let result = ChatSession.executeStop(child, graceful: !hard, seconds: seconds)
            DispatchQueue.main.async { self?.stopped(run, killed: result.killed, left: result.left) }
            run.done.signal()
        }
    }

    private func stopped(_ run: StopRun, killed: Int, left: Int) {
        drain(run.child)
        settle(ledger.childEnded())
        config.log("CHAT sweep n=\(killed) left=\(left)")
        run.child.closeStdin()
        if left > 0 {
            transcript.appendError("\(left) processes started by Claude Code could not be stopped")
            config.log("CHAT notice kind=stop-incomplete")
        }
        if stopping === run { stopping = nil }
        if child === run.child { child = nil }
        if retired === run.child { retired = nil }
        turn = .none
        changed()
    }

    /// The stop timeline (spec F2.2, F2.6) for one child, on the stop queue: graceful closes stdin and waits up to 1 s for claude to leave; every
    /// stop then sends SIGTERM to what is left, SIGKILL at 2 s and again to anything new until 3 s, and the verdict at 3 s counts what is still
    /// alive. It ends early once claude is reaped and nothing is left. "What is left" is the child's `ChatSweepSet`, which starts from what the
    /// live tracking (every second while the child lived, and at each turn's end) already holds and grows again before each signal.
    static func executeStop(_ child: ChatChild, graceful: Bool, seconds: TimeInterval) -> (killed: Int, left: Int) {
        defer { child.releaseCleanup() }
        let start = ProcessInfo.processInfo.systemUptime
        func elapsed() -> TimeInterval { ProcessInfo.processInfo.systemUptime - start }
        func key(_ id: ProcessIdentity) -> String { ChatSweepSet.key(id) }
        var signalled = Set<String>()
        /// Grows the set that the live tracking has kept and returns its members that are alive now.
        func refresh() -> [ProcessIdentity] { child.sweep.grow(.fresh) }
        func send(_ number: Int32) {
            for id in refresh() where ChatProc.signal(id, number) { signalled.insert(key(id)) }
        }
        func reaped(within seconds: TimeInterval) -> Bool { child.reaped.wait(timeout: .now() + seconds) == .success }

        _ = refresh()
        if graceful {
            child.closeStdin()
            while elapsed() < seconds - 2, !child.hardRequested, !reaped(within: 0.02) {}
        }
        send(SIGTERM)
        while elapsed() < seconds - 1 {
            Thread.sleep(forTimeInterval: 0.05)
            if child.exited, refresh().isEmpty { return (signalled.count, 0) }
        }
        send(SIGKILL)
        while elapsed() < seconds {
            Thread.sleep(forTimeInterval: 0.05)
            if child.exited, refresh().isEmpty { return (signalled.count, 0) }
            send(SIGKILL)
        }
        return (signalled.count, refresh().count)
    }

    // MARK: spawn

    private func refuse(_ reason: String, _ message: String) {
        config.log("CHAT refuse reason=\(reason)")
        transcript.appendError(message)
    }

    private func spawn() -> Bool {
        let settings = config.settings()
        guard settings.enabled else { refuse("off", "Chat is turned off"); return false }
        guard let resolved = settings.claudeLocation().resolved else {
            refuse("missing-binary", "\(settings.claudeMissingText()). Install it, or set the path with `clawd-pet chat claude PATH`")
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: settings.folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            refuse("folder-missing", "The chat folder \(settings.folder) does not exist")
            return false
        }
        var resume = confirmedId
        // Only a UUID is ever handed to `--resume`: the CLI also takes a search term there, which could open some other conversation.
        if let id = resume, !ChatResume.isSessionId(id) {
            config.log("CHAT resume dropped reason=not-uuid")
            confirmedId = nil
            resume = nil
        }
        // One writer per conversation: a process that holds it (a terminal, a job) keeps it. The id stays, so the next send after it closes resumes.
        if let id = resume {
            let own = Set([child?.spawned.pid, retired?.spawned.pid].compactMap { $0 })
            switch ChatResume.liveHolder(id: id, roots: config.resume, ownPids: own) {
            case .held:
                refuse("held", ChatResume.heldText)
                return false
            case .unknown:
                refuse("holder-unknown", ChatResume.unknownHolderText)
                return false
            case .none: break
            }
        }
        ledger.clearDoubt()
        let session = resume ?? UUID().uuidString.lowercased()
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--replay-user-messages"]
        arguments += resume != nil ? ["--resume", session] : ["--session-id", session]
        arguments += settings.permissions.arguments
        if let model = settings.model { arguments += ["--model", model] }
        let token = UUID().uuidString.lowercased()
        let spawned: ChatProc.Spawned
        do {
            spawned = try ChatProc.spawn(executable: resolved, arguments: arguments, environment: Self.environment(settings, token: token),
                                         directory: settings.folder)
        } catch {
            refuse("spawn-failed code=\((error as? ChatProc.SpawnFailure).map { "\($0)" } ?? "unknown")", "Claude Code could not be started")
            return false
        }
        conversationId = session
        lastToken = token
        sawSessionState = false
        childResumed = resume != nil; childInitialized = false
        capabilities = []; interruptRequest = nil; withdrawRequests = [:]
        pendingOutcome = nil; resultSeen = false; interruptPending = false
        let made = ChatChild(id: nextChildId, spawned: spawned, token: token, permissions: settings.permissions)
        nextChildId += 1
        child = made
        config.log("CHAT spawn pid=\(spawned.pid) pgid=\(spawned.pid) mode=\(resume != nil ? "resume" : "fresh") permissions=\(settings.permissions.rawValue)")
        made.handoff.onReady = { [weak self, weak made] in
            DispatchQueue.main.async { if let self, let made { self.scheduleDrain(made) } }
        }
        start(readers: made)
        made.startTracking(every: config.trackSeconds)
        return true
    }

    /// Built from scratch: nothing else of the agent's environment reaches claude (spec F2.1).
    static let stateEventsVariable = "CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"

    static func environment(_ settings: ChatSettings, token: String) -> [String: String] {
        var env: [String: String] = [:]
        if let record = getpwuid(getuid()) {
            env["HOME"] = String(cString: record.pointee.pw_dir)
            env["USER"] = String(cString: record.pointee.pw_name)
            env["LOGNAME"] = String(cString: record.pointee.pw_name)
            env["SHELL"] = String(cString: record.pointee.pw_shell)
        }
        let inherited = ProcessInfo.processInfo.environment
        if let tmp = inherited["TMPDIR"] { env["TMPDIR"] = tmp }
        env["LANG"] = inherited["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = settings.path
        env["CLAWD_CHAT"] = "1"
        // The CLI says when a turn is over (`session_state_changed idle`) and what became of each user frame (`command_lifecycle`) (Q13).
        env[Self.stateEventsVariable] = "1"
        env[ChatProc.tokenVariable] = token
        return env
    }

    // MARK: readers (off the main thread)

    private func start(readers child: ChatChild) {
        let maxLine = config.maxLineBytes
        let thread = { (name: String, body: @escaping () -> Void) in
            let t = Thread(block: body); t.name = name; t.stackSize = 512 * 1024; t.start()
        }
        thread("clawd.chat.stdout") { Self.readOutput(child, maxLine: maxLine) }
        thread("clawd.chat.stderr") { Self.readError(child) }
        thread("clawd.chat.reap") {
            let status = ChatProc.reap(child.spawned.pid)
            child.stopTracking()
            child.markExited()
            child.reaped.leave()
            // The exit goes in behind every line the pipe still holds; a detached grandchild can keep the pipe open, so the wait is bounded.
            _ = child.stdoutDone.wait(timeout: .now() + 2)
            _ = child.stderrDone.wait(timeout: .now() + 0.5)
            child.handoff.push(bridge: .exited(code: status.code, signal: status.signal, stderrTail: child.stderrLines(3)))
        }
    }

    private static func readOutput(_ child: ChatChild, maxLine: Int) {
        let descriptor = child.spawned.stdout
        defer { ChatProc.closeDescriptor(descriptor); child.stdoutDone.signal() }
        var line = [UInt8]()
        var skipping = false
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        func emit() {
            if skipping {
                skipping = false
                child.handoff.push(.oversized)
            } else if !line.isEmpty {
                for event in ChatStreamParser.parse(line: String(decoding: line, as: UTF8.self)) {
                    if case .controlRequest(let id, _, _) = event { answer(child, id) }
                    child.handoff.push(event)
                }
            }
            // A long line (an image send's replay) must not leave its capacity behind for the child's whole life.
            line.removeAll(keepingCapacity: Self.keepsReaderBuffer(afterLine: line.count))
        }
        while true {
            let ready = ChatProc.waitReadable(descriptor, milliseconds: 100)
            if ready < 0 { break }
            if ready == 0 { if child.exited { break }; continue }
            let count = ChatProc.readChunk(descriptor, into: buffer, capacity: capacity)
            if count <= 0 { break }
            let bytes = UnsafeRawBufferPointer(start: buffer, count: count)
            var start = 0
            for index in 0..<count where bytes[index] == 0x0A {
                if !skipping { line.append(contentsOf: bytes[start..<index]) }
                emit()
                start = index + 1
            }
            if start < count, !skipping {
                line.append(contentsOf: bytes[start..<count])
                if line.count > maxLine { skipping = true; line.removeAll(keepingCapacity: false) }
            }
        }
        emit()
    }

    private static func readError(_ child: ChatChild) {
        let descriptor = child.spawned.stderr
        defer { ChatProc.closeDescriptor(descriptor); child.stderrDone.signal() }
        let capacity = 16 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let ready = ChatProc.waitReadable(descriptor, milliseconds: 100)
            if ready < 0 { break }
            if ready == 0 { if child.exited { break }; continue }
            let count = ChatProc.readChunk(descriptor, into: buffer, capacity: capacity)
            if count <= 0 { break }
            child.appendStderr(UnsafeRawBufferPointer(start: buffer, count: count))
        }
    }

    /// Every control_request is answered at once, from the reader thread, with the error response (spec F2.3).
    private static func answer(_ child: ChatChild, _ id: String) {
        let response: [String: Any] = ["type": "control_response",
                                       "response": ["subtype": "error", "request_id": id, "error": "not supported by Clawd"]]
        if let data = try? JSONSerialization.data(withJSONObject: response), let line = String(data: data, encoding: .utf8) {
            child.enqueue(line)
        }
    }

    // MARK: applying batches (main queue)

    private func scheduleDrain(_ source: ChatChild) {
        guard !drainScheduled else { return }
        drainScheduled = true
        let wait = max(0, lastDrain + config.batchInterval - config.now())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            self.lastDrain = self.config.now()
            self.drain(source)
            if let current = self.child, current !== source, !current.handoff.isEmpty { self.scheduleDrain(current) }
        }
    }

    private func drain(_ source: ChatChild) {
        let items = source.handoff.take()
        guard !items.isEmpty else { return }
        var ended: ChatTurnOutcome?
        for item in items {
            switch item {
            case .event(let event): if let outcome = apply(event, from: source) { ended = outcome }
            case .backlog:
                transcript.noteBacklog()
                config.log("CHAT notice kind=backlog")
            case .exited(let code, let signal, let tail): if let outcome = childExited(source, code: code, signal: signal, tail: tail) { ended = outcome }
            case .writeFailed:
                if source === child, turn == .running {
                    transcript.endTurnWithoutResult()
                    transcript.appendError("Claude Code did not take the message")
                    ended = .error
                    beginStopAfterFailure(source)
                    onChildLost?(.writeFailed)
                }
            case .overflow:
                if source === child, turn == .running {
                    transcript.endTurnWithoutResult()
                    transcript.appendError("Claude Code wrote faster than Clawd could show it")
                    config.log("CHAT notice kind=backlog-overflow")
                    ended = .error
                    beginStopAfterFailure(source)
                    onChildLost?(.overflow)
                }
            }
        }
        if let ended { finishTurn(ended) }
        changed()
    }

    private func beginStopAfterFailure(_ source: ChatChild) {
        guard source === child else { return }
        turn = .none        // the turn is over; the stop below moves the state to stopping
        beginStop(hard: true, reason: nil)
    }

    /// Applies one parser event; returns the outcome when it ended the turn (the older CLI's result). A turn the CLI ends with `idle` is finished in
    /// place, so a `running` frame that follows in the same batch starts the next one.
    private func apply(_ event: ChatEvent, from source: ChatChild) -> ChatTurnOutcome? {
        guard source !== retired else { return nil }
        guard !source.retiredByResume else { return nil }
        transcript.apply(event)
        guard source === child else { return nil }
        switch event {
        case .controlResponse(let id, let ok, let stillQueued, let cancelled, let withdrawn):
            controlAnswered(id: id, ok: ok, stillQueued: stillQueued, cancelled: cancelled, withdrawn: withdrawn, from: source)
        case .initialized(let session, let model, let mode, let version, let advertised):
            capabilities = Set(advertised)
            conversationId = session
            confirmedId = session
            childInitialized = true
            config.log("CHAT init session=\(session.prefix(8)) model=\(model) mode=\(mode) version=\(version)")
        case .commandCatalog(let frame): onCatalog?(frame)
        case .conversationReset(let trigger, let newId):
            // `/clear` made a new conversation (Q25). The init that follows names the session to resume; the old id stays on disk.
            if trigger == "clear" {
                config.log("CHAT clear from=\(conversationId.map { String($0.prefix(8)) } ?? "none") to=\(newId.prefix(8))")
                onConversationCleared?()
            }
        case .sessionState(let state):
            sawSessionState = true
            switch state {
            case "running": startTurnIfNone(because: ledger.hasOutstanding)
            case "idle": cliIdle()
            default: break      // `requires_action` is not an end (Orca MC/claude-session-state-turn-over.ts:10-12)
            }
        case .replay(let uuid):
            startTurnIfNone(because: ledger.entry(uuid) != nil || ledger.doubt[uuid] != nil)
            settle(ledger.replay(uuid))
        case .commandLifecycle(let uuid, let state):
            if state == "started" { startTurnIfNone(because: ledger.entry(uuid) != nil) }
            settle(ledger.lifecycle(uuid, state))
        case .result(let outcome, _, _, _, _, let names):
            settle(sawSessionState ? ledger.result(named: names) : ledger.result(named: names) + legacyDeliveries())
            return resultEnded(outcome == .success ? .success(seconds: config.now() - turnStart) : .error)
        case .ignored(let type) where type.hasPrefix("result/"):
            guard turn == .running else { return nil }
            transcript.endTurnWithoutResult()
            transcript.appendError("Claude Code ended the turn in a way Clawd does not know (\(type.dropFirst("result/".count)))")
            config.log("CHAT notice kind=unknown-result")
            return resultEnded(.error)
        default: break
        }
        return nil
    }

    /// A result. With a CLI that sends `session_state_changed` it only records the turn's outcome; `idle` ends the turn, and more than one result
    /// can come before it (a steer that ran as its own turn). Without those frames (an older CLI) the result is the end.
    private func resultEnded(_ outcome: ChatTurnOutcome) -> ChatTurnOutcome? {
        guard turn == .running else { return nil }
        var outcome = outcome
        if interruptPending {
            // The CLI answered the interrupt: this result is the interrupted turn's. What runs after it (a steer) is a turn of its own.
            interruptPending = false
            interruptTimer?.cancel(); interruptTimer = nil
            outcome = .interrupted
            if sawSessionState { interruptRequested = false }
        }
        resultSeen = true
        guard !sawSessionState else { pendingOutcome = outcome; return nil }
        return outcome
    }

    /// The sends an older CLI never reports on (no replay, no result names): its result is the only settlement there is.
    private func legacyDeliveries() -> [ChatSendVerdict] {
        var verdicts: [ChatSendVerdict] = []
        for entry in ledger.pending where entry.written { verdicts += ledger.replay(entry.uuid) }
        return verdicts
    }

    /// A replay, a `started` or a `running` frame for a send Clawd wrote, with no turn running, means Claude is running a turn Clawd did not start
    /// (a steer that missed the running turn): the Stop control shows and the queue holds (Q13).
    private func startTurnIfNone(because ours: Bool) {
        guard ours, turn == .none, stopping == nil, child != nil else { return }
        cancelIdle()
        turn = .running
        turnNumber += 1
        turnStart = config.now()
        interruptRequested = false; interruptPending = false
        pendingOutcome = nil; resultSeen = false
        config.log("CHAT turn foreign turn=\(turnNumber)")
        onTurnStarted?()
        changed()
    }

    /// `session_state_changed idle`: the CLI has no work in flight (Q13). A send that is still unconfirmed is looked at first, so what holds the
    /// queue is known when the turn ends.
    private func cliIdle() {
        guard stopping == nil else { return }
        settle(ledger.idle())
        guard turn == .running else { return }
        let outcome = pendingOutcome ?? (interruptPending ? .interrupted : .error)
        if !resultSeen { transcript.endTurnWithoutResult() }
        pendingOutcome = nil; resultSeen = false; interruptPending = false; interruptRequested = false
        finishTurn(outcome)
    }

    private func childExited(_ source: ChatChild, code: Int32?, signal: Int32?, tail: [String]) -> ChatTurnOutcome? {
        guard source === child else { return nil }
        let during = turn == .running ? "turn" : "idle"
        config.log("CHAT exit pid=\(source.spawned.pid) code=\(code.map(String.init) ?? "none") signal=\(signal.map(String.init) ?? "none") during=\(during)")
        guard stopping == nil else { return nil }
        onChildLost?(.exited)
        var outcome: ChatTurnOutcome?
        // The CLI refused `--resume <id>` (Orca's terminal path reads the same text, ChatTermPath.swift): that conversation is not there, so the next
        // spawn starts a fresh one. Any other early exit keeps the id, or the next spawn would fork the chat.
        if childResumed, !childInitialized, (code ?? 1) != 0 || signal != nil, tail.contains(where: { $0.contains("No conversation found") }) {
            config.log("CHAT resume refused session=\((confirmedId ?? "").prefix(8))")
            confirmedId = nil
        }
        if turn == .running {
            transcript.endTurnWithoutResult()
            var message = "Claude Code stopped"
            if let code { message += " (exit \(code))" } else if let signal { message += " (signal \(signal))" }
            transcript.appendError(message)
            if !tail.isEmpty { transcript.appendNotice(tail.joined(separator: "\n")) }
            outcome = .error
            turn = .none
        }
        beginStop(hard: true, reason: nil)
        return outcome
    }

    // MARK: turn end, idle, change

    private func finishTurn(_ outcome: ChatTurnOutcome) {
        interruptTimer?.cancel(); interruptTimer = nil
        if turn == .running { turn = .none }
        child?.trackOnce()
        config.log("CHAT turn end turn=\(turnNumber) outcome=\(Self.name(outcome)) ms=\(Int((config.now() - turnStart) * 1000))")
        armIdle()
        onTurnEnded?(outcome)
    }

    private static func name(_ outcome: ChatTurnOutcome) -> String {
        switch outcome {
        case .success: return "success"
        case .error: return "error"
        case .interrupted: return "interrupted"
        }
    }

    private func armIdle() {
        cancelIdle()
        guard child != nil, stopping == nil else { return }
        idleTimer = config.timers.after(config.idleSeconds) { [weak self] in
            guard let self, self.turn == .none, self.child != nil else { return }
            self.onChildLost?(.idle)       // the queue pauses with `other`: the stop turns what is unconfirmed into doubt cards, and nothing drains after it
            self.beginStop(hard: false, reason: .idle)
        }
    }

    private func cancelIdle() { idleTimer?.cancel(); idleTimer = nil }

    private func changed() { onChange?() }
}
