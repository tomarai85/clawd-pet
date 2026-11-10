import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Sprint 11 (spec 9b item 16, item 4 of the brief): the pointer rules of a walk (stop, resume, 5 s, no start under the pointer) were dead because
// nothing fed the scheduler the pointer. It reads it through `pointerSource` (the runtime environment's `pointer`) on the ticks of a walk and
// once before an idle motion is committed. Each scenario runs on the virtual clock and returns what it found wrong; the negative control
// runs the same scenario with the one rule switched off (`SchedulerGuards`) and needs a violation.

private func lively(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .lively; edit(&s); return s
}
private func calm(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .off; edit(&s); return s
}

/// The host's ticks as production has them (Codex's finding B on round 1). While Clawd moves, the renderer's frames tick the merged timer 12 a
/// second. While it STANDS (a pointer wait) there is no renderer frame at all: the only ticks are the scheduler's own wake, the scene
/// machine's deadlines and the controller's blink, which is 3 to 7 s apart (`blinkEvery`: 7 s is the worst case). A helper that refreshed
/// 12 times a second while Clawd stands would hide every wait that no tick ends.
private final class Host {
    let rig: SchedulerRig
    let blinkEvery: Double
    private var nextBlink: Double
    init(_ rig: SchedulerRig, blinkEvery: Double = 7) {
        self.rig = rig; self.blinkEvery = blinkEvery; nextBlink = rig.now + blinkEvery
    }
    private var animating: Bool { rig.frame.playback != nil }
    /// A blink tick right now; the next one is `blinkEvery` away (a pointer that leaves just after it is the worst case for a wait).
    func blink() { rig.scheduler.refresh(); nextBlink = rig.now + blinkEvery }
    /// Ticks until `condition` holds, looking every `step` (the ticks themselves stay those of production); false when `limit` ran out first.
    @discardableResult
    func tick(until condition: () -> Bool, limit: Double, step: Double = 0.05) -> Bool {
        var spent = 0.0
        while !condition(), spent < limit - 1e-9 { let slice = min(step, limit - spent); tick(slice); spent += slice }
        return condition()
    }
    func tick(_ seconds: Double) {
        let end = rig.now + seconds
        var steps = 0
        while end - rig.now > 1e-9, steps < 200_000 {
            steps += 1
            if animating {
                rig.advance(min(1.0 / 12, end - rig.now)); rig.scheduler.refresh()
                continue
            }
            var slice = min(end - rig.now, nextBlink - rig.now)
            if let wake = rig.scheduler.nextWake { slice = min(slice, wake - rig.now) }
            if let deadline = rig.machine.nextDeadline { slice = min(slice, deadline - rig.now) }
            rig.advance(max(slice, 1e-6))
            if rig.now >= nextBlink - 1e-9 { blink() }
        }
    }
}

enum Sprint11Scenarios {
    /// A walk stops when the pointer comes within one Clawd width of its path ahead, goes on when it leaves, and heads home when it is
    /// still there after 5 s (spec 6.2): on the ticks the host has anyway.
    static func pointerOnWalkTicks(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        let rig = SchedulerRig(settings: lively(), seed: 3, guards: guards)
        var source: CGPoint?
        rig.scheduler.pointerSource = { source }
        let before = rig.events.count
        v.check(rig.run(upTo: 7200) { rig.eventsSince(before).contains { isWalkStart($0.event) } }, "no walk started")
        if v.done { return v }
        let host = Host(rig)
        host.tick(1.0)
        let moved = rig.frame.walkOffset
        v.check(abs(moved) > 5, "Clawd is not walking (offset \(moved))")
        source = CGPoint(x: 576 + moved - 30, y: 120)           // in the path ahead (the walk goes left from Aqua's default spot)
        host.tick(0.2)
        let stopped = rig.frame.walkOffset
        v.check(rig.frame.playback == nil, "Clawd keeps walking with the pointer in the way")
        host.tick(3.0)
        v.check(abs(rig.frame.walkOffset - stopped) < 1e-6, "Clawd moved while the pointer was in the way (\(stopped) -> \(rig.frame.walkOffset))")
        if v.done { return v }
        source = CGPoint(x: 1300, y: 600)
        // While Clawd stands the ticks are few: the 5 s deadline or a blink sees that the pointer has left, within 5 s.
        v.check(host.tick(until: { rig.frame.walkOffset < stopped - 5 }, limit: 5.1),
                "Clawd did not go on within 5 s of the pointer leaving (\(stopped) -> \(rig.frame.walkOffset))")
        source = CGPoint(x: 576 + rig.frame.walkOffset - 30, y: 120)
        host.tick(0.2)
        let again = rig.frame.walkOffset
        host.tick(4.5)
        v.check(abs(rig.frame.walkOffset - again) < 1e-6, "Clawd turned home before 5 s (\(again) -> \(rig.frame.walkOffset))")
        host.tick(1.0)
        v.check(rig.frame.walkOffset > again + 1, "Clawd did not head home after 5 s (\(again) -> \(rig.frame.walkOffset))")
        source = nil
        var spent = 0.0
        func walkEnded() -> Bool { rig.eventsSince(before).contains { if case .walkEnd = $0.event { return true } else { return false } } }
        while spent < 60, !walkEnded() { host.tick(0.5); spent += 0.5 }
        v.check(walkEnded(), "Clawd never got home")
        v.check(abs(rig.frame.walkOffset) < 1e-6, "not home at the end")
        return v
    }

    /// The pointer leaves while Clawd waits, and the only tick that follows is the 5 s deadline itself: it must see that the pointer is
    /// gone, so Clawd goes on out instead of turning home ("heads home if it is still there after 5 s").
    static func patienceSeesAPointerThatLeft(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        let rig = SchedulerRig(settings: lively(), seed: 3, guards: guards)
        var source: CGPoint?
        rig.scheduler.pointerSource = { source }
        let before = rig.events.count
        v.check(rig.run(upTo: 7200) { rig.eventsSince(before).contains { isWalkStart($0.event) } }, "no walk started")
        if v.done { return v }
        let host = Host(rig)
        host.tick(1.0)
        source = CGPoint(x: 576 + rig.frame.walkOffset - 30, y: 120)
        host.tick(0.2)
        let stopped = rig.frame.walkOffset
        v.check(rig.frame.playback == nil, "Clawd keeps walking with the pointer in the way")
        host.tick(2.0)
        v.check(abs(rig.frame.walkOffset - stopped) < 1e-6, "Clawd moved while the pointer was in the way")
        source = CGPoint(x: 1300, y: 600)
        rig.advance(3.5)         // no renderer tick: the scheduler's own wake at the 5 s deadline is the only one
        v.check(rig.frame.walkOffset < stopped - 10, "the pointer had left at the 5 s deadline, yet Clawd did not go on out (\(stopped) -> \(rig.frame.walkOffset))")
        return v
    }

    /// A dictation stops a walk where Clawd stands and it walks home when the scene is over: the pointer is looked at when that walk
    /// starts, because the scene's ticks (the renderer's) are not ticks of a walk and the pointer may have moved onto the way home.
    static func pointerForTheWalkHome(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        let rig = SchedulerRig(settings: lively(), seed: 3, guards: guards)
        var source: CGPoint?
        rig.scheduler.pointerSource = { source }
        let before = rig.events.count
        v.check(rig.run(upTo: 7200) { rig.eventsSince(before).contains { isWalkStart($0.event) } }, "no walk started")
        if v.done { return v }
        let host = Host(rig)
        host.tick(1.0)
        rig.start()                                          // a dictation: Clawd stops where it stands
        let stopped = rig.frame.walkOffset
        v.check(abs(stopped) > 5, "Clawd is not away from home when the dictation starts (offset \(stopped))")
        host.tick(2.0)
        source = CGPoint(x: 576 + stopped + 30, y: 120)       // between Clawd and home while the scene plays
        rig.complete(); host.tick(1.0); rig.ack()
        host.tick(SceneMachine.sentDuration + 0.05)
        v.check(rig.frame.scene == .idle, "the scene did not end")
        host.tick(0.5)
        v.check(abs(rig.frame.walkOffset - stopped) < 1e-6, "Clawd walked home through the pointer that sits on the way (\(stopped) -> \(rig.frame.walkOffset))")
        source = nil
        host.tick(5.1)       // standing again: the ticks are the blink and the re-check, and the wait is over within 5 s of the pointer leaving
        v.check(rig.frame.walkOffset > stopped + 5, "Clawd did not go home once the pointer left (\(stopped) -> \(rig.frame.walkOffset))")
        return v
    }

    /// A wait on the way home ends within 5 s of the pointer leaving, although the only tick Clawd's standing has besides the scheduler's own
    /// wake is the blink, 7 s apart at worst, and the pointer leaves just after one (Codex's finding B on round 1: only the way out had a
    /// deadline). The pointer sits on the way home for different times first, so it leaves at different places between two re-checks.
    static func homewardWaitEndsWithinFiveSeconds(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        for hold in [0.4, 3.0, 4.9, 5.2, 8.0, 10.2, 13.0] {
            let rig = SchedulerRig(settings: lively(), seed: 3, guards: guards)
            var source: CGPoint?
            rig.scheduler.pointerSource = { source }
            let before = rig.events.count
            v.check(rig.run(upTo: 7200) { rig.eventsSince(before).contains { isWalkStart($0.event) } }, "no walk started")
            if v.done { return v }
            let host = Host(rig)
            host.tick(1.0)
            rig.start()                                          // a dictation: Clawd stops where it stands and walks home when the scene is over
            let away = rig.frame.walkOffset
            v.check(abs(away) > 5, "hold \(hold): Clawd is not away from home when the dictation starts (offset \(away))")
            host.tick(2.0)
            source = CGPoint(x: 576 + away + 30, y: 120)         // between Clawd and home
            rig.complete(); host.tick(1.0); rig.ack()
            host.tick(SceneMachine.sentDuration + 0.05)
            v.check(rig.frame.scene == .idle, "hold \(hold): the scene did not end")
            host.tick(hold)
            v.check(abs(rig.frame.walkOffset - away) < 1e-6, "hold \(hold): Clawd walked home through the pointer (\(away) -> \(rig.frame.walkOffset))")
            host.blink()                                          // a tick, and the pointer leaves right after it: the next one is 7 s away
            source = nil
            host.tick(5.1)
            v.check(abs(rig.frame.walkOffset - away) > 3, "hold \(hold): the pointer left and Clawd still stands 5.1 s later (offset \(rig.frame.walkOffset))")
            if v.done { return v }
        }
        return v
    }

    /// A quiet condition that begins at the very instant an idle slot is due: the screen-lock or display-sleep notification is handled before the
    /// timer, so the slot is due and has not run. Nothing may run in a quiet condition, so it must not read the pointer or start a motion or a walk
    /// (Codex's finding C on round 1: the due slot ran first, because the reason was recorded after it).
    static func quietBeginsAtADueIdleSlot(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        for reason in [QuietReason.screenLocked, .displayAsleep] {
            let rig = SchedulerRig(settings: lively { $0.lookPin = "plain" }, seed: 6, guards: guards)
            var reads = 0
            rig.scheduler.pointerSource = { reads += 1; return nil }
            guard let due = rig.scheduler.nextWake else { v.check(false, "\(reason): no wake is armed"); return v }
            rig.clock.advance(max(0, due - rig.now))             // due, and the timer has not had its turn
            let events = rig.events.count, counters = rig.scheduler.counters
            rig.scheduler.setQuiet(reason, active: true)
            v.check(reads == 0, "\(reason): the pointer was read \(reads) times while the quiet condition began")
            v.check(!rig.eventsSince(events).contains { isMotionStart($0.event) || isWalkStart($0.event) },
                    "\(reason): a motion or a walk started while the quiet condition began: \(rig.eventsSince(events).map(\.event))")
            v.check(rig.scheduler.counters == counters, "\(reason): an idle motion or a walk was counted while the quiet condition began")
            v.check(rig.frame.visibility == .quiet(reason) && rig.frame.playback == nil, "\(reason): something is shown in the quiet condition")
            rig.advance(7200)
            rig.scheduler.refresh()
            v.check(reads == 0, "\(reason): the pointer was read \(reads) times in the quiet condition")
            if v.done { return v }
        }
        return v
    }

    /// No idle motion starts over the pointer, and no walk starts with the pointer on its path: it is read once, right before.
    static func pointerBeforeAnIdleMotion(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        do {
            let rig = SchedulerRig(settings: lively { $0.lookPin = "plain"; $0.walk = false }, seed: 6, guards: guards, refresh: false)
            var source: CGPoint? = CGPoint(x: 640, y: 120)          // right of Clawd, inside the stages of A33, A25 and A20
            var reads = 0
            rig.scheduler.pointerSource = { reads += 1; return source }
            rig.scheduler.refresh()
            rig.advance(86_400)
            let ids = Set(rig.ids("idle"))
            v.check(ids.count >= 8, "only \(ids.count) kinds of idle motion in a day")
            for under in ["A33-rose", "A25-spark", "A20-laptop"] { v.check(!ids.contains(under), "\(under) started over the pointer") }
            let slots = rig.ids("idle").count
            v.check(reads <= slots + 1 && reads >= slots, "the pointer was read \(reads) times for \(slots) idle motions: once per motion, no more")
            source = CGPoint(x: 1300, y: 600)
            rig.advance(86_400)
            v.check(Set(rig.ids("idle")).contains("A33-rose"), "A33 never played once the pointer left")
        }
        if v.done { return v }
        do {
            let rig = SchedulerRig(settings: lively { $0.lookPin = "plain" }, seed: 3, guards: guards, refresh: false)
            rig.scheduler.pointerSource = { CGPoint(x: 576 - 30, y: 120) }      // on the way of any walk to the left of Aqua's default spot
            rig.scheduler.refresh()
            rig.advance(86_400)
            v.check(rig.count(where: isWalkStart) == 0, "\(rig.count(where: isWalkStart)) walks started with the pointer on their path")
            v.check(rig.ids("idle").count > 100, "the idle motions went on")
        }
        return v
    }

    /// Nothing is read in a quiet condition, what was known before it is not known after it, and when it ends the pointer is read once.
    static func pointerAcrossAQuietCondition(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        let rig = SchedulerRig(settings: lively(), seed: 3, guards: guards)
        var reads = 0
        var current = CGPoint(x: 100, y: 500)
        rig.scheduler.pointerSource = { reads += 1; return current }
        v.check(rig.run(upTo: 3600) { reads > 0 }, "the pointer was never read")
        v.check(rig.scheduler.pointer == current, "the pointer read is not the one the scheduler holds")
        rig.scheduler.setQuiet(.screenLocked, active: true)
        let atTheStart = reads
        v.check(rig.scheduler.pointer == nil, "what was read before the quiet condition is still held in it")
        rig.advance(7200)
        rig.scheduler.refresh()
        v.check(reads == atTheStart, "the pointer was read \(reads - atTheStart) times in a quiet condition")
        current = CGPoint(x: 900, y: 500)
        rig.scheduler.setQuiet(.screenLocked, active: false)
        v.check(reads == atTheStart + 1, "the pointer was read \(reads - atTheStart) times when the quiet condition ended, not once")
        v.check(rig.scheduler.pointer == current, "the scheduler is not in step with the pointer after the quiet condition")
        return v
    }
}

@Suite("Sprint 11 pointer", .serialized)
struct Sprint11PointerTests {
    private func holds(_ id: String, _ found: Violations, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(found.isEmpty, "\(id): \(found.summary)", sourceLocation: sourceLocation)
    }
    private func control(_ id: String, _ scenario: (SchedulerGuards, Bool) -> Violations, removing rules: [(String, SchedulerGuards)],
                         sourceLocation: SourceLocation = #_sourceLocation) {
        for (name, rule) in rules {
            let found = scenario(.all.subtracting(rule), true)
            negativeControl("\(id) without \(name)", expectationHolds: found.isEmpty, sourceLocation: sourceLocation)
            emit("    first violation: \(found.list.first ?? "none")")
        }
    }

    @Test func Pointer_aWalkStopsForThePointerGoesOnWhenItLeavesAndHeadsHomeAfterFiveSecondsFromTheTicksAlone() { holds("walk ticks", Sprint11Scenarios.pointerOnWalkTicks(.all)) }

    @Test func Pointer_aWalkStopsForThePointerNegativeControl() {
        control("pointer on walk ticks", { Sprint11Scenarios.pointerOnWalkTicks($0, quick: $1) }, removing: [("pointerOnWalkTicks", .pointerOnWalkTicks)])
    }

    @Test func Pointer_theFiveSecondDeadlineSeesAPointerThatHasLeft() { holds("patience", Sprint11Scenarios.patienceSeesAPointerThatLeft(.all)) }

    @Test func Pointer_theFiveSecondDeadlineNegativeControl() {
        control("patience", { Sprint11Scenarios.patienceSeesAPointerThatLeft($0, quick: $1) }, removing: [("walkPatienceRechecks", .walkPatienceRechecks)])
    }

    @Test func Pointer_aWalkHomeAfterADictationLooksAtThePointerWhenItStarts() { holds("walk home", Sprint11Scenarios.pointerForTheWalkHome(.all)) }

    @Test func Pointer_aWalkHomeAfterADictationNegativeControl() {
        control("pointer for the walk home", { Sprint11Scenarios.pointerForTheWalkHome($0, quick: $1) }, removing: [("pointerOnWalkTicks", .pointerOnWalkTicks)])
    }

    @Test func Pointer_noIdleMotionStartsOverThePointerAndNoWalkStartsWithItOnThePath() { holds("before idle", Sprint11Scenarios.pointerBeforeAnIdleMotion(.all)) }

    @Test func Pointer_noIdleMotionStartsOverThePointerNegativeControl() {
        control("pointer before idle", { Sprint11Scenarios.pointerBeforeAnIdleMotion($0, quick: $1) }, removing: [("pointerBeforeIdle", .pointerBeforeIdle)])
    }

    @Test func Pointer_aWaitOnTheWayHomeEndsWithinFiveSecondsOfThePointerLeavingOnTheTicksAHostHasWhileClawdStands() {
        holds("homeward wait", Sprint11Scenarios.homewardWaitEndsWithinFiveSeconds(.all))
    }

    @Test func Pointer_aWaitOnTheWayHomeNegativeControl() {
        control("homeward wait", { Sprint11Scenarios.homewardWaitEndsWithinFiveSeconds($0, quick: $1) }, removing: [("walkHomewardRechecks", .walkHomewardRechecks)])
    }

    @Test func Pointer_aQuietConditionThatBeginsAtADueIdleSlotReadsNothingAndStartsNothing() { holds("quiet begins", Sprint11Scenarios.quietBeginsAtADueIdleSlot(.all)) }

    @Test func Pointer_aQuietConditionThatBeginsAtADueIdleSlotNegativeControl() {
        control("quiet begins", { Sprint11Scenarios.quietBeginsAtADueIdleSlot($0, quick: $1) }, removing: [("quietReasonFirst", .quietReasonFirst)])
    }

    @Test func Pointer_nothingIsReadInAQuietConditionAndTheSchedulerIsBackInStepWhenItEnds() { holds("quiet", Sprint11Scenarios.pointerAcrossAQuietCondition(.all)) }

    @Test func Pointer_nothingIsReadInAQuietConditionNegativeControl() {
        control("pointer across quiet", { Sprint11Scenarios.pointerAcrossAQuietCondition($0, quick: $1) }, removing: [("pointerAfterQuiet", .pointerAfterQuiet)])
    }
}

// MARK: the same rules on the integrated stage (real art, the merged timer with the renderer's own ticks)

private final class StageProbe {
    let clock = VirtualClock()
    let timer: FakeScheduler
    let run: IdleRenderRun
    var lines: [String] = []
    var ticks = 0
    var reads = 0
    var pointer: CGPoint?
    var offsets: [Double] = []
    init(seed: UInt64 = 7) throws {
        timer = FakeScheduler(clock: clock)
        var options = HeadlessOptions(); options.motion = .lively; options.seed = seed
        run = try IdleRenderRun(clock: clock, scheduler: timer, art: artDirectory, options: options, pixelScale: 2)
        let original = run.runtime.present
        run.runtime.present = { [unowned self] stage in self.offsets.append(stage.canvas.minX); original(stage) }
        run.runtime.log = { [unowned self] line in self.lines.append(line) }
        run.controller.machine.onChange = { [unowned self] _ in self.run.runtime.sceneChanged() }
        run.runtime.scheduler.pointerSource = { [unowned self] in self.reads += 1; return self.pointer }
        run.runtime.setQuiet(.aquaNotRunning, active: false)
        run.runtime.start()
    }
    var runtime: StageRuntime { run.runtime }
    func advance(_ seconds: Double) {
        let target = clock.now + seconds
        var steps = 0
        while let fire = timer.fireAt, fire <= target, steps < 200_000 {
            clock.advance(max(0, fire - clock.now)); timer.cancel(); runtime.tick(); ticks += 1; steps += 1
        }
        clock.advance(max(0, target - clock.now))
    }
    func advance(until condition: () -> Bool, limit: Double = 400, step: Double = 0.25) {
        var spent = 0.0
        while !condition(), spent < limit { advance(step); spent += step }
    }
    func lines(_ prefix: String) -> [String] { lines.filter { $0.hasPrefix(prefix) } }
    var x: Double { offsets.last ?? 0 }
}

@Suite("Sprint 11 stage", .serialized)
struct Sprint11StageTests {
    @Test func Pointer_everyTickOfAWalkReadsItAndNoTickOutsideAWalkOrBeforeAnIdleMotionDoes() throws {
        let probe = try StageProbe()
        probe.advance(until: { !probe.lines("WALK start").isEmpty })
        #expect(!probe.lines("WALK start").isEmpty)
        let readsAtStart = probe.reads, ticksAtStart = probe.ticks
        probe.advance(until: { !probe.lines("WALK end").isEmpty }, limit: 120, step: 0.5)
        #expect(!probe.lines("WALK end").isEmpty)
        let ticks = probe.ticks - ticksAtStart, reads = probe.reads - readsAtStart
        #expect(ticks > 20, "the walk had \(ticks) ticks")
        #expect(reads >= ticks - 2 && reads <= ticks + 1, "\(reads) reads for \(ticks) ticks of the walk: one per tick")
        // The wait for the next idle motion is the level's interval from the end of the walk (6 to 15 s at lively); Clawd blinks (a tick)
        // every 3 to 7 s meanwhile. Only the stretch before the next start is standing: a walk that begins reads on its own first tick.
        let starts = { probe.lines("WALK start").count + probe.lines("MOTION start").count }
        let startsBefore = starts()
        var standingReads = 0, standingTicks = 0
        for _ in 0..<60 {
            let reads = probe.reads, ticks = probe.ticks
            probe.advance(0.25)
            if starts() > startsBefore { break }
            standingReads += probe.reads - reads; standingTicks += probe.ticks - ticks
        }
        #expect(standingTicks >= 1, "the blinks tick")
        #expect(standingReads == 0, "no read while Clawd only stands: \(standingReads) in \(standingTicks) ticks")
    }

    @Test func Pointer_aWalkOnTheRealTicksStopsForThePointerWaitsForItToLeaveAndGoesHomeWhenItStays() throws {
        let probe = try StageProbe()
        probe.advance(until: { !probe.lines("WALK start").isEmpty })
        let geometry = HeadlessStage.geometry()
        probe.advance(until: { probe.x < geometry.homeOrigin.x - 20 }, limit: 20, step: 0.1)
        let width = geometry.width
        let ahead = { CGPoint(x: probe.x - 30, y: Double(geometry.homeOrigin.y) + 10) }
        probe.pointer = ahead()
        probe.advance(0.5)
        let stopped = probe.x
        probe.advance(3.0)
        #expect(probe.x == stopped, "Clawd stands while the pointer is in the way (\(stopped) -> \(probe.x))")
        probe.pointer = CGPoint(x: Double(geometry.displayFrame.maxX) - 10, y: Double(geometry.displayFrame.maxY) - 10)
        probe.advance(until: { probe.x < stopped - 5 }, limit: 8, step: 0.25)
        #expect(probe.x < stopped - 5, "Clawd goes on once the pointer left, seen on the ticks that exist while it stands (\(stopped) -> \(probe.x))")
        let again = probe.x
        probe.pointer = ahead()
        probe.advance(until: { probe.x > again + 3 }, limit: 12, step: 0.25)
        #expect(probe.x > again + 3, "and heads home when the pointer stays (\(again) -> \(probe.x), width \(width))")
        probe.pointer = nil
        probe.advance(until: { !probe.lines("WALK end").isEmpty }, limit: 60, step: 0.5)
        #expect(!probe.lines("WALK end").isEmpty)
    }

    /// Codex's finding B on round 1, on the integrated stage: the real art, the merged timer, the renderer's own ticks (none while Clawd stands)
    /// and a blink every 7 s (the worst case). Clawd stops on its way home for the pointer, which stays and then leaves just after a blink.
    @Test func Pointer_aWaitOnTheWayHomeEndsWithinFiveSecondsOfThePointerLeavingOnTheRealTicks() throws {
        let probe = try StageProbe()
        probe.run.controller.randomUnit = { 1.0 }              // every blink 7 s after the one before
        probe.advance(until: { !probe.lines("WALK start").isEmpty })
        let geometry = HeadlessStage.geometry()
        let homeX = Double(geometry.homeOrigin.x), homeY = Double(geometry.homeOrigin.y)
        var farthest = 0.0
        probe.advance(until: {
            farthest = max(farthest, abs(probe.x - homeX))
            return farthest > 20 && abs(probe.x - homeX) < farthest - 10          // out, the pause, and now the way home
        }, limit: 120, step: 0.1)
        #expect(abs(probe.x - homeX) < farthest - 10, "Clawd is on its way home (farthest \(farthest), now \(abs(probe.x - homeX)))")
        probe.pointer = CGPoint(x: probe.x + (homeX > probe.x ? 30 : -30), y: homeY + 10)      // on the way home
        probe.advance(0.5)
        let stopped = probe.x
        probe.advance(12.0)                                    // two re-checks and a blink or two: the pointer is still there
        #expect(probe.x == stopped, "Clawd stands while the pointer is in the way home (\(stopped) -> \(probe.x))")
        probe.advance(until: { probe.run.controller.state().blink }, limit: 10, step: 0.02)
        probe.advance(until: { !probe.run.controller.state().blink }, limit: 1, step: 0.005)
        #expect(!probe.run.controller.state().blink, "a blink has just ended")
        probe.pointer = nil                                    // the pointer leaves right after the blink; the next one is 7 s away
        let left = probe.clock.now
        probe.advance(until: { abs(probe.x - stopped) > 3 }, limit: 8, step: 0.05)
        let waited = probe.clock.now - left
        #expect(abs(probe.x - stopped) > 3, "Clawd goes on once the pointer left")
        #expect(waited <= 5.2, "and within 5 s of it leaving, not at the next blink: \(waited) s")
    }

    @Test func Pointer_aQuietConditionReadsNothingAndItsEndReadsOnce() throws {
        let probe = try StageProbe()
        probe.advance(until: { probe.reads > 0 })
        probe.runtime.setQuiet(.screenLocked, active: true)
        let atTheStart = probe.reads, ticks = probe.ticks
        probe.advance(1000)
        #expect(probe.ticks == ticks, "a quiet condition has no tick at all")
        #expect(probe.reads == atTheStart, "and so no read")
        probe.runtime.setQuiet(.screenLocked, active: false)
        #expect(probe.reads == atTheStart + 1, "the end of the quiet condition reads the pointer once: \(probe.reads - atTheStart)")
    }
}

@Suite("Sprint 11 pointer wiring", .serialized)
@MainActor
struct Sprint11PointerWiringTests {
    @Test func Pointer_theSchedulerReadsTheRuntimesEnvironmentPointer() async throws {
        let rig = try HardenRig()
        let source = try #require(rig.stage.scheduler.pointerSource, "the scheduler is given a pointer source")
        rig.machine.pointer = CGPoint(x: 321, y: 123)
        #expect(source() == CGPoint(x: 321, y: 123))
        rig.machine.pointer = CGPoint(x: 5, y: 6)
        #expect(source() == CGPoint(x: 5, y: 6), "it is read when asked, not remembered")
    }
}
