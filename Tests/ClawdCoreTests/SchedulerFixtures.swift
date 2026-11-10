import Foundation
import CoreGraphics
import ClawdCore

/// A catalog in the schema-2 shape of the Interface Contract, built in code. Sprint 1 produces the real one; the scheduler is
/// tested against this fixture so the two sprints can run in parallel.
enum SchedulerFixture {
    static let looks = ["plain", "helmet", "sunglasses", "headphones", "coffee", "skateboard", "wizard", "shiny"]

    static func catalog(walkStride: Double = 40 * 2.3333 / 4) -> PetCatalog {
        func compat(except excluded: [String] = [], only: [String]? = nil) -> Set<String> {
            Set(only ?? looks).subtracting(excluded)
        }
        func motion(_ id: String, _ uses: [String], _ seconds: Double, stage: StageExtent = .none, clear: Bool = false,
                    weight: Double = 1, compat set: Set<String>? = nil, stride: Double? = nil, hold: Bool = false) -> CatalogMotion {
            CatalogMotion(id: id, board: String(id.prefix { $0 != "-" }), uses: Set(uses.map(MotionUse.init)),
                          frameCount: Int(seconds * 12), duration: seconds, stage: stage, overheadClear: clear, weight: weight,
                          compatibleLooks: set ?? compat(), strideUnits: stride, holdsLastFrame: hold)
        }
        let motions: [CatalogMotion] = [
            motion("A1-thinking", ["idle"], 3.17, stage: StageExtent(up: 2.5)),
            motion("A1-thinking-nobubble", ["thinking"], 3.17, clear: true),
            motion("A2-looking", ["idle", "listening", "walk-pause"], 3.5, clear: true),
            motion("A3-jumping", ["touch", "idle"], 1.75, stage: StageExtent(up: 3.0), compat: compat(except: ["skateboard", "wizard"])),
            motion("A4-waving", ["sent", "touch", "idle"], 1.42, clear: true),
            motion("A5-walking", ["walk"], 2.3333, clear: true, compat: compat(except: ["wizard"]), stride: walkStride),
            motion("A6-turning", ["idle", "multi-touch"], 2.42, clear: true, compat: compat(only: ["plain"])),
            motion("A7-swaying", ["idle"], 4.08, stage: StageExtent(left: 0.9, right: 1.1), clear: true),
            motion("A8-excited", ["sent", "touch", "idle"], 1.92, stage: StageExtent(right: 0.1), clear: true),
            motion("A9-dancing", ["idle"], 3.33, stage: StageExtent(right: 0.1), clear: true),
            motion("A10-breakdancing", ["idle"], 12.42, stage: StageExtent(left: 1.9, right: 3.1, up: 4.0), weight: 0.5),
            motion("A12-heart", ["touch", "idle"], 1.83, stage: StageExtent(up: 6.5)),
            motion("A14-lightbulb", ["idle"], 4.17, stage: StageExtent(up: 4.0), compat: compat(except: ["helmet"])),
            motion("A15-snooze", ["sleep-entry"], 4.58, stage: StageExtent(right: 1.0), clear: true, hold: true),
            motion("A16-meditating", ["idle"], 5.0, stage: StageExtent(right: 0.1), clear: true),
            motion("A19-coffee", ["idle", "signature:coffee"], 2.83, stage: StageExtent(right: 2.6), compat: compat(except: ["wizard"])),
            motion("A20-laptop", ["thinking", "idle"], 3.58, stage: StageExtent(right: 5.0), clear: true, compat: compat(except: ["coffee"])),
            motion("A22-notebook", ["thinking", "idle"], 6.75, stage: StageExtent(left: 0.4, right: 2.1), clear: true),
            motion("A25-spark", ["idle", "signature:wizard"], 6.08, stage: StageExtent(right: 5.5, up: 3.5), compat: compat(except: ["skateboard"])),
            motion("A26-juggling", ["idle"], 4.5, stage: StageExtent(left: 0.4, right: 0.1, up: 4.0)),
            motion("A27-hulahoop", ["idle"], 6.25, stage: StageExtent(left: 1.9, right: 2.1)),
            motion("A33-rose", ["touch", "idle"], 3.42, stage: StageExtent(right: 5.1, up: 0.5)),
            motion("C3-skip", ["entrance"], 0.84, stage: StageExtent(left: 12)),
            motion("C6-peekaboo", ["entrance"], 1.26, stage: StageExtent(left: 12)),
            motion("C7-drop", ["entrance", "drop"], 0.78, stage: StageExtent(up: 6)),
            motion("C8-waddle", ["entrance"], 1.14, stage: StageExtent(left: 12)),
            motion("C9-peek", ["entrance"], 1.2, stage: StageExtent(left: 12)),
            // Traps: a scene or sent use that breaks the pool rules must never be played.
            motion("X-sent-long", ["sent"], 2.6, clear: true),
            motion("X-listen-high", ["listening"], 1.0, stage: StageExtent(up: 3), clear: false),
            motion("X-thinking-high", ["thinking"], 1.0, stage: StageExtent(up: 3), clear: false),
            motion("X-error-high", ["error", "interrupted"], 1.0, stage: StageExtent(up: 2), clear: false),
        ]
        let lookList = [
            CatalogLook(id: "plain", board: "B1", classes: ["plain"]),
            CatalogLook(id: "helmet", board: "D1", classes: ["costume"]),
            CatalogLook(id: "sunglasses", board: "D18", classes: ["costume"]),
            CatalogLook(id: "headphones", board: "D10", classes: ["costume"]),
            CatalogLook(id: "coffee", board: "D9", classes: ["held"], signature: ["A19-coffee"]),
            CatalogLook(id: "skateboard", board: "D14", classes: ["under-feet"]),
            CatalogLook(id: "wizard", board: "D15", classes: ["costume", "held"], signature: ["A25-spark"]),
            CatalogLook(id: "shiny", board: "D7", classes: ["body-color"], weight: 0.5),
        ]
        return PetCatalog(motions: motions, looks: lookList)
    }

    /// 1440 x 900 display, 80 pt Dock at the bottom and a 30 pt menu bar. Aqua's default spot: 120 pt left of the centre.
    static func geometry(scale: Double = 1, homeX: Double = 576, homeY: Double = 100) -> PetGeometry {
        PetGeometry(scale: scale, homeOrigin: CGPoint(x: homeX, y: homeY),
                    displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 80, width: 1440, height: 790))
    }

    static func settings(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
        var s = SchedulerSettings(); edit(&s); return s
    }
}

struct Logged: Equatable {
    var t: TimeInterval
    var event: SchedulerEvent
}

/// The scheduler on a virtual clock with its one fake timer, fed by the real v1 SceneMachine (scene deadlines included).
final class SchedulerRig {
    let clock: VirtualClock
    let timer: FakeScheduler
    let machine: SceneMachine
    let scheduler: PetScheduler
    let random: SeededRandom
    private(set) var events: [Logged] = []
    private(set) var renders = 0
    private(set) var maxTimers = 0
    /// What the scheduler reads as seconds since the last input: the user is at the Mac (0) unless a test fixes another value or sets it to nil
    /// to count from `lastInput`.
    var inputIdle: TimeInterval? = 0
    var lastInput: TimeInterval
    /// A runaway (a deadline that never moves on) or a flood of events ends the run instead of hanging it; the scenario then fails.
    let eventLimit: Int
    var runaway: Bool { scheduler.stallCount > 0 || events.count > eventLimit }
    let started: TimeInterval
    let startedWall: Date
    /// Scene spans seen at the machine, for the invariants that need to know when a dictation was running.
    private(set) var sceneSpans: [(start: TimeInterval, end: TimeInterval?)] = []

    init(catalog: PetCatalog = SchedulerFixture.catalog(), settings: SchedulerSettings = SchedulerSettings(),
         geometry: PetGeometry = SchedulerFixture.geometry(), seed: UInt64 = 1, guards: SchedulerGuards = .all,
         persisted: SchedulerPersisted? = nil, refresh: Bool = true, eventLimit: Int = 400_000, startWall: Double = 1_800_000_000) {
        self.eventLimit = eventLimit
        let wall = Date(timeIntervalSince1970: startWall)
        clock = VirtualClock(now: 5000, wallNow: wall)
        timer = FakeScheduler(clock: clock)
        machine = SceneMachine(clock: clock)
        machine.sleepEnabled = false          // v2: SLEEP belongs to the scheduler (input idle), not to the Aqua event age
        random = SeededRandom(seed: seed)
        started = clock.now; startedWall = wall; lastInput = clock.now
        let rand = random
        scheduler = PetScheduler(clock: clock, timer: timer, catalog: catalog, settings: settings, geometry: geometry,
                                 persisted: persisted ?? SchedulerPersisted(look: "plain", lookSince: wall.timeIntervalSince1970),
                                 random: { rand.unit() })
        scheduler.guards = guards
        scheduler.inputIdle = { [unowned self] in self.inputIdle ?? (self.clock.now - self.lastInput) }
        scheduler.onEvent = { [unowned self] t, e in self.events.append(Logged(t: t, event: e)) }
        scheduler.onFrameChange = { [unowned self] in self.renders += 1 }
        machine.onChange = { [unowned self] _ in
            let base = self.machine.baseScene
            if base != .idle, self.sceneSpans.last?.end != nil || self.sceneSpans.isEmpty {
                self.sceneSpans.append((self.clock.now, nil))
            } else if base == .idle, let last = self.sceneSpans.last, last.end == nil {
                self.sceneSpans[self.sceneSpans.count - 1].end = self.clock.now
            }
            self.scheduler.sceneChanged(base, lease: self.machine.lease)
        }
        if refresh { scheduler.refresh() }
    }

    var now: TimeInterval { clock.now }
    /// The user touched the keyboard or mouse.
    func touchInput() { lastInput = clock.now }
    var seconds: TimeInterval { clock.now - started }
    var frame: SchedulerFrame { scheduler.frame() }
    var wall: Double { clock.wallNow.timeIntervalSince1970 }

    // MARK: time

    /// Moves virtual time forward, firing the scheduler's timer and the scene machine's deadlines at their own instants.
    func advance(_ span: TimeInterval) {
        let target = clock.now + span
        var steps = 0
        while steps < 3_000_000, !runaway {
            steps += 1
            var next: TimeInterval?
            if let t = timer.fireAt, t <= target { next = t }
            if let d = machine.nextDeadline, d <= target, next == nil || d < next! { next = d }
            guard let at = next else { break }
            clock.advance(max(0, at - clock.now))
            if let d = machine.nextDeadline, d <= clock.now { machine.tick() }
            if let t = timer.fireAt, t <= clock.now { timer.cancel(); scheduler.refresh() }
            maxTimers = max(maxTimers, scheduler.ownedTimers)
        }
        clock.advance(max(0, target - clock.now))
    }

    /// Steps from wake to wake until `condition` holds or `limit` seconds have passed. Returns whether it held.
    @discardableResult
    func run(upTo limit: TimeInterval, until condition: () -> Bool) -> Bool {
        let target = clock.now + limit
        var steps = 0
        while steps < 3_000_000, !runaway {
            steps += 1
            if condition() { return true }
            var next: TimeInterval?
            if let t = timer.fireAt, t <= target { next = t }
            if let d = machine.nextDeadline, d <= target, next == nil || d < next! { next = d }
            guard let at = next else { break }
            clock.advance(max(0, at - clock.now))
            if let d = machine.nextDeadline, d <= clock.now { machine.tick() }
            if let t = timer.fireAt, t <= clock.now { timer.cancel(); scheduler.refresh() }
            maxTimers = max(maxTimers, scheduler.ownedTimers)
        }
        let held = condition()
        if !held { clock.advance(max(0, target - clock.now)) }
        return held
    }

    // MARK: dictation

    func send(_ kind: EventKind, lease: Int? = 1) {
        machine.receive(PetEvent(kind, lease: lease, timestamp: clock.wallNow))
    }
    func start(_ lease: Int = 1) { send(.start, lease: lease) }
    func complete(_ lease: Int = 1) { send(.completed(12), lease: lease) }
    func ack(_ success: Bool = true) { send(.pasteAck(success), lease: nil) }
    func cancel(_ lease: Int = 1) { send(.canceled, lease: lease) }
    func fail() { send(.error, lease: nil) }
    /// start, 2 s of listening, completed, ACK after the 1 s THINKING minimum, then the 2 s of SENT.
    func dictate(listening: TimeInterval = 2, lease: Int = 1, thenSettle: Bool = true) {
        start(lease); advance(listening); complete(lease); advance(1.0); ack()
        if thenSettle { advance(SceneMachine.sentDuration + 0.05) }
    }

    // MARK: log helpers

    func ids(_ use: String...) -> [String] {
        events.compactMap { if case .motionStart(let id, let u) = $0.event, use.contains(u) { return id } else { return nil } }
    }
    func count(where match: (SchedulerEvent) -> Bool) -> Int { events.filter { match($0.event) }.count }
    func eventsSince(_ index: Int) -> [Logged] { Array(events.dropFirst(index)) }
}

/// Spans in the event log, for the invariants that compare moments.
struct SpanLog {
    struct Span { var kind: String; var start: TimeInterval; var end: TimeInterval; var selfStarted: Bool }
    var spans: [Span] = []
    var lookTransitions: [(start: TimeInterval, end: TimeInterval, from: String, to: String)] = []
    var sleeps: [(start: TimeInterval, end: TimeInterval)] = []

    init(_ events: [Logged], endOfLog: TimeInterval) {
        var open: [String: (start: TimeInterval, kind: String, selfStarted: Bool)] = [:]
        var walkStart: TimeInterval?
        var transitionStart: (TimeInterval, String, String)?
        var sleepStart: TimeInterval?
        for item in events.sorted(by: { $0.t < $1.t }) {
            switch item.event {
            case .motionStart(let id, let use):
                let selfStarted = use == "idle" || use.hasPrefix("signature") || use == "entrance"
                open[id] = (item.t, use, selfStarted)
            case .motionEnd(let id):
                if let o = open.removeValue(forKey: id) { spans.append(Span(kind: o.kind, start: o.start, end: item.t, selfStarted: o.selfStarted)) }
            case .walkStart: walkStart = item.t
            case .walkEnd:
                if let s = walkStart { spans.append(Span(kind: "walk", start: s, end: item.t, selfStarted: true)) }
                walkStart = nil
            case .lookTransition(let f, let t): transitionStart = (item.t, f, t)
            case .lookTransitionEnd:
                if let s = transitionStart { lookTransitions.append((s.0, item.t, s.1, s.2)) }
                transitionStart = nil
            case .sleepStart: sleepStart = item.t
            case .wake:
                if let s = sleepStart { sleeps.append((s, item.t)) }
                sleepStart = nil
            default: break
            }
        }
        for (_, o) in open { spans.append(Span(kind: o.kind, start: o.start, end: endOfLog, selfStarted: o.selfStarted)) }
        if let s = walkStart { spans.append(Span(kind: "walk", start: s, end: endOfLog, selfStarted: true)) }
        if let s = sleepStart { sleeps.append((s, endOfLog)) }
    }
}
