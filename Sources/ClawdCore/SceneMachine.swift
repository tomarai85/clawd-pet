import Foundation

public enum Scene: String, Codable, CaseIterable { case idle, listening, thinking, sent, interrupted, error, sleep, drag }

/// Pure state machine for the eight scenes. All time comes from the injected `PetClock`,
/// and `tick()` applies every deadline that has passed at the deadline's own time,
/// so a coarse virtual-clock step yields the same timings as fine real-time wakes.
public final class SceneMachine {
    public static let staleAge: TimeInterval = 10
    public static let thinkingMinimum: TimeInterval = 1
    public static let thinkingTimeout: TimeInterval = 5
    public static let listeningTimeout: TimeInterval = 180
    public static let sentDuration: TimeInterval = 2
    public static let noticeDuration: TimeInterval = 1.5
    public static let sleepAfter: TimeInterval = 600
    public static let ackWindow: TimeInterval = 3

    public let clock: PetClock
    public var guards: GuardSet = .all
    public private(set) var baseScene: Scene = .idle
    public private(set) var sceneSince: TimeInterval
    public private(set) var lastEventAt: Date?
    public private(set) var lastActivity: TimeInterval
    public private(set) var lease: Int?
    public private(set) var leaseOpenedAt: Date?
    public private(set) var duration: TimeInterval = 0
    public private(set) var generation = 0
    public private(set) var dragging = false
    public var sleepEnabled = true
    public var onChange: ((Scene) -> Void)?
    public var scene: Scene { dragging ? .drag : baseScene }

    private var completedAt: Date?
    private var completedTick: TimeInterval?
    private var thinkingSince: TimeInterval?
    private var thinkingDeadline: TimeInterval?
    private var listeningActivity: TimeInterval = 0
    private var deferredScene: Scene?
    private var hintPending = false
    private var deviceRunning = false
    /// A chat turn is running (F4): THINKING has no timeout then, and a scene that would end in IDLE goes back to THINKING.
    public private(set) var chatTurnRunning = false

    public init(clock: PetClock) {
        self.clock = clock; sceneSince = clock.now; lastActivity = clock.now
    }

    // MARK: transitions

    private func change(_ requested: Scene, immediate: Bool = false, at time: TimeInterval? = nil) {
        let now = time ?? clock.now
        // C-5, C-6: while a chat turn runs, where a scene would return to IDLE it returns to THINKING.
        let next = (requested == .idle && chatTurnRunning) ? Scene.thinking : requested
        if next == baseScene { deferredScene = nil; return }
        // THINKING is shown for at least one second unless an immediate change (ERROR, timeout) preempts it.
        if !immediate, baseScene == .thinking, let start = thinkingSince, now < start + Self.thinkingMinimum {
            deferredScene = next; return
        }
        deferredScene = nil
        baseScene = next; sceneSince = now
        if next == .thinking { thinkingSince = now; thinkingDeadline = now + Self.thinkingTimeout }
        else { thinkingSince = nil; thinkingDeadline = nil }
        onChange?(scene)
    }
    private func clearLease() { lease = nil; leaseOpenedAt = nil; hintPending = false }
    private func clearCompletion() { completedAt = nil; completedTick = nil }

    /// Aqua started, quit, or the machine woke: drop every lease and show nothing (a running chat turn keeps THINKING, C-6).
    public func reset() {
        clearLease(); clearCompletion(); deferredScene = nil; dragging = false
        generation += 1; change(.idle, immediate: true); lastActivity = clock.now
    }

    // MARK: chat turns (F4)

    /// A chat send started a turn (C-1): THINKING, with no timeout until the turn ends. With an Aqua lease open the dictation keeps its scene
    /// and the turn is only remembered (C-5).
    public func chatTurnStarted() {
        chatTurnRunning = true
        lastActivity = clock.now
        guard lease == nil else { return }
        clearCompletion()
        change(.thinking)
    }

    /// The turn ended (C-2 to C-4): SENT for the result's duration, ERROR at once, INTERRUPTED. While an Aqua lease is open nothing changes (C-5).
    public func chatTurnEnded(_ outcome: ChatTurnOutcome) {
        let wasRunning = chatTurnRunning
        chatTurnRunning = false
        lastActivity = clock.now
        guard wasRunning, lease == nil else {
            // A dictation scene that was holding THINKING for the turn ends in IDLE by its own deadline.
            return
        }
        switch outcome {
        case .success(let seconds): duration = max(0, seconds); change(.sent)
        case .error: change(.error, immediate: true)
        case .interrupted: change(.interrupted)
        }
    }

    // MARK: events

    @discardableResult public func receive(_ event: PetEvent) -> Bool {
        let age = clock.wallNow.timeIntervalSince(event.timestamp)
        if guards.contains(.staleRule), !(age <= Self.staleAge && age >= -2) { return false }
        // Reused lease ids after an Aqua restart belong to a new generation; older lines cannot close the new lease.
        if let opened = leaseOpenedAt, event.timestamp < opened, event.kind != .bootstrap, event.kind != .shutdown { return false }
        let now = clock.now
        switch event.kind {
        case .bootstrap, .shutdown:
            lastEventAt = event.timestamp; reset()
        case .start, .lock:
            guard let id = event.lease else { return false }
            lastEventAt = event.timestamp; lastActivity = now
            if lease == id { listeningActivity = now; return true }
            clearCompletion(); lease = id; leaseOpenedAt = event.timestamp
            duration = 0; hintPending = false; listeningActivity = now
            change(.listening)
        case .completed(let length):
            guard lease != nil, lease == event.lease else { return false }
            lastEventAt = event.timestamp; lastActivity = now
            duration = max(0, event.timestamp.timeIntervalSince(leaseOpenedAt ?? event.timestamp))
            clearLease()
            if length == 0 { clearCompletion(); change(.interrupted) }
            else {
                completedAt = event.timestamp; completedTick = now
                deferredScene = nil
                if baseScene == .thinking { thinkingDeadline = now + Self.thinkingTimeout }
                change(.thinking)
            }
        case .canceled:
            guard lease != nil, lease == event.lease else { return false }
            lastEventAt = event.timestamp; lastActivity = now
            clearLease(); clearCompletion(); change(.interrupted)
        case .error:
            lastEventAt = event.timestamp; lastActivity = now
            clearLease(); clearCompletion()
            change(.error, immediate: true)
        case .pasteAck(let success):
            guard lease == nil, let completed = completedAt, let tick = completedTick else { return false }
            if guards.contains(.ackWindow),
               !(event.timestamp >= completed && event.timestamp.timeIntervalSince(completed) <= Self.ackWindow && now - tick <= Self.ackWindow) {
                return false
            }
            lastEventAt = event.timestamp; lastActivity = now
            clearCompletion()
            if success { change(.sent) } else { change(.error, immediate: true) }
        }
        return true
    }

    /// Source B: the selected input device went running -> stopped while the lease stayed open.
    public func releaseHint() {
        guard lease != nil, baseScene == .listening else { return }
        hintPending = true; deviceRunning = false; change(.thinking)
    }
    public func deviceChanged(running: Bool) { deviceRunning = running }

    // MARK: mouse (in-process, from the view)

    public func mouseDown() {}
    public func mouseDragged() { if !dragging { dragging = true; onChange?(.drag) } }
    public func mouseUp() { if dragging { dragging = false; onChange?(baseScene) } }

    // MARK: time

    /// Next moment at which `tick()` will change something, or nil when the scene needs no wake.
    public var nextDeadline: TimeInterval? {
        if deferredScene != nil, let start = thinkingSince { return start + Self.thinkingMinimum }
        switch baseScene {
        case .listening: return listeningActivity + Self.listeningTimeout
        case .thinking: return chatTurnRunning ? nil : thinkingDeadline
        case .sent: return sceneSince + Self.sentDuration
        case .error, .interrupted: return sceneSince + Self.noticeDuration
        case .idle: return sleepEnabled ? lastActivity + Self.sleepAfter : nil
        case .sleep, .drag: return nil
        }
    }

    public func tick() {
        var guardCount = 0
        while let deadline = nextDeadline, deadline <= clock.now, guardCount < 16 {
            guardCount += 1
            if let deferred = deferredScene { change(deferred, immediate: true, at: deadline); continue }
            switch baseScene {
            case .listening:
                clearLease(); change(.idle, immediate: true, at: deadline)
            case .thinking:
                let resume = hintPending && lease != nil && deviceRunning
                hintPending = false; clearCompletion()
                if resume { listeningActivity = deadline; change(.listening, immediate: true, at: deadline) }
                else { clearLease(); change(.idle, immediate: true, at: deadline) }
            case .sent, .error, .interrupted:
                change(.idle, immediate: true, at: deadline)
            case .idle:
                change(.sleep, immediate: true, at: deadline)
            case .sleep, .drag:
                return
            }
        }
    }
}
