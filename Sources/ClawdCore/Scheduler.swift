import Foundation
import CoreGraphics

/// Everything Clawd does on its own, as pure logic on an injected clock (spec section 6): priority and quiet conditions,
/// idle life and walking, dictation scene pools, touch, looks with transitions, entrances, the drop landing, Reduce Motion,
/// SLEEP by input idle time, bubble style choice. It owns no AppKit object and at most one timer.
///
/// Host contract: call `refresh()` when the timer fires, and the input methods when the world changes; read `frame()` after.
/// Time is `PetClock.now` (monotonic); the look clock and a timed hide use `PetClock.wallNow`.
public final class PetScheduler {
    // MARK: spec constants
    public static let lookGap: TimeInterval = 30
    public static let transitionSink: TimeInterval = 0.8
    public static let transitionRise: TimeInterval = 0.8
    public static var transitionDuration: TimeInterval { transitionSink + transitionRise }
    public static let sleepAfter: TimeInterval = 600
    public static let sleepRecheck: TimeInterval = 60
    public static let walkProbability = 0.4
    /// After this many self-started in-place idle motions in a row, the next idle slot tries a walk before it draws the chance.
    public static let inPlaceRunBeforeWalk = 2
    public static let walkPause: ClosedRange<TimeInterval> = 1...3
    public static let pointerPatience: TimeInterval = 5
    public static let walkMinWidths = 1.5
    public static let walkMaxWidths = 5.0
    public static let walkSpeedRange: ClosedRange<Double> = 20...80
    /// The skateboard glides in the rest pose; no stride, so the speed is a scheduler constant inside the allowed range.
    public static let glideSpeedAtSizeOne = 40.0
    public static let multiTouchClicks = 3
    public static let multiTouchWindow: TimeInterval = 2
    public static let minimumLookMotions = 6
    /// Each interval between look changes is the look-every setting times a factor drawn once in this band (amendment D-3).
    public static let lookJitterLow = 0.75, lookJitterHigh = 1.25
    /// A wall clock set back by more than this moves the look clock once (the rebase of D-3).
    public static let lookClockTolerance: TimeInterval = 60
    /// After the last LockDown Browser application quits, Clawd stays away this long (amendment D-4); while it stands down the running
    /// applications are asked again at this interval, on the scheduler's one timer.
    public static let examSettle: TimeInterval = 120
    public static let examRecheck: TimeInterval = 10
    public static let sentLongest: TimeInterval = 2
    public static let bubbleLongestAfterEnd: TimeInterval = 2
    /// Deadlines applied in one catch-up before the scheduler gives up and counts a stall (a coarse step over days stays far below it).
    static let runawayLimit = 20_000

    // MARK: collaborators and outputs
    public let clock: PetClock
    let timer: PetTimerScheduler
    public var guards: SchedulerGuards = .all
    /// One source for every choice (spec 6.7). Tests install a seeded one.
    public var random: () -> Double
    /// Seconds since the last keyboard or mouse input, read without a permission prompt. nil = unreadable (treated as just now).
    public var inputIdle: () -> TimeInterval? = { nil }
    /// Where the pointer is (global points, bottom-left origin), read without a permission prompt by the scheduler itself and only where
    /// a decision needs it (spec 9b item 16): on every tick while a walk goes on (the pointer-wait pause included, so a departure and the
    /// 5 s deadline are seen), once right before an idle motion or walk is committed, when a walk goes home after a scene, and when a
    /// quiet condition ends. Never during a quiet condition, never on a timer of its own. nil: the host feeds `pointerMoved` itself.
    public var pointerSource: (() -> CGPoint?)?
    public var onEvent: ((TimeInterval, SchedulerEvent) -> Void)?
    /// Something visible changed; the host renders `frame()`. Never called while hidden or in a quiet condition.
    public var onFrameChange: (() -> Void)?
    public var onPersist: ((SchedulerPersisted) -> Void)?
    /// Points per second at size 1 for a walk motion whose art declares no stride, or nil for no walk in that case.
    /// A5 declares none today (Sprint 1, gap 8), so the host decides; the value must lie in 20-80 or it is refused like a stride would be.
    public var walkSpeedWhenStrideUndeclared: Double? {
        didSet { if let v = walkSpeedWhenStrideUndeclared, !Self.walkSpeedRange.contains(v) { walkSpeedWhenStrideUndeclared = nil } }
    }

    public internal(set) var catalog: PetCatalog
    public internal(set) var settings: SchedulerSettings
    public internal(set) var geometry: PetGeometry
    public internal(set) var persisted: SchedulerPersisted
    public internal(set) var reduceMotion = false
    public internal(set) var quietReasons: Set<QuietReason> = []
    public internal(set) var visibility: PetVisibility = .visible
    public internal(set) var pointer: CGPoint?
    public internal(set) var counters = SchedulerCounters()
    public internal(set) var frameRevision = 0
    /// How many times a catch-up hit the runaway limit. Zero in any healthy run.
    public internal(set) var stallCount = 0
    public internal(set) var timerIsArmed = false
    public var ownedTimers: Int { timerIsArmed ? 1 : 0 }
    /// The next moment the scheduler wants to be called (nil: none).
    public var nextWake: TimeInterval? { wakeTime() }

    // MARK: state
    enum RunKind { case idle, touch, multiTouch, entrance, landing, sleep }
    struct Run {
        var kind: RunKind
        var playback: MotionPlayback
        var motionID: String?
        /// Clawd started it by itself (idle motion, entrance, walk): the 30 s look gap counts it.
        var selfStarted: Bool
        /// The pool the motion came from when it stands in for another (a touch motion played as the multi-touch reaction), else nil.
        var fallback: String? = nil
    }
    struct Transition {
        var from: String, to: String
        var start: TimeInterval, swapAt: TimeInterval, end: TimeInterval
        var committed: Bool
    }
    enum Activity {
        case rest
        case run(Run)
        case transition(Transition)
        case walk(WalkRun)
    }
    struct Dictation { var lease: Int?; var style: Int; var since: TimeInterval }
    enum DeadlineKind { case hideEnd, examCheck, bubbleCap, sleepRead, runEnd, transitionSwap, transitionEnd, walkArrive, walkPauseEnd, walkPatience, idleSlot, lookChange, aquaRetry }
    struct Deadline { var time: TimeInterval; var kind: DeadlineKind }

    var activity: Activity = .rest
    /// A walk cut short by a dictation or a click: Clawd stands where it is and walks home when nothing else is going on.
    var pendingWalk: WalkRun?
    var sceneBase: Scene = .idle
    var sceneSince: TimeInterval = 0
    var sceneLease: Int?
    var sceneMotion: MotionPlayback?
    /// The catalog motion whose MOTION start line is out, so its end is logged too.
    var sceneMotionLogged: String?
    var dictation: Dictation?
    var dragging = false
    var dragSince: TimeInterval = 0
    /// The right-click menu is open (spec 6.1, R-HOLD): it holds Clawd still, like `dragging` does, with Clawd's last frame kept.
    public internal(set) var menuOpen = false
    /// The chat panel is open (F1.2, `chatHold`): no walk starts and a running walk stands where it is; idle motions, touch, looks and sleep go on.
    public internal(set) var chatOpen = false
    var nextIdleAt: TimeInterval?
    var nextSleepRead: TimeInterval?
    var wasAtRest = false
    var restSince: TimeInterval = 0
    var lookBackoffUntil: TimeInterval = -.infinity
    var bubbleCapConsumed = false
    var pendingAppear = false
    var lastSelfEnd: TimeInterval?
    var lastTransitionEnd: TimeInterval?
    var lastActivityStart: TimeInterval = 0
    var clicks: [TimeInterval] = []
    /// Whether a LockDown Browser application is running now, asked of the host afresh each time (never a counter of notifications).
    public var examBrowserRunning: () -> Bool = { false }
    /// When this process first saw every LockDown Browser application gone in the current stand-down (monotonic), and the next recheck.
    var examAbsentMono: TimeInterval?
    var examCheckAt: TimeInterval?
    /// While Aqua runs but no exit registration could be made, the moment the follower looks at it again (amendment D-2, round 2): the
    /// scheduler's one timer carries it, there is no timer of its own.
    public private(set) var aquaRetryAt: TimeInterval?
    /// A retry deadline passed and its owner has not run it yet; the host takes it after the pass (`takeAquaRetryDue`).
    var aquaRetryDue = false
    public static let aquaRetryEvery: TimeInterval = 1
    var idleHistory: [String] = []
    /// Self-started in-place idle motions since the last walk started.
    var inPlaceStreak = 0
    /// The last self-started idle actions, newest first: true for a walk, false for an in-place motion.
    var recentActions: [Bool] = []
    static let recentActionsKept = 10
    /// Test seam: when set and it answers true, a walk plan counts as failed (no room). Nil in production.
    var walkPlanFails: (() -> Bool)?
    /// Test observation of the candidate families and the exact weights passed to the automatic picker.
    var onIdleFamilyWeights: (([String], [Double]) -> Void)?
    var poolHistory: [String: String] = [:]
    var rotationLooks: [CatalogLook] = []
    var dirty = false
    /// The visibility changed during this call: the host must hear it even though the frame is no longer shown.
    var visibilityChanged = false

    public init(clock: PetClock, timer: PetTimerScheduler, catalog: PetCatalog, settings: SchedulerSettings = SchedulerSettings(),
                geometry: PetGeometry, persisted: SchedulerPersisted? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.clock = clock; self.timer = timer; self.catalog = catalog; self.settings = settings; self.geometry = geometry
        self.random = random
        self.persisted = persisted ?? SchedulerPersisted(look: PetCatalog.plainLook, lookSince: clock.wallNow.timeIntervalSince1970,
                                                         lookDueFactor: Self.lookFactor(unit: random()))
        lastActivityStart = clock.now; restSince = clock.now
        visibility = computeVisibility(at: clock.now)
        if visibility == .hidden { pendingAppear = true }
        rebuildRotation()
        reconcileLookBag()      // against the catalog this process starts with; the host persists a changed bag in its startup write
    }

    // MARK: time helpers
    var wallEpoch: Double { clock.wallNow.timeIntervalSince1970 }
    func wall(at t: TimeInterval) -> Double { wallEpoch - (clock.now - t) }
    func emit(_ event: SchedulerEvent, at t: TimeInterval) { onEvent?(t, event) }

    // MARK: derived state
    public var look: String { persisted.look }
    /// The pool the current run's motion stands in from (`touch` for a multi-touch reaction played by a touch motion) when that run plays
    /// `motionID`, else nil.
    public func fallback(forMotion motionID: String) -> String? {
        if case .run(let r) = activity, r.motionID == motionID { return r.fallback }
        return nil
    }
    /// The look the next motion will be drawn in: the incoming one while a transition runs.
    var lookForMotion: String { if case .transition(let tr) = activity { return tr.to } else { return persisted.look } }
    public var sceneActive: Bool { sceneBase != .idle }
    public var asleep: Bool { if case .run(let r) = activity, r.kind == .sleep { return true } else { return false } }
    var activityIsRest: Bool { if case .rest = activity { return true } else { return false } }
    /// No scene, motion, walk, reaction, bubble or drag, and awake (spec 6.5).
    var isAtRest: Bool { visibility == .visible && !sceneActive && !dragging && !heldByMenu && pendingWalk == nil && activityIsRest }
    /// An open menu holds Clawd still: no idle slot, no walk, no sleep entry, no look change, no touch reaction, no entrance, no walk home.
    var heldByMenu: Bool { menuOpen && guards.contains(.menuHold) }
    var heldByChat: Bool { chatOpen && guards.contains(.chatHold) }
    public var quietReason: QuietReason? { QuietReason.allCases.first { quietReasons.contains($0) } }

    func computeVisibility(at t: TimeInterval) -> PetVisibility {
        if guards.contains(.settingHide), settings.hidden(atWall: wall(at: t)) { return .hidden }
        if let reason = quietReason { return .quiet(reason) }
        return .visible
    }

    // MARK: running the clock

    /// Applies every deadline that has passed, each at its own time, so a coarse step gives the same schedule as fine wakes.
    func process() {
        rebaseLookClock()
        if persisted.examActive, examCheckAt == nil { examCheckAt = clock.now + Self.examRecheck }
        refreshVisibility(at: clock.now)      // a hide that ended is seen even if its own deadline was missed
        var count = 0
        while let next = nextDeadline(), next.time <= clock.now {
            count += 1
            // A deadline that does not move on after it fires would spin here; the cap keeps the host alive and the count shows it.
            if count > Self.runawayLimit { stallCount += 1; break }
            fire(next)
        }
    }

    /// The host's timer fired (or any moment it wants the scheduler caught up). Call it once after configuring the scheduler
    /// (random source, input idle reader), which is also what starts the first idle wait.
    public func refresh() {
        // A tick while Clawd walks: the pointer is looked at first, so the deadlines due at this tick (a pause that ended, the 5 s of
        // patience) are decided with where the pointer is now.
        var sampled = false
        if guards.contains(.pointerOnWalkTicks), pointerSource != nil, visibility == .visible, case .walk = activity { readPointer(); sampled = true }
        process()
        if sampled, case .walk = activity { reevaluateWalkPointer(at: clock.now) }
        syncRest(at: clock.now)
        finish()
    }

    /// Asks the host where the pointer is (a no-op while the host feeds `pointerMoved` itself).
    func readPointer() {
        if let source = pointerSource { pointer = source() }
    }

    func finish() {
        if dirty {
            dirty = false; frameRevision += 1
            if visibility == .visible || visibilityChanged { onFrameChange?() }
        }
        visibilityChanged = false
        rearm()
    }

    func rearm() {
        timer.cancel(); timerIsArmed = false
        guard let wake = wakeTime() else { return }
        let delay = max(0.001, wake - clock.now)
        timer.arm(after: delay, leeway: delay > 5 ? 1 : 0.005)
        timerIsArmed = true
    }

    /// The system-sleep rule of v1: nothing at all is armed while the machine sleeps.
    func wakeTime() -> TimeInterval? {
        if quietReasons.contains(.systemAsleep), guards.contains(.quietFreeze) { return nil }
        return nextDeadline()?.time
    }

    func hideEndTime() -> TimeInterval? {
        guard guards.contains(.settingHide), settings.hiddenUntil > 0, settings.hidden(atWall: wallEpoch) else { return nil }
        return clock.now + (settings.hiddenUntil - wallEpoch)
    }

    func nextDeadline() -> Deadline? {
        var best: Deadline?
        func offer(_ time: TimeInterval?, _ kind: DeadlineKind) {
            guard let time else { return }
            if let current = best, current.time <= time { return }
            best = Deadline(time: time, kind: kind)
        }
        offer(hideEndTime(), .hideEnd)
        if persisted.examActive, let check = examCheckAt { offer(check, .examCheck) }
        if let retry = aquaRetryAt { offer(retry, .aquaRetry) }
        if visibility != .visible, guards.contains(.quietFreeze) { return best }
        if let cap = bubbleCapTime() { offer(cap, .bubbleCap) }
        offer(nextSleepRead, .sleepRead)
        switch activity {
        case .run(let r):
            if r.kind != .sleep, let end = r.playback.endsAt { offer(end, .runEnd) }
        case .transition(let tr):
            if !tr.committed { offer(tr.swapAt, .transitionSwap) }
            offer(tr.end, .transitionEnd)
        case .walk(let w):
            if w.moving { offer(w.arrival, .walkArrive) }
            else if w.phase == .pause { offer(w.pauseEnd, .walkPauseEnd) }
            else if let since = w.waitingSince, w.phase == .out || guards.contains(.walkHomewardRechecks) { offer(since + Self.pointerPatience, .walkPatience) }
        case .rest: break
        }
        offer(nextIdleAt, .idleSlot)
        offer(lookChangeDeadline(), .lookChange)
        return best
    }

    func fire(_ d: Deadline) {
        let t = d.time
        switch d.kind {
        case .hideEnd: refreshVisibility(at: t, evaluatingAt: t + 0.001)
        case .examCheck: examCheckFired(at: t)
        case .bubbleCap: bubbleCapConsumed = true; dirty = true
        case .sleepRead: handleSleepRead(at: t)
        case .runEnd: endRun(at: t)
        case .transitionSwap: swapTransition(at: t)
        case .transitionEnd: endTransition(at: t)
        case .walkArrive: walkArrived(at: t)
        case .walkPauseEnd: walkPauseEnded(at: t)
        case .walkPatience: walkPatienceRanOut(at: t)
        case .idleSlot: handleIdleSlot(at: t)
        case .lookChange: startLookChange(at: t)
        case .aquaRetry: aquaRetryAt = nil; aquaRetryDue = true
        }
    }

    /// Asks for the retry deadline (one `aquaRetryEvery` from now, when none is armed) or drops it.
    public func setAquaRetry(_ armed: Bool) {
        if armed { if aquaRetryAt == nil { aquaRetryAt = clock.now + Self.aquaRetryEvery } } else { aquaRetryAt = nil; aquaRetryDue = false }
        rearm()
    }

    /// Whether the retry deadline passed since the last call; reading it clears it.
    public func takeAquaRetryDue() -> Bool {
        defer { aquaRetryDue = false }
        return aquaRetryDue
    }

    // MARK: visibility, quiet conditions

    func refreshVisibility(at t: TimeInterval, evaluatingAt evaluation: TimeInterval? = nil) {
        let new = computeVisibility(at: evaluation ?? t)
        guard new != visibility else { return }
        let old = visibility
        visibility = new
        visibilityChanged = true
        if old == .hidden && new != .hidden { emit(.shown, at: t) }
        if new == .hidden && old != .hidden { emit(.hidden, at: t); pendingAppear = true }
        if old == .visible && new != .visible { if guards.contains(.quietFreeze) { suspend(at: t) } }
        else if old != .visible && new == .visible { resume(at: t) }
        dirty = true
    }

    /// Everything stops where it stands and is put back at home: a walk is over, a motion has ended, a half look change is settled.
    func suspend(at t: TimeInterval) {
        endSceneMotionLog(at: t)
        // The menu's window goes with everything else; the host closes it (MENU close reason=hidden), and the hold ends here at once.
        menuOpen = false
        // A drag is a press, and the press goes away with the window: its release will never arrive. Clawd is not dropped anywhere (the
        // host puts the drag back); idle life resumes when the quiet condition ends.
        if dragging, guards.contains(.quietCancelsDrag) { dragging = false }
        // The pointer is not looked at in a quiet condition, so what was known before it is not known afterwards.
        if guards.contains(.pointerAfterQuiet), pointerSource != nil { pointer = nil }
        cutActivity(at: t)
        if let w = pendingWalk { finishWalk(w, at: t, snapHome: true) }
        nextIdleAt = nil; nextSleepRead = nil; wasAtRest = false
        clicks = []
    }

    func resume(at t: TimeInterval) {
        wasAtRest = false
        if guards.contains(.pointerAfterQuiet) { readPointer() }      // back in step with where the pointer is now
        doAppear(at: t)
        syncRest(at: t)
    }

    /// Ends whatever Clawd is doing on its own. A walk goes to `pendingWalk` only through the dictation and click paths.
    func cutActivity(at t: TimeInterval) {
        switch activity {
        case .run(let r):
            endRunNow(r, at: t)
        case .transition(let tr):
            abortTransition(tr, at: t)
        case .walk(let w):
            finishWalk(w, at: t, snapHome: true)
        case .rest: break
        }
    }

    public func setQuiet(_ reason: QuietReason, active: Bool) {
        let wasQuiet = !quietReasons.isEmpty
        // A reason that begins is on record before anything is applied: a deadline due at this very instant (an idle slot, a walk leg, a SLEEP
        // read) would otherwise run, read the pointer and commit a motion while the quiet condition is being entered, and spec 6.1 lets nothing
        // run in one. What was due is cut by the suspend below, at this instant. A reason that ends is applied after what was due.
        if active, guards.contains(.quietReasonFirst) { quietReasons.insert(reason) } else { process() }
        applyQuiet(reason, active: active, wasQuiet: wasQuiet, at: clock.now)
        finish()
    }

    /// One quiet reason begins or ends at `now` (a deadline's own time when a deadline does it); `evaluatingAt` is the moment a timed hide is
    /// judged at.
    func applyQuiet(_ reason: QuietReason, active: Bool, wasQuiet: Bool, at now: TimeInterval, evaluatingAt evaluation: TimeInterval? = nil) {
        if active { quietReasons.insert(reason) } else { quietReasons.remove(reason) }
        let isQuiet = !quietReasons.isEmpty
        if active && reason.appearsOnClear { pendingAppear = true }
        if !wasQuiet && isQuiet, let first = quietReason { emit(.quietOn(reason: first.rawValue), at: now) }
        if wasQuiet && !isQuiet { emit(.quietOff, at: now) }
        refreshVisibility(at: now, evaluatingAt: evaluation)
    }

    // MARK: the exam stand-down (amendment D-4)

    /// Standing down for an exam, or in the 120 s after one.
    public var examActive: Bool { persisted.examActive }

    /// The process starts (before the first picture): whether Clawd stands down. A LockDown Browser application running now stands it down;
    /// a stand-down persisted by an earlier process with none running now starts a fresh 120 s from now (the earlier process's clock and its
    /// observation are not trusted: a SIGKILL may have lost the quit). The host then raises the quiet reason itself.
    public func examStartup(running: Bool) -> Bool {
        let now = clock.now
        if running {
            persisted.examActive = true; persisted.examGraceUntil = nil; examAbsentMono = nil
        } else if persisted.examActive {
            persisted.examGraceUntil = wall(at: now) + Self.examSettle; examAbsentMono = now
            emit(.examClear, at: now)
        } else {
            return false
        }
        examScheduleCheck(from: now)
        onPersist?(persisted)
        return true
    }

    /// A LockDown Browser application launched (the host recognised it from the notification). From this main-queue turn on Clawd has no window.
    public func examApplicationLaunched() {
        process()
        examEvaluate(present: true, at: clock.now, timer: false)
        finish()
    }

    /// An application that matches quit: the running applications are asked again, never counted.
    public func examApplicationTerminated() { examRecheckNow() }

    /// Asks the running applications now (a quit, a wake, an unlock, a Space change): a missed notification is corrected here.
    public func examRecheckNow() {
        process()
        examEvaluate(present: examBrowserRunning(), at: clock.now, timer: false)
        finish()
    }

    /// The scheduler's own recheck: every 10 s while standing down, and at the moment the 120 s can end. It asks afresh.
    func examCheckFired(at t: TimeInterval) {
        examCheckAt = nil
        // This query observes the applications now, even when a queued deadline is delivered much later.
        // Schedule from that observation too, so catch-up cannot consume a grace begun by this check.
        examEvaluate(present: examBrowserRunning(), at: clock.now, timer: true)
    }

    func examEvaluate(present: Bool, at t: TimeInterval, timer: Bool) {
        if present {
            if !persisted.examActive {
                persisted.examActive = true; persisted.examGraceUntil = nil; examAbsentMono = nil
                onPersist?(persisted)
                applyQuiet(.examBrowser, active: true, wasQuiet: !quietReasons.isEmpty, at: t)
            } else if examAbsentMono != nil || persisted.examGraceUntil != nil {
                // Another instance inside the 120 s: the wait starts again after it quits.
                persisted.examGraceUntil = nil; examAbsentMono = nil
                onPersist?(persisted)
            }
            examScheduleCheck(from: t)
            dirty = true
            return
        }
        guard persisted.examActive else { examCheckAt = nil; return }
        let nowWall = wall(at: t)
        guard let absent = examAbsentMono else {
            persisted.examGraceUntil = nowWall + Self.examSettle; examAbsentMono = t
            onPersist?(persisted)
            emit(.examClear, at: t)
            if timer { emit(.examRecheckHealed, at: t) }
            examScheduleCheck(from: t)
            return
        }
        // A wall clock set back far enough that the end would be hours away moves the end once; a missing value is a wait not begun.
        if let until = persisted.examGraceUntil, until.isFinite {
            if nowWall < until - Self.examSettle - Self.lookClockTolerance {
                persisted.examGraceUntil = nowWall + Self.examSettle
                onPersist?(persisted)
            }
        } else {
            persisted.examGraceUntil = nowWall + Self.examSettle
            onPersist?(persisted)
        }
        // A millisecond of slack: the two clocks are read at the same instant by different arithmetic.
        if nowWall >= (persisted.examGraceUntil ?? .infinity) - 0.001, t >= absent + Self.examSettle - 0.001 {
            persisted.examActive = false; persisted.examGraceUntil = nil; examAbsentMono = nil; examCheckAt = nil
            onPersist?(persisted)
            emit(.examSettleEnd, at: t)
            applyQuiet(.examBrowser, active: false, wasQuiet: !quietReasons.isEmpty, at: t, evaluatingAt: t + 0.001)
            dirty = true
            return
        }
        examScheduleCheck(from: t)
    }

    /// The next recheck: 10 s on, or sooner when the 120 s end before it. Only while standing down; none otherwise.
    func examScheduleCheck(from t: TimeInterval) {
        guard persisted.examActive else { examCheckAt = nil; return }
        var next = t + Self.examRecheck
        if let absent = examAbsentMono, let until = persisted.examGraceUntil, until.isFinite {
            let due = max(absent + Self.examSettle, t + (until - wall(at: t)))
            if due > t { next = min(next, due) }
        }
        examCheckAt = next
    }

    /// Clawd's window appeared: Aqua started, the Mac woke, the screen unlocked, a hide ended (spec 6.6).
    public func appear() {
        process()
        pendingAppear = true
        if visibility == .visible { doAppear(at: clock.now); syncRest(at: clock.now) }
        finish()
    }

    func doAppear(at t: TimeInterval) {
        guard pendingAppear, visibility == .visible else { return }
        pendingAppear = false
        if reduceMotion && guards.contains(.reduceMotion) { return }
        guard !sceneActive, !dragging, !heldByMenu, pendingWalk == nil, activityIsRest else { return }
        guard let m = pickFromPool(.entrance, key: "entrance", pointerCheck: false) else { return }
        counters.entrances += 1
        startRun(.entrance, motion: m, use: "entrance", loops: false, selfStarted: true, at: t)
    }

    public func setReduceMotion(_ on: Bool) {
        process()
        let now = clock.now
        guard on != reduceMotion else { finish(); return }
        reduceMotion = on
        if on && guards.contains(.reduceMotion) {
            switch activity {
            case .run(let r) where r.kind == .idle || r.kind == .entrance || r.kind == .landing:
                endRunNow(r, at: now)
            case .walk(let w):
                finishWalk(w, at: now, snapHome: true)
            case .transition(let tr):
                // Looks still change, as a cut.
                if !tr.committed { commitLook(tr.to, at: now) }
                endTransitionNow(at: now)
            default: break
            }
            nextIdleAt = nil
            // A v2 motion that a scene is playing (a LISTENING motion looping, a THINKING or SENT one) stops at once and the scene shows
            // what it would have picked under Reduce Motion: v1's pose. Waiting for the scene to end would keep it moving for minutes.
            if guards.contains(.reduceMotionEndsSceneMotion), sceneActive, sceneMotion?.motionID != nil {
                endSceneMotionLog(at: now)
                chooseSceneMotion(at: now)
            }
        }
        dirty = true
        wasAtRest = false
        syncRest(at: now)
        finish()
    }

    // MARK: rest, idle wait, sleep

    /// Called after anything that may have changed whether Clawd is at rest. Entering rest restarts the idle wait.
    func syncRest(at t: TimeInterval) {
        guard visibility == .visible else {
            if guards.contains(.quietFreeze) { wasAtRest = false; nextIdleAt = nil; nextSleepRead = nil; return }
            return
        }
        if pendingWalk != nil, activityIsRest, !sceneActive, !dragging, !heldByMenu, !heldByChat { resumeWalkHome(at: t) }
        var rest = isAtRest
        if rest && !wasAtRest {
            restSince = t
            restartIdleWait(from: t)
            armSleepRead(at: t)
            rest = isAtRest
        }
        if !rest {
            nextIdleAt = nil
            if !asleep { nextSleepRead = nil }
        }
        wasAtRest = rest
    }

    func restartIdleWait(from t: TimeInterval) {
        nextIdleAt = nil
        guard let range = settings.motion.interval, !(reduceMotion && guards.contains(.reduceMotion)) else { return }
        let base = guards.contains(.idleCountedFromEnd) ? t : min(t, lastActivityStart)
        let low = guards.contains(.idleLowerBound) ? range.lowerBound : 0
        var at = base + low + random() * (range.upperBound - low)
        if guards.contains(.lookGap30), let end = lastTransitionEnd { at = max(at, end + Self.lookGap) }
        nextIdleAt = max(at, t)
    }

    func armSleepRead(at t: TimeInterval) {
        guard guards.contains(.sleepByInputIdle) else { nextSleepRead = nil; return }
        let idle = inputIdle() ?? 0
        if idle >= Self.sleepAfter { enterSleep(at: t) }
        else { nextSleepRead = t + max(1, Self.sleepAfter - idle) }
    }

    func handleSleepRead(at t: TimeInterval) {
        let idle = inputIdle() ?? 0
        if asleep {
            if idle < Self.sleepAfter { wake(at: t) } else { nextSleepRead = t + Self.sleepRecheck }
        } else if isAtRest {
            if idle >= Self.sleepAfter { enterSleep(at: t) } else { nextSleepRead = t + max(1, Self.sleepAfter - idle) }
        } else {
            nextSleepRead = nil
        }
        syncRest(at: t)
    }

    func enterSleep(at t: TimeInterval) {
        nextIdleAt = nil
        let entry = (reduceMotion && guards.contains(.reduceMotion)) ? nil : pickEntry(.sleepEntry)
        emit(.sleepStart, at: t)
        if let entry {
            startRun(.sleep, motion: entry, use: "sleep-entry", loops: false, selfStarted: false, at: t)
            // The asleep frame stays on screen, whether or not the catalog entry says so.
            if case .run(var r) = activity { r.playback.holdsLastFrame = true; activity = .run(r) }
        } else {
            let playback = MotionPlayback(source: .pose("sleep"), use: "sleep-entry", startedAt: t, duration: 1, loops: true, holdsLastFrame: false, mirrored: false)
            activity = .run(Run(kind: .sleep, playback: playback, motionID: nil, selfStarted: false))
        }
        nextSleepRead = t + Self.sleepRecheck
        dirty = true
    }

    func wake(at t: TimeInterval) {
        guard case .run(let r) = activity, r.kind == .sleep else { return }
        endRunNow(r, at: t)
        syncRest(at: t)
    }

    // MARK: motion runs

    func startRun(_ kind: RunKind, motion m: CatalogMotion, use: String, loops: Bool, selfStarted: Bool, fallback: String? = nil,
                  at t: TimeInterval) {
        let playback = MotionPlayback(source: .motion(m.id), use: use, startedAt: t, duration: m.duration, loops: loops,
                                      holdsLastFrame: m.holdsLastFrame, mirrored: false)
        activity = .run(Run(kind: kind, playback: playback, motionID: m.id, selfStarted: selfStarted, fallback: fallback))
        lastActivityStart = t
        emit(.motionStart(id: m.id, use: use), at: t)
        dirty = true
    }

    func endRunNow(_ r: Run, at t: TimeInterval) {
        if let id = r.motionID { emit(.motionEnd(id: id), at: t) }
        if r.selfStarted { lastSelfEnd = t }
        if r.kind == .sleep { emit(.wake, at: t); nextSleepRead = nil }
        activity = .rest
        dirty = true
    }

    func endRun(at t: TimeInterval) {
        guard case .run(let r) = activity else { return }
        endRunNow(r, at: t)
        syncRest(at: t)
    }

    // MARK: idle slot

    func handleIdleSlot(at t: TimeInterval) {
        nextIdleAt = nil
        guard isAtRest else { return }
        // A look change that is due goes first; the idle wait is restarted when it is over.
        if lookIsDue(at: t), lookConditionsHold {
            if guards.contains(.lookOwnDeadline) { return }
            if startLookChange(at: t) { return }
        }
        // Something is about to be committed: where the pointer is NOW decides whether a walk may start and which motions are eligible.
        if guards.contains(.pointerBeforeIdle) { readPointer() }
        if !heldByChat, walkIsPossibleInPrinciple() {
            let roll = random()      // drawn at every possible slot, so a slot with no room consumes the random as before
            let due = inPlaceStreak >= Self.inPlaceRunBeforeWalk
            let walks = recentActions.filter { $0 }.count
            let behind = walks < recentActions.count - walks      // fewer walks than in-place motions among the last ten
            if due || behind || roll < Self.walkProbability, !(walkPlanFails?() ?? false), let plan = planWalk(at: t) {
                inPlaceStreak = 0
                recentActions = Array(([true] + recentActions).prefix(Self.recentActionsKept))
                startWalk(plan, at: t)
                return
            }
        }
        if let pick = planIdleMotion() {
            let m = pick.motion
            idleHistory = Array(([m.id] + idleHistory).prefix(3))
            counters.idleMotions += 1
            inPlaceStreak += 1
            recentActions = Array(([false] + recentActions).prefix(Self.recentActionsKept))
            commitIdlePick(pick)
            let signature = m.uses.contains(.signature(lookForMotion))
            startRun(.idle, motion: m, use: signature && !m.uses.contains(.idle) ? "signature:" + lookForMotion : "idle",
                     loops: false, selfStarted: true, at: t)
        } else {
            restartIdleWait(from: t)
        }
        syncRest(at: t)
    }

    // MARK: scenes

    /// The scene machine changed its base scene (`machine.baseScene`, not the drag overlay) or its lease.
    public func sceneChanged(_ scene: Scene, lease: Int?) {
        process()
        let now = clock.now
        let incoming: Scene = (scene == .sleep || scene == .drag) ? .idle : scene
        guard incoming != sceneBase else { sceneLease = lease; finish(); return }
        let previous = sceneBase
        sceneBase = incoming; sceneSince = now; sceneLease = lease; bubbleCapConsumed = false
        endSceneMotionLog(at: now)
        if incoming == .idle {
            dictation = nil; sceneMotion = nil
        } else {
            sceneStarted(previous: previous, lease: lease, at: now)
        }
        dirty = true
        syncRest(at: now)
        finish()
    }

    func sceneStarted(previous: Scene, lease: Int?, at now: TimeInterval) {
        let scene = sceneBase
        menuOpen = false      // a dictation outranks the menu; the host closes it first, in the same batch
        if asleep { wake(at: now) }
        if guards.contains(.sceneCutsActivity) {
            switch activity {
            case .run(let r): endRunNow(r, at: now)
            case .walk(let w):
                if guards.contains(.walkSceneCancel) { freezeWalk(w, at: now) }
            case .transition(let tr):
                if !guards.contains(.sceneAfterTransition) { abortTransition(tr, at: now) }
            case .rest: break
            }
        }
        var isNew = dictation == nil || !guards.contains(.bubbleStyleKept)
        if let d = dictation, scene == .listening {
            // Listening again is the same dictation only when the release hint resumed it; a new lease or a finished scene starts another.
            if !(previous == .thinking), previous != .listening { isNew = true }
            if let lease, lease != d.lease { isNew = true }
        }
        if isNew {
            let style = BubbleStyles.draw(enabled: settings.enabledBubbleStyles, last: persisted.lastBubbleStyle, unit: random(),
                                          noRepeat: guards.contains(.bubbleNoRepeat), weighted: guards.contains(.bubbleWeights)) ?? 1
            dictation = Dictation(lease: lease, style: style, since: now)
            persisted.lastBubbleStyle = style
            if visibility == .visible { emit(.bubbleStyle(style), at: now) }
            onPersist?(persisted)
        } else if lease != nil {
            dictation?.lease = lease
        }
        chooseSceneMotion(at: now)
    }

    func endSceneMotionLog(at t: TimeInterval) {
        if let id = sceneMotionLogged { emit(.motionEnd(id: id), at: t); sceneMotionLogged = nil }
    }

    func chooseSceneMotion(at now: TimeInterval) {
        let scene = sceneBase
        let (use, pose): (MotionUse, String) = {
            switch scene {
            case .listening: return (.listening, "listen")
            case .thinking: return (.thinking, "think")
            case .sent: return (.sent, "hop")
            case .interrupted: return (.interrupted, "idle")
            default: return (.error, "idle")
            }
        }()
        var items: [CatalogMotion?] = [nil]    // nil is the v1 pose
        if !(reduceMotion && guards.contains(.reduceMotion)) {
            items += catalog.motions.filter { m in
                m.uses.contains(use) && eligible(m, look: lookForMotion, pointerCheck: false)
                    && (!guards.contains(.poolOverheadClear) || m.overheadClear)
                    && (!(scene == .sent) || !guards.contains(.sentMaxDuration) || m.duration <= Self.sentLongest)
            }.map { Optional($0) }
        }
        let key = "scene:" + scene.rawValue
        if guards.contains(.noRepeatMotion), items.count >= 2, let last = poolHistory[key] {
            items.removeAll { ($0?.id ?? "pose:" + pose) == last }
        }
        let pick = items[min(items.count - 1, Int(random() * Double(items.count)))]
        poolHistory[key] = pick?.id ?? "pose:" + pose
        // A running look transition finishes first; the scene motion starts when it is over (at most 2 s later).
        var start = now
        if guards.contains(.sceneAfterTransition), case .transition(let tr) = activity { start = tr.end }
        let loops = scene == .listening
        if let pick {
            sceneMotion = MotionPlayback(source: .motion(pick.id), use: use.name, startedAt: start, duration: pick.duration, loops: loops, holdsLastFrame: false, mirrored: false)
            if visibility == .visible { emit(.motionStart(id: pick.id, use: use.name), at: start); sceneMotionLogged = pick.id }
        } else {
            sceneMotion = MotionPlayback(source: .pose(pose), use: use.name, startedAt: start, duration: 1, loops: true, holdsLastFrame: false, mirrored: false)
        }
    }

    // MARK: touch, drag

    public func click() {
        process()
        let now = clock.now
        defer { finish() }
        guard visibility == .visible, !dragging, !heldByMenu else { return }
        if guards.contains(.clickRules) {
            if sceneActive { return }
            if case .transition = activity { return }
        }
        if asleep { wake(at: now); return }
        // Clicks are ignored exactly while the multi-touch reaction is the current activity: a run that ended at or before `now` was
        // already applied by process(), so the first click after it reacts. An ignored click is dropped: not counted, not queued.
        if guards.contains(.clickRules), case .run(let r) = activity, r.kind == .multiTouch, r.playback.endsAt.map({ now < $0 }) ?? true {
            emit(.clickIgnored(reason: "multi-touch-playing"), at: now)
            return
        }
        clicks = clicks.filter { now - $0 <= Self.multiTouchWindow } + [now]
        let multi = guards.contains(.clickRules) ? clicks.count >= Self.multiTouchClicks : false
        // The previous reaction stops; a walk stands still and goes home afterwards.
        switch activity {
        case .run(let r): endRunNow(r, at: now)
        case .walk(let w): freezeWalk(w, at: now)
        default: break
        }
        if multi {
            clicks = []
            emit(.multiTouch, at: now)
            // A look with no multi-touch motion of its own (wizard, scientist) plays a touch motion as the multi-touch reaction.
            var pick = pickFromPool(.multiTouch, key: "multi-touch", pointerCheck: false), fallback: String?
            if pick == nil, let m = pickFromPool(.touch, key: "touch", pointerCheck: false) { pick = m; fallback = "touch" }
            if let m = pick {
                startRun(.multiTouch, motion: m, use: "multi-touch", loops: false, selfStarted: false, fallback: fallback, at: now)
            }
        } else {
            counters.touches += 1
            emit(.touch, at: now)
            if let m = pickFromPool(.touch, key: "touch", pointerCheck: false) {
                startRun(.touch, motion: m, use: "touch", loops: false, selfStarted: false, at: now)
            }
        }
        dirty = true
        syncRest(at: now)
    }

    public func dragStarted() {
        process()
        let now = clock.now
        defer { finish() }
        guard visibility == .visible, !dragging else { return }
        dragging = true; dragSince = now
        menuOpen = false      // a drag outranks the menu; the host closes it first, in the same batch
        cutActivity(at: now)
        if let w = pendingWalk { pendingWalk = nil; emit(.walkEnd(walkedSeconds: w.walked), at: now) }
        dirty = true
        syncRest(at: now)
    }

    /// The drag ended; `newHome` is where Clawd was dropped and becomes its home.
    public func dragEnded(newHome: CGPoint? = nil) {
        process()
        let now = clock.now
        defer { finish() }
        guard dragging else { return }
        dragging = false
        if let newHome { geometry.homeOrigin = newHome }
        if visibility == .visible, !sceneActive, !(reduceMotion && guards.contains(.reduceMotion)),
           let m = pickFromPool(.drop, key: "drop", pointerCheck: false) {
            startRun(.landing, motion: m, use: "drop", loops: false, selfStarted: false, at: now)
        }
        dirty = true
        syncRest(at: now)
    }

    /// Whether a drag is going on (the host cancels one that lost its window).
    public var isDragging: Bool { dragging }

    /// The press of a drag is gone without a release (its window went away): the drag is over, no landing, no new home. Clawd stands
    /// at the home it had; idle life starts its wait again.
    public func dragCancelled() {
        process()
        defer { finish() }
        guard dragging else { return }
        dragging = false
        dirty = true
        syncRest(at: clock.now)
    }

    // MARK: the right-click menu (spec 6.1, R-HOLD)

    /// The menu is about to open. False (and nothing changes) unless Clawd is visible and neither dragged nor in a dictation scene, and the
    /// menu is not open already. Otherwise the menu holds Clawd still: whatever runs ends at once where Clawd stands (a walk stops at its x and
    /// goes home after `menuClosed()`; a motion, reaction, entrance, landing or sleep ends at the rest pose of the look worn; a look transition
    /// keeps the look it has reached), and nothing lower starts until the menu closes.
    @discardableResult
    public func menuOpened() -> Bool {
        process()
        let now = clock.now
        defer { finish() }
        guard visibility == .visible, !dragging, !sceneActive, !menuOpen else { return false }
        menuOpen = true
        guard guards.contains(.menuHold) else { return true }
        switch activity {
        case .run(let r): endRunNow(r, at: now)
        case .walk(let w): freezeWalk(w, at: now)
        case .transition(let tr): abortTransition(tr, at: now)
        case .rest: break
        }
        dirty = true
        syncRest(at: now)
        return true
    }

    /// The menu closed, whatever the reason: a walk it stopped goes home, the idle wait starts again.
    public func menuClosed() {
        process()
        defer { finish() }
        guard menuOpen else { return }
        menuOpen = false
        syncRest(at: clock.now)
    }

    // MARK: the chat panel (chatHold)

    /// The chat panel opened: a walk in progress freezes where it stands and no walk starts until `chatClosed()`.
    public func chatOpened() {
        process()
        defer { finish() }
        guard !chatOpen else { return }
        chatOpen = true
        guard guards.contains(.chatHold) else { return }
        if case .walk(let w) = activity { freezeWalk(w, at: clock.now) }
        dirty = true
        syncRest(at: clock.now)
    }

    /// The chat panel closed, whatever the reason: a walk it stopped goes home, walks may start again.
    public func chatClosed() {
        process()
        defer { finish() }
        guard chatOpen else { return }
        chatOpen = false
        dirty = true
        syncRest(at: clock.now)
    }

    public func pointerMoved(_ location: CGPoint?) {
        pointer = location
        if case .walk = activity {
            process()
            reevaluateWalkPointer(at: clock.now)
            finish()
        }
    }

    // MARK: settings, geometry, catalog

    public func update(settings new: SchedulerSettings) {
        process()
        let now = clock.now
        let old = settings
        settings = new
        if old.walk != new.walk {
            emit(new.walk ? .walkEnabled : .walkDisabled, at: now)
            if !new.walk, guards.contains(.settingWalk) { sendHome(at: now) }
        }
        if old.motion != new.motion {
            if new.motion == .off, guards.contains(.settingMotion) {
                if case .run(let r) = activity, r.kind == .idle { endRunNow(r, at: now) }
                sendHome(at: now)
            }
            if isAtRest { restartIdleWait(from: now) }
        }
        if old.excluded != new.excluded {
            if guards.contains(.settingExclude) { cutExcluded(at: now) }
        }
        if old.excluded != new.excluded || old.lookPin != new.lookPin {
            rebuildRotation()
            if reconcileLookBag() { onPersist?(persisted) }
        }
        if old.lookPin != nil && new.lookPin == nil {
            persisted.lookSince = wallEpoch
            renewLookDue()
            onPersist?(persisted)
        } else if old.lookEveryHours != new.lookEveryHours, persisted.lookDueAt != nil {
            // The same factors apply to the new setting at once (as the setting always did).
            persisted.lookDueAt = persisted.lookSince + lookDueSpan
            onPersist?(persisted)
        }
        if old.lookPin != new.lookPin, new.lookPin != nil { refreshVarietyFactor() }
        refreshVisibility(at: now)
        dirty = true
        syncRest(at: now)
        finish()
    }

    func cutExcluded(at now: TimeInterval) {
        if case .run(let r) = activity, let id = r.motionID, let m = catalog.motion(id: id), settings.excludes(m), r.kind != .sleep {
            endRunNow(r, at: now)
        }
        if case .walk(let w) = activity, let id = w.stepMotionID, let m = catalog.motion(id: id), settings.excludes(m) { sendHome(at: now) }
        if let playback = sceneMotion, let id = playback.motionID, let m = catalog.motion(id: id), settings.excludes(m) {
            let pose: String = sceneBase == .listening ? "listen" : sceneBase == .thinking ? "think" : sceneBase == .sent ? "hop" : "idle"
            endSceneMotionLog(at: now)
            sceneMotion = MotionPlayback(source: .pose(pose), use: playback.use, startedAt: now, duration: 1, loops: true, holdsLastFrame: false, mirrored: false)
        }
    }

    public func update(geometry new: PetGeometry) {
        process()
        let now = clock.now
        let moved = new != geometry
        geometry = new
        if moved {
            // A walk's numbers belong to the old geometry: it ends where Clawd now is at home.
            if case .walk(let w) = activity { finishWalk(w, at: now, snapHome: true) }
            if let w = pendingWalk { finishWalk(w, at: now, snapHome: true) }
            dirty = true
        }
        syncRest(at: now)
        finish()
    }

    public func update(catalog new: PetCatalog) {
        process()
        let now = clock.now
        catalog = new
        rebuildRotation()
        refreshVarietyFactor()
        if reconcileLookBag() { onPersist?(persisted) }
        if case .run(let r) = activity, let id = r.motionID, new.motion(id: id) == nil { endRunNow(r, at: now) }
        if case .walk(let w) = activity, let id = w.stepMotionID, new.motion(id: id) == nil { finishWalk(w, at: now, snapHome: true) }
        if let id = sceneMotion?.motionID, new.motion(id: id) == nil {
            let pose: String = sceneBase == .listening ? "listen" : sceneBase == .thinking ? "think" : sceneBase == .sent ? "hop" : "idle"
            endSceneMotionLog(at: now)
            sceneMotion = MotionPlayback(source: .pose(pose), use: sceneMotion?.use ?? "", startedAt: now, duration: 1, loops: true, holdsLastFrame: false, mirrored: false)
        }
        dirty = true
        syncRest(at: now)
        finish()
    }

    // MARK: output

    /// The bubble is gone at most 2.0 s after the last scene starts (SENT, INTERRUPTED, ERROR), whatever the host reports.
    func bubbleCapAt() -> TimeInterval? {
        guard guards.contains(.bubbleTimingCap), dictation != nil else { return nil }
        switch sceneBase {
        case .sent, .interrupted, .error: return sceneSince + Self.bubbleLongestAfterEnd
        default: return nil
        }
    }
    /// The same moment as a wake, until it has been reported once.
    func bubbleCapTime() -> TimeInterval? { bubbleCapConsumed ? nil : bubbleCapAt() }

    func bubbleState(at now: TimeInterval) -> BubbleState? {
        if guards.contains(.bubbleOff), !settings.bubble { return nil }
        if guards.contains(.bubbleQuietHidden), visibility != .visible { return nil }
        guard let d = dictation, sceneActive else { return nil }
        if let cap = bubbleCapAt(), now >= cap { return nil }
        return BubbleState(style: d.style, scene: sceneBase)
    }

    public func frame() -> SchedulerFrame {
        let now = clock.now
        var playback: MotionPlayback?
        var transitionProgress: Double?
        var displayed = persisted.look
        var offset = 0.0
        var facing = Facing.right
        if case .transition(let tr) = activity {
            let span = tr.end - tr.start
            transitionProgress = min(1, max(0, (now - tr.start) / span))
            displayed = now < tr.swapAt ? tr.from : tr.to
        }
        if case .walk(let w) = activity {
            offset = w.position(at: now) - w.homeX
            facing = w.dir < 0 ? .left : .right
        } else if let w = pendingWalk {
            offset = w.x - w.homeX
            facing = w.dir < 0 ? .left : .right
        }
        if visibility == .visible {
            if dragging {
                playback = MotionPlayback(source: .pose("dangle"), use: "drag", startedAt: dragSince, duration: 1, loops: true, holdsLastFrame: false, mirrored: false)
            } else if sceneActive {
                if case .transition(let tr) = activity, now < tr.end {
                    playback = MotionPlayback(source: .transition(from: tr.from, to: tr.to), use: "transition", startedAt: tr.start, duration: tr.end - tr.start, loops: false, holdsLastFrame: false, mirrored: false)
                } else if !guards.contains(.sceneCutsActivity), let under = activityPlayback(now: now) {
                    playback = under
                } else {
                    playback = sceneMotion
                }
            } else {
                playback = activityPlayback(now: now)
            }
        }
        return SchedulerFrame(visibility: visibility, scene: sceneBase, dragging: dragging && visibility == .visible, asleep: asleep,
                              playback: playback, look: persisted.look, displayedLook: displayed, transitionProgress: transitionProgress,
                              walkOffset: visibility == .visible ? offset : 0, facing: facing, bubble: bubbleState(at: now))
    }

    func activityPlayback(now: TimeInterval) -> MotionPlayback? {
        switch activity {
        case .rest: return nil
        case .run(let r): return r.playback
        case .transition(let tr):
            return MotionPlayback(source: .transition(from: tr.from, to: tr.to), use: "transition", startedAt: tr.start, duration: tr.end - tr.start, loops: false, holdsLastFrame: false, mirrored: false)
        case .walk(let w): return walkPlayback(w)
        }
    }

    /// When the next look change is due, as a date (nil with a pin that is already worn, or nothing to change to).
    public var nextLookChange: Date? {
        guard lookDueMono() != nil else { return nil }
        if settings.lookPin != nil && settings.lookPin == persisted.look { return nil }
        return Date(timeIntervalSince1970: lookDueWall())
    }
}
